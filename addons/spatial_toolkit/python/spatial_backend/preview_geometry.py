"""Optional preview geometry using the installed GEOS C API (>= 3.10).

No dependency is downloaded. Constrained triangulation keeps polygon holes.
Coordinates are local metres in the Godot X/Z plane.
"""
import ctypes as c
from ctypes.util import find_library
from collections import defaultdict
import math
import re


# Reference height for flat ground, road ribbons and other painted layers.
FLAT_GROUND_Y = -0.03
# Gameplay-only wall extension below the flat reference ground. Source height
# evidence remains the above-ground roof height; no source coordinates change.
FOUNDATION_BOTTOM = -0.05
# Rendering partition only: splitting at this Y lets Godot order the narrow
# lower wall band consistently with flat map layers without moving any surface.
FOUNDATION_RENDER_TOP = 0.5


class GeometryError(ValueError):
    pass


class FootprintIndex:
    """Narrow WGS84 footprint comparisons by bounds before calling GEOS."""

    def __init__(self, entries):
        self.entries = list(entries)
        self.cells = defaultdict(list)
        self.wide = []
        for index, (_, _, bounds) in enumerate(self.entries):
            cells = self._cells(bounds)
            if cells is None:
                self.wide.append(index)
            else:
                for cell in cells:
                    self.cells[cell].append(index)

    @staticmethod
    def _cells(bounds):
        x0, y0, x1, y1 = (math.floor(value * 500) for value in bounds)
        if (x1 - x0 + 1) * (y1 - y0 + 1) > 256:
            return None
        return ((x, y) for x in range(x0, x1 + 1) for y in range(y0, y1 + 1))

    def candidates(self, bounds):
        cells = self._cells(bounds)
        if cells is None:
            indices = range(len(self.entries))
        else:
            indexed = set(self.wide)
            for cell in cells:
                indexed.update(self.cells.get(cell, ()))
            indices = indexed
        west, south, east, north = bounds
        for index in indices:
            key, polygons, (low_x, low_y, high_x, high_y) = self.entries[index]
            if low_x < east and high_x > west and low_y < north and high_y > south:
                yield key, polygons


