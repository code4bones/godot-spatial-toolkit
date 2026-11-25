extends Node
## Optional StyleLayer treatment for textured ground, land-use patches and relief.

signal ground_style_ready

const FLAT_SHADER := preload("res://addons/spatial_toolkit/materials/textured_road.gdshader")
const TERRAIN_SHADER := preload("res://addons/spatial_toolkit/materials/terrain_surface.gdshader")
const AVERAGE_SIZE := 16

@export_range(0.0, 1.0, 0.01) var texture_blend := 0.0
@export_range(0.0, 1.0, 0.01) var tone_variation := 0.0

var _map: Node3D
var _relief: Node
var _world_scale := 1.0
var _assignments: Dictionary = {}
var _previews: Dictionary = {}
var _texture_averages: Dictionary = {}

func _ready() -> void:
	var layer := get_parent()
	_map = layer.get_parent() as Node3D if layer != null else null
	if _map != null:
		_world_scale = maxf(float(_map.get_meta("world_scale", 1.0)), 0.001)
		_relief = layer.get_node_or_null("LandscapeRelief")
		if _relief != null:
			_relief.child_entered_tree.connect(_on_relief_added)
		set_ground_style(texture_blend, tone_variation)
	ground_style_ready.emit()

func _exit_tree() -> void:
	if is_instance_valid(_relief):
		_relief.child_entered_tree.disconnect(_on_relief_added)
	_relief = null
	_map = null
	_restore_materials()
	request_ready()

func set_ground_style(blend: float, variation: float) -> int:
	texture_blend = clampf(blend, 0.0, 1.0)
	tone_variation = clampf(variation, 0.0, 1.0)
	if texture_blend == 0.0 and tone_variation == 0.0:
		return _restore_materials()
	if not is_instance_valid(_map):
		return 0
	for preview: ShaderMaterial in _previews.values():
		_set_strengths(preview)
	var changed := int(_apply_material(_map.get_node_or_null("FlatGround") as MeshInstance3D))
	var landuse := _map.get_node_or_null("Generated/Landuse")
	if landuse != null:
		for surface in landuse.get_children():
			changed += int(_apply_material(surface as MeshInstance3D))
	changed += int(_apply_material(get_parent().get_node_or_null("GrassHill/HillMesh") as MeshInstance3D))
	if is_instance_valid(_relief):
		for hill in _relief.get_children():
			changed += int(_apply_material(hill.get_node_or_null("HillMesh") as MeshInstance3D))
	return changed

func _apply_material(target: MeshInstance3D) -> bool:
	if target == null:
		return false
	var original := target.material_override as ShaderMaterial
	if original == null or (original.shader != FLAT_SHADER and original.shader != TERRAIN_SHADER):
		return false
	var assignment: Dictionary = _assignments.get(target, {})
	if assignment.get("preview") == original:
		return true
	var preview := _previews.get(original) as ShaderMaterial
	if preview == null:
		preview = original.duplicate() as ShaderMaterial
		var albedo := original.get_shader_parameter(&"road_albedo") as Texture2D
		var roughness := original.get_shader_parameter(&"road_roughness") as Texture2D
		preview.set_shader_parameter(&"ground_albedo_average", _texture_average(albedo, Color.TRANSPARENT))
		preview.set_shader_parameter(&"ground_roughness_average", _texture_average(roughness, Color.WHITE).r)
		preview.set_shader_parameter(&"ground_world_scale", _world_scale)
		_set_strengths(preview)
		_previews[original] = preview
	_assignments[target] = {"original": original, "preview": preview}
	target.material_override = preview
	return true

func _set_strengths(material: ShaderMaterial) -> void:
	material.set_shader_parameter(&"ground_texture_blend", texture_blend)
	material.set_shader_parameter(&"ground_tone_variation", tone_variation)

func _on_relief_added(hill: Node) -> void:
	_apply_relief.call_deferred(hill.get_instance_id())

func _apply_relief(hill_id: int) -> void:
	if not is_instance_valid(_relief) or (texture_blend == 0.0 and tone_variation == 0.0):
		return
	var hill := instance_from_id(hill_id) as Node
	if is_instance_valid(hill) and hill.get_parent() == _relief:
		_apply_material(hill.get_node_or_null("HillMesh") as MeshInstance3D)

func _restore_materials() -> int:
	var restored := 0
	for target in _assignments:
		if not is_instance_valid(target):
			continue
		var assignment: Dictionary = _assignments[target]
		if target.material_override == assignment["preview"]:
			target.material_override = assignment["original"]
			restored += 1
	_assignments.clear()
	_previews.clear()
	return restored

func _texture_average(texture: Texture2D, fallback: Color) -> Color:
	if texture == null:
		return fallback
	if _texture_averages.has(texture):
		var cached: Variant = _texture_averages[texture]
		return cached if cached is Color else fallback
	var image := texture.get_image()
	if image == null or image.is_empty() or (image.is_compressed() and image.decompress() != OK):
		_texture_averages[texture] = null
		return fallback
	image.resize(AVERAGE_SIZE, AVERAGE_SIZE, Image.INTERPOLATE_TRILINEAR)
	var mean := Color(0.0, 0.0, 0.0, 0.0)
	for y in AVERAGE_SIZE:
		for x in AVERAGE_SIZE:
			mean += image.get_pixel(x, y)
	mean /= float(AVERAGE_SIZE * AVERAGE_SIZE)
	mean.a = 1.0
	_texture_averages[texture] = mean
	return mean
