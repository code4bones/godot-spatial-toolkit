@tool
class_name SpatialPatrolManager
extends Node3D
## Creates one smooth flying patrol per enabled child rectangle.

signal patrol_spawned(zone: SpatialPatrolZone3D, patrol: SpatialFlyingPatrol, camera: Camera3D)
signal zone_failed(zone: SpatialPatrolZone3D, message: String)

const Graph := preload("res://addons/spatial_toolkit/runtime/patrol_graph.gd")
const MAX_ZONE_CHUNKS := 4096
const MAX_CHASE_CHUNKS := 64
const MAX_PADDED_CHASE_CHUNKS := 36
const MAX_CHASE_GRAPHS := 4
const SIGHT_INTERVAL := 0.1
const PURSUIT_GROUP := &"spatial_patrol_managers"
const ManagedPatrol := preload("res://addons/spatial_toolkit/runtime/managed_flying_patrol.gd")
const PatrolScene := preload("res://addons/spatial_toolkit/runtime/managed_flying_patrol.tscn")

@export_file("*.json") var graph_manifest_path := ""
@export_node_path("Node3D") var map_root_path := NodePath("..")
@export var defaults: SpatialPatrolProfile
@export var autostart := true

@export_group("Chase")
## Maximum number of pursuing patrols owned by this manager. Zero disables pursuit.
@export_range(0, 32, 1, "or_greater") var max_chasers := 2
## Radius in which a patrol can first notice a player.
@export_range(1.0, 1000.0, 1.0, "suffix:m", "or_greater") var detection_radius_m := 120.0
## Radius for keeping or regaining sight of a player already being chased. At least Detection Radius.
@export_range(1.0, 1000.0, 1.0, "suffix:m", "or_greater") var pursuit_radius_m := 240.0
## Continuous visibility required before a patrol can start chasing.
@export_range(0.0, 30.0, 0.05, "suffix:s", "or_greater") var detection_seconds := 1.0
## Time to keep pursuing the last visible position after losing sight.
@export_range(0.0, 30.0, 0.05, "suffix:s", "or_greater") var lose_sight_seconds := 6.0
## With an empty path, use the FlyPlayer child of the map root.
@export_node_path("CharacterBody3D") var chase_target_path: NodePath
@export_group("Rendering")
## Distance from the active camera, in gameplay metres. Zero keeps visual detail at all distances.
@export_range(0.0, 2000.0, 5.0, "suffix:m", "or_greater") var patrol_render_distance_m := 300.0
@export_group("")

var last_errors := PackedStringArray()
var _patrols: Array[ManagedPatrol] = []
var _slot_patrols: Dictionary = {}
var _starting := false
var _sight_elapsed := 0.0
var _contacts: Dictionary[int, SightContact] = {}
var _navigation_snapshot: Graph.Snapshot
var _navigation_chunks: Dictionary = {}
var _navigation_portals: Dictionary = {}
var _chase_graphs: Dictionary = {}
var _patrol_overview_camera: Camera3D

class SightContact:
	var visible_actor_id := 0
	var visible_seconds := -1.0
	var hidden_seconds := -1.0
	var pursued_actor_id := 0
	var last_visible_position := Vector3.INF
	var observed_velocity := Vector3.ZERO

	func observe(actor_id: int, position: Vector3, delta: float) -> void:
		observed_velocity = Vector3.ZERO
		if actor_id != 0:
			if visible_actor_id == actor_id and delta > 0.0 and is_finite(delta):
				var velocity := (position - last_visible_position) / delta
				if velocity.is_finite():
					observed_velocity = velocity
			last_visible_position = position
			visible_seconds = visible_seconds + delta if visible_actor_id == actor_id else 0.0
			hidden_seconds = -1.0
		else:
			last_visible_position = Vector3.INF
			hidden_seconds = 0.0 if hidden_seconds < 0.0 else hidden_seconds + delta
			visible_seconds = -1.0
		visible_actor_id = actor_id

class ThreatIndicator:
	var patrol: SpatialFlyingPatrol
	var fraction: float
	var chasing: bool
	var losing: bool