class Geometry:
    def __init__(self):
        library = find_library("geos_c")
        if not library:
            raise RuntimeError("Preview requires an installed GEOS C library >= 3.10")
        try:
            self.lib = c.CDLL(library)
            self._bind("GEOSversion", c.c_char_p, [])
            self.version = self.lib.GEOSversion().decode("ascii")
            version = re.match(r"(\d+)\.(\d+)", self.version)
            if not version or tuple(map(int, version.groups())) < (3, 10):
                raise RuntimeError(f"GEOS >= 3.10 required; found {self.version}")
            if not hasattr(self.lib, "GEOSConstrainedDelaunayTriangulation_r"):
                raise RuntimeError("GEOS lacks constrained triangulation; GEOS >= 3.10 required")
        except OSError as exc:
            raise RuntimeError(f"Cannot load GEOS C library: {exc}") from exc
        self._bind("GEOS_init_r", c.c_void_p, [])
        self._bind("GEOS_finish_r", None, [c.c_void_p])
        self._bind("GEOSWKTReader_create_r", c.c_void_p, [c.c_void_p])
        self._bind("GEOSWKTReader_destroy_r", None, [c.c_void_p, c.c_void_p])
        self._bind("GEOSWKTReader_read_r", c.c_void_p, [c.c_void_p, c.c_void_p, c.c_char_p])
        self._bind("GEOSGeom_destroy_r", None, [c.c_void_p, c.c_void_p])
        self._bind("GEOSisValid_r", c.c_byte, [c.c_void_p, c.c_void_p])
        for predicate in ("GEOSEquals_r", "GEOSCovers_r", "GEOSIntersects_r"):
            self._bind(predicate, c.c_byte, [c.c_void_p, c.c_void_p, c.c_void_p])
        self._bind("GEOSArea_r", c.c_int, [c.c_void_p, c.c_void_p, c.POINTER(c.c_double)])
        self._bind("GEOSIntersection_r", c.c_void_p, [c.c_void_p, c.c_void_p, c.c_void_p])
        self._bind("GEOSBuffer_r", c.c_void_p, [c.c_void_p, c.c_void_p, c.c_double, c.c_int])
        self._bind("GEOSConstrainedDelaunayTriangulation_r", c.c_void_p, [c.c_void_p, c.c_void_p])
        self._bind("GEOSGetNumGeometries_r", c.c_int, [c.c_void_p, c.c_void_p])
        self._bind("GEOSGetGeometryN_r", c.c_void_p, [c.c_void_p, c.c_void_p, c.c_int])
        self._bind("GEOSGetExteriorRing_r", c.c_void_p, [c.c_void_p, c.c_void_p])
        self._bind("GEOSGeom_getCoordSeq_r", c.c_void_p, [c.c_void_p, c.c_void_p])
        self._bind("GEOSCoordSeq_getSize_r", c.c_int, [c.c_void_p, c.c_void_p, c.POINTER(c.c_uint)])
        for axis in ("X", "Y"):
            self._bind("GEOSCoordSeq_get" + axis + "_r", c.c_int,
                       [c.c_void_p, c.c_void_p, c.c_uint, c.POINTER(c.c_double)])
        self.context = self.lib.GEOS_init_r()
        if not self.context:
            raise RuntimeError("GEOS context initialization failed")
        self.reader = self.lib.GEOSWKTReader_create_r(self.context)
        if not self.reader:
            self.lib.GEOS_finish_r(self.context)
            raise RuntimeError("GEOS reader initialization failed")

    def _bind(self, name, result, arguments):
        fn = getattr(self.lib, name)
        fn.restype, fn.argtypes = result, arguments

    def __enter__(self):
        return self

    def __exit__(self, *_):
        self.lib.GEOSWKTReader_destroy_r(self.context, self.reader)
        self.lib.GEOS_finish_r(self.context)

    def _read(self, wkt):
        geom = self.lib.GEOSWKTReader_read_r(self.context, self.reader, wkt.encode())
        if not geom:
            raise GeometryError("GEOS rejected geometry")
        return geom

    def _destroy(self, geom):
        if geom:
            self.lib.GEOSGeom_destroy_r(self.context, geom)

    @staticmethod
    def _points(points):
        return ",".join(f"{x:.9f} {z:.9f}" for x, z in points)

    def _triangles(self, polygon):
        if self.lib.GEOSisValid_r(self.context, polygon) != 1:
            raise GeometryError("Invalid polygon; no automatic topology repair was applied")
        area = c.c_double()
        self.lib.GEOSArea_r(self.context, polygon, c.byref(area))
        result = self.lib.GEOSConstrainedDelaunayTriangulation_r(self.context, polygon)
        if not result:
            raise GeometryError("Constrained triangulation failed")
        try:
            triangles = []
            for i in range(self.lib.GEOSGetNumGeometries_r(self.context, result)):
                triangle = self.lib.GEOSGetGeometryN_r(self.context, result, i)
                ring = self.lib.GEOSGetExteriorRing_r(self.context, triangle)
                seq = self.lib.GEOSGeom_getCoordSeq_r(self.context, ring)
                size = c.c_uint()
                self.lib.GEOSCoordSeq_getSize_r(self.context, seq, c.byref(size))
                if size.value != 4:
                    raise GeometryError("Triangulator returned a non-triangle")
                points = []
                for j in range(3):
                    x, z = c.c_double(), c.c_double()
                    self.lib.GEOSCoordSeq_getX_r(self.context, seq, j, c.byref(x))
                    self.lib.GEOSCoordSeq_getY_r(self.context, seq, j, c.byref(z))
                    points.append([x.value, z.value])
                triangles.append(points)
            actual = sum(abs(signed_area(t)) for t in triangles)
            if not triangles or not math.isclose(actual, area.value, rel_tol=1e-7, abs_tol=1e-5):
                raise GeometryError("Triangulated area does not match polygon area")
            return triangles
        finally:
            self._destroy(result)

    def _polygon_body(self, rings):
        return "(" + ",".join("(" + self._points(r) + ")" for r in rings) + ")"

    def compare_footprints(self, outer, inner, *, equal):
        objects = []
        try:
            for polygons in (outer, inner):
                body = ",".join(self._polygon_body(rings) for rings in polygons)
                objects.append(self._read("MULTIPOLYGON(" + body + ")"))
            if any(self.lib.GEOSisValid_r(self.context, obj) != 1 for obj in objects):
                return False
            predicate = self.lib.GEOSEquals_r if equal else self.lib.GEOSCovers_r
            return predicate(self.context, *objects) == 1
        finally:
            for obj in objects:
                self._destroy(obj)

    def polygon(self, rings):
        polygon = self._read("POLYGON" + self._polygon_body(rings))
        try:
            return self._triangles(polygon)
        finally:
            self._destroy(polygon)

    def intersects_box(self, polygons, west, south, east, north):
        box = self._read("POLYGON" + self._polygon_body([[
            (west, south), (east, south), (east, north), (west, north), (west, south)]]))
        try:
            for rings in polygons:
                polygon = self._read("POLYGON" + self._polygon_body(rings))
                try:
                    if self.lib.GEOSIntersects_r(self.context, polygon, box) == 1:
                        return True
                finally:
                    self._destroy(polygon)
            return False
        finally:
            self._destroy(box)

    def footprint_overlap(self, first, second):
        """Share of each footprint covered by their intersection, zero if invalid."""
        shapes = []
        overlap = None
        try:
            for polygons in (first, second):
                body = ",".join(self._polygon_body(rings) for rings in polygons)
                shapes.append(self._read("MULTIPOLYGON(" + body + ")"))
            if any(self.lib.GEOSisValid_r(self.context, shape) != 1 for shape in shapes):
                return 0.0, 0.0
            overlap = self.lib.GEOSIntersection_r(self.context, *shapes)
            if not overlap:
                return 0.0, 0.0
            areas = []
            for shape in (*shapes, overlap):
                area = c.c_double()
                if self.lib.GEOSArea_r(self.context, shape, c.byref(area)) != 1:
                    return 0.0, 0.0
                areas.append(area.value)
            return tuple(areas[2] / area if area > 0 else 0.0 for area in areas[:2])
        finally:
            self._destroy(overlap)
            for shape in shapes:
                self._destroy(shape)

    def road(self, points, width):
        line = self._read("LINESTRING(" + self._points(points) + ")")
        polygon = None
        try:
            polygon = self.lib.GEOSBuffer_r(self.context, line, width / 2, 3)
            if not polygon:
                raise GeometryError("Road buffer failed")
            return self._triangles(polygon)
        finally:
            self._destroy(polygon)
            self._destroy(line)


