@tool
extends RefCounted

const FACADE := "res://addons/spatial_toolkit/materials/building_facade.gdshader"
const SLOTS := &"roof_material_variants"
const PROFILE_VARIANT_COUNT := 4

static func pick_variant(building: MeshInstance3D, variants: Array) -> SpatialLayerAppearance:
	var available: Array[SpatialLayerAppearance] = []
	for variant in variants:
		if variant is SpatialLayerAppearance:
			available.append(variant)
	if available.is_empty():
		return null
	var id := str(building.get_meta("source_id", building.name))
	return available[id.sha256_text().substr(0, 8).hex_to_int() % available.size()]

static func styled_material(original: Material, selected: Material, tint: Variant,
		repeat_override_m: float) -> ShaderMaterial:
	var facade := original as ShaderMaterial
	if facade == null or facade.shader == null or facade.shader.resource_path != FACADE:
		return null
	if selected == null:
		if tint == null and repeat_override_m <= 0.0:
			return null
		var tinted := facade.duplicate() as ShaderMaterial
		apply_tint_and_repeat(tinted, tint, repeat_override_m)
		return tinted
	var color: Texture2D
	var normal: Texture2D
	var rough: Texture2D
	var metal: Texture2D
	var repeat_m := 2.0
	var metallic := 0.0
	var material_tint := Color.WHITE
	if selected is StandardMaterial3D:
		color = selected.albedo_texture
		normal = selected.normal_texture if selected.normal_enabled else null
		rough = selected.roughness_texture
		metal = selected.metallic_texture
		repeat_m = float(selected.get_meta("repeat_m", repeat_m))
		metallic = selected.metallic
		material_tint = selected.albedo_color
	elif selected is ShaderMaterial:
		color = selected.get_shader_parameter("road_albedo") as Texture2D
		normal = selected.get_shader_parameter("road_normal") as Texture2D
		rough = selected.get_shader_parameter("road_roughness") as Texture2D
		var shader_repeat: Variant = selected.get_shader_parameter("repeat_size")
		if shader_repeat is float:
			repeat_m = shader_repeat
		var shader_tint: Variant = selected.get_shader_parameter("surface_tint")
		if shader_tint is Color:
			material_tint = shader_tint
	if color == null and not selected is StandardMaterial3D:
		return null
	var copied := facade.duplicate() as ShaderMaterial
	copied.set_shader_parameter("roof_albedo", color)
	copied.set_shader_parameter("roof_normal", normal)
	copied.set_shader_parameter("roof_roughness", rough)
	copied.set_shader_parameter("roof_metal_map", metal)
	copied.set_shader_parameter("roof_has_normal", normal != null)
	copied.set_shader_parameter("roof_has_roughness", rough != null)
	copied.set_shader_parameter("roof_repeat_m", maxf(0.05, repeat_m) if color != null else 0.0)
	copied.set_shader_parameter("roof_metallic", metallic)
	apply_tint_and_repeat(copied, tint if tint is Color else material_tint, repeat_override_m)
	return copied

static func apply_tint_and_repeat(material: ShaderMaterial, tint: Variant, repeat_m: float) -> void:
	if material.get_shader_parameter("roof_albedo") is Texture2D:
		if tint is Color:
			material.set_shader_parameter("roof_tint", tint)
		if repeat_m > 0.0:
			material.set_shader_parameter("roof_repeat_m", repeat_m)
	elif tint is Color:
		material.set_shader_parameter("roof_tint", Color.WHITE)
		material.set_shader_parameter("roof_color", tint)
