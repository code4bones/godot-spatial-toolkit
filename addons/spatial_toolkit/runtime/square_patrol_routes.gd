class_name SpatialSquarePatrolRoutes
extends Node3D
## Prepares closed patrol courses around a square in baked-map coordinates.

const MAX_VARIANTS := 32

@export_node_path("CharacterBody3D") var patrol_path: NodePath
@export_file("*.json") var world_data_path := ""
@export var square := Rect2(0.0, 0.0, 256.0, 256.0)
@export var offsets_m := PackedFloat32Array([10.0, 16.0])
@export var altitude_m := 64.0

var last_error := ""

func _ready() -> void:
	var map := get_parent() as Node3D
	var patrol := get_node_or_null(patrol_path) as SpatialFlyingPatrol
	if map == null or patrol == null:
		_fail("A map parent and a flying patrol are required.")
		return
	var clearance := patrol.agent_radius_m + patrol.safety_margin_m
	if not _valid_course(clearance):
		_fail("Invalid square, offsets, altitude or patrol clearance.")
		return
	var world := SpatialWorldData.load_for_map(map) if world_data_path.is_empty() \
		else SpatialWorldData.load_file(world_data_path)
	if world == null:
		_fail("Square patrol requires the baked map's building bounds.")
		return
	var max_offset := 0.0
	for offset: float in offsets_m:
		max_offset = maxf(max_offset, offset)
	var hub := Vector3(square.get_center().x, altitude_m, square.position.y)
	var obstacles := _building_bounds(world, square.grow(max_offset), clearance)
	for offset_index in offsets_m.size():
		var offset := offsets_m[offset_index]
		for space: String in ["inner", "outer"]:
			var track := square.grow(offset if space == "outer" else -offset)
			for clockwise: bool in [true, false]:
				var points := _loop_points(track, hub, clockwise)
				if _clear_of_buildings(points, obstacles):
					var direction := "clockwise" if clockwise else "counterclockwise"
					var path := _add_route(map, "%s_%d_%s" % [space, offset_index, direction], points, space)
					patrol.routes.append(patrol.get_path_to(path))
	if patrol.routes.is_empty():
		_fail("No patrol loop clears the building bounds. Check the offsets and altitude.")
		return
	patrol.global_position = map.to_global(hub)

func _valid_course(clearance: float) -> bool:
	if not square.position.is_finite() or not square.size.is_finite() or not square.end.is_finite() \
			or square.size.x <= 0.0 or square.size.x != square.size.y \
			or not is_finite(clearance) or clearance <= 0.0 or not is_finite(altitude_m):
		return false
	if offsets_m.is_empty() or offsets_m.size() * 4 > MAX_VARIANTS:
		return false
	for offset: float in offsets_m:
		if not is_finite(offset) or offset <= clearance or offset >= square.size.x * 0.5:
			return false
	return true

func _building_bounds(world: SpatialWorldData, region: Rect2, clearance: float) -> Array[AABB]:
	var result: Array[AABB] = []
	var corridor := AABB(Vector3(region.position.x, altitude_m, region.position.y),
		Vector3(region.size.x, 0.0, region.size.y)).grow(clearance)
	for identity: String in world.building_ids():
		var box := world.building_bounds(identity).grow(clearance)
		if corridor.intersects(box):
			result.append(box)
	return result

func _loop_points(track: Rect2, hub: Vector3, clockwise: bool) -> PackedVector3Array:
	var entry := Vector3(hub.x, hub.y, track.position.y)
	var northwest := Vector3(track.position.x, hub.y, track.position.y)
	var northeast := Vector3(track.end.x, hub.y, track.position.y)
	var southeast := Vector3(track.end.x, hub.y, track.end.y)
	var southwest := Vector3(track.position.x, hub.y, track.end.y)
	return PackedVector3Array([hub, entry, northeast, southeast, southwest, northwest, entry, hub]) \
		if clockwise else PackedVector3Array([hub, entry, northwest, southwest, southeast, northeast, entry, hub])

func _clear_of_buildings(points: PackedVector3Array, obstacles: Array[AABB]) -> bool:
	for index in range(1, points.size()):
		for box: AABB in obstacles:
			if box.intersects_segment(points[index - 1], points[index]) != null:
				return false
	return true

func _add_route(map: Node3D, route_name: String, points: PackedVector3Array, space: String) -> Path3D:
	var path := Path3D.new()
	path.name = route_name
	path.curve = Curve3D.new()
	path.set_meta("patrol_space", space)
	add_child(path)
	for point: Vector3 in points:
		path.curve.add_point(path.to_local(map.to_global(point)))
	return path

func _fail(reason: String) -> void:
	last_error = reason
	push_warning("Spatial Toolkit: " + reason)
