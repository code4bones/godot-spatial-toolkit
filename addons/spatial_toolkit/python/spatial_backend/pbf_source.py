"""Read a local OSM PBF header or extract complete features for a batch of areas.

Header inspection uses Python's standard library. Extraction uses GDAL's OSM
reader, which assembles ways and multipolygon relations before spatial filtering.
All coordinates and output geometries remain WGS84 longitude and latitude.
"""
from collections import Counter
from datetime import datetime, timezone
import json
import math
from pathlib import Path
import struct
import sys
import zlib

LAYERS = ("buildings", "roads", "water", "landuse", "parks")
MAX_HEADER_BYTES = 64 * 1024
MAX_BLOB_BYTES = 32 * 1024 * 1024


def _varint(data, offset):
    value = 0
    for shift in range(0, 70, 7):
        if offset >= len(data):
            raise ValueError("Truncated PBF field.")
        byte = data[offset]
        offset += 1
        value |= (byte & 127) << shift
        if byte < 128:
            return value, offset
    raise ValueError("Invalid PBF integer.")


def _fields(data):
    offset = 0
    result = {}
    while offset < len(data):
        key, offset = _varint(data, offset)
        field, wire = key >> 3, key & 7
        if not field:
            raise ValueError("Invalid PBF field number.")
        if wire == 0:
            value, offset = _varint(data, offset)
        elif wire == 2:
            size, offset = _varint(data, offset)
            end = offset + size
            if end > len(data):
                raise ValueError("Truncated PBF field.")
            value, offset = data[offset:end], end
        else:
            raise ValueError("Unsupported PBF header field encoding.")
        result.setdefault(field, []).append(value)
    return result


def _read_exact(stream, size):
    data = stream.read(size)
    if len(data) != size:
        raise ValueError("Truncated PBF header.")
    return data


def _validate_bbox(raw):
    if not isinstance(raw, dict):
        raise ValueError("The area must have a WGS84 bounding box.")
    bbox = {}
    for key in ("south", "west", "north", "east"):
        value = raw.get(key)
        if isinstance(value, bool) or not isinstance(value, (float, int)) or not math.isfinite(value):
            raise ValueError("Bounding box coordinates must be finite numbers.")
        bbox[key] = float(value)
    if not -90 <= bbox["south"] < bbox["north"] <= 90:
        raise ValueError("The area has invalid latitude bounds.")
    if not -180 <= bbox["west"] <= 180 or not -180 <= bbox["east"] <= 180 or bbox["west"] == bbox["east"]:
        raise ValueError("The area has invalid longitude bounds.")
    return bbox


def read_header(path):
    """Return declared coverage and snapshot metadata without reading entity data."""
    path = Path(path).expanduser().resolve(strict=True)
    if not path.is_file() or path.suffix.lower() != ".pbf":
        raise ValueError("Select an OSM .pbf file.")
    stat = path.stat()
    with path.open("rb") as stream:
        size = struct.unpack(">I", _read_exact(stream, 4))[0]
        if not 0 < size <= MAX_HEADER_BYTES:
            raise ValueError("Invalid PBF block header size.")
        block = _fields(_read_exact(stream, size))
        if block.get(1) != [b"OSMHeader"]:
            raise ValueError("The file does not start with an OSM PBF header.")
        blob_size = block.get(3, [0])[0]
        if not 0 < blob_size <= MAX_BLOB_BYTES:
            raise ValueError("Invalid PBF header payload size.")
        blob = _fields(_read_exact(stream, blob_size))
    if 1 in blob:
        raw = blob[1][0]
    elif 3 in blob:
        decoder = zlib.decompressobj()
        raw = decoder.decompress(blob[3][0], MAX_BLOB_BYTES + 1)
        if len(raw) > MAX_BLOB_BYTES or not decoder.eof:
            raise ValueError("Invalid compressed PBF header.")
    else:
        raise ValueError("Unsupported compression for the PBF header.")
    header = _fields(raw)
    required = {value.decode("utf-8") for value in header.get(4, [])}
    unsupported = required - {"OsmSchema-V0.6", "DenseNodes"}
    if unsupported:
        raise ValueError("Unsupported PBF features: " + ", ".join(sorted(unsupported)))
    if 1 not in header:
        raise ValueError("This PBF file does not declare its geographic bounds.")
    bounds = _fields(header[1][0])
    coordinates = {}
    for field, name in enumerate(("west", "east", "north", "south"), 1):
        encoded = bounds.get(field, [None])[0]
        if encoded is None:
            raise ValueError("The PBF header has incomplete bounds.")
        coordinates[name] = ((encoded >> 1) ^ -(encoded & 1)) / 1e9
    result = {"bbox": _validate_bbox(coordinates), "path": str(path), "size": stat.st_size,
              "mtime": stat.st_mtime, "mtime_ns": stat.st_mtime_ns}
    if 32 in header:
        result["timestamp"] = datetime.fromtimestamp(header[32][0], timezone.utc).isoformat().replace("+00:00", "Z")
    return result


