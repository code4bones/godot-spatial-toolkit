@tool
extends Resource
## Portable style assignments addressed by stable layer keys and source feature IDs.

const VERSION := 3
const Groups := preload("res://addons/spatial_toolkit/core/facade_groups.gd")
const Colors := preload("res://addons/spatial_toolkit/core/facade_colors.gd")
const Ground := preload("res://addons/spatial_toolkit/core/ground_styles.gd")
const Roofs := preload("res://addons/spatial_toolkit/core/roof_styles.gd")
const Layers := preload("res://addons/spatial_toolkit/core/spatial_layers.gd")
const Night := preload("res://addons/spatial_toolkit/runtime/night_city_style.gd")
const Localization := preload("res://addons/spatial_toolkit/ui/editor_localization.gd")
const BUILDING_FIELDS := [
	&"roof_variants", &"roof_material", &"facade_variation", &"facade_weathering", &"decorative_windows",
	&"window_style", &"window_layout",
]

@export_storage var format_version := 0
@export_storage var layer_styles: Dictionary = {}
@export_storage var building_materials: Dictionary = {}
@export_storage var sky_mode: StringName = Night.DAY
@export_storage var sky_settings: SpatialSkySettings
# Imported from earlier portable profiles. Type colours and roof variants
# still provide baseline values beneath overrides on the new layer nodes.
@export_storage var facade_materials: Dictionary = {}
@export_storage var facade_colors: Dictionary = {}
@export_storage var roof_materials: Dictionary = {}
@export_storage var ground_styles: Dictionary = {}

func capture(map: Node3D) -> void:
	format_version = VERSION
	layer_styles.clear()
	building_materials.clear()
	facade_materials.clear()
	ground_styles.clear()
	facade_colors = map.get_meta(Colors.RULES, {}).duplicate(true)
	roof_materials = map.get_meta(Roofs.SLOTS, {}).duplicate(true)
	sky_mode = Night.mode_for(map)
	var current_sky := map.get("sky_settings") as SpatialSkySettings if "sky_settings" in map else null
	sky_settings = current_sky.duplicate() as SpatialSkySettings if current_sky != null else null
	for layer in Layers.style_nodes(map):
		var rule := layer.style_values()
		if rule.has("roof_variants"):
			rule["roof_variants"] = _copy_roof_variants(rule["roof_variants"])
		if rule.has("window_style"):
			rule["window_style"] = (rule["window_style"] as SpatialWindowStyle).copy_for_storage()
		if rule.has("window_layout"):
			rule["window_layout"] = (rule["window_layout"] as SpatialWindowLayout).copy_for_storage()
		if not layer.visible:
			rule["visible"] = false
		if not rule.is_empty():
			layer_styles[layer.style_key] = rule
	for building in Layers.buildings(map):
		var id := str(building.get_meta("source_id", ""))
		if not id.is_empty() and building.has_meta(Groups.INDIVIDUAL):
			building_materials[id] = building.get_meta(Groups.INDIVIDUAL)

func validation_error() -> String:
	if format_version not in [1, 2, VERSION]:
		return Localization.translate("Unsupported appearance profile version · %d") % format_version
	if sky_mode not in [Night.DAY, Night.NIGHT]:
		return Localization.translate("The appearance profile has an invalid sky mode.")
	for key in layer_styles:
		if not key is String or key.is_empty() or not layer_styles[key] is Dictionary \
				or not _valid_layer_rule(key, layer_styles[key]):
			return Localization.translate("Invalid layer settings · %s") % str(key)
	for id in building_materials:
		if not id is String or id.is_empty() or not building_materials[id] is Material:
			return Localization.translate("Invalid material assignment for an individual building.")
	return _validate_profile_defaults()

