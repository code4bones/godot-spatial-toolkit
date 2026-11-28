"""Verified source-area coverage in local gameplay metres.

Source query rectangles describe where obstacle input was collected.
Their projected union is eroded once, preserving covered overlaps and gaps.
"""

import ctypes as c
import hashlib
import math
from pathlib import Path
import re

from pyproj import CRS, Transformer

from ..preview_geometry import Geometry
from .graph import finite_number
from .world_data import _read_object


CHORD_TOLERANCE_M = 0.001
BOUNDARY_PADDING_M = 0.01
BUFFER_QUADRANTS = 32


class Coverage:
    """Own a prepared GEOS coverage geometry until closed."""

    def __init__(self, rings, clearance_m, metadata):
        self._geometry = Geometry()
        self._area = None
        self._prepared = None
        self.metadata = metadata
        geometry = self._geometry
        geometry._bind("GEOSUnaryUnion_r", c.c_void_p, [c.c_void_p, c.c_void_p])
        geometry._bind("GEOSisEmpty_r", c.c_byte, [c.c_void_p, c.c_void_p])
        geometry._bind("GEOSPrepare_r", c.c_void_p, [c.c_void_p, c.c_void_p])
        geometry._bind("GEOSPreparedGeom_destroy_r", None, [c.c_void_p, c.c_void_p])
        geometry._bind("GEOSGeom_createPointFromXY_r", c.c_void_p,
                       [c.c_void_p, c.c_double, c.c_double])
        for name in ("GEOSPreparedCovers_r", "GEOSPreparedIntersects_r"):
            geometry._bind(name, c.c_byte, [c.c_void_p, c.c_void_p, c.c_void_p])
        for axis in ("XMin", "YMin", "XMax", "YMax"):
            geometry._bind(f"GEOSGeom_get{axis}_r", c.c_int,
                           [c.c_void_p, c.c_void_p, c.POINTER(c.c_double)])
        collection = union = None
        try:
            bodies = ["POLYGON((" + ",".join(f"{x:.12f} {z:.12f}" for x, z in ring) + "))"
                      for ring in sorted(rings)]
            collection = geometry._read("GEOMETRYCOLLECTION(" + ",".join(bodies) + ")")
            union = geometry.lib.GEOSUnaryUnion_r(geometry.context, collection)
            if not union or geometry.lib.GEOSisValid_r(geometry.context, union) != 1:
                raise ValueError("Source coverage union failed")
            erosion_m = (clearance_m + BOUNDARY_PADDING_M) / math.cos(math.pi / (4 * BUFFER_QUADRANTS))
            self._area = geometry.lib.GEOSBuffer_r(
                geometry.context, union, -erosion_m, BUFFER_QUADRANTS)
            if not self._area or geometry.lib.GEOSisEmpty_r(geometry.context, self._area) != 0:
                raise ValueError("Source coverage has no interior after clearance")
            self._prepared = geometry.lib.GEOSPrepare_r(geometry.context, self._area)
            if not self._prepared:
                raise ValueError("Source coverage preparation failed")
            bounds = []
            for axis in ("XMin", "YMin", "XMax", "YMax"):
                value = c.c_double()
                if getattr(geometry.lib, f"GEOSGeom_get{axis}_r")(
                        geometry.context, self._area, c.byref(value)) != 1:
                    raise ValueError("Source coverage bounds are unavailable")
                bounds.append(finite_number(value.value, "Coverage bound"))
            self.bounds = tuple(bounds)
        except BaseException:
            geometry._destroy(union)
            geometry._destroy(collection)
            union = collection = None
            self.close()
            raise
        finally:
            if self._geometry is not None:
                geometry._destroy(union)
                geometry._destroy(collection)

    def __enter__(self):
        self._check_open()
        return self

    def __exit__(self, *_):
        self.close()

    def _check_open(self):
        if self._geometry is None:
            raise ValueError("Source coverage is closed")

    def close(self):
        geometry = self._geometry
        if geometry is None:
            return
        if self._prepared:
            geometry.lib.GEOSPreparedGeom_destroy_r(geometry.context, self._prepared)
        geometry._destroy(self._area)
        geometry.__exit__()
        self._prepared = self._area = None
        self._geometry = None

    def _test(self, shape, *, intersects=False):
        geometry = self._geometry
        try:
            predicate = (geometry.lib.GEOSPreparedIntersects_r if intersects
                         else geometry.lib.GEOSPreparedCovers_r)
            result = predicate(geometry.context, self._prepared, shape)
            if result not in (0, 1):
                raise ValueError("Source coverage predicate failed")
            return result == 1
        finally:
            geometry._destroy(shape)

    def contains_point(self, x, z):
        self._check_open()
        x, z = (finite_number(value, "Coverage point") for value in (x, z))
        shape = self._geometry.lib.GEOSGeom_createPointFromXY_r(self._geometry.context, x, z)
        if not shape:
            raise ValueError("Source coverage point construction failed")
        return self._test(shape)

    def contains_segment(self, x1, z1, x2, z2):
        self._check_open()
        x1, z1, x2, z2 = (finite_number(value, "Coverage segment") for value in (x1, z1, x2, z2))
        if (x1, z1) == (x2, z2):
            return self.contains_point(x1, z1)
        shape = self._geometry._read(f"LINESTRING({x1:.17g} {z1:.17g},{x2:.17g} {z2:.17g})")
        return self._test(shape)

    def _cell(self, min_x, min_z, max_x, max_z):
        self._check_open()
        min_x, min_z, max_x, max_z = (finite_number(value, "Coverage cell")
                                     for value in (min_x, min_z, max_x, max_z))
        if min_x >= max_x or min_z >= max_z:
            raise ValueError("Coverage cell must have positive extent")
        return self._geometry._read(
            f"POLYGON(({min_x:.17g} {min_z:.17g},{max_x:.17g} {min_z:.17g},"
            f"{max_x:.17g} {max_z:.17g},{min_x:.17g} {max_z:.17g},{min_x:.17g} {min_z:.17g}))")

    def intersects_cell(self, min_x, min_z, max_x, max_z):
        return self._test(self._cell(min_x, min_z, max_x, max_z), intersects=True)

    def cell_seed_points(self, min_x, min_z, max_x, max_z):
        """Return a strictly interior point for each covered cell component."""
        geometry = self._geometry
        cell = self._cell(min_x, min_z, max_x, max_z)
        geometry._bind("GEOSIntersection_r", c.c_void_p, [c.c_void_p, c.c_void_p, c.c_void_p])
        geometry._bind("GEOSPointOnSurface_r", c.c_void_p, [c.c_void_p, c.c_void_p])
        geometry._bind("GEOSGeomTypeId_r", c.c_int, [c.c_void_p, c.c_void_p])
        geometry._bind("GEOSGeomGetX_r", c.c_int, [c.c_void_p, c.c_void_p, c.POINTER(c.c_double)])
        geometry._bind("GEOSGeomGetY_r", c.c_int, [c.c_void_p, c.c_void_p, c.POINTER(c.c_double)])
        clipped = None
        try:
            clipped = geometry.lib.GEOSIntersection_r(geometry.context, self._area, cell)
            if not clipped:
                raise ValueError("Source coverage cell clipping failed")
            points = []

            def collect(part):
                kind = geometry.lib.GEOSGeomTypeId_r(geometry.context, part)
                if kind in (6, 7):
                    for index in range(geometry.lib.GEOSGetNumGeometries_r(geometry.context, part)):
                        collect(geometry.lib.GEOSGetGeometryN_r(geometry.context, part, index))
                elif kind == 3:
                    area = c.c_double()
                    if geometry.lib.GEOSArea_r(geometry.context, part, c.byref(area)) != 1:
                        raise ValueError("Source coverage cell area failed")
                    if area.value <= 0:
                        return
                    point = geometry.lib.GEOSPointOnSurface_r(geometry.context, part)
                    if not point:
                        raise ValueError("Source coverage seed generation failed")
                    try:
                        x, z = c.c_double(), c.c_double()
                        if (geometry.lib.GEOSGeomGetX_r(geometry.context, point, c.byref(x)) != 1
                                or geometry.lib.GEOSGeomGetY_r(geometry.context, point, c.byref(z)) != 1):
                            raise ValueError("Source coverage seed coordinates failed")
                        points.append((x.value, z.value))
                    finally:
                        geometry._destroy(point)

            collect(clipped)
            return tuple(sorted(points))
        finally:
            geometry._destroy(clipped)
            geometry._destroy(cell)


