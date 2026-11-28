"""Prepare additive, independently editable Godot scene cells."""
from collections import defaultdict
import hashlib
import json
import math
from pathlib import Path
import re

from .merge import merge_whole_osm
from .osm_rules import normalize_osm_rules
from .preview import MergeConflictError, _extent_origin, _validated_features, _with_progress, prepare, validate_geometry
from .preview_geometry import FootprintIndex, Geometry
from .regional_citygml import REGIONAL_DATASETS, read_regional_archive


SCHEMA = 1
DEFAULT_CHUNK_SIZE_M = 1000.0
CELL_ID = re.compile(r"chunk_-?[0-9]+_-?[0-9]+")
SHA256 = re.compile(r"[0-9a-f]{64}")
KALASATAMA_EXTRACT = "helsinki_kalasatama"
KALASATAMA_ARCHIVE = "helsinki_kalasatama_archive"
TUM2TWIN_LOD3 = "tum2twin_lod3"
TUM2TWIN_LOD3_FULL = "tum2twin_lod3_full"
SUPPLEMENTAL_CITYGML = {KALASATAMA_ARCHIVE, TUM2TWIN_LOD3, TUM2TWIN_LOD3_FULL, *REGIONAL_DATASETS}


def _number(value, field, minimum, maximum=math.inf):
    if (isinstance(value, bool) or not isinstance(value, (int, float))
            or not math.isfinite(value) or not minimum <= value <= maximum):
        raise ValueError(f"Invalid world {field}")
    return value


def _json_bytes(data):
    return (json.dumps(data, ensure_ascii=False, separators=(",", ":"), allow_nan=False) + "\n").encode("utf-8")


def _local_path(root, value, name):
    if not isinstance(value, str) or not value or Path(value).is_absolute():
        raise ValueError(f"World {name} must be a path relative to world.json")
    path = (root / value).resolve()
    if not path.is_relative_to(root) or path == root:
        raise ValueError(f"World {name} must stay within the world folder")
    return path


def _previous_manifest(path):
    if not path.is_absolute() or not path.is_file():
        raise ValueError("Previous world index must be an existing absolute path")
    path = path.resolve()
    manifest = json.loads(path.read_bytes())
    if not isinstance(manifest, dict) or _number(manifest.get("schema"), "schema", SCHEMA, SCHEMA) != SCHEMA:
        raise ValueError("Unsupported world index schema")
    revision = _number(manifest.get("revision"), "revision", 1)
    if revision != int(revision):
        raise ValueError("World revision must be an integer")
    local_origin = manifest.get("local_origin")
    if not isinstance(local_origin, dict):
        raise ValueError("Missing world WGS84 origin")
    origin = (_number(local_origin.get("longitude"), "longitude", -180, 180),
              _number(local_origin.get("latitude"), "latitude", -90, 90))
    if manifest.get("projection") != _projection(origin):
        raise ValueError("World projection must match its AEQD origin")
    sources = manifest.get("sources")
    if (not isinstance(sources, list) or not sources
            or any(not isinstance(value, str) or not Path(value).is_absolute() for value in sources)):
        raise ValueError("World sources must be absolute paths")
    records = manifest.get("source_records", [])
    if not isinstance(records, list) or any(
            not isinstance(record, dict)
            or not isinstance(record.get("path"), str)
            or not Path(record["path"]).is_absolute()
            or not isinstance(record.get("sha256"), str)
            or not SHA256.fullmatch(record["sha256"])
            for record in records):
        raise ValueError("Invalid world source provenance")
    chunks = manifest.get("chunks")
    if not isinstance(chunks, dict):
        raise ValueError("World chunk scene index is missing")
    for chunk, value in chunks.items():
        if not CELL_ID.fullmatch(chunk) or _local_path(path.parent, value, "chunk").name != f"{chunk}.tscn":
            raise ValueError(f"Invalid chunk scene index entry: {chunk}")
    registry = _local_path(path.parent, manifest.get("registry"), "registry")
    if not registry.is_file():
        raise ValueError("World registry is missing")
    return manifest, registry