func _valid_layer_rule(key: String, rule: Dictionary) -> bool:
	for field in rule:
		if field in BUILDING_FIELDS and not _is_building_key(key):
			return false
		var value: Variant = rule[field]
		match field:
			"material", "roof_material":
				if not value is Material:
					return false
			"roof_variants":
				if not value is Array:
					return false
				for variant in value:
					if variant == null:
						continue
					if not variant is SpatialLayerAppearance or not _finite_color(variant.tint) \
							or not _finite_number(variant.texture_repeat_m) or variant.texture_repeat_m < 0.0:
						return false
			"tint":
				if not value is Color or not _finite_color(value):
					return false
			"texture_repeat_m":
				if not _finite_number(value) or float(value) <= 0.0:
					return false
			"visible":
				if not value is bool:
					return false
			"facade_variation", "facade_weathering":
				if not _finite_number(value) or value < 0.0 or value > 1.0:
					return false
			"decorative_windows":
				if not value is int or value not in [1, 2]:
					return false
			"window_style":
				if not value is SpatialWindowStyle or not value.validation_error().is_empty():
					return false
			"window_layout":
				if not value is SpatialWindowLayout or not value.validation_error().is_empty():
					return false
			_:
				return false
	return true

func _finite_number(value: Variant) -> bool:
	return (value is float or value is int) and is_finite(float(value))

func _finite_color(color: Color) -> bool:
	return is_finite(color.r) and is_finite(color.g) and is_finite(color.b) and is_finite(color.a)

func _is_building_key(key: String) -> bool:
	return key == "Buildings" or key.begins_with("Buildings/")

func _validate_profile_defaults() -> String:
	if not _valid_material_slots(facade_materials, Groups.BUCKET_COUNT * Groups.BUCKET_COUNT) \
			or not _valid_material_slots(roof_materials, Roofs.PROFILE_VARIANT_COUNT):
		return Localization.translate("The profile has invalid facade or roof group materials.")
	for type in facade_colors:
		if not type is String or type.is_empty() or not facade_colors[type] is Color:
			return Localization.translate("The profile has an invalid facade color.")
	for slot in ground_styles:
		if not slot is int or slot < 0 or slot >= Ground.LABELS.size() or not ground_styles[slot] is Dictionary:
			return Localization.translate("The profile has an invalid ground surface group.")
		var rule: Dictionary = ground_styles[slot]
		var material: Variant = rule.get("material")
		var tint: Variant = rule.get("color")
		if (material != null and (not material is Resource or not Ground.supports_material(material))) \
				or (tint != null and not tint is Color):
			return Localization.translate("The profile has an invalid ground material or color.")
	return ""

func requires_daylight() -> bool:
	if not facade_materials.is_empty() or not facade_colors.is_empty() \
			or not building_materials.is_empty() or not roof_materials.is_empty():
		return true
	for key: String in layer_styles:
		if _is_building_key(key):
			for field in layer_styles[key]:
				if field != "visible":
					return true
	return false

func _valid_material_slots(rules: Dictionary, count: int) -> bool:
	for slot in rules:
		if not slot is int or slot < 0 or slot >= count or not rules[slot] is Material:
			return false
	return true