class ZoneGraph extends SpatialPatrolGraph:
	var adjacency: Array[PackedInt32Array] = []
	var edge_clearance := 0.0

	func links(node_id: int, required_clearance_m: float) -> PackedInt32Array:
		if node_id < 0 or node_id >= adjacency.size() or required_clearance_m > edge_clearance:
			return PackedInt32Array()
		return adjacency[node_id].duplicate()

func _ready() -> void:
	if Engine.is_editor_hint():
		return
	add_to_group(PURSUIT_GROUP)
	if autostart:
		start_patrols.call_deferred()

func _physics_process(delta: float) -> void:
	if Engine.is_editor_hint() or _patrols.is_empty():
		return
	_sight_elapsed += delta
	if _sight_elapsed >= SIGHT_INTERVAL:
		_update_chases(_sight_elapsed)
		refresh_patrol_presentation()
		_sight_elapsed = 0.0

func set_patrol_overview_camera(camera: Camera3D) -> void:
	_patrol_overview_camera = camera
	refresh_patrol_presentation()

func refresh_patrol_presentation() -> void:
	if Engine.is_editor_hint() or not is_inside_tree():
		return
	var camera := get_viewport().get_camera_3d()
	var overview := camera != null and is_instance_valid(_patrol_overview_camera) and camera == _patrol_overview_camera
	for patrol in _patrols:
		if is_instance_valid(patrol) and not patrol.is_queued_for_deletion():
			patrol.update_presentation(camera, patrol_render_distance_m, overview)

func _update_chases(delta: float) -> void:
	var limit := maxi(0, max_chasers)
	var target := _chase_target() if limit > 0 else null
	var target_position := target.global_position if target != null else Vector3.ZERO
	var target_id := target.get_instance_id() if target != null else 0
	var pursuit_radius := maxf(detection_radius_m, pursuit_radius_m) if is_finite(pursuit_radius_m) else detection_radius_m
	var next_contacts: Dictionary[int, SightContact] = {}
	var ready: Array[SpatialFlyingPatrol] = []
	var chasing := 0
	for patrol in get_patrols():
		if not patrol.active:
			continue
		var id := patrol.get_instance_id()
		var contact: SightContact = _contacts.get(id)
		if contact == null:
			contact = SightContact.new()
		next_contacts[id] = contact
		var pursuing := patrol.state == SpatialFlyingPatrol.FlightState.CHASE
		var retaining_target := pursuing and contact.pursued_actor_id == target_id
		var sight_radius := pursuit_radius if retaining_target else detection_radius_m
		var visible := target != null and _has_sight(patrol, target, sight_radius)
		contact.observe(target_id if visible else 0, target_position, delta)
		if pursuing:
			if chasing >= limit or (not visible and contact.hidden_seconds >= lose_sight_seconds):
				patrol.end_chase()
				continue
			if visible:
				if patrol.chase_toward(target_position, contact.observed_velocity):
					contact.pursued_actor_id = target_id
			else:
				patrol.chase_lost_sight()
			chasing += 1
		elif visible and contact.visible_seconds >= detection_seconds:
			ready.append(patrol)
	_contacts = next_contacts
	if chasing >= limit or ready.is_empty():
		return
	ready.sort_custom(func(first: SpatialFlyingPatrol, second: SpatialFlyingPatrol) -> bool:
		var a := first.global_position.distance_squared_to(target_position)
		var b := second.global_position.distance_squared_to(target_position)
		return first.get_instance_id() < second.get_instance_id() if a == b else a < b)
	for patrol in ready:
		var contact := _contacts[patrol.get_instance_id()]
		if patrol.chase_toward(target_position, contact.observed_velocity):
			contact.pursued_actor_id = target_id
			chasing += 1
		if chasing >= limit:
			break

func _chase_target() -> CharacterBody3D:
	var target := get_node_or_null(chase_target_path) as CharacterBody3D if not chase_target_path.is_empty() else null
	if chase_target_path.is_empty():
		var map_root := get_node_or_null(map_root_path)
		if map_root != null:
			target = map_root.get_node_or_null("FlyPlayer") as CharacterBody3D
	return target if is_instance_valid(target) and not target.is_queued_for_deletion() else null

