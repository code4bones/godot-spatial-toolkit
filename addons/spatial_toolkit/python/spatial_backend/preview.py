"""Portable GeoJSON map preparation; independent of the editor UI.

Run: python3 -m backend.preview samples/export.geojson
Requires existing pyproj and GEOS >= 3.10; never installs dependencies.
"""
import argparse
from collections import Counter, defaultdict
import hashlib
import json
import math
import platform
from pathlib import Path

from .building_overlap import coincident_buildings, coincident_walls
from .clearance_geometry import ClearanceGeometry
from .preview_geometry import FOUNDATION_BOTTOM, FOUNDATION_RENDER_TOP, Geometry, GeometryError, building_mesh, surface
from .facade_geometry import (
    MAX_MAP_OPENINGS, FacadeBudgetError, building_with_openings, choose_grid_stride,
    count_plan_at_stride, plan_facade, plan_limited_facade,
)


DEFAULT_WIDTHS = {"tertiary": 9.0, "residential": 6.0, "service": 4.0,
                  "footway": 2.0, "steps": 2.0, "path": 2.0, "cycleway": 2.5}


def positive_number(value):
    try:
        result = float(str(value).strip().removesuffix("m").strip())
        return result if math.isfinite(result) and result > 0 else None
    except (TypeError, ValueError):
        return None


def resolve_height(tags, default_height=3.0, level_height=3.0):
    """Resolve total/body/roof metres; OSM height already includes the roof.

    The mesh remains a flat extrusion to the total height. Roof dimensions are
    retained as evidence and do not imply that a roof shape was reconstructed.
    """
    if positive_number(default_height) is None or positive_number(level_height) is None:
        raise ValueError("Default height and level height must be finite positive metres")
    default_height, level_height = float(default_height), float(level_height)
    notes = []

    def roof_number(key):
        if key not in tags:
            return None
        try:
            value = float(str(tags[key]).strip().removesuffix("m").strip())
            if math.isfinite(value) and value >= 0:
                return value
        except (TypeError, ValueError):
            pass
        notes.append(f"Invalid {key} tag ignored (expected finite nonnegative value)")
        return None

    roof_height, roof_levels = roof_number("roof:height"), roof_number("roof:levels")
    if roof_height is not None:
        roof, roof_source = roof_height, "roof_height_tag"
    elif roof_levels is not None:
        roof, roof_source = roof_levels * level_height, "roof_levels_estimate"
        notes.append(f"Estimated roof height: roof:levels * {level_height:g} m")
    else:
        roof, roof_source = 0.0, "none"
    if not math.isfinite(roof):
        raise GeometryError("Estimated roof height exceeds finite metre range")

    height = positive_number(tags.get("height"))
    if height is not None:
        wall, source = max(0.0, height - roof), "height_tag"
        if roof > height:
            notes.append("Inconsistent roof height exceeds explicit total height; explicit total retained and wall height clamped to 0 m")
        if roof_source != "none":
            notes.append("Explicit height includes roof; roof height was not added to total")
    else:
        if "height" in tags:
            notes.append("Invalid height tag ignored")
        levels = positive_number(tags.get("building:levels"))
        if levels is not None:
            wall, source = levels * level_height, "levels_estimate"
            notes.append(f"Estimated height: building:levels * {level_height:g} m")
        else:
            if "building:levels" in tags:
                notes.append("Invalid building:levels tag ignored")
            wall, source = default_height, "default_estimate"
            notes.append(f"Unknown height: preview default {default_height:g} m")
            if roof_source != "none":
                notes.append("Unknown building body height: default body height plus known roof height")
        height = wall + roof
    if not math.isfinite(height):
        raise GeometryError("Estimated building height exceeds finite metre range")
    return {"height_m": height, "wall_height_m": wall, "roof_height_m": roof,
            "height_source": source, "roof_source": roof_source, "assumptions": notes}


def height_for(tags, default_height=3.0, level_height=3.0):
    """Legacy tuple facade for the central height resolver."""
    resolved = resolve_height(tags, default_height, level_height)
    return resolved["height_m"], resolved["height_source"], resolved["assumptions"]


