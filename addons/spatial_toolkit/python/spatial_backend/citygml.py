"""Read whole CityGML buildings from supported source snapshots."""

import ctypes as c
import gzip
import hashlib
import io
import json
import math
from pathlib import Path
import re
import warnings
import xml.etree.ElementTree as ET
from zipfile import BadZipFile, ZipFile

from .preview_geometry import Geometry, GeometryError, signed_area


_NS = {
    "core": "http://www.opengis.net/citygml/2.0",
    "building": "http://www.opengis.net/citygml/building/2.0",
    "generic": "http://www.opengis.net/citygml/generics/2.0",
    "gml": "http://www.opengis.net/gml",
}
_GML_ID = f"{{{_NS['gml']}}}id"
_GROUND = f"{{{_NS['building']}}}GroundSurface"
_WALL = f"{{{_NS['building']}}}WallSurface"
_OPENING_ROLES = {f"{{{_NS['building']}}}Window": "windows", f"{{{_NS['building']}}}Door": "doors"}
_CITY = f"{{{_NS['core']}}}CityModel"
_BOUNDED_BY = f"{{{_NS['gml']}}}boundedBy"
_CRS = "EPSG:3879"
_TUM_CRS = "EPSG:25832"
_TUM_CRS_NAMES = {_TUM_CRS, "urn:ogc:def:crs:EPSG::25832"}
_TUM_MEMBER = re.compile(r"DEBY_LOD3_[0-9]+\.gml")
_TUM_CATALOG = Path(__file__).with_name("tum2twin_lod3_catalog.json")
_TUM_ZIP_LIMIT = 256 * 1024 * 1024
_TUM_ZIP_XML_LIMIT = 1024 * 1024 * 1024
_BOX_FIELDS = ("west", "south", "east", "north")
_EXTRACT_BOUNDS = (25498225, 6674275, 25498575, 6674625)
_ARCHIVE_LIMIT = 4 * 1024 * 1024
_XML_LIMIT = 16 * 1024 * 1024
_ZIP_LIMIT = 64 * 1024 * 1024
_ZIP_XML_LIMIT = 512 * 1024 * 1024
_ZIP_MEMBER = "Helsinki3D_CityGML_Kalasatama_20190326.gml"
_READ_BLOCK = 256 * 1024


def _projected_selection(box, transform, coverage=None):
    values = tuple(box.get(field) for field in _BOX_FIELDS) if isinstance(box, dict) else ()
    if len(values) != 4 or any(isinstance(value, bool) or not isinstance(value, (int, float))
                               or not math.isfinite(value) for value in values):
        raise ValueError("The CityGML selection must have finite WGS84 bounds")
    west, south, east, north = values
    if not (-180 <= west < east <= 180 and -90 <= south < north <= 90):
        raise ValueError("The CityGML selection must have ordered WGS84 bounds")
    bounds = transform.transform_bounds(*values, errcheck=True)
    if coverage is not None:
        outer_west, outer_south, outer_east, outer_north = coverage
        if not (outer_west <= bounds[0] and outer_south <= bounds[1]
                and bounds[2] <= outer_east and bounds[3] <= outer_north):
            raise ValueError("The selection is outside the local Kalasatama CityGML coverage")
    return bounds, values


def _read_archive(source, expected_sha256):
    with source.open("rb") as stream:
        compressed = stream.read(_ARCHIVE_LIMIT + 1)
    if not compressed or len(compressed) > _ARCHIVE_LIMIT:
        raise ValueError("The Kalasatama CityGML archive has an invalid size")
    compressed_sha256 = hashlib.sha256(compressed).hexdigest()
    if compressed_sha256 != expected_sha256:
        raise ValueError("The Kalasatama CityGML archive changed since the area was fetched")
    try:
        with gzip.GzipFile(fileobj=io.BytesIO(compressed)) as stream:
            raw = stream.read(_XML_LIMIT + 1)
    except (EOFError, OSError) as exc:
        raise ValueError("Could not decompress the Kalasatama CityGML archive") from exc
    if not raw or len(raw) > _XML_LIMIT or b"<!DOCTYPE" in raw:
        raise ValueError("The Kalasatama CityGML XML has an invalid size or declaration")
    try:
        root = ET.fromstring(raw)
    except ET.ParseError as exc:
        raise ValueError("Could not parse the Kalasatama CityGML XML") from exc
    if root.tag != _CITY:
        raise ValueError("The Kalasatama source is not a CityGML 2.0 city model")
    return root, hashlib.sha256(raw).hexdigest()


def _intersects(bounds, box):
    return (bounds[0] <= box[2] and bounds[2] >= box[0]
            and bounds[1] <= box[3] and bounds[3] >= box[1])