def _project_ring(bbox, transform, scale):
    west, south, east, north = bbox
    corners = [(west, south), (east, south), (east, north), (west, north), (west, south)]

    def project(point):
        x, northing = transform.transform(*point, errcheck=True)
        return (finite_number(x * scale, "Projected coverage X"),
                finite_number(-northing * scale, "Projected coverage Z"))

    samples = 0

    def edge(a, b, pa, pb, depth=0):
        nonlocal samples
        samples += 1
        if samples > 100_000:
            raise ValueError("Projected source bbox is too large")
        midpoint = tuple((lo + hi) * 0.5 for lo, hi in zip(a, b))
        pm = project(midpoint)
        error = math.dist(pm, tuple((lo + hi) * 0.5 for lo, hi in zip(pa, pb)))
        if error <= CHORD_TOLERANCE_M and max(abs(a[i] - b[i]) for i in (0, 1)) <= 0.002:
            return [pb]
        if depth >= 20:
            raise ValueError("Source bbox cannot be projected within coverage tolerance")
        return edge(a, midpoint, pa, pm, depth + 1) + edge(midpoint, b, pm, pb, depth + 1)

    ring = [project(corners[0])]
    for a, b in zip(corners, corners[1:]):
        ring.extend(edge(a, b, ring[-1], project(b)))
    return tuple(ring)


