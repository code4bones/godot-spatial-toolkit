@tool
extends RefCounted

const Style := preload("res://addons/spatial_toolkit/core/map_style_module.gd")
const Layers := preload("res://addons/spatial_toolkit/core/spatial_layers.gd")
const RULES := &"facade_base_colors"
const ORIGINAL := &"original_facade_base_color"
const UNSPECIFIED := "yes"
const LABELS := {
	"apartments": "Многоквартирные дома",
	"house": "Дома",
	"residential": "Жилые здания",
	"industrial": "Промышленные здания",
	"warehouse": "Склады",
	"public": "Общественные здания",
	"commercial": "Коммерческие здания",
	"retail": "Торговые здания",
	"office": "Офисы",
	"service": "Служебные здания",
	"school": "Школы",
	"kindergarten": "Детские сады",
	"garages": "Гаражи",
	"garage": "Гаражные здания",
	UNSPECIFIED: "Тип не указан",
}

static func type_id(building: MeshInstance3D) -> String:
	var tags: Dictionary = building.get_meta("source_tags", {})
	var kind := str(tags.get("building", "")).strip_edges().to_lower()
	return UNSPECIFIED if kind.is_empty() else kind

static func groups(map: Node3D) -> Dictionary:
	var result := {}
	for building in Layers.buildings(map):
		if _wall_material(building) != null:
			result.get_or_add(type_id(building), []).append(building)
	return result

static func sample_color(building: MeshInstance3D) -> Color:
	var material := _wall_material(building)
	if material != null:
		var color: Variant = material.get_shader_parameter("wall_color")
		if color is Color:
			return color
	return Color.WHITE

static func changes(buildings: Array, color: Variant) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	var copies := {}
	for building: MeshInstance3D in buildings:
		if not is_instance_valid(building) or building.mesh == null:
			continue
		if building.material_override != null:
			if _uses_shader(building.material_override, Style.FACADE_SHADER_PATH):
				_append_change(result, copies, building, "material_override", building.material_override, "wall_color", color)
			continue
		var foundation := int(building.get_meta("foundation_surface_index", -1))
		for index in building.mesh.get_surface_count():
			var material := building.get_active_material(index) as ShaderMaterial
			var property := "surface_material_override/%d" % index
			if _uses_shader(material, Style.FACADE_SHADER_PATH):
				_append_change(result, copies, building, property, material, "wall_color", color)
			elif index == foundation and _uses_shader(material, Style.FLAT_SHADER_PATH):
				_append_change(result, copies, building, property, material, "surface_color", color)
	return result

static func _append_change(result: Array[Dictionary], copies: Dictionary, building: MeshInstance3D,
		property: String, material: ShaderMaterial, parameter: String, color: Variant) -> void:
	if color == null and not material.has_meta(ORIGINAL):
		return
	if not copies.has(material):
		var copy := material.duplicate() as ShaderMaterial
		if color == null:
			copy.set_shader_parameter(parameter, material.get_meta(ORIGINAL)[0])
			copy.remove_meta(ORIGINAL)
		else:
			if not copy.has_meta(ORIGINAL):
				copy.set_meta(ORIGINAL, [material.get_shader_parameter(parameter)])
			copy.set_shader_parameter(parameter, color)
		copies[material] = copy
	result.append({"building": building, "property": property, "material": copies[material]})

static func _wall_material(building: MeshInstance3D) -> ShaderMaterial:
	if building.mesh == null:
		return null
	if building.material_override != null:
		return building.material_override as ShaderMaterial if _uses_shader(building.material_override, Style.FACADE_SHADER_PATH) else null
	for index in building.mesh.get_surface_count():
		var material := building.get_active_material(index)
		if _uses_shader(material, Style.FACADE_SHADER_PATH):
			return material as ShaderMaterial
	return null

static func _uses_shader(material: Material, path: String) -> bool:
	return material is ShaderMaterial and material.shader != null and material.shader.resource_path == path
