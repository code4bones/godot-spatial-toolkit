"""Identify OSM building shells that would draw the same solid surfaces."""
from collections import defaultdict
import math

from .preview_geometry import GeometryError, signed_area


def coincident_buildings(prepared, geometry):
    """Return redundant source IDs and their owners without rewriting footprints.

    Suppress equal volumes and address-matched building parts covered by their
    whole building at the same height. Nearby and partly overlapping shells
    remain separate, as do features with different resolved dimensions.
    """
    footprints = defaultdict(list)
    parents = defaultdict(list)
    duplicates = {}
    rows = [row for row in prepared if row[2] == "building" and _osm_building_id(row[0])]
    rows.sort(key=lambda row: (_is_part(row[1]), -len(row[1]), row[0]))
    for source_id, tags, _, _, item, _, _ in rows:
        footprint = item["geometry"]
        polygons = [footprint["coordinates"]] if footprint["type"] == "Polygon" else footprint["coordinates"]
        bounds = _bounds(polygons)
        if bounds is None:
            continue
        building = tags.get("building")
        if not isinstance(building, str):
            continue
        dimensions = (building, item["height_m"], item["wall_height_m"], item["roof_height_m"])
        footprint_key = (dimensions, bounds)
        address = (tags.get("addr:street"), tags.get("addr:housenumber"))
        addressed = all(isinstance(value, str) and value for value in address)
        address_key = (dimensions, address)
        owner = _matching_owner(geometry, footprints[footprint_key], polygons, bounds, equal=True)
        reason = "same footprint and solid height"
        if owner is None and _is_part(tags) and addressed:
            owner = _matching_owner(geometry, parents[address_key], polygons, bounds, equal=False)
            reason = "same-height addressed building part covered by its building"
        if owner is not None:
            duplicates[source_id] = {"id": source_id, "rendered_as": owner, "reason": reason}
            continue
        candidate = (source_id, polygons, bounds)
        footprints[footprint_key].append(candidate)
        if not _is_part(tags) and addressed:
            parents[address_key].append(candidate)
    _covered_generic_shells(rows, geometry, duplicates)
    return duplicates


def _covered_generic_shells(rows, geometry, duplicates):
    shells = []
    for fid, tags, _, _, item, _, _ in rows:
        shape = item["geometry"]
        polygons = [shape["coordinates"]] if shape["type"] == "Polygon" else shape["coordinates"]
        bounds = _bounds(polygons)
        if bounds is not None:
            shells.append((item["height_m"], fid, tags, polygons, bounds))
    shells.sort(key=lambda shell: (-shell[0], shell[1]))
    owners = []
    for height, fid, tags, polygons, bounds in shells:
        if fid in duplicates:
            continue
        if tags.get("building") == "yes" and not tags.get("addr:street") and not tags.get("addr:housenumber"):
            for outer_height, owner, outer_polygons, outer_bounds in owners:
                if outer_height <= height:
                    break
                if not _bounds_cover(outer_bounds, bounds):
                    continue
                if not any(_wall_overlap(wall, other) is not None
                           for wall in _exterior_walls(polygons) for other in _exterior_walls(outer_polygons)):
                    continue
                if _matching_owner(geometry, [(owner, outer_polygons, outer_bounds)], polygons, bounds,
                                   equal=False) is not None:
                    duplicates[fid] = {"id": fid, "rendered_as": owner,
                                       "reason": "shorter unaddressed shell covered by a building with a shared exterior wall"}
                    break
        if fid not in duplicates:
            owners.append((height, fid, polygons, bounds))
    # An equal-height alias may already point at a shell covered in this pass.
    for duplicate in duplicates.values():
        while duplicate["rendered_as"] in duplicates:
            duplicate["rendered_as"] = duplicates[duplicate["rendered_as"]]["rendered_as"]


def _exterior_walls(polygons):
    walls = []
    for rings in polygons:
        if not rings:
            continue
        ring = rings[0]
        positive = signed_area(ring) > 0
        walls.extend((a, b) if positive else (b, a) for a, b in zip(ring, ring[1:]))
    return walls


def _bounds_cover(outer, inner):
    return (outer[0] <= inner[0] and outer[1] <= inner[1]
            and outer[2] >= inner[2] and outer[3] >= inner[3])


def _osm_building_id(source_id):
    kind, _, number = source_id.partition("/")
    return kind in ("way", "relation") and number.isdigit()