def _envelope(building):
    element = building.find("gml:boundedBy/gml:Envelope", _NS)
    if element is None or element.get("srsName") != "urn:ogc:drf:crs:EPSG::3879":
        raise ValueError("Expected an EPSG:3879 envelope on a Kalasatama building")
    lower = _positions(element.findtext("gml:lowerCorner", namespaces=_NS))
    upper = _positions(element.findtext("gml:upperCorner", namespaces=_NS))
    if len(lower) != 1 or len(upper) != 1 or any(a > b for a, b in zip(lower[0], upper[0])):
        raise ValueError("Invalid Kalasatama building envelope")
    return lower[0][0], lower[0][1], upper[0][0], upper[0][1]


def _positions(text):
    values = tuple(map(float, (text or "").split()))
    if not values or len(values) % 3 or any(not math.isfinite(value) for value in values):
        raise ValueError("Expected finite three-dimensional CityGML positions")
    return list(zip(values[::3], values[1::3], values[2::3]))


def _rings(polygon, *, closure_tolerance=1e-8, diagnostics=None):
    exterior = polygon.find("gml:exterior/gml:LinearRing/gml:posList", _NS)
    if exterior is None:
        raise ValueError("CityGML polygon is missing its exterior ring")
    rings = []
    for element in [exterior, *polygon.findall("gml:interior/gml:LinearRing/gml:posList", _NS)]:
        if element.get("srsDimension", "3") != "3":
            raise ValueError("Expected three-dimensional CityGML position lists")
        points = _positions(element.text)
        gap = math.dist(points[0], points[-1])
        if diagnostics is not None and len(points) < 4 and len(set(points)) < 3:
            diagnostics["degenerate_source_rings"] = diagnostics.get("degenerate_source_rings", 0) + 1
            if element is exterior:
                return []
            continue
        if len(points) < 4 or gap > closure_tolerance:
            raise ValueError("Expected a closed CityGML linear ring")
        if diagnostics is not None and gap > 1e-8:
            diagnostics["closed_source_rings"] = diagnostics.get("closed_source_rings", 0) + 1
        rings.append(points[:-1])
    return rings


def _subtract(a, b):
    return tuple(x - y for x, y in zip(a, b))


def _cross(a, b):
    return (a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0])


def _dot(a, b):
    return sum(x * y for x, y in zip(a, b))


def _unit(vector):
    length = math.hypot(*vector)
    return tuple(value / length for value in vector) if length >= 1e-10 else None


def _triangles(sheet, geometry, *, repair=False):
    # Work in the polygon's own plane, which includes vertical walls. Ordinary
    # triangulation uses exact source vertices and preserves holes.
    base = sheet[0][0]
    exterior = [_subtract(point, base) for point in sheet[0]]
    pairs = list(zip(exterior, exterior[1:] + exterior[:1]))
    cross_products = [_cross(a, b) for a, b in pairs]
    normal = _unit(tuple(map(sum, zip(*cross_products))))
    if normal is None:
        return
    axis = _unit(max((_subtract(b, a) for a, b in pairs), key=lambda edge: _dot(edge, edge)))
    side = _cross(normal, axis)
    projected = []
    source_vertices = {}
    for ring in sheet:
        coordinates = []
        for point in ring:
            relative = _subtract(point, base)
            xy = (round(_dot(relative, axis), 9), round(_dot(relative, side), 9))
            old = source_vertices.setdefault(xy, point)
            if math.dist(old, point) > 1e-8:
                raise ValueError("CityGML vertices overlap after projection to a surface plane")
            coordinates.append(xy)
        projected.append([*coordinates, coordinates[0]])
    triangles = geometry.repair_polygon(projected) if repair else geometry.polygon(projected)
    for triangle in triangles:
        if signed_area(triangle) < 0:
            triangle[1], triangle[2] = triangle[2], triangle[1]
        vertices = []
        for x, y in triangle:
            point = source_vertices.get((x, y))
            if point is None:
                if not repair:
                    raise GeometryError("CityGML triangulation did not preserve a source vertex")
                # Polygon repair can create intersections in the projected plane.
                side_distance = y / _dot(side, side)
                point = tuple(b + x * a + side_distance * s for b, a, s in zip(base, axis, side))
            vertices.append(point)
        yield vertices


