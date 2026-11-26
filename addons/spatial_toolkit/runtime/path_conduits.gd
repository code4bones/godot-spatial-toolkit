@tool
extends Node3D
## An optional above-ground conduit layer built from imported Paths centerlines.

const Localization := preload("res://addons/spatial_toolkit/ui/editor_localization.gd")
const ConduitPulse := preload("res://addons/spatial_toolkit/runtime/conduit_pulse.gd")
const ConduitFence := preload("res://addons/spatial_toolkit/runtime/path_conduit_fence.gd")
const Layers := preload("res://addons/spatial_toolkit/core/spatial_layers.gd")
const PIPE_SHADER := preload("res://addons/spatial_toolkit/materials/path_conduit.gdshader")
const SIDES := 8
const CHUNK_M := 84.0
const PIPE_HEIGHT_M := 3.6
const PIPE_RADIUS_M := 0.34
const STRAIGHT_MIN_M := 5.5
const STRAIGHT_MAX_M := 18.0

@export_group("Resources")
@export var metal_library: PackedScene
@export var industrial_library: PackedScene
@export var fence_library: PackedScene

@export_group("Pipes", "pipe_")
@export_range(0.1, 100.0, 0.1, "suffix:m") var pipe_height_m := PIPE_HEIGHT_M
@export_range(0.05, 10.0, 0.01, "suffix:m") var pipe_radius_m := PIPE_RADIUS_M
@export_range(0.05, 20.0, 0.01, "suffix:m") var pipe_end_depth_m := 0.48
@export_range(0.1, 100.0, 0.1, "suffix:m") var pipe_ramp_length_m := 8.0
@export_range(0.25, 20.0, 0.05, "suffix:m") var pipe_sample_step_m := 2.0

@export_group("Fencing", "fence_")
@export_range(0.1, 30.0, 0.05, "suffix:m") var fence_side_offset_m := ConduitFence.SIDE_OFFSET_M
@export_range(0.65, 40.0, 0.05, "suffix:m") var fence_bay_length_m := ConduitFence.SPAN_M
@export_range(0.0, 10.0, 0.01, "suffix:m") var fence_top_clearance_m := ConduitFence.TOP_CLEARANCE_M

@export_group("Signals", "signal_")
@export_range(0, 32, 1) var signal_trains := 5
@export_range(0.1, 200.0, 0.1, "suffix:m/s") var signal_speed_mps := ConduitPulse.SPEED_M
@export_range(0.1, 30.0, 0.1, "suffix:m") var signal_ring_spacing_m := ConduitPulse.RING_SPACING_M
@export_range(0.0, 16.0, 0.01) var signal_emission := 1.4

var _neighbors: Dictionary = {}
var _chunks: Dictionary = {}
var _part_meshes: Array[Mesh] = []
var _parts: Dictionary = {}
var _pulse_routes: Array[Dictionary] = []
var _staged_geometry: Array[Node3D] = []
var _scale := 1.0
var _ground_y := 0.0
var _fence: ConduitFence

func _validate_property(property: Dictionary) -> void:
	Localization.localize_inspector_group(property)

