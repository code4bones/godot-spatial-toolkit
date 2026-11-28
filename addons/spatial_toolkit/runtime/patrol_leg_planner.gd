class_name SpatialPatrolLegPlanner
extends RefCounted
## Selects and validates flight legs over saved graph links.

const MAX_ATTEMPTS := 6
const MAX_LEG_LINKS := 128
const TARGET_BAND := 0.85
const LINK_PENALTY_M := 2.0
const VERTICAL_PENALTY := 0.25
const SWEEP_FACE_BAND := 0.14
const SWEEP_LANE_BAND := 0.14
const SHIFT_MAX_LINKS := 3
const SHIFT_MAX_FRACTION := 0.33
const TURN_SHIFT_MAX_LINKS := 4
const TURN_SHIFT_MAX_FRACTION := 0.42
const SHIFT_MIN_FRACTION := 0.08
const SHIFT_TYPICAL_FRACTION := 0.20
const PREFERRED_DEPARTURE_LENGTH_M := 8.0

class Frontier:
	var _nodes := PackedInt32Array()
	var _costs := PackedFloat64Array()

	func is_empty() -> bool:
		return _nodes.is_empty()

	func push(node: int, cost: float) -> void:
		var index := _nodes.size()
		_nodes.append(node)
		_costs.append(cost)
		while index > 0:
			var parent := (index - 1) >> 1
			if not _before(index, parent):
				break
			_swap(index, parent)
			index = parent

	func pop() -> int:
		var node := _nodes[0]
		var last := _nodes.size() - 1
		_swap(0, last)
		_nodes.resize(last)
		_costs.resize(last)
		var index := 0
		while index * 2 + 1 < last:
			var child := index * 2 + 1
			if child + 1 < last and _before(child + 1, child):
				child += 1
			if not _before(child, index):
				break
			_swap(child, index)
			index = child
		return node

	func _before(first: int, second: int) -> bool:
		return _costs[first] < _costs[second] \
			or (_costs[first] == _costs[second] and _nodes[first] < _nodes[second])

	func _swap(first: int, second: int) -> void:
		var node := _nodes[first]
		var cost := _costs[first]
		_nodes[first] = _nodes[second]
		_costs[first] = _costs[second]
		_nodes[second] = node
		_costs[second] = cost

static func plan(graph: SpatialPatrolGraph, start_node: int, clearance_m: float,
		rng: RandomNumberGenerator, target_visits: Dictionary, is_edge_clear: Callable) -> PackedInt32Array:
	if rng == null or not _valid_request(graph, start_node, clearance_m, is_edge_clear):
		return PackedInt32Array()
	# Reuse validation within this call. New legs see the latest scene physics.
	var checked: Dictionary = {}
	for _attempt in MAX_ATTEMPTS:
		var parents := _shortest_paths(graph, start_node, clearance_m, checked)
		var target := _choose_target(graph, parents, start_node, rng, target_visits)
		if target < 0:
			break
		var chain := _chain_to(parents, start_node, target)
		if _validate(chain, checked, is_edge_clear):
			return chain
	return PackedInt32Array()

static func plan_toward(graph: SpatialPatrolGraph, start_node: int, target: Vector3,
		clearance_m: float, is_edge_clear: Callable) -> PackedInt32Array:
	## Approach a graph-local target along saved links and prefer holding position on a tie.
	if not target.is_finite() or not _valid_request(graph, start_node, clearance_m, is_edge_clear):
		return PackedInt32Array()
	var checked: Dictionary = {}
	for _attempt in MAX_ATTEMPTS:
		var parents := _shortest_paths(graph, start_node, clearance_m, checked)
		var endpoint := start_node
		var nearest_distance := graph.points[start_node].distance_squared_to(target)
		for index in parents.size():
			if parents[index] < 0:
				continue
			var distance := graph.points[index].distance_squared_to(target)
			if distance < nearest_distance:
				nearest_distance = distance
				endpoint = index
		var chain := _chain_to(parents, start_node, endpoint)
		if _validate(chain, checked, is_edge_clear):
			return chain
	return PackedInt32Array([start_node])