func _has_sight(patrol: SpatialFlyingPatrol, target: CharacterBody3D, radius: float) -> bool:
	var origin := patrol.global_position
	var point := target.global_position
	if not is_finite(radius) or radius <= 0.0 or origin.distance_squared_to(point) > radius * radius:
		return false
	if origin.is_equal_approx(point):
		return true
	var ray := PhysicsRayQueryParameters3D.create(origin, point, patrol.collision_mask,
		[patrol.get_rid(), target.get_rid()])
	ray.hit_from_inside = true
	return get_world_3d().direct_space_state.intersect_ray(ray).is_empty()

func threat_indicators(actor: CharacterBody3D) -> Array[ThreatIndicator]:
	## One live detection or pursuit indicator per patrol observing this actor.
	var result: Array[ThreatIndicator] = []
	if max_chasers <= 0 or not is_instance_valid(actor) or actor.is_queued_for_deletion():
		return result
	var actor_id := actor.get_instance_id()
	for patrol in _patrols:
		if not is_instance_valid(patrol) or patrol.is_queued_for_deletion() or not patrol.active:
			continue
		var contact: SightContact = _contacts.get(patrol.get_instance_id())
		if contact == null:
			continue
		var chasing := patrol.state == SpatialFlyingPatrol.FlightState.CHASE
		var observed_id := contact.pursued_actor_id if chasing else contact.visible_actor_id
		if observed_id != actor_id:
			continue
		var marker := ThreatIndicator.new()
		marker.patrol = patrol
		marker.chasing = chasing
		marker.losing = chasing and contact.hidden_seconds >= 0.0
		marker.fraction = 1.0
		if marker.losing:
			var elapsed := contact.hidden_seconds + _sight_elapsed
			marker.fraction = clampf(1.0 - elapsed / maxf(lose_sight_seconds, 0.001), 0.0, 1.0)
		elif not chasing and detection_seconds > 0.0:
			marker.fraction = clampf((contact.visible_seconds + _sight_elapsed) / detection_seconds, 0.0, 1.0)
		result.append(marker)
	return result

func get_patrols() -> Array[SpatialFlyingPatrol]:
	var result: Array[SpatialFlyingPatrol] = []
	for patrol in _patrols:
		if is_instance_valid(patrol) and not patrol.is_queued_for_deletion():
			result.append(patrol)
	return result

func patrol_for_slot(slot: int) -> SpatialFlyingPatrol:
	var patrol: Variant = _slot_patrols.get(slot)
	return patrol if is_instance_valid(patrol) and not patrol.is_queued_for_deletion() else null

func camera_for_slot(slot: int) -> Camera3D:
	var patrol := patrol_for_slot(slot)
	return patrol.get_node_or_null("Visual/CameraBoom/PatrolCamera") as Camera3D if patrol != null else null

func stop_patrols() -> void:
	for patrol in get_patrols():
		patrol.stop_patrol()
		patrol.hide()
		patrol.queue_free()
	_patrols.clear()
	_slot_patrols.clear()
	_contacts.clear()
	_sight_elapsed = 0.0
	_navigation_snapshot = null
	_navigation_chunks.clear()
	_navigation_portals.clear()
	_chase_graphs.clear()

