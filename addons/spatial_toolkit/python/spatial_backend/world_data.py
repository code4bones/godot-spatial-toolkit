"""Project the canonical world registry into compact gameplay data.

Road centerlines and building footprints follow the source GeoJSON. Building
bounds come from the saved meshes selected by the bake. Road graph edges are
directed and join existing coordinate vertices within one layer/bridge/tunnel
group. Grade transitions need explicit links because GeoJSON omits OSM node IDs.
"""
import hashlib
import json
import math
import os
from pathlib import Path
import re
import tempfile

from .merge import OSM_ID
from .preview import _read_geojson, _with_progress, validate_geometry
from .world_chunks import _number, _previous_manifest


ROAD_KINDS = {"Roads", "Paths", "PlannedRoads"}
CITYGML_ID = re.compile(r"citygml/[A-Za-z0-9_.:-]+")
ROAD_Y = {"Roads": 0.08, "Paths": 0.10, "PlannedRoads": 0.13}
DRIVABLE = {
    "motorway", "trunk", "primary", "secondary", "tertiary", "motorway_link",
    "trunk_link", "primary_link", "secondary_link", "tertiary_link", "unclassified",
    "residential", "living_street", "service", "road", "track",
}


def _selector(path):
    value = json.loads(path.read_bytes())
    if not isinstance(value, dict) or not isinstance(value.get("roads"), dict) or not isinstance(value.get("buildings"), dict):
        raise ValueError("Bake feature selector must contain roads and buildings objects")
    for identity, kind in value["roads"].items():
        if not OSM_ID.fullmatch(identity) or not isinstance(kind, str) or kind not in ROAD_KINDS:
            raise ValueError("Invalid road identity or kind in bake feature selector")
    for identity, bounds in value["buildings"].items():
        if (not (OSM_ID.fullmatch(identity) or CITYGML_ID.fullmatch(identity))
                or not isinstance(bounds, list) or len(bounds) != 6
                or any(isinstance(v, bool) or not isinstance(v, (int, float)) or not math.isfinite(v) for v in bounds)
                or any(bounds[axis] > bounds[axis + 3] for axis in range(3))):
            raise ValueError("Building selector bounds must be six finite ordered gameplay coordinates")
    if value["roads"].keys() & value["buildings"].keys():
        raise ValueError("A baked source identity cannot be both a road and a building")
    return value


def _grade(tags):
    def flag(key):
        return str(tags.get(key, "no")).strip().lower() not in ("", "no", "false", "0")
    return str(tags.get("layer", "0")).strip(), flag("bridge"), flag("tunnel")


def _directions(tags):
    direction = str(tags.get("oneway", "")).strip().lower()
    if direction == "-1":
        return (-1,)
    if direction in ("yes", "true", "1") or (not direction and tags.get("junction") == "roundabout"):
        return (1,)
    return (1, -1)


def _road_graph(roads):
    points, edges, by_point, seen = [], [], {}, set()
    for identity, road in roads.items():
        tags = road["tags"]
        if road["kind"] != "Roads" or tags.get("highway") not in DRIVABLE:
            continue
        grade = _grade(tags)
        previous = None
        for point in road["points"]:
            key = (point[0], point[2], *grade)
            if key not in by_point:
                by_point[key] = len(points)
                points.append(point)
            current = by_point[key]
            if previous is not None and current != previous:
                for direction in _directions(tags):
                    edge = (previous, current, identity) if direction == 1 else (current, previous, identity)
                    if edge not in seen:
                        edges.append(list(edge))
                        seen.add(edge)
            previous = current
    return {"points": points, "edges": edges, "directed": True,
            "connectivity": "Shared coordinate vertices within equal layer/bridge/tunnel groups",
            "assumptions": ["No inferred crossing intersections or turn restrictions",
                            "Grade transitions need explicit links; OSM node IDs and elevation are absent"]}