def width_for(tags):
    width = positive_number(tags.get("width"))
    if width:
        return width, "width_tag", []
    lanes = positive_number(tags.get("lanes"))
    if lanes:
        return lanes * 3.2, "lanes_estimate", ["Estimated width: lanes * 3.2 m"]
    highway = tags.get("highway", "service")
    subtype = tags.get(highway, "service") if highway in ("proposed", "construction") else highway
    width = DEFAULT_WIDTHS.get(subtype, 4.0)
    return width, "type_estimate", [f"Unknown width: preview {subtype} default {width:g} m"]


def positions(value):
    if not isinstance(value, list) or not value:
        raise ValueError("Coordinates must be nonempty arrays")
    if isinstance(value[0], (float, int)):
        if len(value) < 2 or any(isinstance(v, bool) or not isinstance(v, (float, int)) for v in value):
            raise ValueError("Positions must contain numeric longitude/latitude")
        lon, lat = value[:2]
        if not (all(math.isfinite(v) for v in value) and -180 <= lon <= 180 and -90 <= lat <= 90):
            raise ValueError("Expected finite WGS84 longitude/latitude")
        yield lon, lat
    else:
        for child in value:
            yield from positions(child)


def validate_geometry(geometry):
    if not isinstance(geometry, dict):
        raise ValueError("Expected geometry object")
    kind, coordinates = geometry.get("type"), geometry.get("coordinates")
    points = list(positions(coordinates))
    def point(p):
        return isinstance(p, list) and len(p) >= 2 and isinstance(p[0], (int, float))
    def ring(r):
        return isinstance(r, list) and len(r) >= 4 and all(point(p) for p in r) and r[0][:2] == r[-1][:2]
    def polygon(p):
        return isinstance(p, list) and bool(p) and all(ring(r) for r in p)
    valid = (kind == "LineString" and len(coordinates) >= 2 and all(point(p) for p in coordinates)
             or kind == "Polygon" and polygon(coordinates)
             or kind == "MultiPolygon" and bool(coordinates) and all(polygon(p) for p in coordinates))
    if not valid:
        raise ValueError("Expected valid LineString or closed Polygon/MultiPolygon rings")
    return points