def _is_part(tags):
    return tags.get("building:part") not in (None, "", "no")


def _bounds(polygons):
    points = [point for rings in polygons if rings for point in rings[0]]
    if not points:
        return None
    x, z = zip(*points)
    return min(x), min(z), max(x), max(z)


def _matching_owner(geometry, candidates, polygons, bounds, *, equal):
    for owner, candidate, outer in candidates:
        if not _bounds_cover(outer, bounds):
            continue
        try:
            if geometry.compare_footprints(candidate, polygons, equal=equal):
                return owner
        except GeometryError:
            # Ordinary mesh validation will report invalid source geometry.
            continue
    return None


def coincident_walls(prepared, geometry, redundant):
    """Assign overlapping portions of outward-facing walls at the same address."""
    edges = defaultdict(list)
    polygons_by_id = {}
    material_priority = {}
    for fid, tags, kind, _, item, _, _ in prepared:
        if kind != "building" or fid in redundant or not _osm_building_id(fid):
            continue
        address = (tags.get("addr:street"), tags.get("addr:housenumber"), tags.get("building"))
        if not all(isinstance(value, str) and value for value in address):
            continue
        shape = item["geometry"]
        polygons = [shape["coordinates"]] if shape["type"] == "Polygon" else shape["coordinates"]
        polygons_by_id[fid] = polygons
        material = tags.get("building:material")
        has_material = isinstance(material, str) and bool(material.strip())
        material_priority[fid] = (not has_material, -len(tags), fid)
        for polygon_index, polygon in enumerate(polygons):
            for ring_index, ring in enumerate(polygon):
                outward = (signed_area(ring) > 0) == (ring_index == 0)
                for edge_index, (a, b) in enumerate(zip(ring, ring[1:])):
                    if a == b:
                        continue
                    directed = (tuple(a), tuple(b)) if outward else (tuple(b), tuple(a))
                    edges[address].append((item["height_m"], fid,
                                           (polygon_index, ring_index, edge_index), directed, outward))
    valid = {}
    cutoffs = defaultdict(dict)
    for group in edges.values():
        if len({edge[1] for edge in group}) < 2:
            continue
        preceding = []
        # A lower shell owns the shared height band. At equal height preserve
        # the facade with explicit material evidence, then the richer record.
        ordered = sorted(group, key=lambda edge: (edge[0], material_priority[edge[1]], edge[2]))
        for height, fid, edge_index, directed, outward in ordered:
            overlaps = []
            for other_height, other_id, other_wall in preceding:
                if other_id == fid:
                    continue
                overlap = _wall_overlap(directed, other_wall)
                if overlap is not None and _valid_building(geometry, polygons_by_id, valid, other_id):
                    start, end = overlap
                    if not outward:
                        start, end = 1.0 - end, 1.0 - start
                    overlaps.append((start, end, other_height))
            if overlaps and _valid_building(geometry, polygons_by_id, valid, fid):
                cuts = sorted({0.0, 1.0, *(value for low, high, _ in overlaps for value in (low, high))})
                spans = []
                for start, end in zip(cuts, cuts[1:]):
                    midpoint = (start + end) * 0.5
                    top = max((height for low, high, height in overlaps if low <= midpoint <= high),
                              default=-math.inf)
                    spans.append((start, end, top))
                cutoffs[fid][edge_index] = spans
            preceding.append((height, fid, directed))
    return cutoffs


def _valid_building(geometry, footprints, valid, fid):
    if fid not in valid:
        try:
            polygons = footprints[fid]
            valid[fid] = geometry.compare_footprints(polygons, polygons, equal=True)
        except GeometryError:
            valid[fid] = False
    return valid[fid]


def _wall_overlap(wall, other):
    a, b = wall
    c, d = other
    x, z = b[0] - a[0], b[1] - a[1]
    length = math.hypot(x, z)
    if length < 1e-8:
        return None
    x, z = x / length, z / length
    cx, cz = c[0] - a[0], c[1] - a[1]
    dx, dz = d[0] - a[0], d[1] - a[1]
    if abs(cx * z - cz * x) > 0.002 or abs(dx * z - dz * x) > 0.002:
        return None
    low, high = cx * x + cz * z, dx * x + dz * z
    start, end = max(0.0, low), min(length, high)
    if end - start <= 0.002:
        return None
    if start <= 0.002:
        start = 0.0
    if length - end <= 0.002:
        end = length
    return start / length, end / length
