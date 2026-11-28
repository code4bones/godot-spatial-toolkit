"""Build a deterministic static flight graph for one covered volume.

The agent clearance is measured in gameplay metres. Inflating closed building
boxes by that amount is conservative for a spherical agent. The sampled graph
can miss small passages and reports its connected component count.
"""

from collections import defaultdict
from dataclasses import dataclass
from heapq import nsmallest
from itertools import product
import math
from typing import Callable, Iterable


Point = tuple[float, float, float]
MAX_NODES = 8_192
_CELL_OFFSETS = tuple(product((-1, 0, 1), repeat=3))
_NEIGHBOR_CANDIDATES = 48


def finite_number(value: float, label: str) -> float:
    """Normalize a numeric coordinate and reject non-finite values."""
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise ValueError(f"{label} must be a finite number")
    try:
        value = float(value)
    except OverflowError as exc:
        raise ValueError(f"{label} must be a finite number") from exc
    if not math.isfinite(value):
        raise ValueError(f"{label} must be a finite number")
    return value if value else 0.0


def finite_point(values: Point, label: str) -> Point:
    """Read three finite XYZ coordinates."""
    if not isinstance(values, (tuple, list)) or len(values) != 3:
        raise ValueError(f"{label} must have three coordinates")
    return tuple(finite_number(value, label) for value in values)


@dataclass(frozen=True, slots=True)
class AABB:
    minimum: Point
    maximum: Point

    def __post_init__(self) -> None:
        minimum = finite_point(self.minimum, "AABB minimum")
        maximum = finite_point(self.maximum, "AABB maximum")
        if any(low > high for low, high in zip(minimum, maximum)):
            raise ValueError("AABB bounds must be ordered")
        object.__setattr__(self, "minimum", minimum)
        object.__setattr__(self, "maximum", maximum)

    def contains(self, point: Point) -> bool:
        return all(low <= value <= high for low, value, high in
                   zip(self.minimum, point, self.maximum))

    def intersects(self, other: "AABB") -> bool:
        return all(self.minimum[axis] <= other.maximum[axis] and
                   other.minimum[axis] <= self.maximum[axis] for axis in range(3))

    def expanded(self, amount: float) -> "AABB":
        amount = finite_number(amount, "AABB padding")
        if not amount:
            return self
        if amount < 0:
            raise ValueError("AABB padding must be nonnegative")
        # Bias rounding outwards so clearance is never reduced by rounding.
        return AABB(
            tuple(math.nextafter(value - amount, -math.inf) for value in self.minimum),
            tuple(math.nextafter(value + amount, math.inf) for value in self.maximum),
        )


@dataclass(frozen=True, slots=True)
class Obstacle:
    source_id: str
    bounds: AABB

    def __post_init__(self) -> None:
        if not isinstance(self.source_id, str) or not self.source_id:
            raise ValueError("Obstacle source_id must be a nonempty string")
        if not isinstance(self.bounds, AABB):
            raise ValueError("Obstacle bounds must be an AABB")


@dataclass(frozen=True, slots=True)
class GraphProfile:
    agent_radius_m: float
    safety_margin_m: float
    sample_step_m: float = 32.0
    max_neighbors: int = 12

    def __post_init__(self) -> None:
        for name in ("agent_radius_m", "safety_margin_m", "sample_step_m"):
            object.__setattr__(self, name, finite_number(getattr(self, name), name))
        if self.agent_radius_m < 0 or self.safety_margin_m < 0:
            raise ValueError("Agent radius and safety margin must be nonnegative")
        if not math.isfinite(self.clearance_m):
            raise ValueError("Combined clearance must be finite")
        if self.sample_step_m <= 0 or not math.isfinite(2 * self.sample_step_m):
            raise ValueError("Sample step must be positive with finite doubled distance")
        if type(self.max_neighbors) is not int or self.max_neighbors < 1:
            raise ValueError("Maximum neighbors must be a positive integer")

    @property
    def clearance_m(self) -> float:
        return self.agent_radius_m + self.safety_margin_m


@dataclass(frozen=True, slots=True)
class Edge:
    source: int
    target: int
    distance_m: float
    clearance_m: float
    cost: float
    flags: int


@dataclass(frozen=True, slots=True)
class Graph:
    nodes: tuple[Point, ...]
    edges: tuple[Edge, ...]
    component_count: int


