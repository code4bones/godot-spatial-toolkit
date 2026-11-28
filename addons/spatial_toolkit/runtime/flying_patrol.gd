class_name SpatialFlyingPatrol
extends CharacterBody3D
## Flies recorded spatial graph edges or authored Path3D patrol routes.
## Graph points use the selected map root's local gameplay metres.

enum FlightState { PATROL, CHASE }

signal route_started(route_path: NodePath, patrol_space: String)
signal route_completed(route_path: NodePath)
signal patrol_blocked(reason: String)
signal graph_edge_started(from_node: int, to_node: int)
signal graph_leg_started(nodes: PackedInt32Array, trajectory: PackedVector3Array)
signal graph_leg_completed(destination: int)

const MAX_ROUTES := 256
const MAX_ROUTE_POINTS := 4096
const ARRIVAL_EPSILON := 0.0001
const CHASE_PLAN_INTERVAL_SECONDS := 0.4
const CHASE_RETARGET_DISTANCE_M := 3.0
const CHASE_APPROACH_DISTANCE_M := 4.0
const CHASE_DIRECT_RANGE_M := 16.0
const CHASE_LEAD_SECONDS := 0.55
const CHASE_MAX_LEAD_M := 14.0
const AUTO_CHASE_SPEED_MULTIPLIER := 1.5
const MAX_AUTO_CHASE_LONGITUDINAL_MPS2 := 30.0
const MAX_AUTO_CHASE_LATERAL_MPS2 := 24.0
const MIN_SEPARATION_RADIUS_M := 1.0
const MAP_GROUP := &"spatial_flying_patrol"
const PROJECTILE_LAYER := 1 << 2
const Graph := preload("res://addons/spatial_toolkit/runtime/patrol_graph.gd")
const LegPlanner := preload("res://addons/spatial_toolkit/runtime/patrol_leg_planner.gd")
const Trajectory := preload("res://addons/spatial_toolkit/runtime/patrol_trajectory.gd")

@export var routes: Array[NodePath] = []
@export_file("*.json") var graph_manifest_path := ""
@export var graph_chunk_id := ""
@export var graph_start_node := -1
@export_node_path("Node3D") var graph_root_path := NodePath("..")
@export var smooth_graph_patrol := false
@export var stagger_graph_patrol := false
@export var blend_staggered_legs := false
@export_range(0.1, 30.0, 0.1, "suffix:m/s²") var cruise_acceleration_mps2 := 3.0
@export_range(0.1, 30.0, 0.1, "suffix:m/s²") var lateral_acceleration_mps2 := 3.0
@export_range(0.1, 30.0, 0.1, "suffix:m") var turn_distance_m := 5.0
@export var patrol_seed := 1
@export_range(0.1, 100.0, 0.1, "suffix:m/s") var speed_mps := 10.0
## Top speed during pursuit. Zero uses 150% of the ordinary patrol speed.
@export_range(0.0, 150.0, 0.1, "or_greater", "suffix:m/s") var max_chase_speed_mps := 0.0
@export_range(0.01, 10.0, 0.01, "suffix:m") var agent_radius_m := 0.35
@export_range(0.0, 10.0, 0.01, "suffix:m") var safety_margin_m := 0.15
@export_range(0.1, 20.0, 0.1) var turn_rate := 5.0
@export_node_path("Node3D") var visual_path: NodePath
@export var autostart := true
@export_range(0, 9) var map_marker_number := 0

var state: FlightState:
	get:
		return _flight_state
	set(value):
		if value != FlightState.PATROL:
			stop_patrol()
		elif _flight_state == FlightState.CHASE and active:
			end_chase()
		_flight_state = value
var last_error := ""
var active := false
var completed_routes := 0
var current_route: NodePath
var current_space := ""
## Supplies a local window of the published world graph for exterior flight.
var chase_graph_provider: Callable
## Managed profiles with manual acceleration keep the authored values in both phases.
var automatic_chase_acceleration := true
var _random := RandomNumberGenerator.new()
var _points := PackedVector3Array()
var _next_point := 0
var _shape := SphereShape3D.new()
var _visual: Node3D
var _last_route_by_space: Dictionary = {}
var _graph: SpatialPatrolGraph
var _graph_points := PackedVector3Array()
var _graph_root: Node3D
var _graph_mode := false
var _graph_node := -1
var _graph_previous := -1
var _graph_from := -1
var _graph_to := -1
var _graph_visits: Dictionary = {}
var _graph_edges_completed := 0
var _leg_nodes := PackedInt32Array()
var _trajectory := PackedVector3Array()
var _trajectory_speeds := PackedFloat32Array()
var _trajectory_lengths := PackedFloat64Array()
var _trajectory_next := 1
var _trajectory_progress := 0.0
var _trajectory_length := 0.0
var _current_speed := 0.0
var _rounded_turns := 0
var _graph_goal := -1
var _graph_legs_completed := 0
var _target_visits: Dictionary = {}
var _aligning_departure := false
var _orientation := Quaternion.IDENTITY
var _connecting_to_graph := false
var _graph_leg_kind := "long"
var _graph_sweep_axis := 0
var _graph_sweeps_completed := 0
var _graph_shifts_completed := 0
var _graph_shifts_skipped := 0
var _want_shift := false
var _blended_mode := false
var _phase_queue: Array[Dictionary] = []
var _trajectory_waypoint_indices := PackedInt32Array()
var _rolling_blocked := false
var _flight_state := FlightState.PATROL
var _chase_target_world := Vector3.INF
var _chase_target_velocity := Vector3.ZERO
var _chase_planned_target := Vector3.INF
var _chase_hold_world := Vector3.INF
var _chase_plan_remaining := 0.0
var _returning_from_chase := false
var _chase_return_node := -1

func _init() -> void:
	collision_layer = PROJECTILE_LAYER
	collision_mask = 1
	motion_mode = CharacterBody3D.MOTION_MODE_FLOATING

func _ready() -> void:
	add_to_group(MAP_GROUP)
	_visual = get_node_or_null(visual_path) as Node3D if not visual_path.is_empty() else null
	_random.seed = patrol_seed
	if autostart:
		_start_when_physics_ready.call_deferred()

func _start_when_physics_ready() -> void:
	await get_tree().physics_frame
	if is_inside_tree():
		start_patrol()

func start_patrol() -> bool:
	if not _prepare_patrol():
		return false
	_graph_mode = not graph_manifest_path.is_empty()
	if _graph_mode:
		var result := Graph.open_manifest(graph_manifest_path, graph_chunk_id)
		if not result.get("graph") is SpatialPatrolGraph:
			return _block(str(result.get("error", "Could not read the saved patrol graph.")))
		return _start_graph(result["graph"], graph_start_node)
	if routes.is_empty() or routes.size() > MAX_ROUTES:
		return _block("Patrol requires between 1 and %d routes." % MAX_ROUTES)
	return _choose_route()

