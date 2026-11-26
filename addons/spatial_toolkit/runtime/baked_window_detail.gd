@tool
extends Node3D
## Displays bounded 3D frames using the positions saved by a world bake.

const Localization := preload("res://addons/spatial_toolkit/ui/editor_localization.gd")
const Frames := preload("res://addons/spatial_toolkit/runtime/facade_window_preview.gd")
const DATA_FILE := "window_detail.bin"
const MASK_WIDTH := 1024
const FRAME_CAPACITY := 512
const DETAIL_RADIUS_M := 96.0
const RETREAT_RADIUS_M := 108.0
const MAX_RADIUS_M := 640.0
const GRID_SIZE_M := 128.0
const REFRESH_SECONDS := 0.1

@export_storage var data_path := ""
@export_storage var window_styles: Array[SpatialWindowStyle] = []

@export_group("3D Frame Distance")
## Source metres. The frame appears inside this distance on approach.
@export_range(0.0, MAX_RADIUS_M, 1.0, "suffix:m") var engage_distance_m := DETAIL_RADIUS_M
## Source metres. The active frame remains visible up to this distance on retreat.
@export_range(0.0, MAX_RADIUS_M, 1.0, "suffix:m") var retreat_distance_m := RETREAT_RADIUS_M

var _map: Node3D
var _scale := 1.0
var _transforms: Array[Transform3D] = []
var _style_ids := PackedInt32Array()
var _grid: Dictionary = {}
var _materials: Array[ShaderMaterial] = []
var _pools: Dictionary[int, MultiMeshInstance3D] = {}
var _mesh_fits: Dictionary[int, Transform3D] = {}
var _mask: Image
var _texture: ImageTexture
var _active: Dictionary = {}
var _elapsed := 0.0

func _validate_property(property: Dictionary) -> void:
	Localization.localize_inspector_group(property)

func _ready() -> void:
	set_process(false)
	if Engine.is_editor_hint():
		return
	_map = get_parent() as Node3D
	if _map == null:
		return
	_scale = float(_map.get_meta("world_scale", 1.0))
	if not is_finite(_scale) or _scale <= 0.0 or not _read_data():
		return
	_collect_materials()
	if _materials.is_empty():
		return
	_mask = Image.create(MASK_WIDTH, ceili(float(_transforms.size()) / MASK_WIDTH), false, Image.FORMAT_R8)
	_mask.fill(Color.BLACK)
	_texture = ImageTexture.create_from_image(_mask)
	_create_pools()
	# The bake makes these materials local to each instantiated scene.
	for material in _materials:
		material.set_shader_parameter("baked_window_visibility", _texture)
		material.set_shader_parameter("baked_window_detail_enabled", true)
	set_process(true)
	_update_visible_windows()

func _read_data() -> bool:
	var directory := _map.scene_file_path.get_base_dir()
	var path := data_path
	if not path.is_empty() and not path.is_absolute_path():
		path = directory.path_join(path)
	var sibling := directory.path_join(DATA_FILE) if not directory.is_empty() else ""
	if (path.is_empty() or path.get_file() == DATA_FILE) and FileAccess.file_exists(sibling):
		path = sibling
	if path.is_empty() or not FileAccess.file_exists(path):
		return false
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return false
	var data: Variant = file.get_var(false)
	file.close()
	if not data is Dictionary or data.get("version") not in [1, 2] or not data.get("transforms") is Array:
		push_warning("Spatial Toolkit: invalid baked window detail data at " + path)
		return false
	var poses: Array = data["transforms"]
	if data["version"] == 2:
		var ids: Variant = data.get("style_ids")
		if not ids is PackedInt32Array or ids.size() != poses.size():
			push_warning("Spatial Toolkit: invalid baked window style mapping at " + path)
			return false
		_style_ids = ids
		var checked := {0: true}
		for style_id in _style_ids:
			if checked.has(style_id):
				continue
			if style_id < 0 or style_id >= window_styles.size() or window_styles[style_id] == null:
				push_warning("Spatial Toolkit: missing baked window style %d at %s" % [style_id, path])
				return false
			var error := window_styles[style_id].validation_error()
			if not error.is_empty():
				push_warning("Spatial Toolkit: invalid baked window style %d at %s: %s" % [style_id, path, error])
				return false
			checked[style_id] = true
	else:
		_style_ids.resize(poses.size())
		_style_ids.fill(0)
	for value: Variant in poses:
		if not value is Transform3D or not value.is_finite() or value.basis.determinant() <= 0.0:
			push_warning("Spatial Toolkit: invalid baked window frame at " + path)
			_transforms.clear()
			_grid.clear()
			return false
		var id := _transforms.size()
		_transforms.append(value)
		var cell := _cell(value.origin)
		if not _grid.has(cell):
			_grid[cell] = []
		_grid[cell].append(id)
	return not _transforms.is_empty()