func _ready() -> void:
	if Engine.is_editor_hint():
		return
	var map := get_parent().get_parent() as Node3D if get_parent() != null else null
	if map == null:
		return
	var paths := map.get_node_or_null("Generated/Paths") as Node3D
	var ground := map.get_node_or_null("FlatGround") as Node3D
	if paths == null or ground == null:
		return
	var model_path := map.scene_file_path.get_base_dir().path_join("export_preview.spatial.json")
	if not FileAccess.file_exists(model_path):
		return
	var model: Variant = JSON.parse_string(FileAccess.get_file_as_string(model_path))
	if not model is Dictionary or not model.get("features") is Array:
		return
	_scale = float(map.get_meta("world_scale", 1.0))
	_ground_y = to_local(ground.global_position).y
	var clearances := _load_clearances(map.scene_file_path.get_base_dir())
	var roads := map.get_node_or_null("Generated/Roads")
	_apply_road_clearances(roads, clearances.get("roads", {}))
	var path_cuts: Dictionary = clearances.get("paths", {})
	_part_meshes.append(_extract_part(metal_library, "pipe_60cm_metal"))
	_part_meshes.append(_extract_part(industrial_library, "modular_industrial_pipes_01_pipe02"))
	var meshes := {}
	for mesh in Layers.meshes(paths):
		if mesh.is_visible_in_tree() and mesh.has_meta("source_id"):
			meshes[str(mesh.get_meta("source_id"))] = mesh
	var routed: Array[Node3D] = []
	for feature: Dictionary in model["features"]:
		var id := str(feature.get("id", ""))
		if not meshes.has(id) or feature.get("geometry", {}).get("type") != "LineString":
			continue
		if path_cuts.has(id):
			for line: Array in path_cuts[id]:
				_add_line(line, id)
			routed.append(meshes[id])
		elif _add_line(feature["geometry"]["coordinates"], id):
			routed.append(meshes[id])
	if routed.is_empty():
		return
	if fence_library != null:
		var road_ids := {}
		for road in Layers.meshes(roads):
			if road.is_visible_in_tree() and road.has_meta("source_id"):
				road_ids[road.get_meta("source_id")] = true
		_fence = ConduitFence.new(model["features"], road_ids, _neighbors, pipe_height_m + pipe_radius_m,
			fence_side_offset_m, fence_bay_length_m, fence_top_clearance_m,
			ConduitFence.PIPE_CLEARANCE_M + (pipe_radius_m - PIPE_RADIUS_M))
	var visited := {}
	var routes := 0
	# Degree-two vertices join through the original way boundaries.
	for include_loops in [false, true]:
		for vertex: Vector2 in _neighbors:
			var adjacent: Dictionary = _neighbors[vertex]
			if not include_loops and adjacent.size() == 2:
				continue
			for other: Vector2 in adjacent:
				if not visited.has(Vector4(vertex.x, vertex.y, other.x, other.y)):
					var points := _trace(vertex, other, visited)
					_emit_route(points)
					if _fence != null:
						_add_fence_route(points)
					routes += 1
					if routes % 32 == 0:
						await get_tree().process_frame
						if is_queued_for_deletion() or not is_inside_tree():
							return
	var material := ShaderMaterial.new()
	material.shader = PIPE_SHADER
	var committed := 0
	for key: Vector2i in _chunks:
		var surface: SurfaceTool = _chunks[key]
		surface.set_material(material)
		surface.index()
		var mesh := MeshInstance3D.new()
		mesh.name = "PipeChunk_%d_%d" % [key.x, key.y]
		mesh.mesh = surface.commit()
		mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		_stage_geometry(mesh)
		committed += 1
		if committed % 16 == 0:
			await get_tree().process_frame
			if is_queued_for_deletion() or not is_inside_tree():
				return
	_add_junctions(material)
	_add_straight_parts()
	_chunks.clear()
	_parts.clear()
	_neighbors.clear()
	if _fence != null:
		var fence := await _fence.add_to(self, fence_library, _scale, _ground_y)
		_fence = null
		if is_queued_for_deletion() or not is_inside_tree():
			return
		if fence != null:
			_staged_geometry.append(fence)
	# Publish the complete replacement together, before the next rendered frame.
	for mesh in routed:
		if is_instance_valid(mesh):
			mesh.hide()
	for visual in _staged_geometry:
		visual.show()
	_staged_geometry.clear()
	_add_signal_trains(hash(map.scene_file_path))
	set_meta("source_path_count", routed.size())
	set_meta("route_count", routes)

func clearance_for_lamps(default_m: float) -> float:
	var half_width := maxf(pipe_radius_m, fence_side_offset_m if fence_library != null else 0.0)
	return default_m + maxf(0.0, half_width - ConduitFence.SIDE_OFFSET_M)

func _stage_geometry(mesh: Node3D) -> void:
	mesh.hide()
	add_child(mesh)
	_staged_geometry.append(mesh)