func _prepare_patrol() -> bool:
	stop_patrol()
	_graph = null
	_graph_points = PackedVector3Array()
	_graph_root = null
	_graph_mode = false
	_graph_node = -1
	_graph_previous = -1
	_graph_from = -1
	_graph_to = -1
	_graph_visits.clear()
	_graph_edges_completed = 0
	_leg_nodes = PackedInt32Array()
	_trajectory_progress = 0.0
	_trajectory_length = 0.0
	_rounded_turns = 0
	_graph_goal = -1
	_graph_legs_completed = 0
	_target_visits.clear()
	_connecting_to_graph = false
	_graph_leg_kind = "long"
	_graph_sweep_axis = 0
	_graph_sweeps_completed = 0
	_graph_shifts_completed = 0
	_graph_shifts_skipped = 0
	_want_shift = false
	state = FlightState.PATROL
	if not is_inside_tree() or not global_position.is_finite():
		return _block("Patrol must be inside the scene tree at a finite position.")
	if (not is_finite(speed_mps) or speed_mps <= 0.0 or not is_finite(agent_radius_m)
			or agent_radius_m <= 0.0 or not is_finite(safety_margin_m) or safety_margin_m < 0.0
			or not is_finite(agent_radius_m + safety_margin_m) or not is_finite(turn_rate) or turn_rate <= 0.0):
		return _block("Patrol speed, radius, margin and turn rate must have valid finite values.")
	if not is_finite(max_chase_speed_mps) or max_chase_speed_mps < 0.0:
		return _block("Maximum chase speed must be finite and nonnegative.")
	if smooth_graph_patrol and (not is_finite(cruise_acceleration_mps2) or cruise_acceleration_mps2 <= 0.0
			or not is_finite(lateral_acceleration_mps2) or lateral_acceleration_mps2 <= 0.0
			or not is_finite(turn_distance_m) or turn_distance_m <= 0.0):
		return _block("Smooth patrol acceleration and turn distance must be positive and finite.")
	_shape.radius = agent_radius_m + safety_margin_m
	var collision := get_node_or_null("PatrolCollision") as CollisionShape3D
	if collision == null:
		collision = CollisionShape3D.new()
		collision.name = "PatrolCollision"
		add_child(collision)
	collision.shape = _shape
	_orientation = global_basis.orthonormalized().get_rotation_quaternion()
	if _visual != null:
		_orientation = _visual.global_basis.orthonormalized().get_rotation_quaternion()
	return true

func start_graph(graph: SpatialPatrolGraph, start_node := -1) -> bool:
	if not _prepare_patrol():
		return false
	_graph_mode = true
	return _start_graph(graph, start_node)

func _start_graph(graph: SpatialPatrolGraph, start_node: int) -> bool:
	_graph_root = get_node_or_null(graph_root_path) as Node3D
	if graph == null or _graph_root == null:
		return _block("Graph patrol requires a graph and its map root.")
	if graph.points.is_empty():
		return _block("Patrol graph has no navigation points.")
	_graph = graph
	_graph_points = graph.points.duplicate()
	for point: Vector3 in _graph_points:
		if not point.is_finite():
			return _block("Patrol graph points must have finite coordinates.")
	_graph_node = start_node
	current_route = NodePath()
	current_space = "graph"
	if _graph_node < -1:
		return _block("Patrol start node must be -1 or a saved graph node ID.")
	if _graph_node < 0:
		var shortest := INF
		for index in _graph_points.size():
			var distance := global_position.distance_squared_to(graph_point_world(index))
			if distance < shortest:
				shortest = distance
				_graph_node = index
	if _graph_node < 0 or _graph_node >= _graph_points.size():
		return _block("Configured patrol start node is outside the saved graph.")
	var position_world := graph_point_world(_graph_node)
	if not _segment_clear(global_position, position_world):
		return _block("The patrol cannot safely reach its saved graph start node.")
	if global_position.distance_to(position_world) > ARRIVAL_EPSILON:
		_graph_to = _graph_node
		if smooth_graph_patrol:
			_connecting_to_graph = true
			_graph_goal = _graph_node
			return _set_trajectory(PackedVector3Array([global_position, position_world]))
		_points = PackedVector3Array([position_world])
		_next_point = 0
		active = true
		last_error = ""
		return true
	_graph_visits[_graph_node] = 1
	return _choose_graph_edge()

func graph_point_world(node_id: int) -> Vector3:
	if _graph_root == null or node_id < 0 or node_id >= _graph_points.size():
		return Vector3(INF, INF, INF)
	return _graph_root.to_global(_graph_points[node_id])

func navigation_root() -> Node3D:
	return _graph_root if _graph != null and is_instance_valid(_graph_root) else null

func navigation_graph_for(from_world: Vector3, to_world: Vector3) -> SpatialPatrolGraph:
	if navigation_root() == null:
		return null
	# Managed patrols share the map's published chunks and portals with other flyers.
	if chase_graph_provider.is_valid():
		var published := chase_graph_provider.call(from_world, to_world) as SpatialPatrolGraph
		if published != null:
			return published
	return _graph

func _choose_graph_edge() -> bool:
	if smooth_graph_patrol:
		return _choose_graph_leg()
	_graph_from = _graph_node
	_graph_to = -1
	var neighbors := _graph.links(_graph_node, _shape.radius)
	var available := PackedInt32Array()
	for target in neighbors:
		if target != _graph_node and target >= 0 and target < _graph_points.size() \
				and _segment_clear(global_position, graph_point_world(target)) and not available.has(target):
			available.append(target)
	if available.is_empty():
		return _block("No collision-free recorded graph edge is available at node %d." % _graph_node)
	if available.size() > 1:
		var previous_index := available.find(_graph_previous)
		if previous_index >= 0:
			available.remove_at(previous_index)
	var least_visited := 2147483647
	var choices := PackedInt32Array()
	for target in available:
		var visits := int(_graph_visits.get(target, 0))
		if visits < least_visited:
			least_visited = visits
			choices.clear()
		if visits == least_visited:
			choices.append(target)
	_graph_to = choices[_random.randi_range(0, choices.size() - 1)]
	_points = PackedVector3Array([graph_point_world(_graph_to)])
	_next_point = 0
	active = true
	last_error = ""
	graph_edge_started.emit(_graph_from, _graph_to)
	return true

func _choose_graph_leg() -> bool:
	if stagger_graph_patrol and blend_staggered_legs:
		return _begin_blended_batch()
	if stagger_graph_patrol:
		_leg_nodes = _plan_staggered_leg()
	else:
		_graph_leg_kind = "long"
		_leg_nodes = LegPlanner.plan(_graph, _graph_node, _shape.radius, _random, _target_visits, _graph_edge_clear)
	if _leg_nodes.size() < 2:
		return _block("No safe long patrol leg is reachable from graph node %d." % _graph_node)
	var waypoints := PackedVector3Array()
	for node_id in _leg_nodes:
		waypoints.append(graph_point_world(node_id))
	_graph_from = _leg_nodes[0]
	_graph_to = _leg_nodes[-1]
	_graph_goal = _graph_to
	_connecting_to_graph = false
	if not _set_trajectory(waypoints):
		return false
	graph_leg_started.emit(_leg_nodes.duplicate(), _trajectory.duplicate())
	return true

