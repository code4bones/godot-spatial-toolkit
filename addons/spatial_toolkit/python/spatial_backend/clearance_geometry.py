"""Derived visual and patrol clearances around building footprints."""

import ctypes as c

from .preview_geometry import Geometry

PATH_TAGS = {"footway", "path", "steps", "cycleway"}
PATROL_TAGS = {"motorway", "trunk", "primary", "secondary", "tertiary", "motorway_link",
               "trunk_link", "primary_link", "secondary_link", "tertiary_link", "unclassified",
               "residential", "living_street", "service", "road", "track"}


class ClearanceGeometry(Geometry):
    def __init__(self):
        super().__init__()
        self._bind("GEOSDifferencePrec_r", c.c_void_p, [c.c_void_p] * 3 + [c.c_double])
        self._bind("GEOSIntersects_r", c.c_byte, [c.c_void_p] * 3)
        self._bind("GEOSGeomTypeId_r", c.c_int, [c.c_void_p] * 2)

    def _parts(self, geometry, wanted):
        kind = self.lib.GEOSGeomTypeId_r(self.context, geometry)
        if kind == wanted:
            yield geometry
        elif kind in (5, 6, 7):
            for index in range(self.lib.GEOSGetNumGeometries_r(self.context, geometry)):
                part = self.lib.GEOSGetGeometryN_r(self.context, geometry, index)
                yield from self._parts(part, wanted)

    def _line_points(self, geometry):
        seq = self.lib.GEOSGeom_getCoordSeq_r(self.context, geometry)
        size = c.c_uint()
        self.lib.GEOSCoordSeq_getSize_r(self.context, seq, c.byref(size))
        points = []
        for index in range(size.value):
            x, z = c.c_double(), c.c_double()
            self.lib.GEOSCoordSeq_getX_r(self.context, seq, index, c.byref(x))
            self.lib.GEOSCoordSeq_getY_r(self.context, seq, index, c.byref(z))
            points.append([round(x.value, 6), round(z.value, 6)])
        return points

    def _road_triangles(self, geometry):
        for part in self._parts(geometry, 3):
            area = c.c_double()
            self.lib.GEOSArea_r(self.context, part, c.byref(area))
            if area.value >= 1e-5:
                yield from self._triangles(part)

    def _cut(self, route, mask, feature_id, line):
        if not route or self.lib.GEOSIntersects_r(self.context, route, mask) != 1:
            return None
        clipped = self.lib.GEOSDifferencePrec_r(self.context, route, mask, 0.00001)
        if not clipped:
            raise ValueError("Could not clip " + feature_id)
        try:
            if line:
                return [points for part in self._parts(clipped, 1)
                        if len(points := self._line_points(part)) >= 2]
            return [[[round(x, 6), round(z, 6)] for x, z in triangle]
                    for triangle in self._road_triangles(clipped)]
        finally:
            self._destroy(clipped)

    def generate(self, features, *, visual=True):
        polygons = []
        for feature in features:
            if feature["kind"] != "building":
                continue
            geometry = feature["geometry"]
            if geometry["type"] == "Polygon":
                polygons.append(geometry["coordinates"])
            elif geometry["type"] == "MultiPolygon":
                polygons.extend(geometry["coordinates"])
        changes = {"version": 1, "roads": {}, "paths": {}, "patrols": {}}
        if not polygons:
            return changes
        # Buffering a collection builds a union while keeping courtyard holes.
        walls = self._read("GEOMETRYCOLLECTION(" + ",".join(
            "POLYGON" + self._polygon_body(polygon) for polygon in polygons) + ")")
        road_mask = self.lib.GEOSBuffer_r(self.context, walls, 0.08, 3) if visual else None
        pipe_mask = self.lib.GEOSBuffer_r(self.context, walls, 0.55, 3) if visual else None
        patrol_mask = self.lib.GEOSBuffer_r(self.context, walls, 1.10, 3)
        self._destroy(walls)
        if not patrol_mask or (visual and (not road_mask or not pipe_mask)):
            self._destroy(road_mask)
            self._destroy(pipe_mask)
            self._destroy(patrol_mask)
            raise ValueError("Could not build footprint masks")
        try:
            for feature in features:
                if feature["kind"] != "road" or feature.get("status") != "existing":
                    continue
                geometry = feature["geometry"]
                if geometry["type"] != "LineString" or len(geometry["coordinates"]) < 2:
                    continue
                highway = feature.get("source", {}).get("tags", {}).get("highway")
                if not visual and highway not in PATROL_TAGS:
                    continue
                feature_id = feature["id"]
                line = self._read("LINESTRING(" + self._points(geometry["coordinates"]) + ")")
                try:
                    if highway in PATROL_TAGS:
                        result = self._cut(line, patrol_mask, feature_id, True)
                        if result is not None:
                            changes["patrols"][feature_id] = result
                    if visual and highway in PATH_TAGS:
                        result = self._cut(line, pipe_mask, feature_id, True)
                        if result is not None:
                            changes["paths"][feature_id] = result
                    elif visual:
                        road = self.lib.GEOSBuffer_r(self.context, line, float(feature["width_m"]) * 0.5, 3)
                        try:
                            result = self._cut(road, road_mask, feature_id, False)
                            if result is not None:
                                changes["roads"][feature_id] = result
                        finally:
                            self._destroy(road)
                finally:
                    self._destroy(line)
        finally:
            self._destroy(road_mask)
            self._destroy(pipe_mask)
            self._destroy(patrol_mask)
        return changes