def relevant_obstacles(coverage: AABB, obstacles: Iterable[Obstacle],
                       clearance_m: float) -> tuple[Obstacle, ...]:
    """Select all obstacles in or near the coverage, including across its seams."""
    vicinity = coverage.expanded(clearance_m)
    by_id = {}
    for obstacle in obstacles:
        if not isinstance(obstacle, Obstacle):
            raise ValueError("Every obstacle must have a source ID and AABB")
        previous = by_id.setdefault(obstacle.source_id, obstacle)
        if previous != obstacle:
            raise ValueError(f"Conflicting bounds for obstacle {obstacle.source_id}")
    return tuple(obstacle for _, obstacle in sorted(by_id.items())
                 if vicinity.intersects(obstacle.bounds))


def _inset(coverage: AABB, clearance_m: float) -> AABB:
    minimum = coverage.minimum
    maximum = coverage.maximum
    if clearance_m:
        minimum = tuple(math.nextafter(value + clearance_m, math.inf) for value in minimum)
        maximum = tuple(math.nextafter(value - clearance_m, -math.inf) for value in maximum)
    if any(low >= high for low, high in zip(minimum, maximum)):
        raise ValueError("Coverage must have a positive interior after clearance")
    if not math.isfinite(math.dist(minimum, maximum)):
        raise ValueError("Coverage extent must be finite")
    return AABB(minimum, maximum)


def _segment_hits(box: AABB, start: Point, end: Point) -> bool:
    """Closed segment against closed slabs, including tangency."""
    first, last = 0.0, 1.0
    for lo, hi, a, b in zip(box.minimum, box.maximum, start, end):
        if max(a, b) < lo or min(a, b) > hi:
            return False
        if a == b:
            continue
        if b < a:
            lo, hi = hi, lo
        delta = b - a
        enter = math.nextafter((lo - a) / delta, -math.inf)
        leave = math.nextafter((hi - a) / delta, math.inf)
        first = max(first, enter)
        last = min(last, leave)
        # Keep nearly equal slab crossings blocked despite roundoff in the ratios.
        if first > last and first - last > 4 * max(math.ulp(first), math.ulp(last)):
            return False
    return True


class _ObstacleIndex:
    """A small bounding volume tree over the inflated obstacle boxes."""

    def __init__(self, boxes: list[AABB]) -> None:
        self.bounds = boxes[0]
        self.boxes = boxes
        self.children = ()
        if len(boxes) == 1:
            return
        self.bounds = AABB(
            tuple(min(box.minimum[axis] for box in boxes) for axis in range(3)),
            tuple(max(box.maximum[axis] for box in boxes) for axis in range(3)),
        )
        if len(boxes) > 4:
            axis = max(range(3), key=lambda i: self.bounds.maximum[i] - self.bounds.minimum[i])
            ordered = sorted(boxes, key=lambda box: box.minimum[axis] * 0.5 + box.maximum[axis] * 0.5)
            middle = len(ordered) // 2
            self.children = (_ObstacleIndex(ordered[:middle]), _ObstacleIndex(ordered[middle:]))
            self.boxes = []

    def blocks(self, start: Point, end: Point) -> bool:
        if not _segment_hits(self.bounds, start, end):
            return False
        if self.children:
            return any(child.blocks(start, end) for child in self.children)
        return len(self.boxes) == 1 or any(_segment_hits(box, start, end) for box in self.boxes)


def _lattice(coverage: AABB, step: float) -> Iterable[Point]:
    spans = tuple(hi - lo for lo, hi in zip(coverage.minimum, coverage.maximum))
    ratios = tuple(span / step for span in spans)
    if any(ratio > MAX_NODES for ratio in ratios):
        raise ValueError(f"Lattice exceeds {MAX_NODES} samples; increase sample step or reduce coverage")
    counts = tuple(max(1, math.ceil(ratio)) for ratio in ratios)
    if math.prod(counts) > MAX_NODES:
        raise ValueError(f"Lattice exceeds {MAX_NODES} samples; increase sample step or reduce coverage")
    coordinates = []
    for minimum, maximum, span, count in zip(coverage.minimum, coverage.maximum, spans, counts):
        samples = [minimum + span * ((index + 0.5) / count) for index in range(count)]
        if (samples[0] <= minimum or samples[-1] >= maximum or
                any(first >= second for first, second in zip(samples, samples[1:]))):
            raise ValueError("Coverage coordinates cannot represent the requested sample spacing")
        coordinates.append(samples)
    return product(*coordinates)


def _waypoints(box: AABB, volume: AABB, step: float) -> Iterable[Point]:
    """Sample the outside corners and above the roof of a visible obstacle."""
    if not box.intersects(volume):
        return
    standoff = min(step * 0.05, 0.05)
    center = tuple(max(lo, box_lo) * 0.5 + min(hi, box_hi) * 0.5
                   for lo, hi, box_lo, box_hi in zip(volume.minimum, volume.maximum,
                                                     box.minimum, box.maximum))
    sides_x = (math.nextafter(box.minimum[0] - standoff, -math.inf),
               math.nextafter(box.maximum[0] + standoff, math.inf))
    sides_z = (math.nextafter(box.minimum[2] - standoff, -math.inf),
               math.nextafter(box.maximum[2] + standoff, math.inf))
    roof_y = math.nextafter(box.maximum[1] + standoff, math.inf)
    yield from product(sides_x, (center[1], roof_y), sides_z)
    yield center[0], roof_y, center[2]


