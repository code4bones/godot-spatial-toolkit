@tool
extends Node3D
## Instanced roadside floodlights and wall sconces with a local lighting budget.

const Localization := preload("res://addons/spatial_toolkit/ui/editor_localization.gd")
const RoadLayout := preload("res://addons/spatial_toolkit/runtime/road_lamp_layout.gd")
const WallLayout := preload("res://addons/spatial_toolkit/runtime/wall_lamp_layout.gd")
const NightStyle := preload("res://addons/spatial_toolkit/runtime/night_city_style.gd")
const ROAD_PART := "flood_lights_standing_single"
const ROAD_HEAD := ROAD_PART + "_light"
# A point just beyond the glass in the source head's local space.
const ROAD_LENS_OFFSET := Vector3(0.0, 0.0, 0.09)
const ROAD_LENS_MATERIAL := "flood_lights_glass"
const WALL_PART := "industrial_caged_sconce_a"
const WALL_LENS := Vector3(0.0, 0.177, 0.212)
const CHUNK_SIZE_M := 48.0
const LIGHT_REFRESH_SECONDS := 0.35

@export_group("Resources")
@export var road_lamp_library: PackedScene
@export var wall_lamp_library: PackedScene
@export var wall_emissive: Texture2D

@export_group("Street Lamps", "road_")
@export_range(1.0, 500.0, 0.1, "suffix:m") var road_pitch_m := RoadLayout.PITCH_M
@export_range(1.0, 500.0, 0.1, "suffix:m") var road_service_pitch_m := RoadLayout.SERVICE_PITCH_M
@export_range(0.0, 100.0, 0.1, "suffix:m") var road_minimum_gap_m := RoadLayout.MIN_LAMP_DISTANCE_M
@export_range(0.1, 10.0, 0.01, "suffix:×") var road_model_scale := 1.0
@export_range(0.0, 90.0, 0.1, "degrees") var road_head_tilt_degrees := 65.0
@export var road_light_color := Color("e7f0ff")
@export_range(0.0, 16.0, 0.01) var road_light_energy := 4.1
@export_range(0.1, 100.0, 0.1, "suffix:m") var road_light_range_m := 7.5
@export_range(1.0, 89.0, 0.1, "degrees") var road_light_angle_degrees := 42.0
@export_range(0.0, 16.0, 0.01) var road_lens_emission := 1.35
@export_range(0.0, 16.0, 0.01) var road_reflector_emission := 3.2
@export_range(0, 32, 1) var road_light_limit := 8

@export_group("Wall Lamps", "wall_")
@export_range(0.1, 50.0, 0.05, "suffix:m") var wall_mount_height_m := WallLayout.MOUNT_HEIGHT_M
@export_range(0.0, 100.0, 0.1, "suffix:m") var wall_minimum_gap_m := WallLayout.MIN_MOUNT_SPACING_M
@export_range(0, 32, 1) var wall_max_per_building := WallLayout.MAX_PER_BUILDING
@export_range(0.1, 10.0, 0.01, "suffix:×") var wall_model_scale := 1.0
@export var wall_light_color := Color("ffc18c")
@export_range(0.0, 16.0, 0.01) var wall_light_energy := 1.4
@export_range(0.1, 100.0, 0.1, "suffix:m") var wall_light_range_m := 4.0
@export_range(0.0, 16.0, 0.01) var wall_emission := 2.2
@export_range(0, 32, 1) var wall_light_limit := 6

@export_group("Lamp Visibility")
@export_range(1.0, 2000.0, 1.0, "suffix:m") var model_visibility_m := 115.0
@export_range(1.0, 500.0, 1.0, "suffix:m") var light_activation_m := 55.0
@export_range(0.1, 100.0, 0.1, "suffix:m") var light_fade_m := 12.0

var _player: Node3D
var _scale := 1.0
var _ground_y := 0.0
var _night := false
var _refresh := 0.0
var _road_lens := Vector3.ZERO
var _roads: Array[Dictionary] = []
var _walls: Array[Dictionary] = []
var _road_emitters: Array[Light3D] = []
var _wall_emitters: Array[Light3D] = []

func _validate_property(property: Dictionary) -> void:
	Localization.localize_inspector_group(property)

func _ready() -> void:
	set_process(false)
	if Engine.is_editor_hint():
		return
	_build.call_deferred()