def write_world_data(world, bake_features, output, *, progress=None):
    """Write atomically and return bounded transport counts, preserving input files."""
    paths = [Path(world), Path(bake_features), Path(output)]
    if any(not path.is_absolute() for path in paths):
        raise ValueError("World, bake feature selector and output paths must be absolute")
    world, bake_features, output = [path.resolve() for path in paths]
    if output in (world, bake_features) or output.exists():
        raise ValueError("World data output must be a new file")
    world_raw, selection_raw = world.read_bytes(), bake_features.read_bytes()
    index, registry = _previous_manifest(world)
    if output == registry:
        raise ValueError("World data output must preserve the canonical registry")
    scale = _number(index.get("world_scale"), "world_scale", 1, 100)
    selection = _selector(bake_features)
    registry_raw = registry.read_bytes()
    document = _read_geojson(registry_raw)
    from pyproj import CRS, Transformer
    transform = Transformer.from_crs("EPSG:4326", CRS.from_proj4(index["projection"]), always_xy=True)

    def project(pair):
        x, north = transform.transform(*pair[:2], errcheck=True)
        # Match prepare(): local metric coordinates round before gameplay scaling.
        result = [round(x, 6) * scale, round(-north, 6) * scale]
        if not all(math.isfinite(v) for v in result):
            raise ValueError("Projected coordinate exceeds finite gameplay range")
        return result

    wanted = set(selection["roads"]) | set(selection["buildings"])
    features = {}
    for feature in document["features"]:
        identity = feature.get("id") if isinstance(feature, dict) else None
        if identity in wanted:
            if identity in features:
                raise ValueError("Duplicate selected identity in world registry: " + identity)
            features[identity] = feature
    citygml_buildings = document.get("citygml_buildings", {})
    if not isinstance(citygml_buildings, dict):
        raise ValueError("Invalid CityGML building registry")
    for identity, feature in citygml_buildings.items():
        if identity not in wanted:
            continue
        if not CITYGML_ID.fullmatch(identity) or not isinstance(feature, dict) or feature.get("id") != identity:
            raise ValueError("Invalid CityGML building in world registry: " + identity)
        features[identity] = feature
    missing = wanted - features.keys()
    if missing:
        raise ValueError("Baked features absent from world registry: " + ", ".join(sorted(missing)[:5]))
    roads, buildings = {}, {}
    for identity in _with_progress(sorted(wanted), "world_data", progress):
        feature = features[identity]
        geometry = feature.get("geometry")
        validate_geometry(geometry)
        tags = feature.get("properties") or {}
        if not isinstance(tags, dict):
            raise ValueError("Feature properties must be an object: " + identity)
        if identity in selection["roads"]:
            if geometry["type"] != "LineString":
                raise ValueError("Selected road must be a LineString: " + identity)
            kind = selection["roads"][identity]
            points = [[point[0], ROAD_Y[kind] * scale, point[1]] for point in map(project, geometry["coordinates"])]
            roads[identity] = {"kind": kind, "tags": tags, "points": points}
        if identity in selection["buildings"]:
            if geometry["type"] not in ("Polygon", "MultiPolygon"):
                raise ValueError("Selected building must have polygon footprints: " + identity)
            polygons = [geometry["coordinates"]] if geometry["type"] == "Polygon" else geometry["coordinates"]
            footprints = [[[project(point) for point in ring] for ring in polygon] for polygon in polygons]
            buildings[identity] = {"tags": tags, "bounds": selection["buildings"][identity], "footprints": footprints}
            if "spatial_source" in feature and CITYGML_ID.fullmatch(identity):
                buildings[identity]["source"] = feature["spatial_source"]
    result = {"schema": 1, "units": "gameplay_meters", "axes": {"x": "east", "y": "up", "z": "south"},
              "local_origin": index["local_origin"], "projection": index["projection"], "world_scale": scale,
              "source_world": str(world), "source_world_sha256": hashlib.sha256(world_raw).hexdigest(),
              "source_revision": index["revision"], "source_registry": str(registry),
              "source_registry_sha256": hashlib.sha256(registry_raw).hexdigest(),
              "roads": roads, "buildings": buildings, "road_graph": _road_graph(roads),
              "assumptions": ["Road Y is the flat generated surface offset, without terrain elevation",
                              "Building bounds follow saved baked geometry; footprints follow canonical source polygons with holes",
                              "Source polygons and centerlines retain full objects that may extend beyond selected squares"]}
    encoded = (json.dumps(result, ensure_ascii=False, allow_nan=False, separators=(",", ":")) + "\n").encode("utf-8")
    if (world.read_bytes() != world_raw or bake_features.read_bytes() != selection_raw
            or registry.read_bytes() != registry_raw):
        raise ValueError("World data inputs changed during projection")
    output.parent.mkdir(parents=True, exist_ok=True)
    descriptor, name = tempfile.mkstemp(dir=output.parent, prefix=".world_data_")
    pending_path = Path(name)
    try:
        with os.fdopen(descriptor, "wb") as pending:
            pending.write(encoded)
            pending.flush()
            os.fsync(pending.fileno())
        # An exclusive hard-link publishes a complete file without replacing an existing result.
        os.link(pending_path, output)
    finally:
        pending_path.unlink(missing_ok=True)
    return {"ok": True, "road_count": len(roads), "building_count": len(buildings),
            "graph_point_count": len(result["road_graph"]["points"]),
            "graph_edge_count": len(result["road_graph"]["edges"]), "output": str(output)}
