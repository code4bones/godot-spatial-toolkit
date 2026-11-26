@tool
extends RefCounted
## Per-map ground settings for the background plane and imported land-use patches.

const LABELS := ["Фон карты", "Участки земли"]
const BACKGROUND := 0
const RULES := &"ground_surface_styles"
const ORIGINAL := &"original_ground_material"
const FLAT := preload("res://addons/spatial_toolkit/materials/flat_map_surface.gdshader")
const TEXTURED := preload("res://addons/spatial_toolkit/materials/textured_road.gdshader")
const TERRAIN := preload("res://addons/spatial_toolkit/materials/terrain_surface.gdshader")

static func targets(map: Node3D, slot: int) -> Array[MeshInstance3D]:
	var result: Array[MeshInstance3D] = []
	if not is_instance_valid(map):
		return result
	if slot == BACKGROUND:
		var ground := map.get_node_or_null("FlatGround") as MeshInstance3D
		if _is_target(ground):
			result.append(ground)
	elif slot == 1:
		var layer := map.get_node_or_null("Generated/Landuse")
		if layer != null:
			for node in layer.get_children():
				var patch := node as MeshInstance3D
				if _is_target(patch):
					result.append(patch)
	return result

static func _is_target(mesh: MeshInstance3D) -> bool:
	var material := mesh.material_override as ShaderMaterial if mesh != null else null
	return material != null and mesh.mesh != null and (material.shader == FLAT or material.shader == TEXTURED)

static func _rule(map: Node3D, slot: int) -> Dictionary:
	var rules: Dictionary = map.get_meta(RULES, {}) if is_instance_valid(map) else {}
	return rules.get(slot, {})

static func override_material(map: Node3D, slot: int) -> Resource:
	return _rule(map, slot).get("material") as Resource

static func override_color(map: Node3D, slot: int) -> Variant:
	return _rule(map, slot).get("color")

static func selected_material(map: Node3D, slot: int) -> Resource:
	var assigned := override_material(map, slot)
	if assigned != null:
		return assigned
	var meshes := targets(map, slot)
	if meshes.is_empty():
		return null
	var source := _source_material(meshes[0])
	return source if source.shader == TEXTURED else null

static func selected_color(map: Node3D, slot: int) -> Color:
	var color: Variant = override_color(map, slot)
	if color is Color:
		return color
	var assigned := override_material(map, slot)
	if assigned != null:
		return _material_color(assigned)
	var meshes := targets(map, slot)
	if meshes.is_empty():
		return Color.WHITE
	var source := _source_material(meshes[0])
	if source.shader == FLAT:
		var flat_color: Variant = source.get_shader_parameter(&"surface_color")
		return flat_color if flat_color is Color else Color.WHITE
	return _material_color(source)

static func supports_material(resource: Resource) -> bool:
	if resource is Texture2D:
		return true
	if resource is StandardMaterial3D:
		return resource.albedo_texture != null
	if resource is ShaderMaterial and (resource.shader == TEXTURED or resource.shader == TERRAIN):
		return resource.get_shader_parameter(&"road_albedo") is Texture2D
	return false

static func surface_overrides(meshes: Array[MeshInstance3D], slot: int, material: Resource, color: Variant,
		world_scale: float) -> Dictionary:
	var result := {}
	var copies := {}
	for mesh in meshes:
		var source := _source_material(mesh)
		if material == null and color == null:
			result[mesh] = source
			continue
		if not copies.has(source):
			var edited := _make_surface(source, slot, material, world_scale)
			if color is Color:
				if edited.shader == TEXTURED:
					edited.set_shader_parameter(&"surface_tint", color)
				else:
					edited.set_shader_parameter(&"surface_color", color)
					edited.set_shader_parameter(&"baked_vertex_color", false)
			edited.render_priority = source.render_priority
			edited.set_meta(ORIGINAL, source)
			copies[source] = edited
		result[mesh] = copies[source]
	return result

static func _source_material(mesh: MeshInstance3D) -> ShaderMaterial:
	var active := mesh.material_override as ShaderMaterial
	return active.get_meta(ORIGINAL, active) as ShaderMaterial

static func _material_color(material: Resource) -> Color:
	if material is StandardMaterial3D:
		return material.albedo_color
	if material is ShaderMaterial:
		var tint: Variant = material.get_shader_parameter(&"surface_tint")
		if tint is Color:
			return tint
	return Color.WHITE

static func _make_surface(source: ShaderMaterial, slot: int, material: Resource,
		world_scale: float) -> ShaderMaterial:
	if material == null:
		return source.duplicate() as ShaderMaterial
	var edited := ShaderMaterial.new()
	edited.shader = TEXTURED
	var repeat_m := 6.0 if slot == BACKGROUND else 4.0
	if material is ShaderMaterial:
		for parameter in [&"road_albedo", &"road_normal", &"road_roughness", &"macro_contrast", &"macro_scale",
				&"surface_roughness"]:
			var value: Variant = material.get_shader_parameter(parameter)
			if value != null:
				edited.set_shader_parameter(parameter, value)
		var repeat: Variant = material.get_shader_parameter(&"repeat_size")
		if repeat is float:
			repeat_m = repeat
	elif material is StandardMaterial3D:
		edited.set_shader_parameter(&"road_albedo", material.albedo_texture)
		edited.set_shader_parameter(&"road_normal", material.normal_texture if material.normal_enabled else null)
		edited.set_shader_parameter(&"road_roughness", material.roughness_texture)
		edited.set_shader_parameter(&"surface_roughness", material.roughness)
		repeat_m = float(material.get_meta("repeat_m", repeat_m))
	else:
		edited.set_shader_parameter(&"road_albedo", material)
	edited.set_shader_parameter(&"repeat_size", maxf(0.05, repeat_m) * maxf(0.001, world_scale))
	edited.set_shader_parameter(&"surface_tint", _material_color(material))
	return edited