func _create_pools() -> void:
	var counts: Dictionary[int, int] = {}
	for style_id in _style_ids:
		counts[style_id] = counts.get(style_id, 0) + 1
	for style_id in counts:
		var style: SpatialWindowStyle = window_styles[style_id] if style_id > 0 else null
		var pool := MultiMeshInstance3D.new()
		pool.name = "WindowFrames" if style_id == 0 else "WindowFrames%d" % style_id
		pool.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		pool.multimesh = MultiMesh.new()
		pool.multimesh.transform_format = MultiMesh.TRANSFORM_3D
		var fit := Transform3D.IDENTITY
		if style != null and style.mesh != null:
			pool.multimesh.mesh = style.mesh
			var bounds := style.mesh.get_aabb()
			var depth := bounds.size.z if not is_zero_approx(bounds.size.z) else 1.0
			var basis := Basis.from_scale(Vector3(1.0 / bounds.size.x, 1.0 / bounds.size.y, 1.0 / depth))
			fit = Transform3D(basis, -(basis * bounds.get_center()))
		else:
			pool.multimesh.mesh = Frames.simple_industrial_frame()
			if style != null and style.material == null:
				var frame_material := pool.multimesh.mesh.surface_get_material(0) as StandardMaterial3D
				frame_material.albedo_color = style.frame_color
		if style != null:
			pool.material_override = style.material
		pool.multimesh.instance_count = mini(FRAME_CAPACITY, counts[style_id])
		pool.multimesh.visible_instance_count = 0
		_pools[style_id] = pool
		_mesh_fits[style_id] = fit
		add_child(pool)

func _collect_materials() -> void:
	var chunks := _map.get_node_or_null("BakedChunks")
	if chunks == null:
		return
	var seen := {}
	for node: MeshInstance3D in chunks.find_children("*", "MeshInstance3D", true, false):
		if node.mesh == null:
			continue
		for surface in node.mesh.get_surface_count():
			var material := node.get_active_material(surface) as ShaderMaterial
			if material == null or seen.has(material):
				continue
			var first_id: Variant = material.get_shader_parameter("baked_window_base")
			if not (first_id is int or first_id is float) or int(first_id) < 0:
				continue
			seen[material] = true
			_materials.append(material)

func _process(delta: float) -> void:
	if Engine.is_editor_hint():
		return
	_elapsed -= delta
	if _elapsed <= 0.0:
		_elapsed = REFRESH_SECONDS
		_update_visible_windows()

func _update_visible_windows() -> void:
	if _pools.is_empty() or _mask == null:
		return
	var camera := get_viewport().get_camera_3d()
	var candidates: Array[Vector2] = []
	if camera != null and is_visible_in_tree():
		var eye := _map.to_local(camera.global_position)
		var home := _cell(eye)
		var engage := _distance(engage_distance_m, DETAIL_RADIUS_M)
		var retreat := maxf(engage, _distance(retreat_distance_m, RETREAT_RADIUS_M))
		var reach := ceili(retreat / GRID_SIZE_M)
		for x in range(-reach, reach + 1):
			for y in range(-reach, reach + 1):
				for z in range(-reach, reach + 1):
					for id: int in _grid.get(home + Vector3i(x, y, z), []):
						var pose := _transforms[id]
						var offset := eye - pose.origin
						var radius := (retreat if _active.has(id) else engage) * _scale
						var distance := offset.length_squared()
						if distance <= radius * radius and offset.dot(pose.basis.z) > 0.0:
							candidates.append(Vector2(distance, id))
	candidates.sort_custom(func(a: Vector2, b: Vector2) -> bool:
		return a.y < b.y if a.x == b.x else a.x < b.x)
	var next := {}
	var counts: Dictionary[int, int] = {}
	var count := mini(candidates.size(), FRAME_CAPACITY)
	for index in count:
		var id := int(candidates[index].y)
		var style_id := _style_ids[id]
		var slot: int = counts.get(style_id, 0)
		next[id] = true
		_pools[style_id].multimesh.set_instance_transform(slot, _transforms[id] * _mesh_fits[style_id])
		counts[style_id] = slot + 1
	for style_id in _pools:
		_pools[style_id].multimesh.visible_instance_count = counts.get(style_id, 0)
	var changed := false
	for id: int in _active:
		if not next.has(id):
			_set_mask(id, 0.0)
			changed = true
	for id: int in next:
		if not _active.has(id):
			_set_mask(id, 1.0)
			changed = true
	_active = next
	if changed:
		_texture.update(_mask)

func _set_mask(id: int, value: float) -> void:
	@warning_ignore("integer_division")
	var row := id / MASK_WIDTH
	_mask.set_pixel(id % MASK_WIDTH, row, Color(value, value, value))

func _cell(point: Vector3) -> Vector3i:
	return Vector3i((point / (GRID_SIZE_M * _scale)).floor())

func _distance(value: float, fallback: float) -> float:
	return clampf(value, 0.0, MAX_RADIUS_M) if is_finite(value) else fallback

func _exit_tree() -> void:
	if Engine.is_editor_hint():
		return
	for material in _materials:
		material.set_shader_parameter("baked_window_detail_enabled", false)
		material.set_shader_parameter("baked_window_visibility", null)