static func plan_sweep(graph: SpatialPatrolGraph, start_node: int, clearance_m: float,
		rng: RandomNumberGenerator, target_visits: Dictionary, node_visits: Dictionary,
		is_edge_clear: Callable, axis: int, incoming_node: int = -1) -> PackedInt32Array:
	if (axis != 0 and axis != 2) or rng == null or not _valid_request(graph, start_node, clearance_m, is_edge_clear):
		return PackedInt32Array()
	var bounds := _coverage(graph, start_node)
	if bounds.size[axis] <= 0.0001:
		return plan(graph, start_node, clearance_m, rng, target_visits, is_edge_clear)
	var cells := _cell_visits(graph, bounds, target_visits, node_visits)
	# Bias the interior route as well as the endpoint so sweeps revisit crowded
	# altitude bands less often.
	var coverage_costs := PackedFloat32Array()
	for point: Vector3 in graph.points:
		var visit_cost := _visit_cost(cells[1], _cell(point, bounds)) if point.is_finite() else 0.0
		coverage_costs.append(minf(36.0, 9.0 * visit_cost))
	incoming_node = _usable_incoming(graph, start_node, incoming_node)
	var checked: Dictionary = {}
	for _attempt in MAX_ATTEMPTS:
		var turns: Dictionary = {}
		var parents := _shortest_paths(graph, start_node, clearance_m, checked, node_visits, axis,
			coverage_costs, incoming_node, turns)
		var target := _choose_sweep(graph, parents, start_node, bounds, axis, rng, cells,
			target_visits, node_visits, turns)
		if target < 0:
			# Sparse graphs may have no reachable vertex ahead on the selected axis.
			target = _choose_target(graph, parents, start_node, rng, target_visits)
		if target < 0:
			break
		var chain := _chain_to(parents, start_node, target)
		if _validate(chain, checked, is_edge_clear):
			return chain
	return PackedInt32Array()

static func plan_shift(graph: SpatialPatrolGraph, start_node: int, clearance_m: float,
		rng: RandomNumberGenerator, target_visits: Dictionary, node_visits: Dictionary,
		is_edge_clear: Callable, axis: int, incoming_node: int = -1) -> PackedInt32Array:
	if (axis != 0 and axis != 2) or rng == null or not _valid_request(graph, start_node, clearance_m, is_edge_clear):
		return PackedInt32Array()
	var bounds := _coverage(graph, start_node)
	var lateral_width := bounds.size[2 - axis]
	if lateral_width <= 0.0001:
		return PackedInt32Array()
	var cells := _cell_visits(graph, bounds, target_visits, node_visits)
	incoming_node = _usable_incoming(graph, start_node, incoming_node)
	var checked: Dictionary = {}
	for _attempt in MAX_ATTEMPTS:
		var candidates := _shift_paths(graph, start_node, clearance_m, bounds, axis, checked, incoming_node)
		var ranks: Dictionary = {}
		var origin := graph.points[start_node]
		for target: int in candidates:
			var offset := graph.points[target] - origin
			var sideways := absf(offset[2 - axis])
			if sideways < lateral_width * SHIFT_MIN_FRACTION or sideways < 1.25 * absf(offset[axis]):
				continue
			var axial := absf(offset[axis]) / maxf(bounds.size[axis], 0.0001)
			var spacing := absf(sideways / lateral_width - SHIFT_TYPICAL_FRACTION)
			ranks[target] = 2.0 * axial + 2.0 * spacing \
				+ _novelty_cost(graph, bounds, target, cells, target_visits, node_visits)
			if incoming_node >= 0:
				var travel: Dictionary = candidates[target]
				var extra := maxf(0.0, float(travel["length"]) / lateral_width - SHIFT_MAX_FRACTION)
				ranks[target] += 0.10 * float(travel["turn"]) + 4.0 * extra
		var target := _pick_best(ranks, rng)
		if target < 0:
			break
		var chain: PackedInt32Array = candidates[target]["chain"]
		if _validate(chain, checked, is_edge_clear):
			return chain
	return PackedInt32Array()