def _projection(origin):
    longitude, latitude = origin
    return f"+proj=aeqd +lat_0={latitude:.10f} +lon_0={longitude:.10f} +datum=WGS84 +units=m +no_defs"


def _source_paths(sources):
    if not sources or any(not path.is_absolute() for path in sources):
        raise ValueError("Select at least one absolute GeoJSON source path")
    paths = list(dict.fromkeys(path.resolve() for path in sources))
    for path in paths:
        if path.suffix.lower() not in (".geojson", ".json") or not path.is_file():
            raise ValueError(f"Expected an existing GeoJSON source: {path}")
    return paths


def _pending_sources(sources, source_records, progress):
    fingerprints = {(record["path"], record["sha256"]) for record in source_records}
    known_paths = {path for path, _ in fingerprints}
    pending = []
    for path in _with_progress(sources, "sources", progress):
        if str(path) in known_paths:
            digest = hashlib.sha256()
            with path.open("rb") as source:
                for block in iter(lambda: source.read(1024 * 1024), b""):
                    digest.update(block)
            if (str(path), digest.hexdigest()) in fingerprints:
                continue
        pending.append(path)
    return pending


def _cell_bounds(cell, size):
    x, z = cell
    return [x * size, z * size, (x + 1) * size, (z + 1) * size]


def _clipped_edge(a, b, axis, boundary):
    # Identical crossings on adjacent triangles are calculated in the same direction.
    start, end = (a, b) if a < b else (b, a)
    fraction = (boundary - start[axis]) / (end[axis] - start[axis])
    point = [round(start[index] + fraction * (end[index] - start[index]), 9)
             for index in (0, 1, 2)]
    point[axis] = boundary
    return point


def _clip_axis(polygon, axis, boundary, lower):
    points = []
    start = polygon[-1]
    start_inside = start[axis] >= boundary if lower else start[axis] <= boundary
    for end in polygon:
        end_inside = end[axis] >= boundary if lower else end[axis] <= boundary
        if start_inside != end_inside:
            points.append(_clipped_edge(start, end, axis, boundary))
        if end_inside:
            points.append(end)
        start, start_inside = end, end_inside
    return points


def _twice_area(a, b, c):
    return (b[0] - a[0]) * (c[2] - a[2]) - (b[2] - a[2]) * (c[0] - a[0])


def _clip_triangle(triangle, bounds):
    polygon = triangle
    for axis, boundary, lower in ((0, bounds[0], True), (0, bounds[2], False),
                                  (2, bounds[1], True), (2, bounds[3], False)):
        polygon = _clip_axis(polygon, axis, boundary, lower)
        if len(polygon) < 3:
            return
    for index in range(1, len(polygon) - 1):
        fan_triangle = polygon[0], polygon[index], polygon[index + 1]
        if abs(_twice_area(*fan_triangle)) > 1e-12:
            yield from fan_triangle


def _flat_fragments(item, size):
    vertices = item["vertices"]
    for offset in range(0, len(vertices), 3):
        triangle = vertices[offset:offset + 3]
        xs = [vertex[0] for vertex in triangle]
        zs = [vertex[2] for vertex in triangle]
        x_first, x_last = math.floor(min(xs) / size), math.ceil(max(xs) / size) - 1
        z_first, z_last = math.floor(min(zs) / size), math.ceil(max(zs) / size) - 1
        if (x_first, z_first) == (x_last, z_last):
            yield (x_first, z_first), triangle
            continue
        for x in range(x_first, x_last + 1):
            for z in range(z_first, z_last + 1):
                cell = (x, z)
                clipped = list(_clip_triangle(triangle, _cell_bounds(cell, size)))
                if clipped:
                    yield cell, clipped


def _bounds(vertices):
    return [min(v[0] for v in vertices), min(v[2] for v in vertices),
            max(v[0] for v in vertices), max(v[2] for v in vertices)]