func _add_fence_route(points: PackedVector2Array) -> void:
	var ids := {}
	for index in range(1, points.size()):
		ids.merge(_neighbors[points[index - 1]][points[index]])
	var begin_degree: int = _neighbors[points[0]].size()
	var end_degree: int = _neighbors[points[-1]].size()
	var begin := ConduitFence.END_CLEARANCE_M if begin_degree == 1 else ConduitFence.JUNCTION_CLEARANCE_M
	var end := ConduitFence.END_CLEARANCE_M if end_degree == 1 else ConduitFence.JUNCTION_CLEARANCE_M
	_fence.add_route(points, 0.0 if begin_degree == 2 else begin, 0.0 if end_degree == 2 else end, ids)

func _add_signal_trains(seed_value: int) -> void:
	if _pulse_routes.is_empty():
		return
	var connections := {}
	for index in _pulse_routes.size():
		var route := _pulse_routes[index]
		for endpoint: Vector2 in [route["start"], route["end"]]:
			if not connections.has(endpoint):
				connections[endpoint] = []
			connections[endpoint].append(index)
	var occupied := {}
	for index in signal_trains:
		var pulse := ConduitPulse.new()
		pulse.name = "SignalTrain%d" % (index + 1)
		pulse.speed_mps = signal_speed_mps
		pulse.ring_spacing_m = signal_ring_spacing_m
		pulse.emission = signal_emission
		add_child(pulse)
		pulse.setup(_pulse_routes, connections, occupied, _scale, _ground_y,
			pipe_radius_m, seed_value + index * 179, 1.5 + index * 1.6)

func _load_clearances(directory: String) -> Dictionary:
	var path := directory.path_join("building_clearances.json")
	if not FileAccess.file_exists(path):
		return {}
	var value: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	return value if value is Dictionary and value.get("version") == 1 else {}

func _apply_road_clearances(roads: Node, changes: Dictionary) -> void:
	for road in Layers.meshes(roads):
		var id := str(road.get_meta("source_id", ""))
		if not changes.has(id) or road.mesh == null:
			continue
		var triangles: Array = changes[id]
		if triangles.is_empty():
			road.hide()
			continue
		var level: float = road.mesh.get_aabb().position.y
		var surface := SurfaceTool.new()
		surface.begin(Mesh.PRIMITIVE_TRIANGLES)
		for triangle: Array in triangles:
			for point: Array in triangle:
				surface.set_normal(Vector3.UP)
				surface.add_vertex(Vector3(float(point[0]) * _scale, level, float(point[1]) * _scale))
		surface.index()
		road.mesh = surface.commit()

func _extract_part(library: PackedScene, module_name: String) -> Mesh:
	if library == null:
		return null
	var kit := library.instantiate()
	var part := kit.find_child(module_name, true, false) as MeshInstance3D
	var mesh := part.mesh if part != null else null
	kit.free()
	return mesh

func _add_line(coordinates: Array, source_id: String) -> bool:
	var connected := false
	for index in range(coordinates.size() - 1):
		var a := Vector2(float(coordinates[index][0]), float(coordinates[index][1])).snapped(Vector2.ONE * 0.00001)
		var b := Vector2(float(coordinates[index + 1][0]), float(coordinates[index + 1][1])).snapped(Vector2.ONE * 0.00001)
		if a.is_equal_approx(b):
			continue
		if not _neighbors.has(a):
			_neighbors[a] = {}
		if not _neighbors.has(b):
			_neighbors[b] = {}
		_neighbors[a].get_or_add(b, {})[source_id] = true
		_neighbors[b].get_or_add(a, {})[source_id] = true
		connected = true
	return connected

func _trace(start: Vector2, next: Vector2, visited: Dictionary) -> PackedVector2Array:
	var points := PackedVector2Array([start])
	var previous := start
	var current := next
	while not visited.has(Vector4(previous.x, previous.y, current.x, current.y)):
		visited[Vector4(previous.x, previous.y, current.x, current.y)] = true
		visited[Vector4(current.x, current.y, previous.x, previous.y)] = true
		points.append(current)
		var adjacent: Dictionary = _neighbors[current]
		if adjacent.size() != 2 or current == start:
			break
		var neighbors := adjacent.keys()
		var following: Vector2 = neighbors[1] if neighbors[0] == previous else neighbors[0]
		previous = current
		current = following
	return points

