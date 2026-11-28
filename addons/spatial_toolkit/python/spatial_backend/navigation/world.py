"""Build a snapshot of local graphs and validated links across grid seams."""

from collections import defaultdict
from dataclasses import asdict
import hashlib
import json
import math
from pathlib import Path

from .coverage import load_coverage
from .graph import AABB, _ObstacleIndex, _inset, build_graph, finite_number, relevant_obstacles
from .storage import MANIFEST_NAMES, SCHEMA as STORAGE_SCHEMA, publish_world
from .world_data import bounds_array, load_baked_world


GENERATOR_VERSION = 1
MAX_CANDIDATE_CELLS = 65_536
MAX_PROGRESS_UPDATES = 200
MAX_CHUNK_EXAMPLES = 12


def _digest(value):
    payload = json.dumps(value, sort_keys=True, separators=(",", ":"), allow_nan=False).encode("utf-8")
    return hashlib.sha256(payload).hexdigest()


def _seam_links(first_id, first, second_id, second, axis, seam, reach, clearance_m, clear):
    """Keep nearby clear continuations from both sides of a shared face."""
    tangent = 2 if axis == 0 else 0

    def bucket(point):
        return math.floor(point[tangent] / reach), math.floor(point[1] / reach)

    def nearest(sources, targets, reverse):
        buckets = defaultdict(list)
        for node_id, point in targets:
            buckets[bucket(point)].append((node_id, point))
        for source_id, start in sources:
            lateral, vertical = bucket(start)
            candidates = []
            for dx in (-1, 0, 1):
                for dy in (-1, 0, 1):
                    for target_id, end in buckets.get((lateral + dx, vertical + dy), ()):
                        distance = math.dist(start, end)
                        if distance <= reach:
                            candidates.append((distance, target_id, end))
            for distance, target_id, end in sorted(candidates):
                if clear(start, end):
                    if reverse:
                        yield (target_id, source_id), (distance, end, start)
                    else:
                        yield (source_id, target_id), (distance, start, end)
                    break

    pairs = dict(nearest(first, second, False))
    pairs.update(nearest(second, first, True))
    for (from_node, to_node), (distance, start, end) in sorted(pairs.items()):
        fraction = (seam - start[axis]) / (end[axis] - start[axis])
        position = [a + (b - a) * fraction for a, b in zip(start, end)]
        position[axis] = seam
        yield {"id": _digest(((first_id, start), (second_id, end))),
               "from_chunk": first_id, "from_node": from_node,
               "to_chunk": second_id, "to_node": to_node,
               "position": position, "distance_m": distance, "clearance_m": clearance_m}


def _cell_span(minimum, maximum, origin, size):
    scaled_min, scaled_max = (finite_number((value - origin) / size, "World grid coordinate")
                              for value in (minimum, maximum))
    start, stop = math.floor(scaled_min), math.ceil(scaled_max)
    if not -(2**31) <= start < stop <= 2**31:
        raise ValueError("World coverage must fit signed 32-bit navigation cell indices")
    return range(start, stop)


def _border_nodes(nodes, axis, seam, reach, side):
    return tuple((index, point) for index, point in enumerate(nodes)
                 if 0 < (point[axis] - seam) * side <= reach)


def _sample_seeds(coverage, cell, profile):
    """Supplement the regular lattice in narrow pieces clipped by the source footprint."""
    volume = _inset(cell, profile.clearance_m)
    points = coverage.cell_seed_points(volume.minimum[0], volume.minimum[2],
                                       volume.maximum[0], volume.maximum[2])
    span = volume.maximum[1] - volume.minimum[1]
    count = max(1, math.ceil(span / profile.sample_step_m))
    return ((x, volume.minimum[1] + span * ((i + 0.5) / count), z)
            for x, z in points for i in range(count))


