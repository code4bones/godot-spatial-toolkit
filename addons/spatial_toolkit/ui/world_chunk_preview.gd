@tool
extends Control
## Read-only rendering of the selected square's saved geometry.

const FLAT_SURFACE := preload("res://addons/spatial_toolkit/materials/flat_map_surface.gdshader")
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

var _path := ""
var _refresh_queued := false
var _renders_remaining := 0
var _dirty := true
var _has_meshes := false
var _bounds := AABB()
var _materials: Dictionary[StringName, Material] = {}
var _canvas: TextureRect
var _viewport: SubViewport
var _geometry: Node3D
var _camera: Camera3D
var _render_timeout: Timer
var _status: Label

func _ready() -> void:
	name = "ChunkPreview"
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_canvas = TextureRect.new()
	_canvas.name = "ChunkPreviewCanvas"
	_canvas.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_canvas.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_canvas.stretch_mode = TextureRect.STRETCH_SCALE
	add_child(_canvas)
	_canvas.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_viewport = SubViewport.new()
	_viewport.name = "ChunkPreviewViewport"
	_viewport.own_world_3d = true
	_viewport.gui_disable_input = true
	_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	add_child(_viewport)
	_canvas.texture = _viewport.get_texture()
	_geometry = Node3D.new()
	_geometry.name = "ChunkPreviewGeometry"
	_viewport.add_child(_geometry)
	_camera = Camera3D.new()
	_camera.name = "ChunkPreviewCamera"
	_camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	_camera.keep_aspect = Camera3D.KEEP_HEIGHT
	_camera.current = true
	_viewport.add_child(_camera)
	_add_lighting()
	_render_timeout = Timer.new()
	_render_timeout.one_shot = true
	_render_timeout.timeout.connect(_stop_rendering)
	add_child(_render_timeout)
	_status = Label.new()
	_status.name = "ChunkPreviewStatus"
	_status.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_status.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	add_child(_status)
	_status.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_canvas.resized.connect(_frame_preview)
	visibility_changed.connect(_on_visibility_changed)
	_queue_refresh()

func set_scene_path(path: String) -> void:
	if path == _path:
		return
	_path = path
	_dirty = true
	if is_instance_valid(_viewport):
		for child: Node in _geometry.get_children():
			child.free()
		_has_meshes = false
		_show_status(atr("Select a square to preview.") if path.is_empty() else atr("Loading square preview…"))
	_queue_refresh()

func _on_visibility_changed() -> void:
	if not is_visible_in_tree():
		_stop_rendering()
	elif _dirty:
		_queue_refresh()
	else:
		_frame_preview()

func _queue_refresh() -> void:
	if not _refresh_queued and is_node_ready() and is_visible_in_tree():
		_refresh_queued = true
		_refresh.call_deferred()

func _refresh() -> void:
	_refresh_queued = false
	if not is_visible_in_tree():
		return
	_dirty = false
	if _path.is_empty():
		_show_status(atr("Select a square to preview."))
		return
	var scene: PackedScene
	if _path.begins_with("res://") and ResourceLoader.exists(_path, "PackedScene"):
		scene = ResourceLoader.load(_path, "PackedScene", ResourceLoader.CACHE_MODE_IGNORE) as PackedScene
	if scene != null:
		_read_geometry(scene.get_state())
	if not _has_meshes:
		_show_status(atr("Square preview unavailable."))
		return
	_status.hide()
	_canvas.show()
	_frame_preview.call_deferred()

func _show_status(message: String) -> void:
	_canvas.hide()
	_stop_rendering()
	_status.text = message
	_status.show()

func _add_lighting() -> void:
	var world := WorldEnvironment.new()
	var environment := Environment.new()
	environment.background_mode = Environment.BG_COLOR
	environment.background_color = Color("20272e")
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.ambient_light_color = Color("e6efff")
	environment.ambient_light_energy = 0.62
	world.environment = environment
	_viewport.add_child(world)
	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-60.0, -30.0, 0.0)
	light.light_energy = 0.85
	_viewport.add_child(light)