def _building_surfaces(building, lod=2, *, include_parts=False, closure_tolerance=1e-8, diagnostics=None):
    seen = set()
    parts = building.findall(".//building:BuildingPart", _NS) if lod == 3 or include_parts else []
    surface_path = ("building:lod3MultiSurface//gml:Polygon" if lod == 3
                    else ".//building:lod2MultiSurface//gml:Polygon")
    for part in (building, *parts):
        for boundary in part.findall("building:boundedBy", _NS):
            for surface in boundary:
                features = [surface]
                if lod == 3:
                    features.extend(node for opening in surface.findall("building:opening", _NS)
                                    for node in opening if node.tag in _OPENING_ROLES)
                for feature in features:
                    for polygon in feature.findall(surface_path, _NS):
                        polygon_id = polygon.get(_GML_ID)
                        if polygon_id is not None and polygon_id in seen:
                            continue
                        seen.add(polygon_id)
                        rings = _rings(polygon, closure_tolerance=closure_tolerance, diagnostics=diagnostics)
                        if rings:
                            yield feature.tag, rings


def _footprints(surfaces, project):
    polygons = []
    for sheet in surfaces:
        polygon = []
        for index, ring in enumerate(sheet):
            points = [list(project(east, north)) for east, north, _ in ring]
            relative = [_subtract(point, points[0]) for point in points]
            if (signed_area(relative) > 0) != (index == 0):
                points.reverse()
            polygon.append([*points, points[0]])
        polygons.append(polygon)
    if len(polygons) == 1:
        return {"type": "Polygon", "coordinates": polygons[0]}
    return {"type": "MultiPolygon", "coordinates": polygons}


def _positive_levels(raw):
    try:
        value = float(raw)
    except (TypeError, ValueError):
        return None
    return value if math.isfinite(value) and value > 0 else None


