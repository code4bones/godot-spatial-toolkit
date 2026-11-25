extends Node3D
## Instanced roadside floodlights and wall sconces with a local lighting budget.

const RoadLayout := preload("res://addons/spatial_toolkit/runtime/road_lamp_layout.gd")
const WallLayout := preload("res://addons/spatial_toolkit/runtime/wall_lamp_layout.gd")
const NightStyle := preload("res://addons/spatial_toolkit/runtime/night_city_style.gd")
const ROAD_PART := "flood_lights_standing_single"
const ROAD_HEAD := ROAD_PART + "_light"
const ROAD_HEAD_BASIS := Basis(Vector3.RIGHT, deg_to_rad(65.0))
# A point just beyond the glass in the source head's local space.
const ROAD_LENS_OFFSET := Vector3(0.0, 0.0, 0.09)
const ROAD_LENS_MATERIAL := "flood_lights_glass"
const WALL_PART := "industrial_caged_sconce_a"
const WALL_LENS := Vector3(0.0, 0.177, 0.212)
const ROAD_COLOR := Color("e7f0ff")
const WALL_COLOR := Color("ffc18c")
const CHUNK_SIZE_M := 48.0
const MESH_RANGE_M := 115.0
const LIGHT_RANGE_M := 55.0
const LIGHT_REFRESH_SECONDS := 0.35
const ROAD_LIGHT_LIMIT := 8
const WALL_LIGHT_LIMIT := 6

@export var road_lamp_library: PackedScene
@export var wall_lamp_library: PackedScene
@export var wall_emissive: Texture2D

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

func _ready() -> void:
	set_process(false)
	_build.call_deferred()

func _build() -> void:
	if is_queued_for_deletion():
		return
	var map := get_parent().get_parent() as Node3D
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
		_roads = RoadLayout.build(map, model["features"], _scale)
		await _batch(road_mesh, _roads, "Road")
	if is_queued_for_deletion() or not is_inside_tree():
		return
	if wall_mesh != null:
		_walls = WallLayout.build(map, model["features"], _scale)
		await _batch(wall_mesh, _walls, "Wall")
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
			transform.basis = ROAD_HEAD_BASIS
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
		material.emission = ROAD_COLOR
		material.emission_energy_multiplier = 1.35
		return material
	var mask := material.emission_texture
	if mask == null and wall:
		mask = wall_emissive
	material.emission_enabled = _night and mask != null
	if material.emission_enabled:
		material.emission_texture = mask
		material.emission_operator = BaseMaterial3D.EMISSION_OP_MULTIPLY
		material.emission = WALL_COLOR if wall else ROAD_COLOR
		material.emission_energy_multiplier = 2.2 if wall else 3.2
	return material

func _pose(entry: Dictionary) -> Transform3D:
	var direction: Vector3 = entry["normal"]
	var basis := Basis(Vector3.UP.cross(direction).normalized(), Vector3.UP, direction)
	var origin: Vector3 = entry["position"] * _scale
	origin.y += _ground_y
	return Transform3D(basis.scaled_local(Vector3.ONE * _scale), origin)

func _batch(mesh: Mesh, entries: Array[Dictionary], prefix: String) -> void:
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
			var pose := _pose(entry)
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
		batch.visibility_range_end = MESH_RANGE_M * _scale
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
	for index in mini(ROAD_LIGHT_LIMIT, _roads.size()):
		var lamp := SpotLight3D.new()
		lamp.spot_range = 7.5 * _scale
		lamp.spot_angle = 42.0
		lamp.light_color = ROAD_COLOR
		lamp.light_energy = 4.1
		_prepare_light(pool, lamp)
		_road_emitters.append(lamp)
	for index in mini(WALL_LIGHT_LIMIT, _walls.size()):
		var lamp := OmniLight3D.new()
		lamp.omni_range = 4.0 * _scale
		lamp.light_color = WALL_COLOR
		lamp.light_energy = 1.4
		_prepare_light(pool, lamp)
		_wall_emitters.append(lamp)

func _prepare_light(pool: Node3D, light: Light3D) -> void:
	light.shadow_enabled = false
	light.distance_fade_enabled = true
	light.distance_fade_begin = 43.0 * _scale
	light.distance_fade_length = 12.0 * _scale
	light.hide()
	pool.add_child(light)

func _process(delta: float) -> void:
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
		if distance <= LIGHT_RANGE_M * LIGHT_RANGE_M:
			near.append({"entry": entry, "distance": distance})
	near.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a["distance"] < b["distance"])
	for index in lights.size():
		var light := lights[index]
		if index >= near.size():
			light.hide()
			continue
		var entry: Dictionary = near[index]["entry"]
		var pose := _pose(entry)
		light.position = pose * (WALL_LENS if wall else _road_lens)
		if not wall:
			var aim := light.position + pose.basis * ROAD_HEAD_BASIS.z
			light.look_at(to_global(aim))
		light.show()