func _read_geometry(state: SceneState) -> void:
	# Read serialized properties directly so no nodes or scripts from the square are instantiated.
	var transforms: Dictionary[NodePath, Transform3D] = {^".": Transform3D.IDENTITY}
	var square := Rect2()
	for index in state.get_node_count():
		var path := state.get_node_path(index)
		if index == 0:
			var root_properties := _node_properties(state, index)
			var saved_bounds: Variant = root_properties.get(&"world_chunk_bounds", Rect2())
			if saved_bounds is Rect2:
				square = saved_bounds
			continue
		var parent_path := state.get_node_path(index, true)
		if not transforms.has(parent_path):
			continue
		var layer := _layer_at(path)
		if layer == &"" and path != ^"./Generated":
			continue
		var properties := _node_properties(state, index)
		if not bool(properties.get(&"visible", true)):
			continue
		var local_transform: Transform3D = properties.get(&"transform", Transform3D.IDENTITY)
		var transform := transforms[parent_path] * local_transform
		transforms[path] = transform
		var mesh := properties.get(&"mesh") as Mesh
		if mesh != null and PALETTE.has(layer):
			_add_mesh(mesh, transform, layer)
	if _has_meshes and square.has_area() and square.is_finite():
		_bounds = _bounds.merge(AABB(Vector3(square.position.x, 0.0, square.position.y),
			Vector3(square.size.x, 0.0, square.size.y)))

func _node_properties(state: SceneState, index: int) -> Dictionary:
	var values := {}
	for property_index in state.get_node_property_count(index):
		var key := state.get_node_property_name(index, property_index)
		if key in [&"transform", &"visible", &"mesh", &"world_chunk_bounds"]:
			values[key] = state.get_node_property_value(index, property_index)
	return values

func _layer_at(path: NodePath) -> StringName:
	if path.get_name_count() >= 3 and path.get_name(1) == &"Generated":
		var layer := path.get_name(2)
		return layer if PALETTE.has(layer) else &""
	return &"FlatGround" if path == ^"./FlatGround" else &""

func _add_mesh(mesh: Mesh, transform: Transform3D, layer: StringName) -> void:
	if mesh.get_surface_count() == 0:
		return
	var bounds: AABB = transform * mesh.get_aabb()
	if not bounds.is_finite():
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
	_geometry.add_child(preview)
	_bounds = _bounds.merge(bounds) if _has_meshes else bounds
	_has_meshes = true

func _frame_preview() -> void:
	if not _has_meshes or not _canvas.is_visible_in_tree() or minf(_canvas.size.x, _canvas.size.y) < 2.0:
		return
	var scale := minf(0.5, 512.0 / maxf(_canvas.size.x, _canvas.size.y))
	var dimensions := Vector2i(_canvas.size * scale).max(Vector2i(2, 2))
	if _viewport.size != dimensions:
		_viewport.size = dimensions
	var direction := Vector3(1.0, 1.45, 1.1).normalized()
	var distance := maxf(_bounds.size.length(), 1.0) * 2.0
	var center := _bounds.get_center()
	_camera.look_at_from_position(center + direction * distance, center)
	_camera.far = distance * 2.0
	var aspect := float(dimensions.x) / float(dimensions.y)
	var extents := _bounds.size * 0.5
	var half_width := _camera.basis.x.abs().dot(extents)
	var half_height := _camera.basis.y.abs().dot(extents)
	_camera.size = maxf(maxf(half_height, half_width / aspect) * 2.25, 1.0)
	if DisplayServer.get_name() == "headless":
		_viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
		return
	# The Compatibility renderer can still use the old target size on the first draw.
	_renders_remaining = 2
	if not RenderingServer.frame_post_draw.is_connected(_on_frame_drawn):
		RenderingServer.frame_post_draw.connect(_on_frame_drawn)
	_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	# An idle editor may not draw both frames before it stops processing graphics.
	_render_timeout.start(0.75)

func _on_frame_drawn() -> void:
	_renders_remaining -= 1
	if _renders_remaining == 0:
		_stop_rendering()

func _stop_rendering() -> void:
	if RenderingServer.frame_post_draw.is_connected(_on_frame_drawn):
		RenderingServer.frame_post_draw.disconnect(_on_frame_drawn)
	if is_instance_valid(_viewport):
		_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	if is_instance_valid(_render_timeout):
		_render_timeout.stop()
	_renders_remaining = 0

func _exit_tree() -> void:
	_stop_rendering()