def _payload(building, identity, provenance, surfaces, ground, footprint, geometry, to_world, scale,
             *, repair_shell_faces=False):
    lod = provenance["lod"]
    ground_height = min(point[2] for sheet in ground for ring in sheet for point in ring)
    placement_height = ground_height + provenance.get("source_ground_below_terrain_m", 0.0)
    height = max(point[2] for _, sheet in surfaces for ring in sheet for point in ring) - ground_height
    wall_top = max((point[2] for tag, sheet in surfaces if tag == _WALL
                    for ring in sheet for point in ring), default=ground_height)
    wall_height = max(0.0, wall_top - ground_height)
    provenance = {**provenance, "source_ground_elevation_m": ground_height,
                  "source_id": provenance.get("source_id", identity.removeprefix("citygml/")),
                  "gameplay_y_offset_m": -placement_height}
    tags = {"building": "yes"}
    attributes = [*building.findall("generic:stringAttribute", _NS),
                  *building.findall("generic:doubleAttribute", _NS),
                  *building.findall("generic:intAttribute", _NS)]
    for attribute in attributes:
        value = attribute.findtext("generic:value", namespaces=_NS)
        if attribute.get("name") and value:
            tags[attribute.get("name")] = value
    if _positive_levels(tags.get("building:levels")) is None:
        storeys = _positive_levels(building.findtext("building:storeysAboveGround", namespaces=_NS))
        if storeys is not None and storeys.is_integer():
            tags["building:levels"] = str(int(storeys))
    vertices, normals = [], []
    measured_openings = {"windows": [], "doors": []}
    dropped_opening_polygons = 0
    collapsed_opening_triangles = 0
    repaired_shell_polygons = 0
    degenerate_shell_polygons = 0
    collapsed_shell_triangles = 0
    cache = {}
    horizontal = {}

    def project_xz(east, north):
        key = east, north
        if key not in horizontal:
            x, projected_north = to_world.transform(east, north, errcheck=True)
            horizontal[key] = x, -projected_north
        return horizontal[key]

    for tag, sheet in surfaces:
        opening_role = _OPENING_ROLES.get(tag)
        triangles = _triangles(sheet, geometry)
        repaired = False
        if opening_role:
            try:
                triangles = list(triangles)
            except ValueError:
                triangles = []
            if not triangles:
                dropped_opening_polygons += 1
        elif lod == 3 or repair_shell_faces:
            try:
                triangles = list(triangles)
            except GeometryError:
                triangles = list(_triangles(sheet, geometry, repair=True))
                repaired = True
                repaired_shell_polygons += 1
            if not triangles:
                degenerate_shell_polygons += 1
        for triangle in triangles:
            transformed = []
            for point in triangle:
                if point not in cache:
                    x, z = project_xz(*point[:2])
                    cache[point] = [x * scale, (point[2] - placement_height) * scale, z * scale]
                transformed.append(cache[point])
            a, b, c = transformed
            normal = _unit(_cross(_subtract(b, a), _subtract(c, a)))
            if normal is None:
                if opening_role:
                    collapsed_opening_triangles += 1
                    continue
                if repaired or repair_shell_faces:
                    collapsed_shell_triangles += 1
                    continue
                raise ValueError("CityGML triangle collapsed during world projection")
            if opening_role:
                measured_openings[opening_role].append(len(vertices) // 3)
            vertices.extend((a, c, b))  # Godot front faces are clockwise.
            normals.extend([list(normal)] * 3)
    if not vertices:
        raise ValueError(f"Selected CityGML building has no LoD{lod} triangles")
    dimensions = {"height_m": height, "wall_height_m": wall_height}
    mesh = {
        "id": identity, "layer": "Buildings", "style": f"building_citygml_lod{lod}",
        "vertices": vertices, "normals": normals, "tags": tags, "source": provenance,
        "assumptions": ["Source shell without interiors or image textures",
                        "Rigid vertical placement onto flat OSM gameplay ground"],
        "height_m": height, "wall_height_m": wall_height, "height_source": f"citygml_lod{lod}", "world_scale": scale,
        "source_dimensions_m": dimensions,
        "game_dimensions_m": {key: value * scale for key, value in dimensions.items()},
    }
    if any(measured_openings.values()):
        provenance["modeled_openings"] = True
        mesh["measured_openings"] = measured_openings
    else:
        mesh["facade_geometry"] = _footprints(ground, project_xz)
    if dropped_opening_polygons:
        provenance["unusable_opening_polygons"] = dropped_opening_polygons
    if collapsed_opening_triangles:
        provenance["collapsed_opening_triangles"] = collapsed_opening_triangles
    if repaired_shell_polygons:
        provenance["repaired_shell_polygons"] = repaired_shell_polygons
        mesh["assumptions"].append("Invalid source shell faces polygonized in their surface plane with declared holes")
    if degenerate_shell_polygons:
        provenance["degenerate_shell_polygons"] = degenerate_shell_polygons
    if collapsed_shell_triangles:
        provenance["collapsed_shell_triangles"] = collapsed_shell_triangles
    feature = {"type": "Feature", "id": identity, "geometry": footprint,
               "properties": tags, "spatial_source": provenance}
    return mesh, feature


def _source_provenance(source, source_sha256, xml_sha256):
    return {
        "path": str(source), "sha256": source_sha256, "xml_sha256": xml_sha256,
        "dataset": "Helsinki 3D CityGML Kalasatama 2019-03-26",
        "provider": "City of Helsinki", "license": "CC-BY-4.0",
        "attribution": "City of Helsinki, Helsinki 3D city model, 2019-03-26, CC BY 4.0",
        "source_url": "https://3d.hel.ninja/data/citygml/Helsinki3D_CityGML_Kalasatama_20190326.zip",
        "license_url": "https://creativecommons.org/licenses/by/4.0/",
        "source_crs": _CRS, "source_vertical_datum": "N2000", "units": "metres", "lod": 2,
    }


def _footprint_selection(building, candidates, geometry, to_wgs84):
    surfaces = list(_building_surfaces(building))
    ground = [sheet for tag, sheet in surfaces if tag == _GROUND]
    if not ground:
        raise ValueError("Selected CityGML building has no GroundSurface")
    footprint = _footprints(ground, lambda east, north: to_wgs84.transform(east, north, errcheck=True))
    polygons = ([footprint["coordinates"]] if footprint["type"] == "Polygon"
                else footprint["coordinates"])
    if any(geometry.intersects_box(polygons, *box) for box in candidates):
        return surfaces, ground, footprint
    return None


def read_helsinki(source: Path, source_sha256: str, boxes: list[dict], projection: str,
                  world_scale: float) -> dict[str, tuple[dict, dict]]:
    """Return whole selected CityGML shells and their WGS84 footprints by source ID."""
    from pyproj import CRS, Transformer

    to_extract = Transformer.from_crs("EPSG:4326", _CRS, always_xy=True)
    selections = [_projected_selection(box, to_extract, _EXTRACT_BOUNDS) for box in boxes]
    if not selections:
        return {}
    root, xml_sha256 = _read_archive(source, source_sha256)
    to_world = Transformer.from_crs(_CRS, CRS.from_proj4(projection), always_xy=True)
    to_wgs84 = Transformer.from_crs(_CRS, "EPSG:4326", always_xy=True)
    provenance = _source_provenance(source, source_sha256, xml_sha256)
    buildings = {}
    with Geometry() as geometry:
        for building in root.findall("core:cityObjectMember/building:Building", _NS):
            bounds = _envelope(building)
            candidates = [wgs84_box for box, wgs84_box in selections if _intersects(bounds, box)]
            if not candidates:
                continue
            identifier = building.get(_GML_ID)
            if not identifier:
                raise ValueError("Selected CityGML building is missing its GMLID")
            identity = "citygml/" + identifier
            if identity in buildings:
                raise ValueError("Duplicate GMLID in the Kalasatama CityGML extract: " + identifier)
            try:
                selected = _footprint_selection(building, candidates, geometry, to_wgs84)
                if selected is not None:
                    buildings[identity] = _payload(building, identity, provenance, *selected,
                                                   geometry, to_world, world_scale)
            except ValueError as exc:
                raise ValueError(f"CityGML building {identifier}: {exc}") from exc
    return dict(sorted(buildings.items()))


def _scan_zip_members(stream, consume_member, label="Kalasatama", *, keep_envelope=None,
                      version="2.0", xml_limit=_ZIP_XML_LIMIT, on_read=None):
    """Return the XML digest, or None when a root envelope excludes the member."""
    parser = ET.XMLPullParser(("start", "end"))
    root = None
    depth = 0
    digest = hashlib.sha256()
    size = 0
    previous = b""
    versions = (version,) if version else ("1.0", "2.0")
    city_roots = {f"{{http://www.opengis.net/citygml/{value}}}CityModel": value for value in versions}
    member_tag = building_tag = ""
    for block in iter(lambda: stream.read(_READ_BLOCK), b""):
        size += len(block)
        if size > xml_limit or b"<!DOCTYPE" in (previous + block).replace(b"\x00", b""):
            raise ValueError(f"The {label} CityGML XML has an invalid size or declaration")
        previous = block[-2 * len(b"<!DOCTYPE"):]
        digest.update(block)
        parser.feed(block)
        for event, element in parser.read_events():
            if event == "start":
                depth += 1
                if root is None:
                    detected = city_roots.get(element.tag)
                    if detected is None:
                        raise ValueError(f"The {label} source is not a supported CityGML city model")
                    root = element
                    member_tag = f"{{http://www.opengis.net/citygml/{detected}}}cityObjectMember"
                    building_tag = f"{{http://www.opengis.net/citygml/building/{detected}}}Building"
            else:
                if depth == 2:
                    if element.tag == member_tag:
                        keep_envelope = None
                        building = element.find(building_tag)
                        if building is not None:
                            consume_member(building)
                    elif element.tag == _BOUNDED_BY and keep_envelope is not None:
                        if not keep_envelope(element):
                            return None
                        keep_envelope = None
                    root.remove(element)
                depth -= 1
        if on_read is not None:
            on_read(size)
    parser.close()
    return digest.hexdigest()


def _scan_official_zip(source, source_sha256, consume_member):
    try:
        with source.open("rb") as archive:
            digest = hashlib.sha256()
            size = 0
            for block in iter(lambda: archive.read(_READ_BLOCK), b""):
                size += len(block)
                if size > _ZIP_LIMIT:
                    raise ValueError("The official Kalasatama ZIP exceeds its size limit")
                digest.update(block)
            if digest.hexdigest() != source_sha256:
                raise ValueError("The Kalasatama CityGML archive changed since the area was fetched")
            archive.seek(0)
            with ZipFile(archive) as zipped:
                entries = zipped.infolist()
                if len(entries) != 1 or entries[0].filename != _ZIP_MEMBER:
                    raise ValueError("The ZIP does not contain the official Kalasatama CityGML export")
                if not 0 < entries[0].file_size <= _ZIP_XML_LIMIT:
                    raise ValueError("The Kalasatama CityGML XML has an invalid size")
                with zipped.open(entries[0]) as stream:
                    return _scan_zip_members(stream, consume_member)
    except (ET.ParseError, BadZipFile, OSError) as exc:
        raise ValueError(f"Could not read the official Kalasatama ZIP: {exc}") from exc


def read_helsinki_archive(source: Path, source_sha256: str, boxes: list[dict], projection: str,
                          world_scale: float, *, on_skipped=None) -> dict[str, tuple[dict, dict]]:
    """Read supplemental buildings without assuming complete archive coverage."""
    from pyproj import CRS, Transformer

    to_extract = Transformer.from_crs("EPSG:4326", _CRS, always_xy=True)
    selections = [_projected_selection(box, to_extract) for box in boxes]
    if not selections:
        return {}
    provenance = _source_provenance(source, source_sha256, "")
    provenance["dataset_id"] = "helsinki_kalasatama_archive"
    to_world = Transformer.from_crs(_CRS, CRS.from_proj4(projection), always_xy=True)
    to_wgs84 = Transformer.from_crs(_CRS, "EPSG:4326", always_xy=True)
    buildings = {}
    skips = {}
    scores = {}
    with Geometry() as geometry:
        def collect(building):
            bounds = _envelope(building)
            candidates = [wgs84_box for box, wgs84_box in selections if _intersects(bounds, box)]
            if not candidates:
                return
            identifier = building.get(_GML_ID)
            if not identifier:
                raise ValueError("Selected CityGML building is missing its GMLID")
            identity = "citygml/" + identifier
            score = sum(len(surface.findall(".//gml:Polygon", _NS))
                        for surface in building.findall(".//building:lod2MultiSurface", _NS))
            # Duplicates occur in the official export. Preserve the first on a tie.
            if score <= scores.get(identity, -1):
                return
            scores[identity] = score
            buildings.pop(identity, None)
            skips.pop(identity, None)
            try:
                selected = _footprint_selection(building, candidates, geometry, to_wgs84)
                if selected is not None:
                    buildings[identity] = _payload(building, identity, provenance, *selected,
                                                   geometry, to_world, world_scale)
            except ValueError as exc:
                skips[identity] = str(exc)

        xml_sha256 = _scan_official_zip(source, source_sha256, collect)
    for mesh, _ in buildings.values():
        # The feature and its mesh share this provenance dictionary.
        mesh["source"]["xml_sha256"] = xml_sha256
    if skips and on_skipped is not None:
        on_skipped(skips)
    elif skips:
        detail = "; ".join(f"{identity}: {skips[identity]}" for identity in sorted(skips)[:5])
        warnings.warn(f"Skipped {len(skips)} unusable Helsinki archive buildings ({detail})", RuntimeWarning)
    return dict(sorted(buildings.items()))


class _TumGeometry(Geometry):
    def __init__(self):
        super().__init__()
        pointer = c.c_void_p
        self._bind("GEOSUnaryUnion_r", pointer, [pointer, pointer])
        self._bind("GEOSGeoJSONWriter_create_r", pointer, [pointer])
        self._bind("GEOSGeoJSONWriter_writeGeometry_r", pointer, [pointer, pointer, pointer, c.c_int])
        self._bind("GEOSGeoJSONWriter_destroy_r", None, [pointer, pointer])
        self._bind("GEOSFree_r", None, [pointer, pointer])
        self._bind("GEOSGeomTypeId_r", c.c_int, [pointer, pointer])
        self._bind("GEOSisEmpty_r", c.c_byte, [pointer, pointer])
        self._bind("GEOSMakeValidParams_create_r", pointer, [pointer])
        self._bind("GEOSMakeValidParams_destroy_r", None, [pointer, pointer])
        self._bind("GEOSMakeValidParams_setMethod_r", c.c_int, [pointer, pointer, c.c_int])
        self._bind("GEOSMakeValidParams_setKeepCollapsed_r", c.c_int, [pointer, pointer, c.c_int])
        self._bind("GEOSMakeValidWithParams_r", pointer, [pointer, pointer, pointer])

    def repair_polygon(self, rings):
        polygon = self._read("POLYGON" + self._polygon_body(rings))
        params = self.lib.GEOSMakeValidParams_create_r(self.context)
        repaired = None
        try:
            # GEOS_MAKE_VALID_STRUCTURE repairs each ring and keeps holes subtractive.
            if (not params or not self.lib.GEOSMakeValidParams_setMethod_r(self.context, params, 1)
                    or not self.lib.GEOSMakeValidParams_setKeepCollapsed_r(self.context, params, 0)):
                raise GeometryError("Could not configure CityGML source surface repair")
            repaired = self.lib.GEOSMakeValidWithParams_r(self.context, polygon, params)
            if not repaired:
                raise GeometryError("Could not repair invalid CityGML source surface")
            if self.lib.GEOSisEmpty_r(self.context, repaired) == 1:
                return []
            kind = self.lib.GEOSGeomTypeId_r(self.context, repaired)
            if kind == 3:  # GEOS_POLYGON
                return self._triangles(repaired)
            if kind != 6:  # GEOS_MULTIPOLYGON
                raise GeometryError("CityGML surface repair did not produce polygons")
            return [triangle for index in range(self.lib.GEOSGetNumGeometries_r(self.context, repaired))
                    for triangle in self._triangles(self.lib.GEOSGetGeometryN_r(self.context, repaired, index))]
        finally:
            if params:
                self.lib.GEOSMakeValidParams_destroy_r(self.context, params)
            self._destroy(repaired)
            self._destroy(polygon)

    def ground_footprint(self, ground, to_wgs84, *, diagnostics=None):
        # Merge adjacent source patches in their metre-based CRS before projection.
        planar = _footprints(ground, lambda east, north: (east, north))
        polygons = [planar["coordinates"]] if planar["type"] == "Polygon" else planar["coordinates"]
        if diagnostics is not None:
            polygons = self._valid_ground_patches(polygons, diagnostics)
        if not polygons:
            raise GeometryError("CityGML GroundSurface has no polygonal area")
        if len(polygons) > 1:
            parts = ",".join("POLYGON" + self._polygon_body(rings) for rings in polygons)
            patches = self._read("GEOMETRYCOLLECTION(" + parts + ")")
            merged = writer = encoded = None
            try:
                merged = self.lib.GEOSUnaryUnion_r(self.context, patches)
                writer = self.lib.GEOSGeoJSONWriter_create_r(self.context)
                if merged and writer:
                    encoded = self.lib.GEOSGeoJSONWriter_writeGeometry_r(self.context, writer, merged, -1)
                if not encoded:
                    raise GeometryError("Could not merge CityGML GroundSurface patches")
                planar = json.loads(c.string_at(encoded))
            finally:
                if encoded:
                    self.lib.GEOSFree_r(self.context, encoded)
                if writer:
                    self.lib.GEOSGeoJSONWriter_destroy_r(self.context, writer)
                self._destroy(merged)
                self._destroy(patches)
            if planar["type"] not in ("Polygon", "MultiPolygon") or not planar["coordinates"]:
                raise GeometryError("CityGML GroundSurface merge has no polygonal area")
            polygons = [planar["coordinates"]] if planar["type"] == "Polygon" else planar["coordinates"]
        sheets = [[[(east, north, 0.0) for east, north in ring[:-1]] for ring in polygon]
                  for polygon in polygons]
        return _footprints(sheets, lambda east, north: to_wgs84.transform(east, north, errcheck=True))

    def _valid_ground_patches(self, polygons, diagnostics):
        result = []
        for rings in polygons:
            polygon = self._read("POLYGON" + self._polygon_body(rings))
            try:
                valid = self.lib.GEOSisValid_r(self.context, polygon) == 1
            finally:
                self._destroy(polygon)
            if valid:
                result.append(rings)
            else:
                east, north = rings[0][0]
                local = [[(x - east, y - north) for x, y in ring] for ring in rings]
                for triangle in self.repair_polygon(local):
                    restored = [(x + east, y + north) for x, y in triangle]
                    result.append([[*restored, restored[0]]])
                diagnostics["repaired_ground_patches"] = diagnostics.get("repaired_ground_patches", 0) + 1
        return result


def _tum_envelope(bounded_by):
    envelope = bounded_by.find("gml:Envelope", _NS)
    if envelope is None or envelope.get("srsName") not in _TUM_CRS_NAMES:
        return None
    try:
        lower = tuple(map(float, envelope.findtext("gml:lowerCorner", "", _NS).split()))
        upper = tuple(map(float, envelope.findtext("gml:upperCorner", "", _NS).split()))
    except ValueError:
        return None
    if (len(lower) != len(upper) or len(lower) not in (2, 3)
            or envelope.get("srsDimension", str(len(lower))) != str(len(lower))
            or any(not math.isfinite(a) or not math.isfinite(b) or a > b for a, b in zip(lower, upper))):
        return None
    return lower[0], lower[1], upper[0], upper[1]


def _scan_tum_zip(source, source_sha256, consume_member, keep_envelope):
    try:
        with source.open("rb") as archive:
            digest = hashlib.sha256()
            size = 0
            for block in iter(lambda: archive.read(_READ_BLOCK), b""):
                size += len(block)
                if size > _TUM_ZIP_LIMIT:
                    raise ValueError("The TUM2TWIN CityGML ZIP exceeds its size limit")
                digest.update(block)
            if digest.hexdigest() != source_sha256:
                raise ValueError("The TUM2TWIN CityGML archive changed since the area was fetched")
            archive.seek(0)
            with ZipFile(archive) as zipped:
                entries = zipped.infolist()
                names = {entry.filename for entry in entries}
                members = sorted(name for name in names if _TUM_MEMBER.fullmatch(name))
                if (not members or len(entries) != len(names)
                        or names.difference(members, {"LICENSE.txt", "provenance.json"})):
                    raise ValueError("Expected unique TUM2TWIN LoD3 CityGML files in the ZIP root")
                sizes = [zipped.getinfo(name).file_size for name in members]
                if any(not 0 < size <= _ZIP_XML_LIMIT for size in sizes) or sum(sizes) > _TUM_ZIP_XML_LIMIT:
                    raise ValueError("The TUM2TWIN CityGML XML has an invalid size")
                hashes = {}
                for name in members:
                    with zipped.open(name) as stream:
                        member_hash = _scan_zip_members(
                            stream, lambda building: consume_member(building, name), "TUM2TWIN",
                            keep_envelope=keep_envelope)
                    if member_hash is not None:
                        hashes[name] = member_hash
                return hashes
    except (ET.ParseError, BadZipFile, OSError) as exc:
        raise ValueError(f"Could not read the TUM2TWIN CityGML ZIP: {exc}") from exc


def read_tum_archive(source: Path, source_sha256: str, boxes: list[dict], projection: str,
                     world_scale: float, *, on_skipped=None) -> dict[str, tuple[dict, dict]]:
    """Read selected TUM2TWIN LoD3 shells and opening surfaces by source GMLID."""
    from pyproj import CRS, Transformer

    to_native = Transformer.from_crs("EPSG:4326", _TUM_CRS, always_xy=True)
    selections = [_projected_selection(box, to_native) for box in boxes]
    if not selections:
        return {}
    to_world = Transformer.from_crs(_TUM_CRS, CRS.from_proj4(projection), always_xy=True)
    to_wgs84 = Transformer.from_crs(_TUM_CRS, "EPSG:4326", always_xy=True)
    catalog = json.loads(_TUM_CATALOG.read_text(encoding="utf-8"))
    repository = catalog["repository"]
    revision = catalog["revision"]
    official_hashes = {record["file"]: record["sha256"] for record in catalog["members"]}
    provenance = {
        "path": str(source), "sha256": source_sha256, "dataset_id": "tum2twin_lod3",
        "dataset": "TUM2TWIN CityGML LoD3", "provider": "Technical University of Munich",
        "license": "CC-BY-4.0", "attribution": "TUM2TWIN, Technical University of Munich, CC BY 4.0",
        "source_url": repository, "license_url": "https://creativecommons.org/licenses/by/4.0/",
        "source_crs": _TUM_CRS, "source_vertical_datum": "not specified", "units": "metres", "lod": 3,
    }
    buildings = {}
    skips = {}

    def keep_envelope(bounded_by):
        envelope = _tum_envelope(bounded_by)
        return envelope is None or any(_intersects(native, envelope) for native, _ in selections)

    with _TumGeometry() as geometry:
        def collect(building, member):
            identifier = building.get(_GML_ID)
            identity = "citygml/" + identifier if identifier else member
            try:
                declared = {node.get("srsName") for node in building.iter() if node.get("srsName")}
                if not declared or declared.difference(_TUM_CRS_NAMES):
                    raise ValueError("Expected LoD3 geometry in EPSG:25832")
                surfaces = list(_building_surfaces(building, lod=3))
                ground = [sheet for tag, sheet in surfaces if tag == _GROUND]
                if not ground:
                    raise ValueError("Selected LoD3 building has no GroundSurface")
                east, north, _ = zip(*(point for sheet in ground for ring in sheet for point in ring))
                bounds = (min(east), min(north), max(east), max(north))
                candidates = [wgs84 for native, wgs84 in selections if _intersects(bounds, native)]
                if not candidates:
                    return
                footprint = geometry.ground_footprint(ground, to_wgs84)
                polygons = ([footprint["coordinates"]] if footprint["type"] == "Polygon"
                            else footprint["coordinates"])
                if not any(geometry.intersects_box(polygons, *box) for box in candidates):
                    return
                if not identifier:
                    raise ValueError("Selected CityGML building is missing its GMLID")
                if identity in buildings:
                    raise ValueError("Duplicate GMLID in the TUM2TWIN CityGML archive: " + identifier)
                source_data = {**provenance, "archive_member": member}
                buildings[identity] = _payload(building, identity, source_data, surfaces, ground,
                                               footprint, geometry, to_world, world_scale)
            except ValueError as exc:
                skips[identity] = str(exc)

        xml_hashes = _scan_tum_zip(source, source_sha256, collect, keep_envelope)
    for mesh, _ in buildings.values():
        source_data = mesh["source"]
        member = source_data["archive_member"]
        source_data["xml_sha256"] = xml_hashes[member]
        if official_hashes.get(member) == xml_hashes[member]:
            source_data["source_revision"] = revision
            source_data["source_url"] = f"{repository}/-/blob/{revision}/citygml/lod3-building-datasets/{member}"
    if skips and on_skipped is not None:
        on_skipped(skips)
    elif skips:
        detail = "; ".join(f"{identity}: {skips[identity]}" for identity in sorted(skips)[:5])
        warnings.warn(f"Skipped {len(skips)} unusable TUM2TWIN buildings ({detail})", RuntimeWarning)
    return dict(sorted(buildings.items()))