func apply_to_new_map(map: Node3D) -> Dictionary:
	if "sky_mode" in map:
		map.set("sky_mode", str(sky_mode))
	if "sky_settings" in map:
		map.set("sky_settings", sky_settings.duplicate() as SpatialSkySettings if sky_settings != null else null)
	map.set_meta(Night.MODE, sky_mode)
	var nodes := Layers.style_nodes(map)
	var by_key := {}
	for node in nodes:
		by_key[node.style_key] = node
	_apply_profile_defaults(map, by_key)
	var unmatched_layers := []
	for key: String in layer_styles:
		var layer := by_key.get(key) as SpatialLayer3D
		if layer == null:
			unmatched_layers.append(key)
		else:
			_apply_layer_rule(layer, layer_styles[key])
	var remaining := building_materials.duplicate()
	var facade_count := 0
	var roof_count := 0
	for building in Layers.buildings(map):
		var source_id := str(building.get_meta("source_id", ""))
		if building_materials.has(source_id):
			building.set_meta(Groups.INDIVIDUAL, building_materials[source_id])
			remaining.erase(source_id)
		var effective := Layers.effective(building)
		facade_count += int(effective.has("material") or building.has_meta(Groups.INDIVIDUAL))
		roof_count += int(effective.has("roof_variants") or effective.has("roof_material"))
	Layers.apply(map)
	var ground_count := 0
	for key: String in ["FlatGround", "Landuse"]:
		for mesh in Layers.meshes(by_key.get(key) as Node):
			var effective := Layers.effective(mesh)
			ground_count += int(effective.has("material") or effective.has("tint") or effective.has("texture_repeat_m"))
	var missing := remaining.keys()
	missing.sort()
	unmatched_layers.sort()
	return {"path": resource_path, "format_version": format_version, "facades": facade_count,
		"roofs": roof_count, "ground_surfaces": ground_count, "sky_mode": str(sky_mode),
		"matched_building_materials": building_materials.size() - missing.size(),
		"unmatched_building_ids": missing, "matched_layer_styles": layer_styles.size() - unmatched_layers.size(),
		"unmatched_layer_keys": unmatched_layers}

func _apply_layer_rule(layer: SpatialLayer3D, rule: Dictionary) -> void:
	if rule.has("tint"):
		layer.override_tint = true
	for field in rule:
		match field:
			"roof_variants":
				layer.set("roof_variants", _copy_roof_variants(rule[field]))
			"roof_material":
				if not rule.has("roof_variants"):
					layer.set("roof_variants", _material_variants([rule[field]]))
			"window_style":
				layer.set("window_style", (rule[field] as SpatialWindowStyle).copy_for_storage())
			"window_layout":
				layer.set("window_layout", (rule[field] as SpatialWindowLayout).copy_for_storage())
			_:
				layer.set(field, rule[field])

func _copy_roof_variants(variants: Array) -> Array[SpatialLayerAppearance]:
	var copied: Array[SpatialLayerAppearance] = []
	for variant: SpatialLayerAppearance in variants:
		copied.append(variant.duplicate() as SpatialLayerAppearance if variant != null else null)
	return copied

func _material_variants(materials: Array) -> Array[SpatialLayerAppearance]:
	var variants: Array[SpatialLayerAppearance] = []
	for material: Material in materials:
		var variant := SpatialLayerAppearance.new()
		variant.material = material
		variants.append(variant)
	return variants

func _apply_profile_defaults(map: Node3D, by_key: Dictionary) -> void:
	for id: int in facade_materials:
		var layer := Layers.node_for_building_group(map, id)
		if layer != null:
			layer.material = facade_materials[id]
	for slot: int in ground_styles:
		var layer := by_key.get("FlatGround" if slot == Ground.BACKGROUND else "Landuse") as SpatialLayer3D
		if layer == null:
			continue
		var rule: Dictionary = ground_styles[slot]
		var material: Variant = rule.get("material")
		if material is Texture2D:
			var converted := StandardMaterial3D.new()
			converted.albedo_texture = material
			layer.material = converted
		elif material is Material:
			layer.material = material
		var tint: Variant = rule.get("color")
		if tint is Color:
			layer.override_tint = true
			layer.tint = tint
	if not roof_materials.is_empty():
		var buildings_layer := by_key.get("Buildings") as SpatialBuildingLayer3D
		if buildings_layer != null:
			var materials: Array[Material] = []
			for index in Roofs.PROFILE_VARIANT_COUNT:
				materials.append(roof_materials.get(index) as Material)
			buildings_layer.roof_variants = _material_variants(materials)
	if not facade_colors.is_empty():
		map.set_meta(Colors.RULES, facade_colors.duplicate(true))
		var colors_by_type := Colors.groups(map)
		for type in facade_colors:
			for change in Colors.changes(colors_by_type.get(type, []), facade_colors[type]):
				change["building"].set(change["property"], change["material"])