func start_patrols() -> void:
	if Engine.is_editor_hint() or _starting or not is_inside_tree():
		return
	_starting = true
	stop_patrols()
	last_errors.clear()
	await get_tree().physics_frame
	if not is_inside_tree():
		_starting = false
		return
	var map_root := get_node_or_null(map_root_path) as Node3D
	var zones: Array[SpatialPatrolZone3D] = []
	var counts: Dictionary = {}
	for child in get_children():
		if child is SpatialPatrolZone3D:
			child.runtime_error = ""
			if child.enabled:
				zones.append(child)
				if child.camera_slot > 0:
					counts[child.camera_slot] = int(counts.get(child.camera_slot, 0)) + 1
	if map_root == null or not map_root.global_basis.get_scale().is_equal_approx(Vector3.ONE):
		_fail_zones(zones, "Choose a map root with unit gameplay scale.")
		_starting = false
		return
	var opened := Graph.read_manifest(graph_manifest_path)
	if not opened["error"].is_empty():
		_fail_zones(zones, opened["error"])
		_starting = false
		return
	_navigation_snapshot = opened["snapshot"]
	for zone in zones:
		if not is_instance_valid(zone) or zone.is_queued_for_deletion():
			continue
		if zone.camera_slot > 0 and counts[zone.camera_slot] > 1:
			_fail_zone(zone, "Camera slot %d is assigned to multiple patrol zones." % zone.camera_slot)
			continue
		var error := zone.validation_error(map_root)
		var profile := zone.resolved_profile(defaults)
		if error.is_empty():
			error = profile.validation_error()
		if not error.is_empty():
			_fail_zone(zone, error)
			continue
		var bounds := zone.map_bounds(map_root, profile)
		var assembled := assemble_zone_graph(_navigation_snapshot, bounds,
			_patrol_clearance(profile), _navigation_chunks, _navigation_portals)
		if not assembled["error"].is_empty():
			_fail_zone(zone, assembled["error"])
			continue
		var restricted := assembled["graph"] as SpatialPatrolGraph
		if restricted.points.size() < 2:
			_fail_zone(zone, "This zone has no connected patrol links at the requested altitude and clearance.")
			continue
		_spawn(zone, map_root, profile, restricted)
	_starting = false

func _spawn(zone: SpatialPatrolZone3D, map_root: Node3D, profile: SpatialPatrolProfile,
		graph: SpatialPatrolGraph) -> void:
	var patrol := PatrolScene.instantiate() as ManagedPatrol
	profile.apply_to(patrol)
	patrol.patrol_seed = zone.patrol_seed
	patrol.map_marker_number = zone.camera_slot
	var clearance := _patrol_clearance(profile)
	var start := _find_spawn_node(patrol, map_root, graph, clearance)
	if start < 0:
		patrol.free()
		_fail_zone(zone, "No graph start node is clear of nearby patrols and solid geometry.")
		return
	zone.add_child(patrol)
	patrol.graph_root_path = patrol.get_path_to(map_root)
	patrol.chase_graph_provider = _chase_graph_for.bind(map_root, clearance)
	patrol.global_position = map_root.to_global(graph.points[start])
	var camera := get_viewport().get_camera_3d()
	patrol.update_presentation(camera, patrol_render_distance_m,
		camera != null and is_instance_valid(_patrol_overview_camera) and camera == _patrol_overview_camera)
	var marker := patrol.get_node("Marker") as Label3D
	marker.text = "◆ %d" % zone.camera_slot if zone.camera_slot > 0 else "◆"
	patrol.patrol_blocked.connect(_on_patrol_blocked.bind(zone))
	_patrols.append(patrol)
	if zone.camera_slot > 0:
		_slot_patrols[zone.camera_slot] = patrol
	patrol_spawned.emit(zone, patrol, patrol.get_node("Visual/CameraBoom/PatrolCamera") as Camera3D)
	if not patrol.start_graph(graph, start):
		_patrols.erase(patrol)
		if zone.camera_slot > 0:
			_slot_patrols.erase(zone.camera_slot)
		patrol.queue_free()
		return

func _find_spawn_node(patrol: SpatialFlyingPatrol, map_root: Node3D, graph: SpatialPatrolGraph,
		clearance: float) -> int:
	var world := get_world_3d()
	var peers: Array[SpatialFlyingPatrol] = []
	for node in get_tree().get_nodes_in_group(SpatialFlyingPatrol.MAP_GROUP):
		var peer := node as SpatialFlyingPatrol
		if peer != null and peer.active and not peer.is_queued_for_deletion() and peer.get_world_3d() == world:
			peers.append(peer)
	var shape := SphereShape3D.new()
	shape.radius = clearance
	var query := PhysicsShapeQueryParameters3D.new()
	query.shape = shape
	query.collision_mask = patrol.collision_mask
	var center := graph.coverage.get_center()
	var nearest := -1
	var nearest_distance := INF
	var radius := patrol.separation_radius_m()
	for index in graph.points.size():
		var point := graph.points[index]
		var distance := point.distance_squared_to(center)
		if not is_finite(distance) or distance >= nearest_distance:
			continue
		var position_world := map_root.to_global(point)
		var separated := true
		for peer in peers:
			var gap := radius + peer.separation_radius_m()
			if position_world.distance_squared_to(peer.global_position) < gap * gap:
				separated = false
				break
		if not separated:
			continue
		query.transform = Transform3D(Basis.IDENTITY, position_world)
		if world.direct_space_state.intersect_shape(query, 1).is_empty():
			nearest = index
			nearest_distance = distance
	return nearest