def signed_area(points):
    return sum(a[0] * b[1] - b[0] * a[1]
               for a, b in zip(points, points[1:] + points[:1])) / 2


def surface(triangles, y):
    vertices, normals = [], []
    for triangle in triangles:
        a, b, d = triangle
        if signed_area(triangle) > 0:
            b, d = d, b
        vertices.extend([[a[0], y, a[1]], [b[0], y, b[1]], [d[0], y, d[1]]])
        normals.extend([[0, 1, 0]] * 3)
    return vertices, normals


def building_mesh(geometry, polygons, height, wall_cutoffs=None):
    vertices, normals = [], []
    wall_cutoffs = wall_cutoffs or {}
    for polygon_index, rings in enumerate(polygons):
        v, n = surface(geometry.polygon(rings), height)
        vertices.extend(v)
        normals.extend(n)
        for index, ring in enumerate(rings):
            sign = (1 if signed_area(ring) > 0 else -1) * (1 if index == 0 else -1)
            for edge_index, (a, b) in enumerate(zip(ring, ring[1:])):
                dx, dz = b[0] - a[0], b[1] - a[1]
                length = math.hypot(dx, dz)
                if length < 1e-8:
                    continue
                normal = [sign * dz / length, 0, -sign * dx / length]
                cut = min(FOUNDATION_RENDER_TOP, height)
                spans = wall_cutoffs.get((polygon_index, index, edge_index), [(0.0, 1.0, -math.inf)])
                for start, end, shared_height in spans:
                    ax, az = a[0] + dx * start, a[1] + dz * start
                    bx, bz = b if end == 1.0 else (a[0] + dx * end, a[1] + dz * end)
                    for bottom, top in ((FOUNDATION_BOTTOM, cut), (cut, height)):
                        bottom = max(bottom, shared_height)
                        if top <= bottom:
                            continue
                        lo_a, lo_b = [ax, bottom, az], [bx, bottom, bz]
                        hi_a, hi_b = [ax, top, az], [bx, top, bz]
                        vertices.extend([lo_a, lo_b, hi_b, lo_a, hi_b, hi_a])
                        normals.extend([normal] * 6)
    return vertices, normals