def _osm_config():
    lines = ["[general]", "closed_ways_are_polygons=building,landuse,natural,leisure,area=yes",
             "attribute_name_laundering=no", "report_all_tags=yes", "tags_format=json"]
    for layer in ("points", "lines", "multipolygons", "multilinestrings", "other_relations"):
        lines.extend(["", "[" + layer + "]", "osm_id=yes",
                      "attributes=building,highway,landuse,natural,leisure", "ignore=", "all_tags=yes"])
    return "\n".join(lines) + "\n"


def _layer(tags):
    if tags.get("building", "no") != "no":
        return "buildings"
    if "highway" in tags:
        return "roads"
    if "landuse" in tags:
        return "landuse"
    if tags.get("natural") == "water":
        return "water"
    if tags.get("leisure") == "park":
        return "parks"
    return ""


def _bbox_parts(bbox):
    west, east = bbox["west"], bbox["east"]
    spans = [(west, east)] if east > west else [(west, 180.0), (-180.0, east)]
    return [(left, bbox["south"], right, bbox["north"]) for left, right in spans if left < right]


def _rectangle(ogr, bounds):
    west, south, east, north = bounds
    ring = ogr.Geometry(ogr.wkbLinearRing)
    for x, y in ((west, south), (east, south), (east, north), (west, north), (west, south)):
        ring.AddPoint_2D(x, y)
    polygon = ogr.Geometry(ogr.wkbPolygon)
    polygon.AddGeometry(ring)
    return polygon


def _covers(coverage, bbox):
    if bbox["south"] < coverage["south"] or bbox["north"] > coverage["north"]:
        return False
    coverage_parts = _bbox_parts(coverage)
    return all(any(outer[0] <= part[0] and outer[2] >= part[2] for outer in coverage_parts)
               for part in _bbox_parts(bbox))


def _write_json(path, value):
    temporary = path.with_suffix(path.suffix + ".tmp")
    with temporary.open("w", encoding="utf-8") as stream:
        json.dump(value, stream, ensure_ascii=False, separators=(",", ":"), allow_nan=False)
    temporary.replace(path)