func _plan_staggered_leg() -> PackedInt32Array:
	var phase := _plan_phase(_forecast_context())
	_graph_leg_kind = phase["kind"]
	_graph_sweep_axis = phase["axis"]
	_graph_shifts_skipped += phase["skipped_shifts"]
	return phase["nodes"]

func _forecast_context() -> Dictionary:
	return {"node": _graph_node, "previous": _graph_previous, "targets": _target_visits.duplicate(),
		"visits": _graph_visits.duplicate(), "sweeps": _graph_sweeps_completed,
		"want_shift": _want_shift, "axis": _graph_sweep_axis}

func _plan_phase(context: Dictionary) -> Dictionary:
	var chain := PackedInt32Array()
	var kind := "sweep"
	var axis := int(context["axis"])
	var skipped := 0
	var incoming := int(context["previous"]) if blend_staggered_legs else -1
	if context["want_shift"]:
		chain = LegPlanner.plan_shift(_graph, context["node"], _shape.radius, _random,
			context["targets"], context["visits"], _graph_edge_clear, axis, incoming)
		if chain.size() >= 2:
			kind = "shift"
		else:
			skipped = 1
	if chain.size() < 2:
		axis = 0 if int(context["sweeps"]) % 4 < 2 else 2
		chain = LegPlanner.plan_sweep(_graph, context["node"], _shape.radius, _random,
			context["targets"], context["visits"], _graph_edge_clear, axis, incoming)
		if chain.size() >= 2:
			var displacement := _graph_points[chain[-1]] - _graph_points[chain[0]]
			var other_axis := 2 if axis == 0 else 0
			if absf(displacement[axis]) <= ARRIVAL_EPSILON and absf(displacement[other_axis]) > ARRIVAL_EPSILON:
				axis = other_axis
	return {"nodes": chain, "kind": kind, "axis": axis, "skipped_shifts": skipped}

func _forecast_completion(context: Dictionary, phase: Dictionary) -> void:
	var nodes: PackedInt32Array = phase["nodes"]
	context["node"] = nodes[-1]
	context["previous"] = nodes[-2]
	context["targets"][nodes[-1]] = int(context["targets"].get(nodes[-1], 0)) + 1
	for node_id in nodes.slice(1):
		context["visits"][node_id] = int(context["visits"].get(node_id, 0)) + 1
	context["want_shift"] = phase["kind"] == "sweep"
	context["sweeps"] += int(phase["kind"] == "sweep")
	context["axis"] = phase["axis"]

func _begin_blended_batch() -> bool:
	_phase_queue.clear()
	_rolling_blocked = false
	var context := _forecast_context()
	var waypoints := PackedVector3Array([graph_point_world(_graph_node)])
	for _index in 3:
		var phase := _plan_phase(context)
		var nodes: PackedInt32Array = phase["nodes"]
		if nodes.size() < 2:
			break
		phase["start_waypoint"] = waypoints.size() - 1
		for node_id in nodes.slice(1):
			waypoints.append(graph_point_world(node_id))
		phase["end_waypoint"] = waypoints.size() - 1
		_phase_queue.append(phase)
		_forecast_completion(context, phase)
	if _phase_queue.is_empty():
		return _block("No safe patrol phase is reachable from graph node %d." % _graph_node)
	if not _set_trajectory(waypoints):
		return false
	if _trajectory_waypoint_indices.size() != waypoints.size():
		return _block("Blended patrol trajectory is missing its waypoint mapping.")
	for phase: Dictionary in _phase_queue:
		phase["start_index"] = _trajectory_waypoint_indices[phase["start_waypoint"]]
		phase["end_index"] = _trajectory_waypoint_indices[phase["end_waypoint"]]
	_blended_mode = true
	_connecting_to_graph = false
	_activate_phase()
	return true

func _activate_phase() -> void:
	var phase := _phase_queue[0]
	_leg_nodes = phase["nodes"]
	_graph_from = _leg_nodes[0]
	_graph_to = _leg_nodes[-1]
	_graph_goal = _graph_to
	_graph_leg_kind = phase["kind"]
	_graph_sweep_axis = phase["axis"]
	_graph_shifts_skipped += phase["skipped_shifts"]
	phase["skipped_shifts"] = 0
	_rounded_turns = _queued_rounded_turns()
	graph_leg_started.emit(_leg_nodes.duplicate(),
		_trajectory.slice(phase["start_index"], int(phase["end_index"]) + 1))

func _queued_rounded_turns() -> int:
	var waypoints := PackedVector3Array()
	for phase: Dictionary in _phase_queue:
		var nodes: PackedInt32Array = phase["nodes"]
		for index in nodes.size():
			if index > 0 or waypoints.is_empty():
				waypoints.append(graph_point_world(nodes[index]))
	var count := 0
	for index in range(1, waypoints.size() - 1):
		if not _trajectory.has(waypoints[index]):
			count += 1
	return count

func _append_blended_phase() -> bool:
	if _phase_queue.size() < 2 or _rolling_blocked:
		return false
	var context := _forecast_context()
	for phase: Dictionary in _phase_queue:
		_forecast_completion(context, phase)
	var added := _plan_phase(context)
	var new_nodes: PackedInt32Array = added["nodes"]
	if new_nodes.size() < 2:
		return false
	var tail := _phase_queue[-1]
	var tail_nodes: PackedInt32Array = tail["nodes"]
	var splice := int(tail["start_index"])
	var waypoints := PackedVector3Array([_trajectory[splice]])
	for node_id in tail_nodes.slice(1):
		waypoints.append(graph_point_world(node_id))
	var old_goal_waypoint := waypoints.size() - 1
	for node_id in new_nodes.slice(1):
		waypoints.append(graph_point_world(node_id))
	var rounded := Trajectory.smooth(waypoints, turn_distance_m, _segment_clear)
	var suffix: PackedVector3Array = rounded.get("points", PackedVector3Array())
	var mapping: PackedInt32Array = rounded.get("waypoint_indices", PackedInt32Array())
	if suffix.size() < 2 or mapping.size() != waypoints.size():
		return false
	var prepared := _trajectory.slice(0, splice)
	prepared.append_array(suffix)
	var speeds := Trajectory.speed_profile(prepared, speed_mps, cruise_acceleration_mps2,
		lateral_acceleration_mps2, _current_speed)
	if speeds.size() != prepared.size() or speeds[0] + 0.001 < _current_speed:
		return false
	var lengths := PackedFloat64Array([_trajectory_lengths[0]])
	for index in range(1, prepared.size()):
		lengths.append(lengths[-1] + prepared[index - 1].distance_to(prepared[index]))
	tail["end_index"] = splice + mapping[old_goal_waypoint]
	added["start_index"] = tail["end_index"]
	added["end_index"] = splice + mapping[-1]
	_phase_queue.append(added)
	_trajectory = prepared
	_trajectory_speeds = speeds
	_trajectory_lengths = lengths
	_trajectory_length = lengths[-1]
	return true

