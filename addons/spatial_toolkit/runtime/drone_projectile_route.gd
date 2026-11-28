extends RefCounted
## Connects a gameplay projectile to the map's published patrol corridors.

const MAX_CONNECTOR_CANDIDATES := 112
const MAX_CONNECTORS := 24
const MAX_EXPANDED_NODES := 8192
const MAX_EDGE_CHECKS := 512
const MAX_PATH_ATTEMPTS := 6
const MAX_SMOOTH_CHECKS := 512
const CORNER_TRIM_M := 8.0

static func plan(graph: SpatialPatrolGraph, graph_root: Node3D, start: Vector3,
		destination: Vector3, clearance_m: float, max_distance_m: float,
		is_segment_clear: Callable) -> PackedVector3Array:
	if graph == null or graph.points.is_empty() or not is_instance_valid(graph_root) \
			or not start.is_finite() or not destination.is_finite() or not is_segment_clear.is_valid() \
			or not is_finite(max_distance_m) or start.distance_to(destination) > max_distance_m \
			or not is_finite(clearance_m) or clearance_m < 0.0:
		return PackedVector3Array()
	var transform := graph_root.global_transform
	var local_start := graph_root.to_local(start)
	var local_destination := graph_root.to_local(destination)
	var points := PackedVector3Array()
	points.resize(graph.points.size())
	for index in points.size():
		points[index] = transform * graph.points[index]
	var entries := _connections(graph, points, start, destination, local_start,
		clearance_m, max_distance_m, is_segment_clear)
	var exits := _connections(graph, points, destination, start, local_destination,
		clearance_m, max_distance_m, is_segment_clear, true)
	if entries.is_empty() or exits.is_empty():
		return PackedVector3Array()
	var checked: Dictionary[Vector2i, bool] = {}
	for _attempt in MAX_PATH_ATTEMPTS:
		var nodes := _find_links(graph, points, entries, exits, destination, clearance_m, max_distance_m, checked)
		if nodes.is_empty():
			break
		var clear := true
		for index in range(1, nodes.size()):
			var first := nodes[index - 1]
			var second := nodes[index]
			var edge := _edge_key(first, second)
			if not checked.has(edge):
				if checked.size() >= MAX_EDGE_CHECKS:
					return PackedVector3Array()
				checked[edge] = is_segment_clear.call(points[first], points[second])
			clear = checked[edge] and clear
		if clear:
			var route := PackedVector3Array([start])
			for node in nodes:
				if route[-1] != points[node]:
					route.append(points[node])
			if route[-1] != destination:
				route.append(destination)
			return _rounded_route(route, graph, transform.affine_inverse(), clearance_m, is_segment_clear)
	return PackedVector3Array()

static func _connections(graph: SpatialPatrolGraph, points: PackedVector3Array, endpoint: Vector3,
		other_endpoint: Vector3, local_endpoint: Vector3, clearance: float, max_distance: float,
		is_segment_clear: Callable, ending := false) -> Dictionary[int, float]:
	# Retain a bounded set of nearby nodes before making physics queries.
	var nearby := SpatialPatrolLegPlanner.Frontier.new()
	var count := 0
	var cutoff := max_distance
	for node in points.size():
		var distance := points[node].distance_to(endpoint)
		if not is_finite(distance) or distance > cutoff \
				or distance + points[node].distance_to(other_endpoint) > max_distance:
			continue
		nearby.push(node, -distance)
		if count == MAX_CONNECTOR_CANDIDATES:
			cutoff = points[nearby.pop()].distance_to(endpoint)
		else:
			count += 1
	var candidates := PackedInt32Array()
	candidates.resize(count)
	for index in range(count - 1, -1, -1):
		candidates[index] = nearby.pop()
	var connections: Dictionary[int, float] = {}
	var inside := graph.covers_flight_segment(local_endpoint, local_endpoint, clearance, true)
	for node in candidates:
		if not _connector_covered(graph, local_endpoint, graph.points[node], clearance, inside):
			continue
		var point := points[node]
		if point == endpoint or (is_segment_clear.call(point, endpoint) if ending \
				else is_segment_clear.call(endpoint, point)):
			connections[node] = point.distance_to(endpoint)
			if connections.size() == MAX_CONNECTORS:
				break
	return connections

