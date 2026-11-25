extends Node
## Optional map-local facade trial on one source building or the entire map.

signal weathering_ready

const FACADE_SHADER := preload("res://addons/spatial_toolkit/materials/building_facade.gdshader")
const STRENGTH := &"facade_weathering_strength"
const TEXTURE_BLEND := &"facade_texture_blend"
const HIGHLIGHTS := &"facade_highlights"
const ROOF_BLEND := &"roof_texture_blend"
const AVERAGE_SIZE := 16
const STARTUP_BATCH_SIZE := 32
const STARTUP_FRAME_BUDGET_USEC := 5000
const NEUTRAL_ALBEDO := Color(0.645, 0.645, 0.645, 1.0)
const HIGHLIGHT_METAL := Vector2(0.35, 0.49)
const HIGHLIGHT_CONCRETE := Vector2(0.66, 0.38)
const HIGHLIGHT_BRICK := Vector2(0.79, 0.30)
const HIGHLIGHT_GENERIC := Vector2(0.74, 0.34)

@export var source_id := ""
@export var all_buildings := false
@export_range(0.0, 1.0, 0.01) var strength := 1.0
@export_range(0.0, 1.0, 0.01) var texture_blend := 0.0
@export_range(0.0, 1.0, 0.01) var facade_highlights := 0.0
@export_range(0.0, 1.0, 0.01) var roof_texture_blend := 0.0

var _buildings: Array[MeshInstance3D] = []
var _assignments: Dictionary = {}
var _previews: Dictionary = {}
var _profiles: Dictionary = {}
var _averages: Dictionary = {}
var _applying := false

func _ready() -> void:
	var map := get_parent().get_parent()
	var buildings := map.get_node_or_null("Generated/Buildings") if map != null else null
	if buildings != null and (all_buildings or not source_id.is_empty()):
		for child in buildings.get_children():
			if child is MeshInstance3D and (all_buildings or str(child.get_meta("source_id", "")) == source_id):
				_buildings.append(child)
				if not all_buildings:
					break
	if all_buildings and strength > 0.0 and not _buildings.is_empty():
		_apply_startup()
	else:
		set_weathering_strength(strength)
		weathering_ready.emit()

func _apply_startup() -> void:
	_applying = true
	var processed := 0
	var deadline := Time.get_ticks_usec() + STARTUP_FRAME_BUDGET_USEC
	for building in _buildings:
		if is_instance_valid(building):
			_apply_building(building)
		processed += 1
		if processed == STARTUP_BATCH_SIZE or Time.get_ticks_usec() >= deadline:
			await get_tree().process_frame
			if not _applying or is_queued_for_deletion():
				_applying = false
				return
			processed = 0
			deadline = Time.get_ticks_usec() + STARTUP_FRAME_BUDGET_USEC
	_applying = false
	weathering_ready.emit()

func is_applying() -> bool:
	return _applying

func _exit_tree() -> void:
	_applying = false
	_restore_materials()

func set_weathering_strength(value: float) -> int:
	_applying = false
	strength = clampf(value, 0.0, 1.0)
	if strength <= 0.0:
		return _restore_materials()
	var applied := 0
	for building in _buildings:
		if is_instance_valid(building):
			applied += _apply_building(building)
	return applied

func _apply_building(building: MeshInstance3D) -> int:
	if building.is_queued_for_deletion() or building.mesh == null:
		return 0
	if building.material_override != null:
		return int(_apply_material(building, &"material_override", building.material_override))
	var applied := 0
	for index in building.mesh.get_surface_count():
		var property := StringName("surface_material_override/%d" % index)
		applied += int(_apply_material(building, property, building.get_active_material(index)))
	return applied

func _apply_material(building: MeshInstance3D, property: StringName, active: Material) -> bool:
	var facade := active as ShaderMaterial
	if facade == null or facade.shader != FACADE_SHADER:
		return false
	if not _assignments.has(building):
		_assignments[building] = {}
	var slots: Dictionary = _assignments[building]
	var previous: Dictionary = slots.get(property, {})
	var preview := previous.get("preview") as ShaderMaterial
	if preview != facade:
		var profile := _highlight_profile(building, facade)
		var key := [facade, profile]
		preview = _previews.get(key) as ShaderMaterial
		if preview == null:
			preview = _create_preview(facade)
			preview.set_shader_parameter("facade_highlight_profile", profile)
			_previews[key] = preview
		slots[property] = {"original": building.get(property), "preview": preview}
		building.set(property, preview)
	preview.set_shader_parameter(STRENGTH, strength)
	preview.set_shader_parameter(TEXTURE_BLEND, texture_blend)
	preview.set_shader_parameter(HIGHLIGHTS, facade_highlights)
	preview.set_shader_parameter(ROOF_BLEND, roof_texture_blend)
	return true