func _cross_phase_boundary() -> void:
	if _phase_queue.is_empty() or _trajectory_next <= int(_phase_queue[0]["end_index"]):
		return
	var completed: Dictionary = _phase_queue.pop_front()
	var nodes: PackedInt32Array = completed["nodes"]
	_graph_node = nodes[-1]
	_graph_previous = nodes[-2]
	_graph_edges_completed += nodes.size() - 1
	for node_id in nodes.slice(1):
		_graph_visits[node_id] = int(_graph_visits.get(node_id, 0)) + 1
	_target_visits[_graph_node] = int(_target_visits.get(_graph_node, 0)) + 1
	_graph_legs_completed += 1
	if completed["kind"] == "sweep":
		_graph_sweeps_completed += 1
		_want_shift = true
	else:
		_graph_shifts_completed += 1
		_want_shift = false
	graph_leg_completed.emit(_graph_node)
	if not active or state != FlightState.PATROL or _phase_queue.is_empty():
		return
	var consumed := _trajectory_next - 1
	_trajectory = _trajectory.slice(consumed)
	_trajectory_speeds = _trajectory_speeds.slice(consumed)
	_trajectory_lengths = _trajectory_lengths.slice(consumed)
	_trajectory_next = 1
	for phase: Dictionary in _phase_queue:
		phase["start_index"] -= consumed
		phase["end_index"] -= consumed
	if not _append_blended_phase():
		_rolling_blocked = true
	_activate_phase()

func _graph_edge_clear(from_node: int, to_node: int) -> bool:
	return _segment_clear(graph_point_world(from_node), graph_point_world(to_node))

func _set_trajectory(waypoints: PackedVector3Array) -> bool:
	var error := _install_trajectory(waypoints, 0.0)
	return error.is_empty() or _block(error)

func _install_trajectory(waypoints: PackedVector3Array, entry_speed: float, segment_clear := Callable()) -> String:
	if not segment_clear.is_valid():
		segment_clear = _segment_clear
	var result := Trajectory.smooth(waypoints, turn_distance_m, segment_clear)
	var points: PackedVector3Array = result.get("points", PackedVector3Array())
	if points.size() < 2:
		return "Patrol trajectory contains no safe flight segment."
	var lengths := PackedFloat64Array([0.0])
	for index in range(1, points.size()):
		if not points[index].is_finite() or not segment_clear.call(points[index - 1], points[index]):
			return "Patrol trajectory failed its final collision check."
		lengths.append(lengths[-1] + points[index - 1].distance_to(points[index]))
	# A return route can start above patrol speed while the drone is braking.
	var profile_speed := maxf(_trajectory_speed_limit(), entry_speed)
	var acceleration := _trajectory_accelerations()
	var speeds := Trajectory.speed_profile(points, profile_speed, acceleration.x, acceleration.y, entry_speed)
	if speeds.size() != points.size():
		return "Patrol trajectory has an invalid speed profile."
	if speeds[0] + 0.001 < entry_speed:
		return "The current speed is too high for the updated trajectory."
	_trajectory = points
	_trajectory_waypoint_indices = result.get("waypoint_indices", PackedInt32Array())
	_rounded_turns = int(result.get("rounded_turns", 0))
	_trajectory_lengths = lengths
	_trajectory_speeds = speeds
	_trajectory_next = 1
	_trajectory_progress = 0.0
	_trajectory_length = _trajectory_lengths[-1]
	_current_speed = entry_speed
	_aligning_departure = is_zero_approx(entry_speed)
	if _aligning_departure:
		velocity = Vector3.ZERO
	active = true
	last_error = ""
	return ""

func chase_toward(target_world: Vector3, observed_velocity := Vector3.ZERO) -> bool:
	## Keep the last observed point until PatrolManager updates it or calls end_chase().
	if not active or not _graph_mode or not smooth_graph_patrol or not target_world.is_finite():
		return false
	var interior := _graph.coverage.grow(-_shape.radius)
	if interior.size.x <= 0.0 or interior.size.y <= 0.0 or interior.size.z <= 0.0:
		return false
	if _flight_state != FlightState.CHASE:
		_flight_state = FlightState.CHASE
		_returning_from_chase = false
		_chase_return_node = -1
		_chase_planned_target = Vector3.INF
		_chase_hold_world = Vector3.INF
		_chase_plan_remaining = 0.0
		_blended_mode = false
		_phase_queue.clear()
		_connecting_to_graph = false
		_graph_leg_kind = "chase"
	_chase_target_world = target_world
	_chase_target_velocity = observed_velocity if observed_velocity.is_finite() else Vector3.ZERO
	return true

func chase_lost_sight() -> void:
	if _chase_target_velocity == Vector3.ZERO:
		return
	_chase_target_velocity = Vector3.ZERO
	_chase_planned_target = Vector3.INF
	_chase_plan_remaining = 0.0

func end_chase() -> void:
	if _flight_state != FlightState.CHASE or not active:
		return
	_flight_state = FlightState.PATROL
	_chase_target_world = Vector3.INF
	_chase_target_velocity = Vector3.ZERO
	_chase_hold_world = Vector3.INF
	_returning_from_chase = true
	_chase_return_node = -1
	_chase_plan_remaining = 0.0
	_graph_leg_kind = "return"

func _update_chase_plan(delta: float) -> void:
	_chase_plan_remaining -= delta
	if _chase_plan_remaining > 0.0:
		return
	_chase_plan_remaining = CHASE_PLAN_INTERVAL_SECONDS
	if _returning_from_chase:
		if _chase_return_node < 0:
			_plan_return_to_patrol()
		return
	var waypoints := _departure_prefix()
	var start := waypoints[-1]
	var stop_distance := maxf(CHASE_APPROACH_DISTANCE_M, _shape.radius + 1.0)
	var peers := _pursuit_neighbours()
	var target := _predicted_chase_target(stop_distance)
	var approach := target.move_toward(global_position, stop_distance)
	var navigation := _chase_navigation(start, approach)
	if target != _chase_target_world and (navigation == null \
			or not _chase_segment_clear(_chase_target_world, target, navigation, peers)):
		target = _chase_target_world
		approach = target.move_toward(global_position, stop_distance)
		navigation = _chase_navigation(start, approach)
	if navigation == null:
		if not _inside_home(global_position) or not _inside_home(start):
			return
		var interior := _graph.coverage.grow(-_shape.radius)
		target = _graph_root.to_global(_graph_root.to_local(target).clamp(interior.position, interior.end))
		approach = target.move_toward(global_position, stop_distance)
		navigation = _graph
	if _chase_planned_target.is_finite() and target.distance_to(_chase_planned_target) < CHASE_RETARGET_DISTANCE_M:
		return
	approach = _chase_approach(approach, target, stop_distance, navigation, peers)
	var segment_clear := _chase_segment_clear.bind(navigation, peers)
	if _current_speed <= ARRIVAL_EPSILON and global_position.distance_to(approach) <= ARRIVAL_EPSILON:
		_trajectory.clear()
		_chase_planned_target = target
		_chase_hold_world = global_position
		return
	var nodes := PackedInt32Array()
	var can_approach := _chase_connector_clear(start, approach, navigation, peers)
	var installed := not can_approach and _try_chase_portal_route(waypoints, approach, navigation, peers)
	if not can_approach and not installed:
		nodes = _append_chase_links(waypoints, approach, navigation, segment_clear)
		can_approach = _chase_connector_clear(waypoints[-1], approach, navigation, peers)
	if not installed:
		if can_approach:
			_append_waypoint(waypoints, approach)
		if waypoints.size() < 2 or not _install_trajectory(waypoints, _current_speed, segment_clear).is_empty():
			return
	_chase_planned_target = target
	_chase_hold_world = approach if _trajectory[-1].is_equal_approx(approach) else Vector3.INF
	_graph_goal = nodes[-1] if navigation == _graph and not nodes.is_empty() else -1
	if _graph_goal >= 0:
		graph_leg_started.emit(nodes, _trajectory.duplicate())