def _partition(items, size, progress):
    cells = defaultdict(list)
    for item in _with_progress(items, "partition", progress):
        vertices = item["vertices"]
        if item["layer"] == "Buildings":
            x_min, z_min, x_max, z_max = _bounds(vertices)
            cell = (math.floor((x_min + x_max) / (2 * size)),
                    math.floor((z_min + z_max) / (2 * size)))
            cells[cell].append(item)
            continue
        fragments = defaultdict(list)
        for cell, clipped in _flat_fragments(item, size):
            fragments[cell].extend(clipped)
        # The source generator produces horizontal surfaces with a uniform up normal.
        normal = item["normals"][0]
        for cell, clipped in fragments.items():
            cells[cell].append({**item, "vertices": clipped, "normals": [normal] * len(clipped)})
    return cells


def _write_cells(output, meshes, provenance, size, progress):
    cells = _partition(meshes.pop("items"), size, progress)
    if progress is not None:
        progress("write", 0, 0)
    directory = output / "payloads"
    directory.mkdir()
    results = []
    for cell, items in sorted(cells.items()):
        cell_id = f"chunk_{cell[0]}_{cell[1]}"
        bounds = _cell_bounds(cell, size)
        view = list(bounds)
        for item in items:
            if item["layer"] == "Buildings":
                low_x, low_z, high_x, high_z = _bounds(item["vertices"])
                view = [min(view[0], low_x), min(view[1], low_z), max(view[2], high_x), max(view[3], high_z)]
        payload = {**meshes, "source": provenance, "items": items, "bounds_xz_m": view}
        path = directory / f"{cell_id}.json"
        path.write_bytes(_json_bytes(payload))
        results.append({"id": cell_id, "payload": str(path), "bounds": bounds})
    return results


def _citygml_requests(records):
    requests = []
    for record in records:
        source = record.get("source", {})
        if not isinstance(source, dict) or "citygml" not in source:
            continue
        dataset = source["citygml"]
        if (not isinstance(dataset, dict) or dataset.get("id") not in (KALASATAMA_EXTRACT, *SUPPLEMENTAL_CITYGML)
                or not isinstance(dataset.get("path"), str) or not Path(dataset["path"]).is_absolute()
                or not isinstance(dataset.get("sha256"), str) or not SHA256.fullmatch(dataset["sha256"])):
            raise ValueError("Invalid CityGML source. Fetch the area again in Map Areas.")
        if (dataset["id"] in SUPPLEMENTAL_CITYGML
                and (not isinstance(source.get("layers"), list) or "buildings" not in source["layers"])):
            raise ValueError("Fetch the OSM buildings layer when using a supplemental CityGML archive.")
        bbox = source.get("bbox")
        if not isinstance(bbox, dict):
            raise ValueError("CityGML requires the original WGS84 area bounds")
        box = {key: _number(bbox.get(key), key, -limit, limit)
               for key, limit in (("west", 180), ("south", 90), ("east", 180), ("north", 90))}
        if not (box["west"] < box["east"] and box["south"] < box["north"]):
            raise ValueError("CityGML area bounds are reversed or empty")
        requests.append((dataset, box))
    return requests


def _osm_buildings_in_boxes(features, boxes):
    if not boxes or not features:
        return set()
    result = set()
    with Geometry() as geometry:
        for feature in features:
            tags = feature.get("properties")
            shape = feature["geometry"]
            if (not isinstance(tags, dict) or tags.get("building") in (None, "no")
                    or shape.get("type") not in ("Polygon", "MultiPolygon")):
                continue
            try:
                polygons, bounds = _polygons_and_bounds(shape)
            except ValueError:
                continue  # The regular geometry generator reports unusable OSM features.
            for box in boxes:
                west, south, east, north = (box[key] for key in ("west", "south", "east", "north"))
                if (bounds[2] >= west and bounds[0] <= east and bounds[3] >= south and bounds[1] <= north
                        and geometry.intersects_box(polygons, west, south, east, north)):
                    result.add(feature["id"])
                    break
    return result