func _highlight_profile(building: MeshInstance3D, facade: ShaderMaterial) -> Vector2:
	var albedo := facade.get_shader_parameter("finish_albedo") as Texture2D
	var metallic_value: Variant = facade.get_shader_parameter("finish_metallic")
	if metallic_value is float and metallic_value >= 0.24:
		var metallic_map := facade.get_shader_parameter("finish_metal_map") as Texture2D
		if metallic_value * _texture_average(metallic_map, Color.WHITE).r >= 0.24:
			return HIGHLIGHT_METAL
	var material_name := albedo.resource_path.get_file().to_lower() if albedo != null else ""
	if material_name.contains("metal") or material_name.contains("steel"):
		return HIGHLIGHT_METAL
	if material_name.contains("brick"):
		return HIGHLIGHT_BRICK
	if material_name.contains("concrete") or material_name.contains("cement") or material_name.contains("stucco"):
		return HIGHLIGHT_CONCRETE
	if material_name.is_empty():
		var tags: Dictionary = building.get_meta("source_tags", {})
		var osm_material := str(tags.get("building:material", "")).to_lower()
		if osm_material.contains("brick") or facade.get_shader_parameter("facade_style") == 1:
			return HIGHLIGHT_BRICK
		if osm_material.contains("concrete"):
			return HIGHLIGHT_CONCRETE
	return HIGHLIGHT_GENERIC

func _create_preview(facade: ShaderMaterial) -> ShaderMaterial:
	var preview := facade.duplicate() as ShaderMaterial
	_set_texture_averages(preview, "finish", "facade_weathering", 1.0)
	_set_texture_averages(preview, "roof", "roof_weathering", 0.91)
	return preview

func _set_texture_averages(preview: ShaderMaterial, prefix: String, target: String, roughness_default: float) -> void:
	var albedo := preview.get_shader_parameter(prefix + "_albedo") as Texture2D
	if albedo != null:
		var roughness := preview.get_shader_parameter(prefix + "_roughness") as Texture2D
		var metallic := preview.get_shader_parameter(prefix + "_metal_map") as Texture2D
		var key := [albedo, roughness, metallic, roughness_default]
		if not _profiles.has(key):
			var roughness_fallback := Color(roughness_default, roughness_default, roughness_default)
			_profiles[key] = {
				"albedo": _texture_average(albedo, NEUTRAL_ALBEDO),
				"finish": Vector2(_texture_average(roughness, roughness_fallback).r,
					_texture_average(metallic, Color.WHITE).r),
			}
		var profile: Dictionary = _profiles[key]
		preview.set_shader_parameter(target + "_albedo_average", profile["albedo"])
		preview.set_shader_parameter(target + "_finish_average", profile["finish"])

func _restore_materials() -> int:
	var restored := 0
	for building in _assignments:
		if not is_instance_valid(building):
			continue
		var slots: Dictionary = _assignments[building]
		for property in slots:
			var assignment: Dictionary = slots[property]
			if building.get(property) == assignment["preview"]:
				building.set(property, assignment["original"])
				restored += 1
	_assignments.clear()
	_previews.clear()
	return restored

func _texture_average(texture: Texture2D, fallback: Color) -> Color:
	if texture == null:
		return fallback
	if _averages.has(texture):
		var cached: Variant = _averages[texture]
		return cached if cached is Color else fallback
	var image := texture.get_image()
	if image == null or image.is_empty() or (image.is_compressed() and image.decompress() != OK):
		_averages[texture] = null
		return fallback
	image.resize(AVERAGE_SIZE, AVERAGE_SIZE, Image.INTERPOLATE_TRILINEAR)
	var mean := Color(0.0, 0.0, 0.0, 0.0)
	for y in AVERAGE_SIZE:
		for x in AVERAGE_SIZE:
			mean += image.get_pixel(x, y)
	mean /= float(AVERAGE_SIZE * AVERAGE_SIZE)
	_averages[texture] = mean
	return mean