def extract(request, staging):
    """Extract a batch in one source pass, retaining full intersecting features."""
    if not isinstance(request, dict):
        raise ValueError("The PBF extraction request must be an object.")
    try:
        from osgeo import gdal, ogr
    except ImportError as error:
        raise ValueError("Local PBF extraction requires the GDAL Python package with the OSM driver.") from error
    if gdal.GetDriverByName("OSM") is None:
        raise ValueError("The configured Python GDAL installation has no OSM driver.")
    if int(gdal.VersionInfo("VERSION_NUM")) < 3100000:
        raise ValueError("Local PBF extraction requires GDAL 3.10 or newer.")
    header = read_header(request["path"])
    layers = request.get("layers")
    if not isinstance(layers, list) or not layers or any(layer not in LAYERS for layer in layers):
        raise ValueError("Select one or more supported PBF layers.")
    if not isinstance(request.get("regions"), list) or not request["regions"]:
        raise ValueError("Select one or more areas to extract.")
    staging = Path(staging).resolve()
    staging.mkdir(parents=True, exist_ok=True)
    regions = []
    outputs = {}
    seen_ids = set()
    for raw in request["regions"]:
        if not isinstance(raw, dict):
            raise ValueError("Each selected area must be an object with an ID and bounding box.")
        ident = raw.get("id")
        if isinstance(ident, bool) or not isinstance(ident, int) or ident <= 0 or ident in seen_ids:
            raise ValueError("Area IDs must be distinct positive integers.")
        seen_ids.add(ident)
        bbox = _validate_bbox(raw.get("bbox"))
        if not _covers(header["bbox"], bbox):
            outputs[ident] = {"id": ident, "error": "The selected area is outside the PBF file bounds."}
            continue
        regions.append({"id": ident, "bbox": bbox, "filters": [_rectangle(ogr, part) for part in _bbox_parts(bbox)],
                        "ids": set(), "skipped": 0, "stream": None})
    if not regions:
        return {"regions": list(outputs.values())}
    warnings = Counter()
    def record_warning(level, _number, message):
        if level >= gdal.CE_Warning:
            warnings[message] += 1
    gdal.UseExceptions()
    gdal.PushErrorHandler(record_warning)
    previous_tmp = gdal.GetConfigOption("CPL_TMPDIR")
    gdal.SetConfigOption("CPL_TMPDIR", str(staging))
    config = staging / "reader-osmconf.ini"
    dataset = None
    try:
        for region in regions:
            region["temporary"] = staging / ("area_" + str(region["id"]) + ".json.tmp")
            region["stream"] = region["temporary"].open("w", encoding="utf-8")
            region["stream"].write('{"type":"FeatureCollection","features":[')
        config.write_text(_osm_config(), encoding="utf-8")
        dataset = gdal.OpenEx(header["path"], gdal.OF_VECTOR | gdal.OF_READONLY,
                              allowed_drivers=["OSM"], open_options=["CONFIG_FILE=" + str(config),
                              "INTERLEAVED_READING=YES", "TAGS_FORMAT=JSON", "MAX_TMPFILE_SIZE=100"])
        if dataset is None:
            raise ValueError("Could not open the local PBF file.")
        dataset.ExecuteSQL("SET interest_layers = lines,multipolygons")
        # Filter assembled geometry only. A points filter could lose way vertices.
        parts = [part for region in regions for part in _bbox_parts(region["bbox"])]
        envelope = (min(p[0] for p in parts), min(p[1] for p in parts),
                    max(p[2] for p in parts), max(p[3] for p in parts))
        for name in ("lines", "multipolygons"):
            layer = dataset.GetLayerByName(name)
            layer.SetSpatialFilterRect(*envelope)
            predicates = {"buildings": "building IS NOT NULL AND building <> 'no'",
                          "roads": "highway IS NOT NULL", "landuse": "landuse IS NOT NULL",
                          "water": "natural = 'water'", "parks": "leisure = 'park'"}
            layer.SetAttributeFilter(" OR ".join("(" + predicates[key] + ")" for key in layers))
        while True:
            feature, layer = dataset.GetNextFeature()[:2]
            if feature is None:
                break
            raw_tags = feature.GetField("all_tags")
            tags = json.loads(raw_tags) if raw_tags else {}
            category = _layer(tags)
            if category not in layers:
                continue
            geometry = feature.GetGeometryRef()
            if geometry is None:
                continue
            west, east, south, north = geometry.GetEnvelope()
            candidates = [region for region in regions if any(
                west <= part[2] and east >= part[0] and south <= part[3] and north >= part[1]
                for part in _bbox_parts(region["bbox"]))]
            if not candidates:
                continue
            origin = "way"
            raw_id = feature.GetField("osm_id")
            if layer.GetName() == "multipolygons":
                raw_way_id = feature.GetField("osm_way_id")
                if raw_way_id is not None:
                    raw_id = raw_way_id
                else:
                    origin = "relation"
            if category == "roads" and origin == "relation":
                continue
            if raw_id is None or not geometry.IsValid():
                for region in candidates:
                    region["skipped"] += 1
                continue
            candidates = [region for region in candidates
                          if any(geometry.Intersects(box) for box in region["filters"])]
            if not candidates:
                continue
            shape = json.loads(geometry.ExportToJson())
            if category == "roads" and shape["type"] == "MultiPolygon" and origin == "way":
                coordinates = shape["coordinates"]
                if len(coordinates) == 1 and len(coordinates[0]) == 1:
                    shape = {"type": "LineString", "coordinates": coordinates[0][0]}
            expected = ("LineString",) if category == "roads" else ("Polygon", "MultiPolygon")
            if shape["type"] not in expected:
                for region in candidates:
                    region["skipped"] += 1
                continue
            ident = origin + "/" + str(raw_id)
            item = {"type": "Feature", "id": ident, "properties": tags, "geometry": shape}
            for region in candidates:
                if ident not in region["ids"]:
                    if region["ids"]:
                        region["stream"].write(",")
                    json.dump(item, region["stream"], ensure_ascii=False, separators=(",", ":"), allow_nan=False)
                    region["ids"].add(ident)
        dataset = None
        after = Path(header["path"]).stat()
        if (after.st_size, after.st_mtime_ns) != (header["size"], header["mtime_ns"]):
            raise ValueError("The PBF file changed during extraction. Retry with a stable file.")
        for region in regions:
            provenance = {key: header[key] for key in ("path", "size", "mtime_ns", "timestamp") if key in header}
            provenance.update({"provider": "local_pbf", "bbox": region["bbox"], "layers": layers,
                               "skipped": region["skipped"], "attribution": "© OpenStreetMap contributors",
                               "gdal_version": gdal.VersionInfo("RELEASE_NAME"),
                               "reader_warnings": [{"message": message, "count": count} for message, count in sorted(warnings.items())]})
            region["stream"].write('],"source":')
            json.dump(provenance, region["stream"], ensure_ascii=False, separators=(",", ":"), allow_nan=False)
            region["stream"].write("}")
            region["stream"].close()
            filename = "area_" + str(region["id"]) + ".json"
            region["temporary"].replace(staging / filename)
            outputs[region["id"]] = {"id": region["id"], "file": filename}
    finally:
        dataset = None
        config.unlink(missing_ok=True)
        for region in regions:
            if region["stream"] is not None:
                region["stream"].close()
            if "temporary" in region:
                region["temporary"].unlink(missing_ok=True)
        gdal.SetConfigOption("CPL_TMPDIR", previous_tmp)
        gdal.PopErrorHandler()
    return {"regions": [outputs[raw["id"]] for raw in request["regions"]]}


def main(arguments=None):
    arguments = sys.argv[1:] if arguments is None else arguments
    staging = None
    try:
        if len(arguments) == 2 and arguments[0] == "header":
            print(json.dumps(read_header(arguments[1]), ensure_ascii=False, allow_nan=False))
            return 0
        if len(arguments) == 3 and arguments[0] == "extract":
            staging = Path(arguments[2]).resolve()
            staging.mkdir(parents=True, exist_ok=True)
            request = json.loads(Path(arguments[1]).read_text(encoding="utf-8"))
            result = extract(request, staging)
            _write_json(staging / "result.json", result)
            return 0
        raise ValueError("Usage: pbf_source.py header FILE or extract REQUEST_JSON STAGING_DIR")
    except (OSError, ValueError, KeyError, TypeError, RuntimeError, OverflowError, zlib.error) as error:
        result = {"error": str(error), "regions": []}
        if staging is not None:
            _write_json(staging / "result.json", result)
        else:
            print(json.dumps(result, ensure_ascii=False))
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