static func _patrol_clearance(profile: SpatialPatrolProfile) -> float:
	# Use the same radius precision as the physics shape that follows these links.
	var radius := profile.agent_radius_m + profile.safety_margin_m
	if not is_finite(radius):
		return radius
	var shape := SphereShape3D.new()
	shape.radius = radius
	return shape.radius

func _chase_graph_for(from_world: Vector3, to_world: Vector3, map_root: Node3D,
		clearance_m: float) -> SpatialPatrolGraph:
	## Load only the published tiles around this flight, sharing the zone snapshot and chunk cache.
	if _navigation_snapshot == null or not is_instance_valid(map_root):
		return null
	var manifest := _navigation_snapshot.manifest
	var origin: Vector3 = Graph._point(manifest["origin"])
	var grid_size: float = manifest["chunk_size_m"]
	var local_start := map_root.to_local(from_world)
	var local_finish := map_root.to_local(to_world)
	var start := (local_start - origin) / grid_size
	var finish := (local_finish - origin) / grid_size
	for coordinate in [start.x, start.z, finish.x, finish.z]:
		if not is_finite(coordinate) or coordinate < -2147483646.0 or coordinate > 2147483645.0:
			return null
	var first := Vector2i(floori(start.x), floori(start.z))
	var last := Vector2i(floori(finish.x), floori(finish.z))
	var published: Dictionary = manifest["chunks"]
	var first_id := "%d_%d" % [first.x, first.y]
	var last_id := "%d_%d" % [last.x, last.y]
	if not published.has(first_id) or not published.has(last_id):
		return null
	var low := first.min(last)
	var high := first.max(last)
	var width := int(high.x) - low.x + 1
	var depth := int(high.y) - low.y + 1
	if width > MAX_CHASE_CHUNKS or depth > MAX_CHASE_CHUNKS or width * depth > MAX_CHASE_CHUNKS:
		return null
	var window := Rect2i(low, high - low + Vector2i.ONE)
	if (width + 2) * (depth + 2) <= MAX_PADDED_CHASE_CHUNKS:
		window = window.grow(1)
	var key := [window, clearance_m]
	if not _chase_graphs.has(key):
		if _chase_graphs.size() >= MAX_CHASE_GRAPHS:
			_chase_graphs.erase(_chase_graphs.keys()[0])
		_chase_graphs[key] = _assemble_chase_graph(window, clearance_m, origin, grid_size)
	var start_chunk: Dictionary = _navigation_chunks.get(first_id, {})
	var finish_chunk: Dictionary = _navigation_chunks.get(last_id, {})
	if not _covers_horizontal_point(start_chunk.get("graph"), local_start) \
			or not _covers_horizontal_point(finish_chunk.get("graph"), local_finish):
		return null
	return _chase_graphs[key] as SpatialPatrolGraph

static func _covers_horizontal_point(graph: SpatialPatrolGraph, point: Vector3) -> bool:
	return graph != null and graph.coverage.grow(0.0001).has_point(
		Vector3(point.x, graph.coverage.get_center().y, point.z))