func _predicted_chase_target(stop_distance: float) -> Vector3:
	var offset := _chase_target_world - global_position
	if offset.dot(_chase_target_velocity) <= 0.0:
		return _chase_target_world
	# Keep a short lead on visible retreating targets and taper it near the standoff distance.
	var weight := clampf((offset.length() - stop_distance) / 6.0, 0.0, 1.0)
	var lead := (_chase_target_velocity * (CHASE_LEAD_SECONDS * weight)).limit_length(CHASE_MAX_LEAD_M)
	return _chase_target_world + lead

func _plan_return_to_patrol() -> void:
	var waypoints := _departure_prefix()
	var start := waypoints[-1]
	var home := _nearest_graph_node(_graph, start)
	if home < 0:
		return
	var destination := graph_point_world(home)
	var navigation := _chase_navigation(start, destination)
	if navigation == null:
		return
	var segment_clear := _chase_segment_clear.bind(navigation, _pursuit_neighbours())
	var anchor := _nearest_graph_node(_graph, start, segment_clear)
	if anchor < 0:
		_append_chase_links(waypoints, destination, navigation, segment_clear)
		if not segment_clear.call(waypoints[-1], destination):
			return
		anchor = home
	_append_waypoint(waypoints, graph_point_world(anchor))
	if waypoints.size() < 2:
		_resume_patrol_at_node(anchor)
	elif _install_trajectory(waypoints, _current_speed, segment_clear).is_empty():
		_chase_return_node = anchor
		_graph_goal = anchor
		graph_leg_started.emit(PackedInt32Array([anchor]), _trajectory.duplicate())

func _resume_patrol_at_node(node_id: int) -> void:
	_returning_from_chase = false
	_chase_return_node = -1
	_graph_node = node_id
	_graph_previous = -1
	_graph_visits[_graph_node] = maxi(1, int(_graph_visits.get(_graph_node, 0)))
	_choose_graph_leg()

func _chase_navigation(start: Vector3, finish: Vector3) -> SpatialPatrolGraph:
	if _inside_home(global_position) and _inside_home(start) and _inside_home(finish):
		return _graph
	if chase_graph_provider.is_valid():
		return chase_graph_provider.call(global_position, finish) as SpatialPatrolGraph
	return null

func _append_chase_links(waypoints: PackedVector3Array, destination: Vector3, navigation: SpatialPatrolGraph,
		segment_clear: Callable) -> PackedInt32Array:
	var anchor := _nearest_graph_node(navigation, waypoints[-1], segment_clear)
	if anchor < 0:
		return PackedInt32Array()
	var nodes := LegPlanner.plan_toward(navigation, anchor, _graph_root.to_local(destination), _shape.radius,
		func(source: int, target: int) -> bool:
			return segment_clear.call(_graph_root.to_global(navigation.points[source]),
				_graph_root.to_global(navigation.points[target])))
	for node_id in nodes:
		_append_waypoint(waypoints, _graph_root.to_global(navigation.points[node_id]))
	return nodes

func _try_chase_portal_route(prefix: PackedVector3Array, destination: Vector3, navigation: SpatialPatrolGraph,
		peers: Array[SpatialFlyingPatrol]) -> bool:
	var start := prefix[-1]
	var local_start := _graph_root.to_local(start)
	var local_destination := _graph_root.to_local(destination)
	var best_length := INF
	var waypoint := Vector3.INF
	for portal in navigation.flight_portals:
		if portal.clearance_m < _shape.radius:
			continue
		var from := portal.from_region
		var to := portal.to_region
		if not ((from.has_point(local_start) and to.has_point(local_destination)) \
				or (to.has_point(local_start) and from.has_point(local_destination))):
			continue
		var gate := _graph_root.to_global(portal.position)
		var distance := start.distance_to(gate) + gate.distance_to(destination)
		if distance < best_length and _chase_segment_clear(start, gate, navigation, peers, true) \
				and _chase_segment_clear(gate, destination, navigation, peers, true):
			best_length = distance
			waypoint = gate
	if not waypoint.is_finite():
		return false
	var route := prefix.duplicate()
	_append_waypoint(route, waypoint)
	_append_waypoint(route, destination)
	# Rounded points must also cross the seam within the published portal's clearance.
	var segment_clear := _chase_segment_clear.bind(navigation, peers, true)
	return _install_trajectory(route, _current_speed, segment_clear).is_empty()

func _nearest_graph_node(navigation: SpatialPatrolGraph, origin: Vector3, segment_clear := Callable()) -> int:
	var nearest := -1
	var distance := INF
	for index in navigation.points.size():
		var point := _graph_root.to_global(navigation.points[index])
		var candidate_distance := origin.distance_squared_to(point)
		if candidate_distance < distance and (not segment_clear.is_valid() or segment_clear.call(origin, point)):
			nearest = index
			distance = candidate_distance
	return nearest

func _departure_prefix() -> PackedVector3Array:
	# Retain enough of the checked path to begin braking before turning onto a new route.
	var waypoints := PackedVector3Array([global_position])
	if _current_speed <= ARRIVAL_EPSILON:
		return waypoints
	var acceleration := _trajectory_accelerations().x
	var remaining := maxf(1.0, _current_speed * _current_speed / (2.0 * acceleration) + 1.0)
	for index in range(_trajectory_next, _trajectory.size()):
		var start := waypoints[-1]
		var next := _trajectory[index]
		var length := start.distance_to(next)
		_append_waypoint(waypoints, start.move_toward(next, remaining))
		remaining -= length
		if remaining <= ARRIVAL_EPSILON:
			break
	return waypoints

func _append_waypoint(waypoints: PackedVector3Array, point: Vector3) -> void:
	if waypoints[-1].distance_to(point) > ARRIVAL_EPSILON:
		waypoints.append(point)

func _inside_home(point: Vector3) -> bool:
	var interior := _graph.coverage.grow(ARRIVAL_EPSILON - _shape.radius)
	return interior.has_point(_graph_root.to_local(point))

func _chase_connector_clear(start: Vector3, finish: Vector3, navigation: SpatialPatrolGraph,
		peers: Array[SpatialFlyingPatrol]) -> bool:
	return _chase_segment_clear(start, finish, navigation, peers, start.distance_to(finish) > CHASE_DIRECT_RANGE_M)