def prepare(source, output, default_height=3.0, level_height=3.0, overwrite=True,
            snapshot_source=False, world_scale=1.0, open_windows=False, window_density="auto",
            window_limit=6, window_every_n=5, breakable_windows=False):
    try:
        from pyproj import CRS, Transformer, __version__ as pyproj_version
    except ImportError as exc:
        raise RuntimeError("Map generation requires pyproj installed in the selected Python environment") from exc

    if positive_number(default_height) is None or positive_number(level_height) is None:
        raise ValueError("Default height and level height must be finite positive metres")
    if isinstance(world_scale, bool) or not isinstance(world_scale, (int, float)) or not math.isfinite(world_scale) or not 1 <= world_scale <= 100:
        raise ValueError("World scale must be a finite number between 1 and 100")
    if not isinstance(open_windows, bool):
        raise ValueError("Open windows must be a boolean")
    if window_density not in ("limited", "auto", "full"):
        raise ValueError("Window density must be 'limited', 'auto' or 'full'")
    for name, value in (("Window limit", window_limit), ("Window every N", window_every_n)):
        if isinstance(value, bool) or not isinstance(value, int) or not 1 <= value <= 1000:
            raise ValueError(f"{name} must be an integer between 1 and 1000")
    if breakable_windows and (not open_windows or window_density != "limited" or window_limit > 8):
        raise ValueError("Breakable windows require limited apertures with at most eight per building")
    world_scale = float(world_scale)
    default_height, level_height = float(default_height), float(level_height)
    source, output = Path(source), Path(output)
    if output.exists() and (not output.is_dir() or (not overwrite and any(output.iterdir()))):
        raise ValueError("Output directory must be new or empty; refusing to overwrite existing content")
    raw = source.read_bytes()
    doc = json.loads(raw)
    if not isinstance(doc, dict) or doc.get("type") != "FeatureCollection" or not isinstance(doc.get("features"), list):
        raise ValueError("Expected FeatureCollection")
    if doc.get("crs"):
        crs = doc["crs"]
        name = crs.get("properties", {}).get("name", "") if isinstance(crs, dict) and isinstance(crs.get("properties"), dict) else ""
        if name not in ("urn:ogc:def:crs:OGC:1.3:CRS84", "urn:ogc:def:crs:OGC::CRS84", "EPSG:4326"):
            raise ValueError(f"Unsupported declared CRS: {name}")
    features = doc["features"]
    validated, skipped, seen, all_points = [], [], set(), []
    for index, f in enumerate(features):
        fid = f"feature_{index}"
        try:
            if not isinstance(f, dict) or f.get("type") != "Feature":
                raise ValueError("Expected Feature object")
            tags = f.get("properties")
            tags = {} if tags is None else tags
            if not isinstance(tags, dict):
                raise ValueError("Feature properties must be an object or null")
            source_id = f.get("id", tags.get("@id", fid))
            if isinstance(source_id, bool) or not isinstance(source_id, (str, int, float)):
                raise ValueError("Feature ID must be a string or number")
            if isinstance(source_id, float) and not math.isfinite(source_id):
                raise ValueError("Feature ID must be finite")
            fid = str(source_id)
            if fid in seen:
                raise RuntimeError(f"Duplicate source ID: {fid}")
            seen.add(fid)
            if tags.get("building") not in (None, "no"):
                kind = "building"
            elif "highway" in tags:
                kind = "road"
            elif "landuse" in tags:
                kind = "landuse"
            elif tags.get("natural") == "water":
                kind = "water"
            elif tags.get("leisure") == "park":
                kind = "landuse"
            else:
                raise ValueError("Unsupported feature tags")
            for key in ("highway", "landuse", "proposed", "construction"):
                if key in tags and not isinstance(tags[key], str):
                    raise ValueError(f"Tag {key} must be a string")
            points = validate_geometry(f.get("geometry"))
            validated.append((fid, tags, kind, f["geometry"]))
            all_points.extend(points)
        except ValueError as exc:
            skipped.append({"id": fid, "reason": str(exc)})
    if not all_points:
        reasons = "; ".join(f"{s['id']}: {s['reason']}" for s in skipped[:5])
        raise ValueError("No usable features" + (f": {reasons}" if reasons else ""))
    lon = (min(p[0] for p in all_points) + max(p[0] for p in all_points)) / 2
    lat = (min(p[1] for p in all_points) + max(p[1] for p in all_points)) / 2
    projection = f"+proj=aeqd +lat_0={lat:.10f} +lon_0={lon:.10f} +datum=WGS84 +units=m +no_defs"
    transform = Transformer.from_crs("EPSG:4326", CRS.from_proj4(projection), always_xy=True)

    def project(value):
        if len(value) >= 2 and isinstance(value[0], (int, float)):
            x, north = transform.transform(*value[:2], errcheck=True)
            return [round(x, 6), round(-north, 6)]
        return [project(v) for v in value]

    provenance = {"path": source.as_posix(), "sha256": hashlib.sha256(raw).hexdigest(),
                  "generator": doc.get("generator"), "timestamp": doc.get("timestamp"),
                  "copyright": doc.get("copyright"), "crs": "EPSG:4326 / GeoJSON longitude,latitude"}
    model = {"version": "0.1", "source": provenance, "units": "meters",
             "local_origin": {"longitude": lon, "latitude": lat}, "projection": projection,
             "axes": {"x": "east", "y": "up", "z": "south"}, "features": []}
    game_transform = {"kind": "uniform_scale", "world_scale": world_scale,
                      "origin_local_m": [0, 0, 0], "source_units": "meters",
                      "game_units": "meters", "scope": "generated_geometry_only",
                      "drone_scaled": False}
    model["game_transform"] = game_transform
    report = {"source": provenance, "input_features": len(features), "generated": {},
              "height_sources": {}, "width_sources": {}, "polygon_holes": 0, "skipped": skipped,
              "limitations": ["Flat ground; no elevation data", "No collision, navigation or road lane markings",
                              "Road junctions use overlapping round buffers; no intersection or lane topology solving",
                              "Stairs rendered as flat paths; proposed and construction geometry is schematic",
                              "Building roof shapes and min_height are not modeled; flat extrusion reaches resolved total including roof", "Source extent is not clipped to a requested bbox"],
              "dependencies": {"python": platform.python_version(), "pyproj": pyproj_version,
                               "GEOS": ">=3.10 system C library"}}
    report["game_transform"] = game_transform
    foundation_assumption = "Gameplay-only wall foundation extends to -0.05 source-local m below the flat ground; source geometry and above-ground height evidence are unchanged"
    report["foundation"] = {"source_bottom_y_m": FOUNDATION_BOTTOM,
                            "bottom_y_m": FOUNDATION_BOTTOM * world_scale,
                            "render_top_source_y_m": FOUNDATION_RENDER_TOP,
                            "render_top_y_m": FOUNDATION_RENDER_TOP * world_scale,
                            "units": "meters", "assumption": foundation_assumption}
    report["facade_openings"] = {"enabled": open_windows, "count": 0, "buildings": 0,
                                  "buildings_without_openings": 0,
                                  "layout": "limited_exterior_windows" if window_density == "limited" else "edge_local_regular_grid",
                                  "interior": "empty_hall_no_intermediate_floors",
                                  "max_per_building": 10000, "max_per_map": MAX_MAP_OPENINGS,
                                  "density_mode": window_density, "grid_stride": 1,
                                  "estimated_full_count": 0, "planned_count": 0, "adjusted": False,
                                  "window_limit": window_limit, "window_every_n": window_every_n,
                                  "eligible_buildings": 0, "selected_buildings": 0}
    if open_windows:
        report["limitations"].append("Open windows and 0.2 m inward wall thickness are procedural assumptions, not measured facade data; hollow halls have base floors but no intermediate floors or rooms")
    if world_scale != 1:
        report["limitations"].append("Gameplay geometry is uniformly scaled from source-local metres; source dimensions and geography remain unscaled")
    mesh_items, seen = [], set()
    counts, heights, widths = Counter(), Counter(), Counter()
    network = defaultdict(set)
    bounds = [math.inf, math.inf, -math.inf, -math.inf]
    with Geometry() as geometry:
        report["dependencies"]["GEOS"] = geometry.version
        # Resolve/project once, then choose density before allocating any facade
        # triangles. Roof-only triangulation validates each building's topology;
        # invalid features are skipped once, never counted as eligible windows.
        prepared, full_plans = [], []
        for fid, tags, kind, g in validated:
            item = {"id": fid, "kind": kind, "source": {"id": fid, "tags": tags},
                    "assumptions": ["Ground elevation assumed 0 m"], "geometry": {"type": g.get("type"), "coordinates": project(g.get("coordinates", []))}}
            roofs, full_plan = None, None
            if kind == "building":
                try:
                    if g.get("type") not in ("Polygon", "MultiPolygon"):
                        raise GeometryError("Expected Polygon or MultiPolygon")
                    resolved = resolve_height(tags, default_height, level_height)
                    item.update({key: value for key, value in resolved.items() if key != "assumptions"})
                    item["assumptions"].extend(resolved["assumptions"])
                    if open_windows:
                        coord = item["geometry"]["coordinates"]
                        polygons = [coord] if g["type"] == "Polygon" else coord
                        roofs = [triangle for rings in polygons for triangle in geometry.polygon(rings)]
                        levels = positive_number(tags.get("building:levels"))
                        facade_floor_height = item["wall_height_m"] / levels if levels else level_height
                        full_plan = plan_facade(polygons, item["height_m"], item["wall_height_m"], facade_floor_height)
                        full_plans.append(full_plan)
                except GeometryError as exc:
                    report["skipped"].append({"id": fid, "reason": str(exc)})
                    continue
            prepared.append((fid, tags, kind, g, item, roofs, full_plan))
        # Legacy open-shell imports preserve their independently cut facades.
        # Glazed maps use the solid-wall ownership rules before selecting panes.
        resolve_overlap = not open_windows or breakable_windows
        redundant = coincident_buildings(prepared, geometry) if resolve_overlap else {}
        wall_cutoffs = coincident_walls(prepared, geometry, redundant) if resolve_overlap else {}
        if wall_cutoffs:
            report["coincident_wall_edges"] = {fid: len(edges) for fid, edges in sorted(wall_cutoffs.items())}
        aliases = defaultdict(list)
        for duplicate in redundant.values():
            aliases[duplicate["rendered_as"]].append(duplicate["id"])
        if redundant:
            report["coincident_buildings"] = [redundant[fid] for fid in sorted(redundant)]
        limited_selection = {}
        if window_density == "limited":
            grid_stride = 1
            building_rows = sorted((entry for entry in prepared
                                    if entry[2] == "building" and entry[0] not in redundant),
                                   key=lambda entry: entry[0])
            planned_count = 0
            for rank, entry in enumerate(building_rows):
                fid, _, _, _, _, _, full_plan = entry
                if full_plan is None:
                    continue
                selected = rank % window_every_n == 0 and fid not in wall_cutoffs
                selected_plan = plan_limited_facade(full_plan, window_limit) if selected else None
                limited_selection[fid] = (rank, selected, selected_plan)
                planned_count += selected_plan["count"] if selected else 0
            if planned_count > MAX_MAP_OPENINGS:
                raise FacadeBudgetError(
                    f"Limited window layout plans {planned_count} openings, exceeding the "
                    f"{MAX_MAP_OPENINGS} per-map budget. Reduce window limit, increase window "
                    "every N or import a smaller area; no buildings were silently omitted.")
        else:
            grid_stride = choose_grid_stride(full_plans, window_density, map_budget=MAX_MAP_OPENINGS)
            planned_count = sum(count_plan_at_stride(plan, grid_stride) for plan in full_plans)
        if breakable_windows:
            full_plans = [entry[6] for entry in prepared
                          if entry[6] is not None and entry[0] not in redundant and entry[0] not in wall_cutoffs]
        estimated_full_count = sum(plan["estimated_full_count"] for plan in full_plans)
        report["facade_openings"].update(
            grid_stride=grid_stride,
            estimated_full_count=estimated_full_count, planned_count=planned_count,
            eligible_buildings=sum(any(edge[1] == 0 and edge[8] > 0 for edge in plan["edges"])
                                   and plan["full_rows"] > 0 for plan in full_plans),
            selected_buildings=(sum(selected for _, selected, _ in limited_selection.values())
                                if window_density == "limited" else len(full_plans)),
            adjusted=(planned_count != estimated_full_count if window_density == "limited" else grid_stride > 1))
        for fid, tags, kind, g, item, roofs, full_plan in prepared:
            if fid in redundant:
                item["rendered_as"] = redundant[fid]["rendered_as"]
                item["assumptions"].append(redundant[fid]["reason"])
                model["features"].append(item)
                continue
            coord = item["geometry"]["coordinates"]
            facade_openings = {"enabled": False, "count": 0, "samples": []}
            try:
                if kind in ("building", "landuse", "water"):
                    if g.get("type") not in ("Polygon", "MultiPolygon"):
                        raise GeometryError("Expected Polygon or MultiPolygon")
                    polygons = [coord] if g["type"] == "Polygon" else coord
                    if kind == "building":
                        if open_windows:
                            rank, selected = 0, True
                            if window_density == "limited":
                                rank, selected, selected_plan = limited_selection[fid]
                            else:
                                selected_plan = (full_plan if grid_stride == 1 else plan_facade(
                                    polygons, item["height_m"], item["wall_height_m"], full_plan["floor_height"], grid_stride))
                            if window_density == "limited" and (not selected or selected_plan["count"] == 0):
                                v, n = building_mesh(geometry, polygons, item["height_m"], wall_cutoffs.get(fid))
                                facade_openings = {
                                    "enabled": True, "count": 0, "samples": [], "planned_count": 0,
                                    "selected": selected, "selection_rank": rank,
                                    "window_limit": window_limit, "window_every_n": window_every_n,
                                    "estimated_full_count": full_plan["estimated_full_count"],
                                    "floor_height_m": full_plan["floor_height"], "wall_thickness_m": 0.0,
                                    "foundation_bottom_y_m": FOUNDATION_BOTTOM,
                                    "foundation_render_top_y_m": FOUNDATION_RENDER_TOP,
                                    "density_mode": "limited", "grid_stride": 1,
                                    "layout": "limited_exterior_windows", "interior": "solid_source_massing_no_interior",
                                    "adjusted": full_plan["estimated_full_count"] > 0,
                                    "assumption": "Procedural limited windows; solid source massing retained for buildings without selected apertures",
                                    "no_openings_reason": (
                                        "shared_wall_cutoff" if fid in wall_cutoffs else
                                        "notselectedeveryN" if not selected else "No eligible exterior facade fits an aperture"
                                    ),
                                }
                            else:
                                v, n, facade_openings = building_with_openings(
                                    geometry, polygons, item["height_m"], item["wall_height_m"],
                                    full_plan["floor_height"], MAX_MAP_OPENINGS - report["facade_openings"]["count"],
                                    grid_stride=grid_stride, plan=selected_plan, roof_triangles=roofs)
                                if window_density == "limited":
                                    facade_openings.update(selection_rank=rank, window_every_n=window_every_n)
                            item["assumptions"].append(facade_openings["assumption"])
                        else:
                            v, n = building_mesh(geometry, polygons, item["height_m"], wall_cutoffs.get(fid))
                        style = "building_" + item["height_source"]
                    else:
                        v, n = [], []
                        # Large industrial/residential polygons form the background;
                        # grass sits above these, roads sit above all landuse.
                        landuse = tags.get("landuse", "grass")
                        y = 0.04 if kind == "water" else 0.025 if landuse == "grass" else 0.01
                        for rings in polygons:
                            pv, pn = surface(geometry.polygon(rings), y)
                            v.extend(pv); n.extend(pn)
                        style = "water" if kind == "water" else "land_" + landuse
                else:
                    if g.get("type") != "LineString":
                        raise GeometryError("Expected road LineString")
                    width, reason, notes = width_for(tags)
                    item.update(width_m=width, width_source=reason)
                    item["assumptions"].extend(notes)
                    status = tags["highway"] if tags["highway"] in ("proposed", "construction") else "existing"
                    path = tags["highway"] in ("footway", "path", "steps", "cycleway")
                    item["status"] = status
                    style = "road_" + (status if status != "existing" else "path" if path else "existing")
                    v, n = surface(geometry.road(coord, width), 0.10 if path else 0.08 if status == "existing" else 0.13)
                if not v:
                    raise GeometryError("Empty mesh")
            except GeometryError as exc:
                report["skipped"].append({"id": fid, "reason": str(exc)})
                continue
            if kind == "building":
                item["assumptions"].append(foundation_assumption)
                heights[item["height_source"]] += 1
                if open_windows:
                    report["facade_openings"]["count"] += facade_openings["count"]
                    report["facade_openings"]["buildings"] += int(facade_openings["count"] > 0)
                    report["facade_openings"]["buildings_without_openings"] += int(facade_openings["count"] == 0)
            if kind in ("building", "landuse", "water"):
                report["polygon_holes"] += sum(max(0, len(p) - 1) for p in polygons)
            if kind == "road":
                widths[item["width_source"]] += 1
                for p in coord:
                    network[tuple(p)].add(fid)
            source_dimensions = {key: item[key] for key in
                                 ("height_m", "wall_height_m", "roof_height_m", "width_m")
                                 if item.get(key) is not None}
            game_dimensions = {key: value * world_scale for key, value in source_dimensions.items()}
            if not all(math.isfinite(value) for value in game_dimensions.values()):
                raise ValueError(f"Scaled gameplay dimensions are non-finite for feature {fid}")
            # Apply one final transform to all geometry, including road buffers,
            # facade openings, reveals and flat-layer offsets. Source model and
            # resolved source dimensions above are deliberately never rewritten.
            if world_scale != 1.0:
                v = [[component * world_scale for component in vertex] for vertex in v]
                if facade_openings["enabled"]:
                    for key in ("floor_height_m", "wall_thickness_m", "base_floor_y_m", "foundation_bottom_y_m", "foundation_render_top_y_m"):
                        if key in facade_openings:
                            facade_openings[key] *= world_scale
                    for sample in facade_openings["samples"]:
                        sample["center"] = [component * world_scale for component in sample["center"]]
                        sample["width_m"] *= world_scale
                        sample["height_m"] *= world_scale
            if not all(math.isfinite(component) for vertex in v for component in vertex):
                raise ValueError(f"Scaled gameplay vertices are non-finite for feature {fid}")
            for x, _, z in v:
                bounds = [min(bounds[0], x), min(bounds[1], z), max(bounds[2], x), max(bounds[3], z)]
            layer = "Buildings" if kind == "building" else "Landuse" if kind == "landuse" else "Water" if kind == "water" else "PlannedRoads" if item["status"] != "existing" else "Paths" if path else "Roads"
            mesh_items.append({"id": fid, "layer": layer, "style": style, "vertices": v, "normals": n,
                               "tags": tags, "assumptions": item["assumptions"],
                               "height_m": item.get("height_m"), "wall_height_m": item.get("wall_height_m"),
                               "roof_height_m": item.get("roof_height_m"), "height_source": item.get("height_source"),
                               "roof_source": item.get("roof_source"), "width_m": item.get("width_m"),
                               "world_scale": world_scale, "source_dimensions_m": source_dimensions,
                               "game_dimensions_m": game_dimensions, "facade_openings": facade_openings,
                               **({"coincident_source_ids": sorted(aliases[fid])} if fid in aliases else {}),
                               **({"source_foundation_bottom_y_m": FOUNDATION_BOTTOM,
                                   "foundation_bottom_y_m": FOUNDATION_BOTTOM * world_scale,
                                   "source_foundation_render_top_y_m": FOUNDATION_RENDER_TOP,
                                   "foundation_render_top_y_m": FOUNDATION_RENDER_TOP * world_scale} if kind == "building" else {})})
            counts[layer] += 1
            model["features"].append(item)
    if not mesh_items:
        reasons = "; ".join(f"{s['id']}: {s['reason']}" for s in report["skipped"][:5])
        raise ValueError(f"No usable features generated: {reasons}")
    report["settings"] = {"default_height_m": default_height, "level_height_m": level_height,
                          "world_scale": world_scale, "open_windows": open_windows,
                          "window_density": window_density,
                          "window_limit": window_limit, "window_every_n": window_every_n}
    if breakable_windows:
        report["settings"]["breakable_windows"] = True
    model["road_shared_vertices"] = [{"position_xz": list(p), "feature_ids": sorted(ids)} for p, ids in sorted(network.items()) if len(ids) > 1]
    with ClearanceGeometry() as clearance:
        model["patrol_clearances"] = clearance.generate(model["features"], visual=False)["patrols"]
    report.update(generated=dict(counts), height_sources=dict(heights), width_sources=dict(widths),
                  shared_road_vertices=len(model["road_shared_vertices"]), bounds_xz_m=bounds,
                  triangles=sum(len(m["vertices"]) // 3 for m in mesh_items))
    output.mkdir(parents=True, exist_ok=True)
    if not overwrite and any(output.iterdir()):
        raise ValueError("Output directory must be new or empty; refusing to overwrite existing content")
    payloads = {"spatial": model, "meshes": {"source": provenance, "bounds_xz_m": bounds,
                 "projection": projection, "local_origin": model["local_origin"],
                 "world_scale": world_scale, "open_windows": open_windows,
                 "window_density": window_density,
                 "window_limit": window_limit, "window_every_n": window_every_n,
                 "game_transform": game_transform, "items": mesh_items}, "report": report}
    for suffix, payload in payloads.items():
        (output / f"export_preview.{suffix}.json").write_text(json.dumps(payload, ensure_ascii=False, indent=2 if suffix != "meshes" else None, allow_nan=False) + "\n", encoding="utf-8")
    if snapshot_source:
        # Use exactly the bytes already parsed and hashed, even if the external
        # source changes while processing. No second read can diverge from provenance.
        (output / "source.geojson").write_bytes(raw)
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path)
    parser.add_argument("--output", type=Path, default=Path("artifacts/export_preview"))
    parser.add_argument("--world-scale", type=float, default=1.0)
    parser.add_argument("--open-windows", action="store_true")
    parser.add_argument("--window-density", choices=("limited", "auto", "full"), default="auto")
    parser.add_argument("--window-limit", type=int, default=6)
    parser.add_argument("--window-every-n", type=int, default=5)
    args = parser.parse_args()
    report = prepare(args.source, args.output, world_scale=args.world_scale, open_windows=args.open_windows,
                     window_density=args.window_density, window_limit=args.window_limit,
                     window_every_n=args.window_every_n)
    print(json.dumps({k: v for k, v in report.items() if k not in ("source", "limitations")}, indent=2))


if __name__ == "__main__":
    main()