func _assemble_chase_graph(window: Rect2i, clearance_m: float, origin: Vector3,
		grid_size: float) -> SpatialPatrolGraph:
	var chunks: Dictionary = {}
	var node_count := 0
	var bounds := AABB()
	var published: Dictionary = _navigation_snapshot.manifest["chunks"]
	for z in range(window.position.y, window.end.y):
		for x in range(window.position.x, window.end.x):
			var id := "%d_%d" % [x, z]
			if not published.has(id):
				continue
			if not _navigation_chunks.has(id):
				_navigation_chunks[id] = _navigation_snapshot.open_chunk(id)
			var chunk := _navigation_chunks[id].get("graph") as SpatialPatrolGraph
			if chunk == null:
				continue
			node_count += chunk.points.size()
			if node_count > Graph.MAX_NODES:
				return null
			bounds = chunk.coverage if chunks.is_empty() else bounds.merge(chunk.coverage)
			chunks[id] = chunk
	if chunks.is_empty():
		return null
	var portals: Array = []
	if chunks.size() > 1:
		if _navigation_portals.is_empty():
			_navigation_portals.merge(_navigation_snapshot.read_portals())
			if not str(_navigation_portals.get("error", "")).is_empty():
				push_warning("Patrol chase portals: " + str(_navigation_portals["error"]))
		portals = _navigation_portals.get("portals", [])
	var assembled := _join_graph_chunks(chunks, portals, bounds, clearance_m, origin, grid_size, false)
	if not assembled["error"].is_empty():
		push_warning("Patrol chase navigation: " + str(assembled["error"]))
		return null
	return assembled["graph"] as SpatialPatrolGraph

func _on_patrol_blocked(message: String, zone: SpatialPatrolZone3D) -> void:
	if is_instance_valid(zone):
		_fail_zone(zone, message)

func _fail_zones(zones: Array[SpatialPatrolZone3D], message: String) -> void:
	if zones.is_empty():
		last_errors.append(message)
	for zone in zones:
		_fail_zone(zone, message)

func _fail_zone(zone: SpatialPatrolZone3D, message: String) -> void:
	zone.runtime_error = message
	last_errors.append("%s: %s" % [zone.name, message])
	zone_failed.emit(zone, message)
	push_warning("Patrol zone %s: %s" % [zone.name, message])

static func _zone_chunks(snapshot: Graph.Snapshot, bounds: AABB) -> Dictionary:
	var size: Variant = snapshot.manifest.get("chunk_size_m")
	var origin: Variant = Graph._point(snapshot.manifest.get("origin"))
	if not Graph._number(size) or size <= 0.0 or origin == null:
		return {"error": "Navigation manifest has an invalid grid."}
	if not bounds.position.is_finite() or not bounds.end.is_finite() \
			or bounds.size.x <= 0.0 or bounds.size.y <= 0.0 or bounds.size.z <= 0.0:
		return {"error": "Patrol zone must have finite positive extents."}
	var first_x := floorf((bounds.position.x - origin.x) / size)
	var first_z := floorf((bounds.position.z - origin.z) / size)
	var last_x := ceilf((bounds.end.x - origin.x) / size) - 1.0
	var last_z := ceilf((bounds.end.z - origin.z) / size) - 1.0
	for coordinate in [first_x, first_z, last_x, last_z]:
		if not is_finite(coordinate) or coordinate < -2147483648.0 or coordinate > 2147483647.0:
			return {"error": "Patrol zone exceeds the supported navigation grid coordinates."}
	if (last_x - first_x + 1.0) * (last_z - first_z + 1.0) > MAX_ZONE_CHUNKS:
		return {"error": "Patrol zone intersects more than %d navigation chunks." % MAX_ZONE_CHUNKS}
	var ids := PackedStringArray()
	for z in range(int(first_z), int(last_z) + 1):
		for x in range(int(first_x), int(last_x) + 1):
			var id := "%d_%d" % [x, z]
			if not snapshot.manifest["chunks"].has(id):
				return {"error": "Navigation chunk %s is missing for this patrol zone." % id}
			ids.append(id)
	return {"chunk_ids": ids, "error": ""}