func _chase_segment_clear(start: Vector3, finish: Vector3, navigation: SpatialPatrolGraph,
		peers: Array[SpatialFlyingPatrol], published_shortcut := false) -> bool:
	var covered := true
	if navigation == _graph and (not _inside_home(start) or not _inside_home(finish)):
		return false
	if published_shortcut:
		covered = navigation.covers_flight_shortcut(_graph_root.to_local(start), _graph_root.to_local(finish), _shape.radius)
	elif navigation != _graph:
		covered = navigation.covers_flight_segment(_graph_root.to_local(start), _graph_root.to_local(finish), _shape.radius)
	return covered and _pursuit_segment_clear(start, finish, peers) and _segment_clear(start, finish)

func separation_radius_m() -> float:
	## Keep the visible craft apart even with a small authored navigation radius.
	return maxf(MIN_SEPARATION_RADIUS_M, agent_radius_m + safety_margin_m)

func _pursuit_neighbours() -> Array[SpatialFlyingPatrol]:
	var peers: Array[SpatialFlyingPatrol] = []
	var world := get_world_3d()
	for node in get_tree().get_nodes_in_group(MAP_GROUP):
		var peer := node as SpatialFlyingPatrol
		if peer != null and peer != self and peer.active and not peer.is_queued_for_deletion() and peer.get_world_3d() == world \
				and (peer.state == FlightState.CHASE or peer._returning_from_chase):
			peers.append(peer)
	return peers

func _chase_approach(approach: Vector3, target: Vector3, distance: float,
		navigation: SpatialPatrolGraph, peers: Array[SpatialFlyingPatrol]) -> Vector3:
	if _chase_spot_available(approach, peers):
		return approach
	var direction := (global_position - target).normalized()
	if direction.is_zero_approx():
		direction = Vector3.BACK
	var axis := Vector3.UP if absf(direction.y) < 0.9 else Vector3.RIGHT
	# Try flanking the target on either side before changing altitude.
	for turn_axis: Vector3 in [axis, direction.cross(axis).normalized()]:
		for degrees: float in [35.0, -35.0, 70.0, -70.0, 110.0, -110.0, 150.0, -150.0, 180.0]:
			var candidate := target + direction.rotated(turn_axis, deg_to_rad(degrees)) * distance
			if _chase_spot_available(candidate, peers) and _chase_segment_clear(candidate, candidate, navigation, peers):
				return candidate
	return approach

func _chase_spot_available(point: Vector3, peers: Array[SpatialFlyingPatrol]) -> bool:
	for peer in peers:
		var distance := separation_radius_m() + peer.separation_radius_m()
		if point.distance_squared_to(peer.global_position) < distance * distance \
				or point.distance_squared_to(peer._chase_hold_world) < distance * distance:
			return false
	return true

func _pursuit_segment_clear(start: Vector3, finish: Vector3, peers: Array[SpatialFlyingPatrol]) -> bool:
	var movement := finish - start
	if movement.is_zero_approx():
		return true
	for peer in peers:
		var offset := start - peer.global_position
		var distance := separation_radius_m() + peer.separation_radius_m()
		var distance_squared := distance * distance
		# If two drones have just joined the chase close together, let them move apart.
		if offset.length_squared() < distance_squared and offset.dot(movement) >= 0.0:
			continue
		var nearest := Geometry3D.get_closest_point_to_segment(peer.global_position, start, finish)
		if nearest.distance_squared_to(peer.global_position) < distance_squared:
			return false
	return true

func stop_patrol() -> void:
	active = false
	velocity = Vector3.ZERO
	_points.clear()
	_next_point = 0
	_trajectory = PackedVector3Array()
	_trajectory_speeds = PackedFloat32Array()
	_trajectory_lengths = PackedFloat64Array()
	_current_speed = 0.0
	_aligning_departure = false
	_blended_mode = false
	_phase_queue.clear()
	_chase_target_world = Vector3.INF
	_chase_target_velocity = Vector3.ZERO
	_chase_planned_target = Vector3.INF
	_chase_hold_world = Vector3.INF
	_chase_plan_remaining = 0.0
	_returning_from_chase = false
	_chase_return_node = -1

func destroy() -> void:
	if is_queued_for_deletion():
		return
	stop_patrol()
	collision_layer = 0
	hide()
	queue_free()

func is_visible_for_player_aim() -> bool:
	return is_visible_in_tree()

func predict_curve_position(seconds_ahead: float) -> Vector3:
	## Sample only the already planned world-space path. Hold at an unplanned turn.
	var point := global_position
	if (not active or not is_finite(seconds_ahead) or seconds_ahead <= 0.0 or _aligning_departure
			or not is_finite(speed_mps) or speed_mps <= 0.0):
		return point
	if _trajectory_next >= _trajectory.size():
		var remaining := speed_mps * seconds_ahead
		for index in range(_next_point, _points.size()):
			var next := _points[index]
			var length := point.distance_to(next)
			if remaining <= length:
				return point.move_toward(next, remaining)
			remaining -= length
			point = next
		return point

	var time_left := seconds_ahead
	var entry_speed := _current_speed
	var speed_limit := _trajectory_speed_limit()
	var acceleration := _trajectory_accelerations().x
	if not is_finite(acceleration) or acceleration <= 0.0:
		return point
	for index in range(_trajectory_next, _trajectory.size()):
		var next := _trajectory[index]
		var length := point.distance_to(next)
		if length <= ARRIVAL_EPSILON:
			continue
		var speed_cap := minf(_trajectory_speeds[index], speed_limit)
		if entry_speed > speed_limit:
			# Forecast braking immediately when pursuit ends, including across short samples.
			var braking_distance := minf(length, (entry_speed * entry_speed - speed_limit * speed_limit) / (2.0 * acceleration))
			var after_braking := sqrt(maxf(speed_limit * speed_limit,
				entry_speed * entry_speed - 2.0 * acceleration * braking_distance))
			var braking_time := (entry_speed - after_braking) / acceleration
			if time_left <= braking_time:
				return point.move_toward(next, (entry_speed - 0.5 * acceleration * time_left) * time_left)
			point = point.move_toward(next, braking_distance)
			time_left -= braking_time
			entry_speed = after_braking
			length -= braking_distance
			if length <= ARRIVAL_EPSILON:
				point = next
				continue
		var exit_speed := minf(speed_cap, sqrt(entry_speed * entry_speed + 2.0 * acceleration * length))
		# Estimate time along this sampled segment with the same speed cap and acceleration.
		var peak_speed := minf(speed_limit,
			sqrt(acceleration * length + (entry_speed * entry_speed + exit_speed * exit_speed) * 0.5))
		peak_speed = maxf(peak_speed, maxf(entry_speed, exit_speed))
		var accel_time := (peak_speed - entry_speed) / acceleration
		var brake_time := (peak_speed - exit_speed) / acceleration
		var accel_distance := (entry_speed + peak_speed) * 0.5 * accel_time
		var brake_distance := (exit_speed + peak_speed) * 0.5 * brake_time
		var cruise_distance := maxf(0.0, length - accel_distance - brake_distance)
		var cruise_time := cruise_distance / peak_speed
		if time_left <= accel_time:
			return point.move_toward(next, (entry_speed + 0.5 * acceleration * time_left) * time_left)
		time_left -= accel_time
		if time_left <= cruise_time:
			return point.move_toward(next, accel_distance + peak_speed * time_left)
		time_left -= cruise_time
		if time_left <= brake_time:
			var braking_motion := (peak_speed - 0.5 * acceleration * time_left) * time_left
			return point.move_toward(next, accel_distance + cruise_distance + braking_motion)
		if speed_cap <= ARRIVAL_EPSILON:
			return next
		time_left -= brake_time
		entry_speed = exit_speed
		point = next
	return point