def _polygons_and_bounds(shape):
    polygons = [shape["coordinates"]] if shape["type"] == "Polygon" else shape["coordinates"]
    return polygons, _extent_bounds(validate_geometry(shape))


def _osm_buildings_matching_archive(features, archived):
    """Replace OSM only when exactly one measured footprint largely agrees."""
    if not features or not archived:
        return set()
    candidates = FootprintIndex((identity, *_polygons_and_bounds(feature["geometry"]))
                                for identity, feature in archived.items())
    matches = set()
    with Geometry() as geometry:
        for feature in features:
            tags = feature.get("properties")
            shape = feature["geometry"]
            if (not isinstance(tags, dict) or tags.get("building") in (None, "no")
                    or shape.get("type") not in ("Polygon", "MultiPolygon")):
                continue
            try:
                polygons, bounds = _polygons_and_bounds(shape)
            except ValueError:
                continue
            agreed = 0
            for _, measured in candidates.candidates(bounds):
                osm_share, citygml_share = geometry.footprint_overlap(polygons, measured)
                if osm_share >= 0.8 and citygml_share >= 0.8:
                    agreed += 1
                    if agreed > 1:
                        break
            if agreed == 1:
                matches.add(feature["id"])
    return matches


def _extent_bounds(points):
    xs, ys = zip(*points)
    return min(xs), min(ys), max(xs), max(ys)


def _citygml_additions(old_requests, requests, old_registry, registry, features, known_ids, projection, scale, progress):
    from .citygml import read_helsinki, read_helsinki_archive, read_tum_archive

    groups = defaultdict(list)
    for dataset, box in requests:
        groups[dataset["id"], Path(dataset["path"]), dataset["sha256"]].append(box)
    hashes = defaultdict(set)
    for dataset, _ in [*old_requests, *requests]:
        hashes[dataset["id"]].add(dataset["sha256"])
    if any(len(values) > 1 for values in hashes.values()):
        raise ValueError("A CityGML source changed. Create a new world to use the updated data.")

    old_boxes = [box for dataset, box in old_requests if dataset["id"] == KALASATAMA_EXTRACT]
    new_boxes = [box for dataset, box in requests if dataset["id"] == KALASATAMA_EXTRACT]
    previous = json.loads(old_registry.read_bytes()) if old_requests else {}
    buildings = previous.get("citygml_buildings", {})
    if not isinstance(buildings, dict):
        raise ValueError("Invalid CityGML building registry in the previous world")
    archive_ids = previous.get("citygml_archive_ids", [])
    if (not isinstance(archive_ids, list)
            or any(not isinstance(identity, str) or identity not in buildings for identity in archive_ids)):
        raise ValueError("Invalid archive references in the previous CityGML world")
    old_archived = {identity: buildings[identity] for identity in archive_ids}
    archived = dict(old_archived)
    equivalent_ids = {alias for feature in old_archived.values()
                      for alias in feature.get("spatial_source", {}).get("equivalent_citygml_ids", ())}
    mesh_items = []
    archive_skips = {}
    archive_readers = {KALASATAMA_ARCHIVE: read_helsinki_archive,
                       TUM2TWIN_LOD3: read_tum_archive, TUM2TWIN_LOD3_FULL: read_tum_archive}
    for (dataset_id, path, digest), boxes in groups.items():
        if dataset_id in REGIONAL_DATASETS:
            selected = read_regional_archive(dataset_id, path, digest, boxes, projection, scale,
                                             on_skipped=archive_skips.update, progress=progress)
        elif dataset_id in archive_readers:
            selected = archive_readers[dataset_id](path, digest, boxes, projection, scale, on_skipped=archive_skips.update)
        else:
            selected = read_helsinki(path, digest, boxes, projection, scale)
        for identity, (mesh, feature) in selected.items():
            if identity in equivalent_ids:
                continue
            aliases = feature.get("spatial_source", {}).get("equivalent_citygml_ids", ())
            if any(alias in old_archived for alias in aliases):
                raise ValueError("This world already contains an alternate CityGML building covered by a landmark. "
                                 "Create a new world to replace it.")
            if dataset_id in SUPPLEMENTAL_CITYGML:
                archived[identity] = buildings.get(identity, feature)
            if identity not in buildings:
                buildings[identity] = feature
                mesh_items.append(mesh)

    prior_features = features[:known_ids]
    prior_overlap = _osm_buildings_in_boxes(prior_features, new_boxes)
    if archived.keys() != old_archived.keys():
        prior_overlap |= _osm_buildings_matching_archive(prior_features, archived)
    if prior_overlap:
        already_suppressed = (_osm_buildings_in_boxes(prior_features, old_boxes)
                              | _osm_buildings_matching_archive(prior_features, old_archived))
        if prior_overlap - already_suppressed:
            raise ValueError("This world already has OSM buildings in the CityGML area. Create a new world to replace them.")
    registry["citygml_buildings"] = buildings
    if archived:
        registry["citygml_archive_ids"] = sorted(archived)
    new_features = features[known_ids:]
    suppressed = (_osm_buildings_in_boxes(new_features, [*old_boxes, *new_boxes])
                  | _osm_buildings_matching_archive(new_features, archived))
    return mesh_items, suppressed, archive_skips


