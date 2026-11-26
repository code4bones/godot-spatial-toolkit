@tool
extends SubViewport
## Renders saved square geometry with a shared palette for dock previews and thumbnails.

const FLAT_SURFACE := preload("res://addons/spatial_toolkit/materials/flat_map_surface.gdshader")
const GEOMETRY_BUDGET_USEC := 3500
const FLAT_ORDER: Array[StringName] = [&"FlatGround", &"Landuse", &"Water", &"Roads", &"Paths", &"PlannedRoads"]
const PALETTE := {
	&"FlatGround": Color("2e3a3d"),
	&"Landuse": Color("52644c"),
	&"Water": Color("457c9f"),
	&"Roads": Color("9a9c98"),
	&"Paths": Color("7e8f95"),
	&"PlannedRoads": Color("b08d5d"),
	&"Buildings": Color("d2c4aa"),
}

var geometry: Node3D
var bounds := AABB()
var _camera: Camera3D
var _materials: Dictionary[StringName, Material] = {}
var _state: SceneState
var _node_index := 0
var _transforms := {}
var _square := Rect2()

func _ready() -> void:
	own_world_3d = true
	gui_disable_input = true
	render_target_update_mode = UPDATE_DISABLED
	geometry = Node3D.new()
	geometry.name = "ChunkPreviewGeometry"
	add_child(geometry)
	_camera = Camera3D.new()
	_camera.name = "ChunkPreviewCamera"
	_camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	_camera.keep_aspect = Camera3D.KEEP_HEIGHT
	_camera.current = true
	add_child(_camera)
	var world := WorldEnvironment.new()
	var environment := Environment.new()
	environment.background_mode = Environment.BG_COLOR
	environment.background_color = Color("20272e")
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.ambient_light_color = Color("e6efff")
	environment.ambient_light_energy = 0.62
	world.environment = environment
	add_child(world)
	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-60.0, -30.0, 0.0)
	light.light_energy = 0.85
	add_child(light)

func begin_geometry(state: SceneState) -> void:
	_state = state
	_node_index = 0
	_square = Rect2()
	_transforms = {^".": Transform3D.IDENTITY}

func clear_geometry() -> bool:
	_state = null
	_transforms = {}
	var deadline := Time.get_ticks_usec() + GEOMETRY_BUDGET_USEC
	while geometry.get_child_count() > 0:
		var mesh := geometry.get_child(-1)
		geometry.remove_child(mesh)
		mesh.queue_free()
		if Time.get_ticks_usec() >= deadline:
			return geometry.get_child_count() == 0
	return true

func is_building() -> bool:
	return _state != null

func has_geometry() -> bool:
	return geometry.get_child_count() > 0

func step_geometry() -> bool:
	var deadline := Time.get_ticks_usec() + GEOMETRY_BUDGET_USEC
	var count := _state.get_node_count()
	while _node_index < count:
		_read_node(_node_index)
		_node_index += 1
		if Time.get_ticks_usec() >= deadline:
			return false
	_state = null
	_transforms = {}
	if has_geometry() and _square.has_area() and _square.is_finite():
		bounds = bounds.merge(AABB(Vector3(_square.position.x, 0.0, _square.position.y),
			Vector3(_square.size.x, 0.0, _square.size.y)))
	return true

func frame_geometry(dimensions: Vector2i) -> void:
	size = dimensions
	var direction := Vector3(1.0, 1.45, 1.1).normalized()
	var distance := maxf(bounds.size.length(), 1.0) * 2.0
	var center := bounds.get_center()
	_camera.look_at_from_position(center + direction * distance, center)
	_camera.far = distance * 2.0
	var aspect := float(dimensions.x) / float(dimensions.y)
	var extents := bounds.size * 0.5
	var half_width := _camera.basis.x.abs().dot(extents)
	var half_height := _camera.basis.y.abs().dot(extents)
	_camera.size = maxf(maxf(half_height, half_width / aspect) * 2.25, 1.0)

func _read_node(index: int) -> void:
	# Inspect serialized properties without instantiating any nodes or scripts from the square.
	if index == 0:
		var saved_bounds: Variant = _node_properties(index).get(&"world_chunk_bounds", Rect2())
		if saved_bounds is Rect2:
			_square = saved_bounds
		return
	var parent_path := _state.get_node_path(index, true)
	if not _transforms.has(parent_path):
		return
	var path := _state.get_node_path(index)
	var layer := _layer_at(path)
	if layer == &"" and path != ^"./Generated":
		return
	var properties := _node_properties(index)
	if not bool(properties.get(&"visible", true)):
		return
	var local_transform: Transform3D = properties.get(&"transform", Transform3D.IDENTITY)
	var transform: Transform3D = _transforms[parent_path] * local_transform
	_transforms[path] = transform
	var mesh := properties.get(&"mesh") as Mesh
	if mesh != null and PALETTE.has(layer):
		_add_mesh(mesh, transform, layer)

func _node_properties(index: int) -> Dictionary:
	var values := {}
	for property_index in _state.get_node_property_count(index):
		var key := _state.get_node_property_name(index, property_index)
		if key in [&"transform", &"visible", &"mesh", &"world_chunk_bounds"]:
			values[key] = _state.get_node_property_value(index, property_index)
	return values

func _layer_at(path: NodePath) -> StringName:
	if path.get_name_count() >= 3 and path.get_name(1) == &"Generated":
		var layer := path.get_name(2)
		return layer if PALETTE.has(layer) else &""
	return &"FlatGround" if path == ^"./FlatGround" else &""

func _add_mesh(mesh: Mesh, transform: Transform3D, layer: StringName) -> void:
	if mesh.get_surface_count() == 0:
		return
	var mesh_bounds: AABB = transform * mesh.get_aabb()
	if not mesh_bounds.is_finite():
		return
	if not _materials.has(layer):
		if layer == &"Buildings":
			var material := StandardMaterial3D.new()
			material.albedo_color = PALETTE[layer]
			material.roughness = 0.9
			material.cull_mode = BaseMaterial3D.CULL_DISABLED
			_materials[layer] = material
		else:
			var material := ShaderMaterial.new()
			material.shader = FLAT_SURFACE
			material.set_shader_parameter(&"surface_color", PALETTE[layer])
			material.render_priority = FLAT_ORDER.find(layer)
			_materials[layer] = material
	var preview := MeshInstance3D.new()
	preview.mesh = mesh
	preview.transform = transform
	preview.material_override = _materials[layer]
	preview.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	bounds = bounds.merge(mesh_bounds) if has_geometry() else mesh_bounds
	geometry.add_child(preview)