func _choose_route() -> bool:
	var valid: Array[Dictionary] = []
	var seen: Dictionary = {}
	for path: NodePath in routes:
		if seen.has(path):
			continue
		seen[path] = true
		var route := get_node_or_null(path) as Path3D
		if route == null or route.curve == null:
			continue
		var curve := route.curve
		if curve.point_count < 2 or curve.point_count > MAX_ROUTE_POINTS:
			continue
		var points := PackedVector3Array()
		var previous := global_position
		var clear := true
		for point_index in curve.point_count:
			var point := route.to_global(curve.get_point_position(point_index))
			if not point.is_finite() or not _segment_clear(previous, point):
				clear = false
				break
			if previous.distance_to(point) > ARRIVAL_EPSILON:
				points.append(point)
			previous = point
		if clear and not points.is_empty():
			valid.append({"path": path, "points": points,
				"space": str(route.get_meta("patrol_space", ""))})
	if valid.is_empty():
		return _block("No collision-free patrol route is reachable from the current position.")
	var opposite := "outer" if current_space == "inner" else "inner"
	var alternatives: Array[Dictionary] = []
	if current_space in ["inner", "outer"]:
		alternatives = valid.filter(func(route: Dictionary) -> bool: return route["space"] == opposite)
	if not alternatives.is_empty():
		valid = alternatives
	if valid.size() > 1:
		valid = valid.filter(func(route: Dictionary) -> bool: return route["path"] != current_route)
	var fresh: Array[Dictionary] = valid.filter(func(route: Dictionary) -> bool:
		return route["path"] != _last_route_by_space.get(route["space"], NodePath()))
	if not fresh.is_empty():
		valid = fresh
	var selected: Dictionary = valid[_random.randi_range(0, valid.size() - 1)]
	current_route = selected["path"]
	current_space = selected["space"]
	_last_route_by_space[current_space] = current_route
	_points = selected["points"]
	_next_point = 0
	active = true
	last_error = ""
	route_started.emit(current_route, current_space)
	return true

func _segment_clear(start: Vector3, finish: Vector3) -> bool:
	var query := PhysicsShapeQueryParameters3D.new()
	query.shape = _shape
	query.transform = Transform3D(Basis.IDENTITY, start)
	query.margin = 0.0
	query.collision_mask = collision_mask
	query.exclude = [get_rid()]
	var physics := get_world_3d().direct_space_state
	if not physics.intersect_shape(query, 1).is_empty():
		return false
	query.motion = finish - start
	var fractions := physics.cast_motion(query)
	return fractions.size() == 2 and fractions[0] >= 1.0

func _physics_process(delta: float) -> void:
	if not active or not is_finite(delta) or delta <= 0.0:
		velocity = Vector3.ZERO
		return
	if not is_finite(speed_mps) or speed_mps <= 0.0:
		_block("Patrol speed must remain positive and finite.")
		return
	if _flight_state == FlightState.CHASE and (not is_finite(max_chase_speed_mps) or max_chase_speed_mps < 0.0):
		_block("Maximum chase speed must stay finite and nonnegative.")
		return
	if _flight_state == FlightState.CHASE or _returning_from_chase:
		_update_chase_plan(delta)
		if not _trajectory.is_empty():
			_advance_trajectory(delta)
		return
	if _graph_mode and smooth_graph_patrol and not _trajectory.is_empty():
		_advance_trajectory(delta)
		return
	var remaining := speed_mps * delta
	while remaining > ARRIVAL_EPSILON and _next_point < _points.size():
		var offset := _points[_next_point] - global_position
		var distance := offset.length()
		if distance <= ARRIVAL_EPSILON:
			_next_point += 1
			continue
		var direction := offset / distance
		var length := minf(remaining, distance)
		var motion := direction * length
		if not _segment_clear(global_position, global_position + motion):
			_block("Patrol route became blocked. The patrol stopped before the obstacle.")
			return
		velocity = direction * speed_mps
		if move_and_collide(motion) != null:
			_block("Patrol encountered a physics collision and stopped.")
			return
		_turn_visual(direction, delta)
		remaining -= length
		if length >= distance:
			_next_point += 1
	if _next_point >= _points.size():
		if _graph_mode:
			if _graph_from >= 0:
				_graph_edges_completed += 1
			_graph_previous = _graph_from
			_graph_node = _graph_to
			_graph_visits[_graph_node] = int(_graph_visits.get(_graph_node, 0)) + 1
			_choose_graph_edge()
		else:
			completed_routes += 1
			route_completed.emit(current_route)
			_choose_route()

func _turn_visual(direction: Vector3, delta: float) -> void:
	if _visual == null:
		return
	var up := Vector3.UP if absf(direction.dot(Vector3.UP)) < 0.99 else Vector3.FORWARD
	var target := Basis.looking_at(direction, up).get_rotation_quaternion()
	var current := _visual.global_basis.orthonormalized().get_rotation_quaternion()
	var scale_value := _visual.basis.get_scale()
	_visual.global_basis = Basis(current.slerp(target, 1.0 - exp(-turn_rate * delta))).scaled(scale_value)

func _advance_trajectory(delta: float) -> void:
	if _trajectory_next >= _trajectory.size():
		_complete_graph_leg()
		return
	var departure := (_trajectory[_trajectory_next] - global_position).normalized()
	if _aligning_departure:
		_aligning_departure = not _steer_trajectory(departure, delta)
		velocity = Vector3.ZERO
		return
	var previous_speed := _current_speed
	var acceleration := _trajectory_accelerations().x
	_current_speed = move_toward(_current_speed, _trajectory_target_speed(delta, acceleration), acceleration * delta)
	var budget := (previous_speed + _current_speed) * 0.5 * delta
	var frame_start := global_position
	var peers: Array[SpatialFlyingPatrol] = []
	if _flight_state == FlightState.CHASE or _returning_from_chase:
		peers = _pursuit_neighbours()
	while _trajectory_next < _trajectory.size():
		var offset := _trajectory[_trajectory_next] - global_position
		var distance := offset.length()
		var must_stop := _trajectory_speeds[_trajectory_next] <= 0.0001
		if must_stop and distance <= 0.5 * acceleration * delta * delta and previous_speed <= acceleration * delta:
			budget = maxf(budget, distance)
		if budget <= 0.0 and distance > ARRIVAL_EPSILON:
			break
		var length := minf(budget, distance)
		var motion := offset.normalized() * length
		if not _pursuit_segment_clear(global_position, global_position + motion, peers):
			_current_speed = 0.0
			_chase_planned_target = Vector3.INF
			_chase_return_node = -1
			break
		if not _segment_clear(global_position, global_position + motion):
			_trajectory_blocked("Patrol trajectory became blocked. The patrol stopped before the obstacle.")
			return
		if move_and_collide(motion) != null:
			_trajectory_blocked("Patrol encountered a physics collision and stopped.")
			return
		# Use the actual position so rounding cannot exhaust the distance budget
		# before the body reaches a braking waypoint.
		_trajectory_progress = _trajectory_lengths[_trajectory_next] \
			- global_position.distance_to(_trajectory[_trajectory_next])
		budget -= length
		if length < distance:
			break
		_trajectory_next += 1
		if must_stop:
			_current_speed = 0.0
			_aligning_departure = true
		if _blended_mode:
			_cross_phase_boundary()
			if not active:
				return
		if must_stop:
			break
	var movement := global_position - frame_start
	if not movement.is_zero_approx():
		_steer_trajectory(movement.normalized(), delta)
	velocity = movement.normalized() * _current_speed
	if _trajectory_next >= _trajectory.size():
		_complete_graph_leg()

