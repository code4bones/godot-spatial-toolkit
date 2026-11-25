@tool
extends RefCounted

const FACADE := "res://addons/spatial_toolkit/materials/building_facade.gdshader"
const SLOTS := &"roof_material_variants"
const DEFAULTS := [
	["Бетон", "rebar_reinforced_concrete", 4.0, 0.0],
	["Металлическая плита", "metal_plate", 3.0, 0.38],
	["Профилированный лист", "box_profile_metal", 3.0, 0.42],
	["Синий металл", "blue_metal", 3.0, 0.32],
]

static func variant_id(building: MeshInstance3D) -> int:
	var id := str(building.get_meta("source_id", building.name))
	return id.sha256_text().substr(0, 8).hex_to_int() % DEFAULTS.size()

static func default_label(id: int) -> String:
	return DEFAULTS[id][0]

static func apply_to_map(map: Node3D) -> void:
	var buildings := map.get_node_or_null("Generated/Buildings")
	if buildings == null:
		return
	var assignments: Dictionary = map.get_meta(SLOTS, {})
	var variants: Array[Material] = []
	for id in DEFAULTS.size():
		var assigned := assignments.get(id) as Material
		variants.append(assigned if assigned != null else default_material(id))
	for child in buildings.get_children():
		var building := child as MeshInstance3D
		if building == null:
			continue
		for change in updates(building, variants[variant_id(building)]):
			building.set(change["property"], change["material"])

static func default_albedo(id: int) -> Texture2D:
	var path := "res://assets/textures/%s_facade_diff_1k.png" % DEFAULTS[id][1]
	return load(path) as Texture2D if ResourceLoader.exists(path) else null

static func default_material(id: int) -> StandardMaterial3D:
	var data: Array = DEFAULTS[id]
	var prefix := "res://assets/textures/%s_facade_" % data[1]
	var albedo := default_albedo(id)
	if albedo == null:
		return null
	var material := StandardMaterial3D.new()
	material.resource_name = default_label(id)
	material.albedo_texture = albedo
	var normal_path := prefix + "nor_gl_1k.png"
	if ResourceLoader.exists(normal_path):
		material.normal_texture = load(normal_path) as Texture2D
		material.normal_enabled = material.normal_texture != null
	var rough_path := prefix + "rough_1k.png"
	if ResourceLoader.exists(rough_path):
		material.roughness_texture = load(rough_path) as Texture2D
	material.set_meta("repeat_m", data[2])
	material.metallic = data[3]
	return material

static func updates(building: MeshInstance3D, selected: Material) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	if building.mesh == null or selected == null:
		return result
	if building.material_override != null:
		var material := _roof_material(building.material_override, selected)
		if material != null:
			result.append({"property": "material_override", "material": material})
		return result
	for index in building.mesh.get_surface_count():
		var material := _roof_material(building.get_active_material(index), selected)
		if material != null:
			result.append({"property": "surface_material_override/%d" % index, "material": material})
	return result

static func _roof_material(original: Material, selected: Material) -> ShaderMaterial:
	var facade := original as ShaderMaterial
	if facade == null or facade.shader == null or facade.shader.resource_path != FACADE:
		return null
	var color: Texture2D
	var normal: Texture2D
	var rough: Texture2D
	var metal: Texture2D
	var repeat_m := 2.0
	var metallic := 0.0
	if selected is StandardMaterial3D:
		color = selected.albedo_texture
		normal = selected.normal_texture
		rough = selected.roughness_texture
		metal = selected.metallic_texture
		repeat_m = float(selected.get_meta("repeat_m", repeat_m))
		metallic = selected.metallic
	elif selected is ShaderMaterial:
		color = selected.get_shader_parameter("road_albedo") as Texture2D
		normal = selected.get_shader_parameter("road_normal") as Texture2D
		rough = selected.get_shader_parameter("road_roughness") as Texture2D
		if color != null:
			repeat_m = float(selected.get_shader_parameter("repeat_size"))
	if color == null:
		return null
	var copied := facade.duplicate() as ShaderMaterial
	copied.set_shader_parameter("roof_albedo", color)
	copied.set_shader_parameter("roof_normal", normal)
	copied.set_shader_parameter("roof_roughness", rough)
	copied.set_shader_parameter("roof_metal_map", metal)
	copied.set_shader_parameter("roof_has_normal", normal != null)
	copied.set_shader_parameter("roof_has_roughness", rough != null)
	copied.set_shader_parameter("roof_repeat_m", maxf(0.05, repeat_m))
	copied.set_shader_parameter("roof_metallic", metallic)
	return copied