static func _shortest_paths(graph: SpatialPatrolGraph, start: int, clearance_m: float,
		checked: Dictionary, node_visits: Dictionary = {}, sweep_axis: int = -1,
		coverage_costs := PackedFloat32Array(), incoming_node: int = -1,
		turn_data: Dictionary = {}) -> PackedInt32Array:
	var count := graph.points.size()
	var parents := PackedInt32Array()
	parents.resize(count)
	parents.fill(-1)
	var costs := PackedFloat64Array()
	costs.resize(count)
	costs.fill(INF)
	costs[start] = 0.0
	var settled := PackedByteArray()
	settled.resize(count)
	var departure_costs := PackedFloat32Array()
	var turn_costs := PackedFloat32Array()
	if incoming_node >= 0:
		departure_costs.resize(count)
		turn_costs.resize(count)
	var frontier := Frontier.new()
	frontier.push(start, 0.0)
	while not frontier.is_empty():
		var source := frontier.pop()
		if settled[source]:
			continue
		settled[source] = 1
		for target: int in graph.links(source, clearance_m):
			if target < 0 or target >= count or settled[target] \
					or not checked.get(_edge_key(source, target), true):
				continue
			var offset := graph.points[target] - graph.points[source]
			var distance := offset.length()
			if not is_finite(distance) or distance <= 0.0:
				continue
			var cost := costs[source] + distance + VERTICAL_PENALTY * absf(offset.y) + LINK_PENALTY_M
			if sweep_axis >= 0:
				cost += 0.45 * absf(offset[2 - sweep_axis]) + coverage_costs[target]
			cost += minf(16.0, 4.0 * _visit_cost(node_visits, target))
			var turn := 0.0
			if incoming_node >= 0:
				var predecessor := incoming_node if source == start else parents[source]
				turn = _turn_cost(graph, predecessor, source, target, source == start)
				cost += turn
			if cost < costs[target]:
				costs[target] = cost
				parents[target] = source
				if incoming_node >= 0:
					departure_costs[target] = turn if source == start else departure_costs[source]
					turn_costs[target] = turn_costs[source] + turn
				frontier.push(target, cost)
	if incoming_node >= 0:
		turn_data["departure"] = departure_costs
		turn_data["chain"] = turn_costs
	return parents

static func _choose_sweep(graph: SpatialPatrolGraph, parents: PackedInt32Array, start: int,
		bounds: AABB, axis: int, rng: RandomNumberGenerator, cells: Array[Dictionary],
		target_visits: Dictionary, node_visits: Dictionary, turns: Dictionary) -> int:
	var origin := graph.points[start]
	var direction := 1.0 if origin[axis] <= bounds.get_center()[axis] else -1.0
	var axial_width := bounds.size[axis]
	var lateral_axis := 2 - axis
	var lateral_width := maxf(bounds.size[lateral_axis], 0.0001)
	var farthest := 0.0
	for index in parents.size():
		if parents[index] >= 0:
			farthest = maxf(farthest, direction * (graph.points[index][axis] - origin[axis]))
	if farthest <= 0.0001:
		return -1
	var face_threshold := maxf(farthest * 0.75, farthest - axial_width * SWEEP_FACE_BAND)
	var nearest_lane := INF
	var face: Array[int] = []
	for index in parents.size():
		if parents[index] >= 0 and direction * (graph.points[index][axis] - origin[axis]) >= face_threshold:
			face.append(index)
			nearest_lane = minf(nearest_lane, absf(graph.points[index][lateral_axis] - origin[lateral_axis]))
	var ranks: Dictionary = {}
	for target: int in face:
		var offset := graph.points[target] - origin
		var lateral := absf(offset[lateral_axis])
		if lateral > nearest_lane + lateral_width * SWEEP_LANE_BAND:
			continue
		var remaining := farthest - direction * offset[axis]
		ranks[target] = 2.0 * lateral / lateral_width + remaining / axial_width \
			+ _novelty_cost(graph, bounds, target, cells, target_visits, node_visits)
		if not turns.is_empty():
			ranks[target] += 0.05 * turns["departure"][target] + 0.013 * turns["chain"][target]
	return _pick_best(ranks, rng)