func _build() -> void:
	if is_queued_for_deletion():
		return
	var map := get_parent().get_parent() as Node3D if get_parent() != null else null
	if map == null:
		return
	var ground := map.get_node_or_null("FlatGround") as Node3D
	if ground == null or map.scene_file_path.is_empty():
		return
	var path := map.scene_file_path.get_base_dir().path_join("export_preview.spatial.json")
	if not FileAccess.file_exists(path):
		return
	var model: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if not model is Dictionary or not model.get("features") is Array:
		return
	_player = map.get_node_or_null("FlyPlayer") as Node3D
	_scale = float(map.get_meta("world_scale", 1.0))
	_ground_y = to_local(ground.global_position).y
	_night = NightStyle.mode_for(map) == NightStyle.NIGHT
	var road_mesh := _assemble(road_lamp_library, ROAD_PART, false)
	var wall_mesh := _assemble(wall_lamp_library, WALL_PART, true)
	if road_mesh != null:
		_roads = RoadLayout.build(map, model["features"], _scale, road_pitch_m, road_service_pitch_m, road_minimum_gap_m)
		await _batch(road_mesh, _roads, false)
	if is_queued_for_deletion() or not is_inside_tree():
		return
	if wall_mesh != null:
		_walls = WallLayout.build(map, model["features"], _scale, wall_mount_height_m,
			wall_minimum_gap_m, wall_max_per_building, wall_model_scale)
		await _batch(wall_mesh, _walls, true)
	if is_queued_for_deletion() or not is_inside_tree():
		return
	if _night and is_instance_valid(_player):
		_create_emitters()
		_update_emitters()
		set_process(true)
	set_meta("road_lamp_count", _roads.size())
	set_meta("wall_lamp_count", _walls.size())

func _assemble(library: PackedScene, part: String, wall: bool) -> ArrayMesh:
	if library == null:
		return null
	var kit := library.instantiate()
	var parts: Array[Dictionary] = []
	var bounds := AABB()
	var road_base := Vector3.ZERO
	var road_lens := Vector3.ZERO
	if not wall:
		var stand := kit.find_child(ROAD_PART + "_stand", true, false) as MeshInstance3D
		var head := kit.find_child(ROAD_HEAD, true, false) as MeshInstance3D
		if stand == null or stand.mesh == null or head == null or head.mesh == null:
			kit.free()
			push_warning("Spatial Toolkit: missing tripod stand or lamp head")
			return null
		road_base = _kit_transform(stand).origin
	for node: MeshInstance3D in kit.find_children("*", "MeshInstance3D", true, false):
		if node.mesh == null or not str(node.name).begins_with(part) or node.name == ROAD_PART + "_cable":
			continue
		var transform := _kit_transform(node)
		if node.name == ROAD_HEAD:
			transform.basis = Basis(Vector3.RIGHT, deg_to_rad(road_head_tilt_degrees))
			road_lens = transform * ROAD_LENS_OFFSET
		var box := transform * node.mesh.get_aabb()
		bounds = box if parts.is_empty() else bounds.merge(box)
		parts.append({"mesh": node.mesh, "transform": transform})
	kit.free()
	if parts.is_empty():
		push_warning("Spatial Toolkit: missing lamp module " + part)
		return null
	var anchor := bounds.get_center()
	if wall:
		anchor.y = 0.0
		anchor.z = bounds.position.z
	else:
		anchor = Vector3(road_base.x, bounds.position.y, road_base.z)
		_road_lens = road_lens - anchor
	var surfaces := {}
	for entry in parts:
		var mesh: Mesh = entry["mesh"]
		var pose: Transform3D = entry["transform"]
		pose.origin -= anchor
		for surface in mesh.get_surface_count():
			var original := mesh.surface_get_material(surface)
			if not surfaces.has(original):
				var builder := SurfaceTool.new()
				builder.begin(Mesh.PRIMITIVE_TRIANGLES)
				builder.set_material(_lamp_material(original, wall))
				surfaces[original] = builder
			var builder: SurfaceTool = surfaces[original]
			builder.append_from(mesh, surface, pose)
	var output := ArrayMesh.new()
	for builder: SurfaceTool in surfaces.values():
		builder.commit(output)
	return output

func _kit_transform(node: Node3D) -> Transform3D:
	var pose := node.transform
	var parent := node.get_parent() as Node3D
	while parent != null:
		pose = parent.transform * pose
		parent = parent.get_parent() as Node3D
	return pose

func _lamp_material(original: Material, wall: bool) -> Material:
	if not original is StandardMaterial3D:
		return original
	var material := original.duplicate() as StandardMaterial3D
	if _night and not wall and original.resource_name == ROAD_LENS_MATERIAL:
		# The kit has a transparent lens and a separate emissive reflector.
		# A lit diffuser keeps the beam visibly attached to its lens.
		material.transparency = BaseMaterial3D.TRANSPARENCY_DISABLED
		material.emission_enabled = true
		material.emission = road_light_color
		material.emission_energy_multiplier = road_lens_emission
		return material
	var mask := material.emission_texture
	if mask == null and wall:
		mask = wall_emissive
	material.emission_enabled = _night and mask != null
	if material.emission_enabled:
		material.emission_texture = mask
		material.emission_operator = BaseMaterial3D.EMISSION_OP_MULTIPLY
		material.emission = wall_light_color if wall else road_light_color
		material.emission_energy_multiplier = wall_emission if wall else road_reflector_emission
	return material