func _trajectory_blocked(reason: String) -> void:
	if _flight_state != FlightState.CHASE and not _returning_from_chase:
		_block(reason)
		return
	_current_speed = 0.0
	velocity = Vector3.ZERO
	_trajectory.clear()
	_chase_planned_target = Vector3.INF
	_chase_hold_world = Vector3.INF
	_chase_return_node = -1

func _trajectory_speed_limit() -> float:
	return _chase_speed_limit() if _flight_state == FlightState.CHASE else speed_mps

func _chase_speed_limit() -> float:
	return maxf(speed_mps, max_chase_speed_mps) if max_chase_speed_mps > 0.0 \
		else speed_mps * AUTO_CHASE_SPEED_MULTIPLIER

func effective_chase_accelerations() -> Vector2:
	var base := Vector2(cruise_acceleration_mps2, lateral_acceleration_mps2)
	if not automatic_chase_acceleration:
		return base
	var ratio := _chase_speed_limit() / speed_mps
	return Vector2(
		clampf(base.x * ratio, base.x, maxf(base.x, MAX_AUTO_CHASE_LONGITUDINAL_MPS2)),
		clampf(base.y * ratio * ratio, base.y, maxf(base.y, MAX_AUTO_CHASE_LATERAL_MPS2)))

func _trajectory_accelerations() -> Vector2:
	if _flight_state == FlightState.CHASE or _returning_from_chase:
		return effective_chase_accelerations()
	return Vector2(cruise_acceleration_mps2, lateral_acceleration_mps2)

func _trajectory_target_speed(delta: float, acceleration: float) -> float:
	var allowed := _trajectory_speed_limit()
	var acceleration_step := acceleration * delta
	for index in range(_trajectory_next, _trajectory.size()):
		var remaining := maxf(_trajectory_lengths[index] - _trajectory_progress, 0.0)
		var cap := float(_trajectory_speeds[index])
		# Solve the next-speed bound after this frame's trapezoidal travel.
		var discriminant := acceleration_step * acceleration_step \
			- 4.0 * (acceleration_step * _current_speed - cap * cap - 2.0 * acceleration * remaining)
		var bound := (sqrt(maxf(discriminant, 0.0)) - acceleration_step) * 0.5
		allowed = minf(allowed, maxf(bound, 0.0))
	return allowed

func _steer_trajectory(direction: Vector3, delta: float) -> bool:
	if direction.is_zero_approx():
		return true
	var up := Vector3.UP if absf(direction.dot(Vector3.UP)) < 0.99 else Vector3.FORWARD
	var target := Basis.looking_at(direction, up).get_rotation_quaternion()
	_orientation = _orientation.slerp(target, 1.0 - exp(-turn_rate * delta))
	if _visual != null:
		_visual.global_basis = Basis(_orientation).scaled(_visual.basis.get_scale())
	return _orientation.angle_to(target) < deg_to_rad(5.0)

func _complete_graph_leg() -> void:
	_current_speed = 0.0
	velocity = Vector3.ZERO
	if _flight_state == FlightState.CHASE or _returning_from_chase:
		_trajectory.clear()
		_chase_planned_target = Vector3.INF
		if _chase_return_node >= 0:
			_resume_patrol_at_node(_chase_return_node)
		return
	if _blended_mode:
		_blended_mode = false
		if active and state == FlightState.PATROL:
			_begin_blended_batch()
		return
	_graph_node = _graph_goal
	if _connecting_to_graph:
		_graph_visits[_graph_node] = 1
		_choose_graph_leg()
		return
	_graph_previous = _leg_nodes[-2]
	_graph_edges_completed += _leg_nodes.size() - 1
	for node_id in _leg_nodes.slice(1):
		_graph_visits[node_id] = int(_graph_visits.get(node_id, 0)) + 1
	_target_visits[_graph_goal] = int(_target_visits.get(_graph_goal, 0)) + 1
	_graph_legs_completed += 1
	if stagger_graph_patrol:
		if _graph_leg_kind == "sweep":
			_graph_sweeps_completed += 1
			_want_shift = true
		elif _graph_leg_kind == "shift":
			_graph_shifts_completed += 1
			_want_shift = false
	graph_leg_completed.emit(_graph_goal)
	if active and state == FlightState.PATROL:
		_choose_graph_leg()

func remaining_chase_trajectory() -> PackedVector3Array:
	## The unflown part of the active pursuit path, in world coordinates.
	if not active or state != FlightState.CHASE or _trajectory_next >= _trajectory.size():
		return PackedVector3Array()
	var points := PackedVector3Array([global_position])
	points.append_array(_trajectory.slice(_trajectory_next))
	return points

func get_debug_state() -> Dictionary:
	return {"state": FlightState.keys()[state], "active": active, "route": str(current_route),
		"chase_target_world": _chase_target_world, "returning_from_chase": _returning_from_chase,
		"patrol_space": current_space, "next_point": _next_point,
		"point_count": _points.size(), "completed_routes": completed_routes, "error": last_error,
		"graph_mode": _graph_mode,
		"graph_from_node": _graph_from, "graph_to_node": _graph_to,
		"graph_edges_completed": _graph_edges_completed, "graph_visited_nodes": _graph_visits.size(),
		"graph_goal_node": _graph_goal, "graph_legs_completed": _graph_legs_completed,
		"graph_leg_kind": _graph_leg_kind, "graph_sweep_axis": _graph_sweep_axis,
		"graph_sweeps_completed": _graph_sweeps_completed, "graph_shifts_completed": _graph_shifts_completed,
		"graph_shifts_skipped": _graph_shifts_skipped,
		"current_speed_mps": _current_speed if _graph_mode and smooth_graph_patrol else velocity.length(),
		"rounded_turns": _rounded_turns, "trajectory_point_index": _trajectory_next,
		"trajectory_point_count": _trajectory.size(), "trajectory_progress_m": _trajectory_progress,
		"trajectory_length_m": _trajectory_length, "aligning_departure": _aligning_departure,
		"blended_phases_queued": _phase_queue.size(), "blend_fallback_stop": _rolling_blocked}

func _block(reason: String) -> bool:
	stop_patrol()
	last_error = reason
	patrol_blocked.emit(reason)
	return false