static func assemble_zone_graph(snapshot: Graph.Snapshot, bounds: AABB, clearance_m: float,
		loaded_chunks: Dictionary, portal_catalog: Dictionary) -> Dictionary:
	var selected := _zone_chunks(snapshot, bounds)
	if not selected["error"].is_empty():
		return selected
	if not is_finite(clearance_m) or clearance_m < 0.0:
		return {"error": "Patrol clearance must be finite and nonnegative."}
	var ids: PackedStringArray = selected["chunk_ids"]
	var chunks: Dictionary = {}
	var origin: Vector3 = Graph._point(snapshot.manifest["origin"])
	var grid_size: float = snapshot.manifest["chunk_size_m"]
	for id in ids:
		if not loaded_chunks.has(id):
			loaded_chunks[id] = snapshot.open_chunk(id)
		var opened: Dictionary = loaded_chunks[id]
		if not opened["error"].is_empty():
			return {"error": "Navigation chunk %s: %s" % [id, opened["error"]]}
		var graph := opened["graph"] as SpatialPatrolGraph
		var intersection := _tile_volume(id, origin, grid_size, bounds).intersection(bounds)
		if graph == null or not _encloses(graph.coverage, intersection):
			return {"error": "Zone altitude or rectangle exceeds navigation chunk %s coverage." % id}
		chunks[id] = graph
	if ids.size() == 1:
		return {"graph": restrict_graph(chunks[ids[0]], bounds, clearance_m), "error": ""}
	if portal_catalog.is_empty():
		portal_catalog.merge(snapshot.read_portals())
	if not str(portal_catalog.get("error", "Missing navigation portals.")).is_empty():
		return {"error": portal_catalog.get("error", "Missing navigation portals.")}
	var assembled := _join_graph_chunks(chunks, portal_catalog["portals"], bounds, clearance_m,
		origin, grid_size, true)
	if not assembled["error"].is_empty():
		return assembled
	return {"graph": restrict_graph(assembled["graph"], bounds, clearance_m), "error": ""}

static func _tile_volume(id: String, origin: Vector3, grid_size: float, vertical_bounds: AABB) -> AABB:
	var cell := id.split("_")
	var low := Vector3(origin.x + int(cell[0]) * grid_size, vertical_bounds.position.y,
		origin.z + int(cell[1]) * grid_size)
	return AABB(low, Vector3(grid_size, vertical_bounds.size.y, grid_size))

static func _join_graph_chunks(chunks: Dictionary, portals: Array, bounds: AABB, clearance_m: float,
		origin: Vector3, grid_size: float, restrict_to_bounds: bool) -> Dictionary:
	var combined := ZoneGraph.new()
	combined.coverage = bounds
	combined.edge_clearance = clearance_m
	var interior := bounds.grow(-clearance_m)
	if restrict_to_bounds and (interior.size.x <= 0.0 or interior.size.y <= 0.0 or interior.size.z <= 0.0):
		return {"graph": combined, "error": ""}
	var remaps: Dictionary = {}
	var regions: Dictionary[String, AABB] = {}
	for id: String in chunks:
		var graph: SpatialPatrolGraph = chunks[id]
		var tile := _tile_volume(id, origin, grid_size, graph.coverage)
		var region := graph.coverage.intersection(tile).intersection(bounds)
		if not region.has_volume():
			continue
		combined.flight_regions.append(region)
		regions[id] = region
		var allowed := region.grow(0.0001)
		if restrict_to_bounds:
			allowed = allowed.intersection(interior)
		var remap: Dictionary = {}
		for node in graph.points.size():
			if not allowed.has_point(graph.points[node]):
				continue
			if combined.points.size() >= Graph.MAX_NODES:
				return {"error": "Navigation window exceeds %d retained graph nodes." % Graph.MAX_NODES}
			remap[node] = combined.points.size()
			combined.points.append(graph.points[node])
			combined.adjacency.append(PackedInt32Array())
		remaps[id] = remap
		for node: int in remap:
			for target in graph.links(node, clearance_m):
				if remap.has(target):
					combined.adjacency[remap[node]].append(remap[target])
	for portal: Dictionary in portals:
		var from_id: String = portal["from_chunk"]
		var to_id: String = portal["to_chunk"]
		if not remaps.has(from_id) or not remaps.has(to_id) or portal["clearance_m"] < clearance_m:
			continue
		var source := int(portal["from_node"])
		var target := int(portal["to_node"])
		var from_graph: SpatialPatrolGraph = chunks[from_id]
		var to_graph: SpatialPatrolGraph = chunks[to_id]
		if source >= from_graph.points.size() or target >= to_graph.points.size():
			return {"error": "A navigation portal references a missing decoded node."}
		if not _valid_portal_geometry(portal, from_graph.points[source], to_graph.points[target], origin, grid_size):
			return {"error": "A navigation portal has invalid seam geometry."}
		if remaps[from_id].has(source) and remaps[to_id].has(target):
			var a: int = remaps[from_id][source]
			var b: int = remaps[to_id][target]
			if not combined.adjacency[a].has(b):
				combined.adjacency[a].append(b)
				combined.adjacency[b].append(a)
				var axis := 0 if from_id.get_slice("_", 0) != to_id.get_slice("_", 0) else 2
				combined.flight_portals.append(Graph.FlightPortal.new(Vector2i(a, b), regions[from_id], regions[to_id],
					Graph._point(portal["position"]), axis, portal["clearance_m"]))
	return {"graph": combined, "error": ""}