func _emit_route(points: PackedVector2Array) -> void:
	var length := 0.0
	for index in range(1, points.size()):
		length += points[index - 1].distance_to(points[index])
	var begin_ramp: bool = _neighbors[points[0]].size() == 1
	var end_ramp: bool = _neighbors[points[-1]].size() == 1
	var ramp := minf(pipe_ramp_length_m, length / (2.0 if begin_ramp and end_ramp else 1.0))
	var height := pipe_height_m if not (begin_ramp and end_ramp) else minf(pipe_height_m, length * 0.65)
	var positions := PackedVector3Array()
	var distances := PackedFloat32Array()
	var travelled := 0.0
	for index in range(1, points.size()):
		var a := points[index - 1]
		var b := points[index]
		var span := a.distance_to(b)
		var steps := maxi(2, ceili(span / maxf(0.25, pipe_sample_step_m)))
		for step in steps:
			var progress := float(step) / steps
			var point := a.lerp(b, progress)
			var distance := travelled + span * progress
			positions.append(_point_at_height(point, distance, length, ramp, height, begin_ramp, end_ramp))
			distances.append(distance)
		travelled += span
	positions.append(_point_at_height(points[-1], length, length, ramp, height, begin_ramp, end_ramp))
	distances.append(length)
	var bounds := Rect2(points[0], Vector2.ZERO)
	for point in points:
		bounds = bounds.expand(point)
	_pulse_routes.append({"points": positions, "bounds": bounds, "length": length, "start": points[0], "end": points[-1]})
	var variant := 1 if posmod(hash(points[0]), 4) == 0 else 0
	if _part_meshes[variant] == null:
		variant = 0
	var index := 0
	while index < positions.size() - 1:
		var key := Vector2i(floori(positions[index].x / CHUNK_M), floori(positions[index].z / CHUNK_M))
		var last := _straight_run(positions, distances, index) if _part_meshes[variant] != null else index
		if last > index:
			_store_straight_part(key, variant, positions[index], positions[last])
			index = last
			continue
		if not _chunks.has(key):
			var surface := SurfaceTool.new()
			surface.begin(Mesh.PRIMITIVE_TRIANGLES)
			_chunks[key] = surface
		_emit_span(_chunks[key], positions, distances, index)
		index += 1

func _straight_run(positions: PackedVector3Array, distance: PackedFloat32Array, start: int) -> int:
	var axis := (positions[start + 1] - positions[start]).normalized()
	if absf(axis.y) > 0.001:
		return start
	if start > 0 and axis.dot((positions[start] - positions[start - 1]).normalized()) < 0.9999:
		return start
	var finish := start + 1
	while finish + 1 < positions.size():
		var next := (positions[finish + 1] - positions[finish]).normalized()
		if axis.dot(next) < 0.9999 or absf(next.y) > 0.001:
			# Leave the turning span to the swept mesh.
			finish -= 1
			break
		if distance[finish + 1] - distance[start] > STRAIGHT_MAX_M:
			break
		finish += 1
	return finish if distance[finish] - distance[start] >= STRAIGHT_MIN_M else start

func _store_straight_part(key: Vector2i, variant: int, a: Vector3, b: Vector3) -> void:
	var ident := Vector3i(key.x, key.y, variant)
	if not _parts.has(ident):
		_parts[ident] = []
	var bounds := _part_meshes[variant].get_aabb()
	var tangent := (b - a).normalized()
	var side := tangent.cross(Vector3.UP).normalized()
	var basis := Basis(side, tangent, side.cross(tangent)).scaled_local(Vector3(
		pipe_radius_m * 2.0 / bounds.size.x, a.distance_to(b) / bounds.size.y,
		pipe_radius_m * 2.0 / bounds.size.z) * _scale)
	var center := bounds.get_center()
	center.y = bounds.position.y
	var origin := a * _scale - basis * center
	origin.y += _ground_y
	_parts[ident].append(Transform3D(basis, origin))