static func _shift_paths(graph: SpatialPatrolGraph, start: int, clearance_m: float, bounds: AABB,
		axis: int, checked: Dictionary, incoming_node: int) -> Dictionary:
	# Keep the best path at each hop count so extra hops cannot hide a useful short link.
	var frontier := {start: {"length": 0.0, "turn": 0.0, "cost": 0.0, "chain": PackedInt32Array([start])}}
	var shortest: Dictionary = {}
	var turn_aware := incoming_node >= 0
	var budget := bounds.size[2 - axis] * (TURN_SHIFT_MAX_FRACTION if turn_aware else SHIFT_MAX_FRACTION)
	var hops := TURN_SHIFT_MAX_LINKS if turn_aware else SHIFT_MAX_LINKS
	var origin := graph.points[start][axis]
	var midpoint := bounds.get_center()[axis]
	var side := origin - midpoint
	var hold_side := absf(side) > bounds.size[axis] * 0.08
	var axial_limit := bounds.size[axis] * 0.22 + 0.0001
	for _hop in hops:
		var next: Dictionary = {}
		for source: int in frontier:
			var travel: Dictionary = frontier[source]
			var chain: PackedInt32Array = travel["chain"]
			for target: int in graph.links(source, clearance_m):
				if target < 0 or target >= graph.points.size() or chain.has(target) \
						or not checked.get(_edge_key(source, target), true):
					continue
				var point := graph.points[target]
				if absf(point[axis] - origin) > axial_limit or (hold_side and (point[axis] - midpoint) * side < 0.0):
					continue
				var distance := point.distance_to(graph.points[source])
				var length := float(travel["length"]) + distance
				if not is_finite(length) or distance <= 0.0 or length > budget:
					continue
				var turn := float(travel["turn"])
				if turn_aware:
					var predecessor := incoming_node if chain.size() == 1 else chain[-2]
					turn += _turn_cost(graph, predecessor, source, target, chain.size() == 1)
				var cost := length + 1.6 * turn
				if next.has(target) and cost >= float(next[target]["cost"]):
					continue
				var extended := chain.duplicate()
				extended.append(target)
				next[target] = {"length": length, "turn": turn, "cost": cost, "chain": extended}
		for target: int in next:
			if not shortest.has(target) or next[target]["cost"] < shortest[target]["cost"]:
				shortest[target] = next[target]
		if next.is_empty():
			break
		frontier = next
	return shortest

static func _usable_incoming(graph: SpatialPatrolGraph, start: int, incoming: int) -> int:
	if incoming >= 0 and incoming < graph.points.size() and graph.points[incoming].is_finite() \
			and graph.points[incoming].distance_squared_to(graph.points[start]) > 0.00000001:
		return incoming
	return -1

static func _turn_cost(graph: SpatialPatrolGraph, previous: int, at: int, next: int, departure: bool) -> float:
	var incoming := graph.points[at] - graph.points[previous]
	var outgoing := graph.points[next] - graph.points[at]
	var in_length := incoming.length()
	var out_length := outgoing.length()
	if not is_finite(in_length) or not is_finite(out_length) or minf(in_length, out_length) <= 0.0001:
		return 0.0
	var dot := clampf(incoming.dot(outgoing) / (in_length * out_length), -1.0, 1.0)
	var deflection := 1.0 - dot
	# The same 45% trim used by the trajectory leaves space between adjacent turns.
	var trim := minf(16.0, 0.45 * minf(in_length, out_length))
	var radius := trim * sqrt((1.0 + dot) / maxf(deflection, 0.00001))
	var cost := 12.0 * deflection * deflection + 16.0 * deflection / maxf(radius, 1.0)
	if departure:
		cost += 1.4 * maxf(0.0, PREFERRED_DEPARTURE_LENGTH_M - out_length)
	return cost

static func _valid_request(graph: SpatialPatrolGraph, start: int, clearance_m: float,
		is_edge_clear: Callable) -> bool:
	return graph != null and start >= 0 and start < graph.points.size() \
		and graph.points.size() <= SpatialPatrolGraph.MAX_NODES and graph.points[start].is_finite() \
		and is_finite(clearance_m) and clearance_m >= 0.0 and is_edge_clear.is_valid()

static func _chain_to(parents: PackedInt32Array, start: int, target: int) -> PackedInt32Array:
	var chain := PackedInt32Array([target])
	while target != start:
		target = parents[target]
		chain.append(target)
	chain.reverse()
	if chain.size() > MAX_LEG_LINKS + 1:
		chain.resize(MAX_LEG_LINKS + 1)
	return chain

static func _coverage(graph: SpatialPatrolGraph, start_node: int) -> AABB:
	if graph.coverage.size.x > 0.0 or graph.coverage.size.z > 0.0:
		return graph.coverage
	var bounds := AABB(graph.points[start_node], Vector3.ZERO)
	for point: Vector3 in graph.points:
		if point.is_finite():
			bounds = bounds.expand(point)
	return bounds