static func _valid_portal_geometry(portal: Dictionary, start: Vector3, finish: Vector3,
		origin: Vector3, grid_size: float) -> bool:
	var first: PackedStringArray = portal["from_chunk"].split("_")
	var last: PackedStringArray = portal["to_chunk"].split("_")
	var dx := int(last[0]) - int(first[0])
	var dz := int(last[1]) - int(first[1])
	if absi(dx) + absi(dz) != 1:
		return false
	var axis := 0 if dx != 0 else 2
	var seam := origin[axis] + maxi(int(first[0 if axis == 0 else 1]), int(last[0 if axis == 0 else 1])) * grid_size
	var position: Vector3 = Graph._point(portal["position"])
	var distance := start.distance_to(finish)
	var tolerance := maxf(0.001, grid_size * 0.00001)
	return minf(start[axis], finish[axis]) < seam and maxf(start[axis], finish[axis]) > seam \
		and absf(position[axis] - seam) <= tolerance \
		and absf(position.distance_to(start) + position.distance_to(finish) - distance) <= tolerance \
		and absf(float(portal["distance_m"]) - distance) <= tolerance

static func _encloses(outer: AABB, inner: AABB) -> bool:
	return outer.position.x <= inner.position.x and outer.position.y <= inner.position.y \
		and outer.position.z <= inner.position.z and outer.end.x >= inner.end.x \
		and outer.end.y >= inner.end.y and outer.end.z >= inner.end.z

static func restrict_graph(source: SpatialPatrolGraph, bounds: AABB, clearance_m: float) -> SpatialPatrolGraph:
	## Keep the largest component. Every retained segment and Bézier control point stays in this convex box.
	var result := ZoneGraph.new()
	result.coverage = bounds
	result.edge_clearance = clearance_m
	var regions := source.flight_regions
	if regions.is_empty():
		regions = [source.coverage]
	for source_region in regions:
		var region := source_region.intersection(bounds)
		if region.has_volume():
			result.flight_regions.append(region)
	var interior := bounds.grow(-clearance_m)
	if interior.size.x <= 0.0 or interior.size.y <= 0.0 or interior.size.z <= 0.0:
		return result
	var candidates: Dictionary = {}
	for index in source.points.size():
		if interior.has_point(source.points[index]):
			candidates[index] = true
	var visited: Dictionary = {}
	var largest := PackedInt32Array()
	for node_id: int in candidates:
		if visited.has(node_id):
			continue
		var component := PackedInt32Array([node_id])
		visited[node_id] = true
		var cursor := 0
		while cursor < component.size():
			for target in source.links(component[cursor], clearance_m):
				if candidates.has(target) and not visited.has(target):
					visited[target] = true
					component.append(target)
			cursor += 1
		if component.size() > largest.size():
			largest = component
	largest.sort()
	var remap: Dictionary = {}
	for original in largest:
		remap[original] = result.points.size()
		result.points.append(source.points[original])
	for original in largest:
		var links := PackedInt32Array()
		for target in source.links(original, clearance_m):
			if remap.has(target):
				links.append(remap[target])
		links.sort()
		result.adjacency.append(links)
	for portal in source.flight_portals:
		if remap.has(portal.nodes.x) and remap.has(portal.nodes.y):
			var endpoints := Vector2i(remap[portal.nodes.x], remap[portal.nodes.y])
			result.flight_portals.append(Graph.FlightPortal.new(endpoints, portal.from_region.intersection(bounds),
				portal.to_region.intersection(bounds), portal.position, portal.axis, portal.clearance_m))
	return result