def build_world(world_data, world_index, output, *, heights, profile, grid_origin=(0, 0),
                grid_size_m=256.0, bake_manifest=None, progress=None, manifest_name=MANIFEST_NAMES[0]):
    """Publish covered grid cells and seam links for the verified source world index."""
    size = finite_number(grid_size_m, "Grid size")
    if size <= 2 * profile.clearance_m:
        raise ValueError("Grid size must exceed twice the configured clearance")
    origin_x, origin_z = (finite_number(value, "Grid origin") for value in grid_origin)
    low_y, high_y = (finite_number(value, "Height bound") for value in heights)
    if finite_number(high_y - low_y, "Height extent") <= 2 * profile.clearance_m:
        raise ValueError("Height range must exceed twice the configured clearance")
    world = load_baked_world(world_data, bake_manifest=bake_manifest)
    origin = (origin_x, 0.0, origin_z)
    reach = 2 * profile.sample_step_m
    boxes = [obstacle.bounds.expanded(profile.clearance_m) for obstacle in world.obstacles]
    index = _ObstacleIndex(boxes) if boxes else None
    portals = []
    empty_chunks = 0
    empty_examples = []
    uncovered_chunks = 0
    uncovered_examples = []

    with load_coverage(Path(world_index), world.provenance, profile.clearance_m) as coverage:
        min_x, min_z, max_x, max_z = coverage.bounds
        cells_x = _cell_span(min_x, max_x, origin_x, size)
        cells_z = _cell_span(min_z, max_z, origin_z, size)
        total = len(cells_x) * len(cells_z)
        if total > MAX_CANDIDATE_CELLS:
            raise ValueError(f"World grid exceeds {MAX_CANDIDATE_CELLS} candidate cells; increase grid size")
        progress_step = max(1, math.ceil(total / MAX_PROGRESS_UPDATES))
        settings = {"generator_version": GENERATOR_VERSION, "storage_schema": STORAGE_SCHEMA,
                    "origin": origin, "grid_size_m": size, "profile": asdict(profile),
                    "clearance_m": profile.clearance_m, "obstacle_model": "closed_aabb"}
        footprint = coverage.metadata
        footprint_hash = _digest(footprint)

        def contains_point(point):
            return coverage.contains_point(point[0], point[2])

        def contains_segment(start, end):
            return coverage.contains_segment(start[0], start[2], end[0], end[2])

        def seam_clear(start, end):
            return (index is None or not index.blocks(start, end)) and contains_segment(start, end)

        def chunks():
            nonlocal empty_chunks, uncovered_chunks
            north = {}
            for row, cell_z in enumerate(cells_z):
                z = origin_z + cell_z * size
                far_z = origin_z + (cell_z + 1) * size
                south = {}
                west = None
                for column, cell_x in enumerate(cells_x):
                    done = row * len(cells_x) + column
                    if progress is not None and done % progress_step == 0:
                        progress(done, total)
                    x = origin_x + cell_x * size
                    far_x = origin_x + (cell_x + 1) * size
                    chunk_id = f"{cell_x}_{cell_z}"
                    if not coverage.intersects_cell(x, z, far_x, far_z):
                        uncovered_chunks += 1
                        if len(uncovered_examples) < MAX_CHUNK_EXAMPLES:
                            uncovered_examples.append(chunk_id)
                        west = None
                        continue
                    cell = AABB((x, low_y, z), (far_x, high_y, far_z))
                    obstacles = relevant_obstacles(cell, world.obstacles, profile.clearance_m)
                    graph = build_graph(cell, obstacles, profile, contains_point=contains_point,
                                        contains_segment=contains_segment,
                                        extra_samples=_sample_seeds(coverage, cell, profile))
                    if not graph.nodes:
                        empty_chunks += 1
                        if len(empty_examples) < MAX_CHUNK_EXAMPLES:
                            empty_examples.append(chunk_id)
                    for neighbor, axis, seam in ((west, 0, x), (north.get(cell_x), 2, z)):
                        if neighbor is not None:
                            neighbor_id, neighbor_nodes = neighbor
                            border = _border_nodes(graph.nodes, axis, seam, reach, 1)
                            portals.extend(_seam_links(neighbor_id, neighbor_nodes, chunk_id, border,
                                                       axis, seam, reach, profile.clearance_m, seam_clear))
                    west = chunk_id, _border_nodes(graph.nodes, 0, far_x, reach, -1)
                    south[cell_x] = chunk_id, _border_nodes(graph.nodes, 2, far_z, reach, -1)
                    chunk_settings = {**settings, "chunk_id": chunk_id, "coverage": bounds_array(cell),
                                      "coverage_mode": "source_area_union", "coverage_key": footprint_hash}
                    obstacle_data = [{"source_id": item.source_id, "bounds": bounds_array(item.bounds)}
                                     for item in obstacles]
                    yield chunk_id, graph, {**chunk_settings, "provenance": world.provenance,
                                            "cache_key": _digest({**chunk_settings, "obstacles": obstacle_data}),
                                            "obstacle_source_ids": [item.source_id for item in obstacles]}
                north = south

        metadata = {**settings, "provenance": world.provenance, "coverage_mode": "source_area_union",
                    "coverage_key": footprint_hash, "source_coverage": footprint,
                    "covered_bounds": [min_x, low_y, min_z, max_x, high_y, max_z]}
        result = publish_world(Path(output).resolve(), origin=origin, grid_size_m=size,
                               chunks=chunks(), portals=iter(portals), metadata=metadata,
                               manifest_name=manifest_name)
    if progress is not None:
        progress(total, total)
    return {**result, "empty_chunk_count": empty_chunks, "empty_chunk_examples": empty_examples,
            "uncovered_chunk_count": uncovered_chunks, "uncovered_chunk_examples": uncovered_examples}