def prepare_world_chunks(sources, output, *, previous=None, chunk_size=DEFAULT_CHUNK_SIZE_M, world_scale=1.0,
                         default_height=3.0, level_height=3.0, progress=None, osm_rules=None):
    """Write a pending world revision without touching its previous index or scenes."""
    if not output.is_absolute() or (output.exists() and (not output.is_dir() or any(output.iterdir()))):
        raise ValueError("World output directory must be absolute and new or empty")
    output = output.resolve()
    sources = _source_paths(sources)
    manifest, old_registry = _previous_manifest(previous) if previous is not None else ({}, None)
    chunk_size = _number(manifest.get("chunk_size_m", chunk_size), "chunk_size_m", 1e-6)
    world_scale = _number(manifest.get("world_scale", world_scale), "world_scale", 1, 100)
    default_height = _number(manifest.get("default_height_m", default_height), "default_height_m", 1e-6)
    level_height = _number(manifest.get("level_height_m", level_height), "level_height_m", 1e-6)
    osm_rules = normalize_osm_rules(manifest.get("osm_rules") if previous is not None else osm_rules)
    size = chunk_size * world_scale
    if not math.isfinite(size):
        raise ValueError("Scaled chunk size must be finite")

    pending = _pending_sources(sources, manifest.get("source_records", []), progress)
    inputs = [old_registry, *pending] if old_registry is not None else pending
    registry, merge = merge_whole_osm(_with_progress(inputs, "merge", progress))
    for path, record in zip(inputs, merge["sources"]):
        record["path"] = str(path)
    if registry is None:
        output.mkdir(parents=True, exist_ok=True)
        (output / "merge_conflicts.json").write_bytes(_json_bytes(merge))
        raise MergeConflictError(merge)

    new_source_records = merge["sources"][1:] if old_registry is not None else merge["sources"]
    known_ids = merge["sources"][0]["new_ids"] if old_registry is not None else 0
    features = registry["features"]
    old_citygml = _citygml_requests(manifest.get("source_records", []))
    new_citygml = _citygml_requests(new_source_records)
    if old_registry is not None:
        origin = (manifest["local_origin"]["longitude"], manifest["local_origin"]["latitude"])
    else:
        base = features[:new_source_records[0]["new_ids"]]
        if not base and new_citygml:
            box = new_citygml[0][1]
            origin = ((box["west"] + box["east"]) / 2, (box["south"] + box["north"]) / 2)
        else:
            _, _, points = _validated_features({"features": base})
            origin = _extent_origin(points)
    projection = _projection(origin)
    local_origin = dict(zip(("longitude", "latitude"), origin))
    registry_paths = list(dict.fromkeys([*manifest.get("sources", []), *map(str, sources)]))
    records = {(row.get("path"), row.get("sha256")): row for row in manifest.get("source_records", [])}
    seen_records = len(records)
    offset = known_ids
    for record in new_source_records:
        records.setdefault((record["path"], record["sha256"]), record)
        end = offset + record["new_ids"]
        for feature in features[offset:end]:
            feature["spatial_source"] = {"path": record["path"], "sha256": record["sha256"]}
        offset = end

    new_features = features[known_ids:]
    citygml_items, suppressed, archive_skips = [], set(), {}
    if old_citygml or new_citygml:
        citygml_items, suppressed, archive_skips = _citygml_additions(
            old_citygml, new_citygml, old_registry, registry, features, known_ids, projection, world_scale, progress)
        for record in new_source_records:
            dataset = record.get("source", {}).get("citygml")
            if dataset is not None and dataset["id"] == KALASATAMA_EXTRACT:
                record["verified_citygml_sha256"] = dataset["sha256"]
    osm_geometry = [feature for feature in new_features if feature["id"] not in suppressed] if suppressed else new_features
    registry_path = output / "source.geojson"
    registry_data = _json_bytes(registry)
    provenance = {"path": str(registry_path), "sha256": hashlib.sha256(registry_data).hexdigest(),
                  "generator": registry.get("generator"), "copyright": registry.get("copyright"),
                  "crs": "EPSG:4326 / GeoJSON longitude,latitude", "merge_sources": registry_paths}
    output.mkdir(parents=True, exist_ok=True)
    skipped = 0
    cells = []
    if osm_geometry or citygml_items or suppressed or archive_skips:
        # Keep the canonical registry separate from the new-only geometry input.
        meshes = {"items": [], "local_origin": local_origin, "projection": projection,
                  "world_scale": world_scale, "osm_rules": osm_rules}
        report = {"skipped": []}
        if osm_geometry:
            additions = output / "added.geojson"
            additions.write_bytes(_json_bytes({"type": "FeatureCollection", "features": osm_geometry}))
            report = prepare(additions, output / "unused", default_height, level_height,
                             overwrite=False, world_scale=world_scale, local_origin=origin,
                             mesh_output=meshes.update, patrol_clearances=False, progress=progress,
                             osm_rules=osm_rules)
        if citygml_items or suppressed or archive_skips:
            meshes["items"].extend(citygml_items)
            report["citygml"] = {"new_buildings": len(citygml_items), "suppressed_osm_buildings": sorted(suppressed),
                                "archive_skipped_count": len(archive_skips),
                                "archive_skipped": dict(sorted(archive_skips.items())[:20])}
        skipped = len(report["skipped"])
        (output / "report.json").write_bytes(_json_bytes(report))
        cells = _write_cells(output, meshes, provenance, size, progress)

    registry_path.write_bytes(registry_data)
    plan = {
        "manifest": {"schema": SCHEMA, "local_origin": local_origin, "projection": projection,
                     "chunk_size_m": chunk_size, "world_scale": world_scale,
                     "default_height_m": default_height, "level_height_m": level_height,
                     "osm_rules": osm_rules,
                     "sources": registry_paths, "source_records": list(records.values())},
        "cells": cells,
        "summary": {"source_count": len(registry_paths), "unique_osm_ids": len(features),
                    "processed_sources": len(pending), "unchanged_sources": len(sources) - len(pending),
                    "identical_duplicates": merge["identical_duplicates"], "new_ids": len(new_features),
                    "new_sources": len(records) - seen_records, "skipped_count": skipped,
                    "touched_chunks": len(cells)},
    }
    if old_citygml or new_citygml:
        plan["summary"].update(citygml_buildings=len(citygml_items), suppressed_osm_buildings=len(suppressed))
    if archive_skips:
        plan["summary"]["citygml_skipped_buildings"] = len(archive_skips)
    path = output / "plan.json"
    path.write_bytes(_json_bytes(plan))
    return path