def load_coverage(path: Path, provenance: dict, clearance_m: float) -> Coverage:
    """Verify the baked snapshot and project its query areas into map X/Z."""
    clearance_m = finite_number(clearance_m, "Coverage clearance")
    if clearance_m < 0:
        raise ValueError("Coverage clearance must be nonnegative")
    data, raw = _read_object(Path(path))
    digest = hashlib.sha256(raw).hexdigest()
    if digest != provenance.get("source_world_sha256"):
        raise ValueError("Source world checksum differs from the baked snapshot")
    for field, source_field in (("source_revision", "revision"), ("world_scale", "world_scale"),
                                ("projection", "projection"), ("local_origin", "local_origin")):
        if data.get(source_field) != provenance.get(field):
            raise ValueError(f"Source world and baked snapshot disagree on {field}")
    if isinstance(data.get("schema"), bool) or data.get("schema") != 1:
        raise ValueError("Unsupported source world schema")
    if type(data.get("revision")) is not int or data["revision"] < 1:
        raise ValueError("Source world revision must be a positive integer")
    origin = data.get("local_origin")
    if not isinstance(origin, dict):
        raise ValueError("Source world is missing its geographic local_origin")
    longitude = finite_number(origin.get("longitude"), "Coverage local_origin.longitude")
    latitude = finite_number(origin.get("latitude"), "Coverage local_origin.latitude")
    if abs(longitude) > 180 or abs(latitude) > 90:
        raise ValueError("Source world local_origin is outside WGS84")
    records = data.get("source_records")
    if not isinstance(records, list) or not records:
        raise ValueError("Source world is missing source_records coverage")
    bboxes = set()
    for record in records:
        source = record.get("source") if isinstance(record, dict) else None
        bbox = source.get("bbox") if isinstance(source, dict) else None
        layers = source.get("layers") if isinstance(source, dict) else None
        if not _has_building_coverage(record, source, layers):
            raise ValueError("Every source coverage record must include the buildings layer")
        if not isinstance(record.get("sha256"), str) or not re.fullmatch(r"[0-9a-f]{64}", record["sha256"]):
            raise ValueError("Source coverage record is missing its SHA-256 provenance")
        if not isinstance(bbox, dict):
            raise ValueError("Source coverage record is missing its query bbox")
        values = tuple(finite_number(bbox.get(key), "Source bbox")
                       for key in ("west", "south", "east", "north"))
        west, south, east, north = values
        if not (-180 <= west < east <= 180 and -90 < south < north < 90):
            raise ValueError("Source bbox must be an ordered WGS84 rectangle")
        bboxes.add(values)
    scale = finite_number(data["world_scale"], "Coverage world scale")
    if not 1 <= scale <= 100:
        raise ValueError("Coverage world scale must be between 1 and 100")
    try:
        projection = CRS.from_user_input(data["projection"])
        if not projection.is_projected or any(axis.unit_conversion_factor != 1 for axis in projection.axis_info):
            raise ValueError("Coverage projection must use projected metres")
        transform = Transformer.from_crs("EPSG:4326", projection, always_xy=True)
        rings = [_project_ring(bbox, transform, scale) for bbox in sorted(bboxes)]
    except (RuntimeError, ValueError) as exc:
        raise ValueError(f"Cannot project source coverage: {exc}") from exc
    metadata = {"source_world_sha256": digest, "source_bboxes_wgs84": sorted(bboxes),
                "clearance_m": clearance_m, "boundary_padding_m": BOUNDARY_PADDING_M,
                "chord_tolerance_m": CHORD_TOLERANCE_M}
    return Coverage(rings, clearance_m, metadata)


def _has_building_coverage(record, source, layers):
    dataset = source.get("citygml") if isinstance(source, dict) else None
    if isinstance(dataset, dict) and dataset.get("id") == "helsinki_kalasatama":
        digest = dataset.get("sha256")
        # World generation checks the archive and the selected bounds before
        # publishing this attestation. A bake need not reopen the source file.
        return (isinstance(digest, str) and re.fullmatch(r"[0-9a-f]{64}", digest) is not None
                and record.get("verified_citygml_sha256") == digest)
    return isinstance(layers, list) and "buildings" in layers