def _candidate_links(nodes: tuple[Point, ...], origin: Point,
                     reach: float) -> list[tuple[float, int, int]]:
    def cell(point: Point) -> tuple[int, int, int]:
        return tuple(math.floor((value - low) / reach) for value, low in zip(point, origin))

    cells = [cell(point) for point in nodes]
    by_cell = defaultdict(list)
    for index, key in enumerate(cells):
        by_cell[key].append(index)

    def nearby(source: int) -> Iterable[tuple[float, int]]:
        x, y, z = cells[source]
        for dx, dy, dz in _CELL_OFFSETS:
            for target in by_cell.get((x + dx, y + dy, z + dz), ()):
                if source != target:
                    distance = math.dist(nodes[source], nodes[target])
                    if distance <= reach:
                        yield distance, target

    links = {}
    for source in range(len(nodes)):
        for distance, target in nsmallest(_NEIGHBOR_CANDIDATES, nearby(source)):
            link = (source, target) if source < target else (target, source)
            links[link] = distance
    return sorted((distance, source, target) for (source, target), distance in links.items())


def _connect(nodes: tuple[Point, ...], index: _ObstacleIndex | None,
             origin: Point, profile: GraphProfile,
             contains_segment: Callable[[Point, Point], bool] | None) -> Graph:
    parents = list(range(len(nodes)))
    degree = [0] * len(nodes)
    edges = []

    def root(node: int) -> int:
        while parents[node] != node:
            parents[node] = parents[parents[node]]
            node = parents[node]
        return node

    def add_edge(distance: float, source: int, target: int) -> bool:
        if max(degree[source], degree[target]) >= profile.max_neighbors:
            return False
        if index is not None and index.blocks(nodes[source], nodes[target]):
            return False
        if contains_segment is not None and not contains_segment(nodes[source], nodes[target]):
            return False
        edges.append(Edge(source, target, distance, profile.clearance_m, distance, 0))
        degree[source] += 1
        degree[target] += 1
        return True

    # Give links between currently disconnected groups priority over cycle edges.
    cycles = []
    for distance, source, target in _candidate_links(nodes, origin, 2 * profile.sample_step_m):
        first, second = root(source), root(target)
        if first == second:
            cycles.append((distance, source, target))
        elif add_edge(distance, source, target):
            parents[second] = first
    for distance, source, target in cycles:
        add_edge(distance, source, target)
    components = sum(index == parent for index, parent in enumerate(parents))
    return Graph(nodes, tuple(sorted(edges, key=lambda edge: (edge.source, edge.target))), components)


def build_graph(coverage: AABB, obstacles: Iterable[Obstacle], profile: GraphProfile, *,
                contains_point: Callable[[Point], bool] | None = None,
                contains_segment: Callable[[Point, Point], bool] | None = None,
                extra_samples: Iterable[Point] = ()) -> Graph:
    """Sample a covered volume and join nearby points with proven clearance."""
    if not isinstance(coverage, AABB) or not isinstance(profile, GraphProfile):
        raise ValueError("Graph generation requires an AABB and a graph profile")
    volume = _inset(coverage, profile.clearance_m)
    lattice = _lattice(volume, profile.sample_step_m)
    boxes = [obstacle.bounds.expanded(profile.clearance_m)
             for obstacle in relevant_obstacles(coverage, obstacles, profile.clearance_m)]
    boxes = [box for box in boxes if box.intersects(volume)]
    index = _ObstacleIndex(boxes) if boxes else None
    nodes = set()

    def add_sample(point: Point) -> None:
        if volume.contains(point) and (index is None or not index.blocks(point, point)):
            if contains_point is not None and not contains_point(point):
                return
            nodes.add(tuple(coordinate or 0.0 for coordinate in point))
            if len(nodes) > MAX_NODES:
                raise ValueError(f"Graph exceeds {MAX_NODES} nodes; increase sample step or reduce coverage")

    for point in lattice:
        add_sample(point)
    for point in extra_samples:
        add_sample(point)
    for box in boxes:
        for point in _waypoints(box, volume, profile.sample_step_m):
            add_sample(point)
    return _connect(tuple(sorted(nodes)), index, volume.minimum, profile, contains_segment)