func _pose(entry: Dictionary, wall: bool) -> Transform3D:
	var direction: Vector3 = entry["normal"]
	var basis := Basis(Vector3.UP.cross(direction).normalized(), Vector3.UP, direction)
	var origin: Vector3 = entry["position"] * _scale
	origin.y += _ground_y
	var model_scale := wall_model_scale if wall else road_model_scale
	return Transform3D(basis.scaled_local(Vector3.ONE * _scale * model_scale), origin)

func _batch(mesh: Mesh, entries: Array[Dictionary], wall: bool) -> void:
	var prefix := "Wall" if wall else "Road"
	var chunks := {}
	for entry in entries:
		var point: Vector3 = entry["position"]
		var cell := Vector2i(floori(point.x / CHUNK_SIZE_M), floori(point.z / CHUNK_SIZE_M))
		chunks.get_or_add(cell, []).append(entry)
	var count := 0
	for cell: Vector2i in chunks:
		var members: Array = chunks[cell]
		var buffer := PackedFloat32Array()
		buffer.resize(members.size() * 12)
		var ids := PackedStringArray()
		for index in members.size():
			var entry: Dictionary = members[index]
			var pose := _pose(entry, wall)
			ids.append(entry["source_id"])
			for row in 3:
				var offset := index * 12 + 4 * row
				buffer[offset] = pose.basis.x[row]
				buffer[offset + 1] = pose.basis.y[row]
				buffer[offset + 2] = pose.basis.z[row]
				buffer[offset + 3] = pose.origin[row]
		var multimesh := MultiMesh.new()
		multimesh.transform_format = MultiMesh.TRANSFORM_3D
		multimesh.mesh = mesh
		multimesh.instance_count = members.size()
		multimesh.buffer = buffer
		var batch := MultiMeshInstance3D.new()
		batch.name = "%sLamps_%d_%d" % [prefix, cell.x, cell.y]
		batch.multimesh = multimesh
		batch.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		batch.visibility_range_end = model_visibility_m * _scale
		batch.visibility_range_end_margin = 8.0 * _scale
		batch.set_meta("source_ids", ids)
		add_child(batch)
		count += 1
		if count % 16 == 0:
			await get_tree().process_frame
			if is_queued_for_deletion() or not is_inside_tree():
				return

func _create_emitters() -> void:
	var pool := Node3D.new()
	pool.name = "NearbyLampEmitters"
	add_child(pool)
	for index in mini(road_light_limit, _roads.size()):
		var lamp := SpotLight3D.new()
		lamp.spot_range = road_light_range_m * _scale
		lamp.spot_angle = road_light_angle_degrees
		lamp.light_color = road_light_color
		lamp.light_energy = road_light_energy
		_prepare_light(pool, lamp)
		_road_emitters.append(lamp)
	for index in mini(wall_light_limit, _walls.size()):
		var lamp := OmniLight3D.new()
		lamp.omni_range = wall_light_range_m * _scale
		lamp.light_color = wall_light_color
		lamp.light_energy = wall_light_energy
		_prepare_light(pool, lamp)
		_wall_emitters.append(lamp)

func _prepare_light(pool: Node3D, light: Light3D) -> void:
	light.shadow_enabled = false
	light.distance_fade_enabled = true
	var fade := minf(light_activation_m, light_fade_m)
	light.distance_fade_begin = (light_activation_m - fade) * _scale
	light.distance_fade_length = fade * _scale
	light.hide()
	pool.add_child(light)

func _process(delta: float) -> void:
	if Engine.is_editor_hint():
		return
	_refresh -= delta
	if _refresh <= 0.0 and is_instance_valid(_player):
		_refresh = LIGHT_REFRESH_SECONDS
		_update_emitters()

func _update_emitters() -> void:
	var eye := to_local(_player.global_position)
	eye.y -= _ground_y
	eye /= _scale
	_stream_lights(_roads, _road_emitters, eye, false)
	_stream_lights(_walls, _wall_emitters, eye, true)

func _stream_lights(entries: Array[Dictionary], lights: Array[Light3D], eye: Vector3, wall: bool) -> void:
	if lights.is_empty():
		return
	var near: Array[Dictionary] = []
	for entry in entries:
		var distance := eye.distance_squared_to(entry["position"])
		if distance <= light_activation_m * light_activation_m:
			near.append({"entry": entry, "distance": distance})
	near.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a["distance"] < b["distance"])
	for index in lights.size():
		var light := lights[index]
		if index >= near.size():
			light.hide()
			continue
		var entry: Dictionary = near[index]["entry"]
		var pose := _pose(entry, wall)
		light.position = pose * (WALL_LENS if wall else _road_lens)
		if not wall:
			var head := Basis(Vector3.RIGHT, deg_to_rad(road_head_tilt_degrees))
			var aim := light.position + pose.basis * head.z
			light.look_at(to_global(aim))
		light.show()