static func _cell_visits(graph: SpatialPatrolGraph, bounds: AABB, target_visits: Dictionary,
		node_visits: Dictionary) -> Array[Dictionary]:
	var result: Array[Dictionary] = [{}, {}]
	var records := [target_visits, node_visits]
	for index in records.size():
		for id: Variant in records[index]:
			if id is int and id >= 0 and id < graph.points.size() and graph.points[id].is_finite():
				var cell := _cell(graph.points[id], bounds)
				result[index][cell] = int(result[index].get(cell, 0)) + maxi(0, int(records[index][id]))
	return result

static func _cell(point: Vector3, bounds: AABB) -> Vector3i:
	var offset := point - bounds.position
	return Vector3i(clampi(floori(5.0 * offset.x / maxf(bounds.size.x, 0.0001)), 0, 4),
		clampi(floori(4.0 * offset.y / maxf(bounds.size.y, 0.0001)), 0, 3),
		clampi(floori(5.0 * offset.z / maxf(bounds.size.z, 0.0001)), 0, 4))

static func _visit_cost(visits: Dictionary, key: Variant) -> float:
	return log(1.0 + float(maxi(0, int(visits.get(key, 0)))))

static func _novelty_cost(graph: SpatialPatrolGraph, bounds: AABB, target: int,
		cells: Array[Dictionary], targets: Dictionary, nodes: Dictionary) -> float:
	var cell := _cell(graph.points[target], bounds)
	return _visit_cost(targets, target) + 0.45 * _visit_cost(cells[0], cell) \
		+ 0.25 * _visit_cost(nodes, target) + 0.12 * _visit_cost(cells[1], cell)

static func _pick_best(ranks: Dictionary, rng: RandomNumberGenerator) -> int:
	if ranks.is_empty():
		return -1
	var best := INF
	for score: float in ranks.values():
		best = minf(score, best)
	var choices := PackedInt32Array()
	for target: int in ranks:
		if ranks[target] <= best + 0.05:
			choices.append(target)
	choices.sort()
	return choices[rng.randi_range(0, choices.size() - 1)]

static func _choose_target(graph: SpatialPatrolGraph, parents: PackedInt32Array, start: int,
		rng: RandomNumberGenerator, target_visits: Dictionary) -> int:
	var origin := graph.points[start]
	var center := graph.coverage.get_center()
	if graph.coverage.size.x <= 0.0 and graph.coverage.size.z <= 0.0:
		var extent := AABB(origin, Vector3.ZERO)
		for index in parents.size():
			if parents[index] >= 0:
				extent = extent.expand(graph.points[index])
		center = extent.get_center()
	var outward := Vector2(origin.x - center.x, origin.z - center.z).normalized()
	var scores := PackedFloat64Array()
	scores.resize(parents.size())
	var across := PackedByteArray()
	across.resize(parents.size())
	var farthest := -1.0
	var farthest_across := -1.0
	for index in parents.size():
		if parents[index] < 0:
			continue
		var point := graph.points[index]
		var travel := Vector2(point.x - origin.x, point.z - origin.z)
		# A small vertical term also gives a useful target in vertical-only graphs.
		var score := travel.length() + absf(point.y - origin.y) * 0.05
		if Vector2(point.x - center.x, point.z - center.z).dot(outward) < -0.0001:
			across[index] = 1
			score = 0.55 * -travel.dot(outward) + 0.45 * score
			farthest_across = maxf(farthest_across, score)
		scores[index] = score
		farthest = maxf(farthest, score)
	var threshold := (farthest_across if farthest_across >= 0.0 else farthest) * TARGET_BAND
	var least_visits := 9223372036854775807
	var candidates := PackedInt32Array()
	for index in parents.size():
		if parents[index] < 0 or scores[index] < threshold or (farthest_across >= 0.0 and not across[index]):
			continue
		var visits := int(target_visits.get(index, 0))
		if visits < least_visits:
			least_visits = visits
			candidates.clear()
		if visits == least_visits:
			candidates.append(index)
	if candidates.is_empty():
		return -1
	return candidates[rng.randi_range(0, candidates.size() - 1)]

static func _validate(chain: PackedInt32Array, checked: Dictionary, is_edge_clear: Callable) -> bool:
	for index in range(1, chain.size()):
		var a := chain[index - 1]
		var b := chain[index]
		var key := _edge_key(a, b)
		if not checked.has(key):
			checked[key] = bool(is_edge_clear.call(a, b))
		if not checked[key]:
			return false
	return true

static func _edge_key(a: int, b: int) -> Vector2i:
	return Vector2i(mini(a, b), maxi(a, b))