static func _connector_covered(graph: SpatialPatrolGraph, endpoint: Vector3, node: Vector3,
		clearance: float, inside: bool) -> bool:
	if inside:
		return graph.covers_flight_shortcut(endpoint, node, clearance)
	# A muzzle can be above the grid or just outside the coverage box. Its
	# connector must enter the candidate node's region before crossing any seam.
	var regions := graph.flight_regions
	if regions.is_empty():
		if not graph.coverage.has_volume():
			return true
		regions = [graph.coverage]
	var first_entry := INF
	var node_entry := INF
	for coverage_region in regions:
		var region := SpatialPatrolGraph._flight_region_with_clearance(coverage_region, clearance)
		if not region.has_volume():
			continue
		var entry: Variant = region.intersects_segment(endpoint, node)
		if entry is Vector3:
			var distance := endpoint.distance_to(entry)
			first_entry = minf(first_entry, distance)
			if region.has_point(node):
				node_entry = minf(node_entry, distance)
	return is_finite(node_entry) and node_entry <= first_entry + SpatialPatrolGraph.FLIGHT_REGION_TOLERANCE

static func _find_links(graph: SpatialPatrolGraph, points: PackedVector3Array,
		entries: Dictionary[int, float], exits: Dictionary[int, float], destination: Vector3,
		clearance: float, max_distance: float, checked: Dictionary[Vector2i, bool]) -> PackedInt32Array:
	var costs := PackedFloat64Array()
	costs.resize(points.size())
	costs.fill(INF)
	var parents := PackedInt32Array()
	parents.resize(points.size())
	parents.fill(-1)
	var settled := PackedByteArray()
	settled.resize(points.size())
	var frontier := SpatialPatrolLegPlanner.Frontier.new()
	for node: int in entries:
		costs[node] = entries[node]
		frontier.push(node, costs[node] + points[node].distance_to(destination))
	var expanded := 0
	while not frontier.is_empty() and expanded < MAX_EXPANDED_NODES:
		var source := frontier.pop()
		if settled[source] != 0:
			continue
		settled[source] = 1
		expanded += 1
		if exits.has(source):
			return _chain_to(parents, source)
		for target: int in graph.links(source, clearance):
			if target < 0 or target >= points.size() or settled[target] != 0 \
					or not checked.get(_edge_key(source, target), true):
				continue
			var cost := costs[source] + points[source].distance_to(points[target])
			var estimate := cost + points[target].distance_to(destination)
			if cost < costs[target] and estimate <= max_distance:
				costs[target] = cost
				parents[target] = source
				frontier.push(target, estimate)
	return PackedInt32Array()

static func _chain_to(parents: PackedInt32Array, end: int) -> PackedInt32Array:
	var nodes := PackedInt32Array([end])
	var current := parents[end]
	while current >= 0:
		nodes.append(current)
		current = parents[current]
	nodes.reverse()
	return nodes

static func _edge_key(first: int, second: int) -> Vector2i:
	return Vector2i(mini(first, second), maxi(first, second))

static func _rounded_route(route: PackedVector3Array, graph: SpatialPatrolGraph,
		inverse: Transform3D, clearance: float, is_segment_clear: Callable) -> PackedVector3Array:
	if route.size() < 3 or route.size() > MAX_SMOOTH_CHECKS:
		return route
	var tested := [0]
	var local_start := inverse * route[0]
	var local_finish := inverse * route[-1]
	var start_outside := not graph.covers_flight_segment(local_start, local_start, clearance, true)
	var finish_outside := not graph.covers_flight_segment(local_finish, local_finish, clearance, true)
	var can_round := func(first: Vector3, second: Vector3) -> bool:
		if tested[0] >= MAX_SMOOTH_CHECKS:
			return false
		tested[0] += 1
		var local_first := inverse * first
		var local_second := inverse * second
		if not graph.flight_regions.is_empty() or graph.coverage.has_volume():
			var covered := graph.covers_flight_shortcut(local_first, local_second, clearance)
			if not covered and start_outside and first == route[0]:
				covered = _connector_covered(graph, local_first, local_second, clearance, false)
			if not covered and finish_outside and second == route[-1]:
				covered = _connector_covered(graph, local_second, local_first, clearance, false)
			if not covered:
				return false
		return is_segment_clear.call(first, second)
	var rounded: PackedVector3Array = SpatialPatrolTrajectory.smooth(route, CORNER_TRIM_M, can_round)["points"]
	return route if rounded.is_empty() else rounded