func _add_straight_parts() -> void:
	var counts := PackedInt32Array([0, 0])
	for key: Vector3i in _parts:
		var transforms: Array = _parts[key]
		var instances := MultiMesh.new()
		instances.transform_format = MultiMesh.TRANSFORM_3D
		instances.mesh = _part_meshes[key.z]
		instances.instance_count = transforms.size()
		for index in transforms.size():
			instances.set_instance_transform(index, transforms[index])
		var mesh := MultiMeshInstance3D.new()
		mesh.name = "KitPipe_%d_%d_%d" % [key.x, key.y, key.z]
		mesh.multimesh = instances
		mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		_stage_geometry(mesh)
		counts[key.z] += transforms.size()
	set_meta("kit_module_counts", counts)

func _point_at_height(point: Vector2, distance: float, length: float, ramp: float,
		height: float, begin_ramp: bool, end_ramp: bool) -> Vector3:
	var rise := 1.0
	if begin_ramp:
		rise = smoothstep(0.0, ramp, distance)
	if end_ramp:
		rise = minf(rise, smoothstep(0.0, ramp, length - distance))
	return Vector3(point.x, lerpf(-pipe_end_depth_m, height, rise), point.y)

func _emit_span(surface: SurfaceTool, points: PackedVector3Array, distance: PackedFloat32Array,
		index: int) -> void:
	var tangent_a := (points[index + 1] - points[maxi(0, index - 1)]).normalized()
	var tangent_b := (points[mini(index + 2, points.size() - 1)] - points[index]).normalized()
	var direction := (points[index + 1] - points[index]).normalized()
	if tangent_a.is_zero_approx():
		tangent_a = direction
	if tangent_b.is_zero_approx():
		tangent_b = direction
	var rings := [Basis.looking_at(tangent_a), Basis.looking_at(tangent_b)]
	for side in SIDES:
		_vertex(surface, points[index], rings[0], side, distance[index])
		_vertex(surface, points[index + 1], rings[1], side, distance[index + 1])
		_vertex(surface, points[index], rings[0], side + 1, distance[index])
		_vertex(surface, points[index], rings[0], side + 1, distance[index])
		_vertex(surface, points[index + 1], rings[1], side, distance[index + 1])
		_vertex(surface, points[index + 1], rings[1], side + 1, distance[index + 1])

func _vertex(surface: SurfaceTool, point: Vector3, basis: Basis, side: int, distance: float) -> void:
	var slice := Vector2.from_angle(float(side % SIDES) * TAU / SIDES)
	var normal := basis.x * slice.x + basis.y * slice.y
	var position := (point + normal * pipe_radius_m) * _scale
	position.y += _ground_y
	surface.set_uv(Vector2(float(side) / SIDES, distance))
	surface.set_normal(normal)
	surface.add_vertex(position)

func _add_junctions(material: ShaderMaterial) -> void:
	var points := PackedVector2Array()
	for point: Vector2 in _neighbors:
		if _neighbors[point].size() > 2:
			points.append(point)
	if points.is_empty():
		return
	var joint := SphereMesh.new()
	joint.radius = pipe_radius_m * _scale * 1.08
	joint.height = joint.radius * 2.0
	joint.radial_segments = 8
	joint.rings = 4
	joint.material = material
	var instances := MultiMesh.new()
	instances.transform_format = MultiMesh.TRANSFORM_3D
	instances.mesh = joint
	instances.instance_count = points.size()
	for index in points.size():
		var point := points[index] * _scale
		instances.set_instance_transform(index, Transform3D(Basis.IDENTITY,
			Vector3(point.x, _ground_y + pipe_height_m * _scale, point.y)))
	var mesh := MultiMeshInstance3D.new()
	mesh.name = "PipeJunctions"
	mesh.multimesh = instances
	mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_stage_geometry(mesh)
