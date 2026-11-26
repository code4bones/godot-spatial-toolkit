@tool
class_name SpatialAttributeBank
extends Resource
## Shared style rules for one chunked world.

const AppearanceProfile := preload("res://addons/spatial_toolkit/core/map_appearance_profile.gd")
const Groups := preload("res://addons/spatial_toolkit/core/facade_groups.gd")
const Ground := preload("res://addons/spatial_toolkit/core/ground_styles.gd")
const Layers := preload("res://addons/spatial_toolkit/core/spatial_layers.gd")
const Localization := preload("res://addons/spatial_toolkit/ui/editor_localization.gd")
const Roofs := preload("res://addons/spatial_toolkit/core/roof_styles.gd")

@export_storage var format_version := 1
@export_storage var layer_styles: Dictionary = {}
@export_storage var individual_materials: Dictionary = {}
@export_storage var facade_colors: Dictionary = {}
@export_storage var sky_mode: StringName = &"day"
@export_storage var sky_settings: SpatialSkySettings

var _applying := false


func seed_from_profile(profile: Resource) -> String:
	if profile == null:
		return ""
	var source := profile as AppearanceProfile
	if source == null:
		return Localization.translate("The selected resource must be a map appearance profile.")
	var error := source.validation_error()
	if not error.is_empty():
		return error
	for id: int in source.facade_materials:
		layer_styles[Layers.building_group_key(id)] = {"material": source.facade_materials[id]}
	for slot: int in source.ground_styles:
		var key := "FlatGround" if slot == Ground.BACKGROUND else "Landuse"
		var ground_rule: Dictionary = source.ground_styles[slot]
		var rule: Dictionary = layer_styles.get(key, {})
		var material: Variant = ground_rule.get("material")
		if material is Texture2D:
			var converted := StandardMaterial3D.new()
			converted.albedo_texture = material
			rule["material"] = converted
		elif material is Material:
			rule["material"] = material
		if ground_rule.get("color") is Color:
			rule["tint"] = ground_rule["color"]
		if not rule.is_empty():
			layer_styles[key] = rule
	if not source.roof_materials.is_empty():
		var variants: Array[SpatialLayerAppearance] = []
		for index in Roofs.PROFILE_VARIANT_COUNT:
			var variant := SpatialLayerAppearance.new()
			variant.material = source.roof_materials.get(index) as Material
			variants.append(variant)
		var rule: Dictionary = layer_styles.get("Buildings", {})
		rule["roof_variants"] = variants
		layer_styles["Buildings"] = rule
	for key: String in source.layer_styles:
		var merged: Dictionary = layer_styles.get(key, {})
		var rule: Dictionary = source.layer_styles[key].duplicate()
		rule.erase("visible")
		if rule.has("roof_variants"):
			rule["roof_variants"] = _copy_roofs(rule["roof_variants"])
			rule.erase("roof_material")
			merged.erase("roof_material")
		elif rule.has("roof_material"):
			merged.erase("roof_variants")
		if rule.has("window_style"):
			rule["window_style"] = (rule["window_style"] as SpatialWindowStyle).copy_for_storage()
		if rule.has("window_layout"):
			rule["window_layout"] = (rule["window_layout"] as SpatialWindowLayout).copy_for_storage()
		merged.merge(rule, true)
		if not merged.is_empty():
			layer_styles[key] = merged
	individual_materials = source.building_materials.duplicate()
	facade_colors = source.facade_colors.duplicate()
	sky_mode = source.sky_mode
	sky_settings = source.sky_settings.duplicate() as SpatialSkySettings if source.sky_settings != null else null
	return ""


func apply_to_map(map: Node3D) -> void:
	if map == null or _applying:
		return
	_applying = true
	if "sky_mode" in map and str(map.get("sky_mode")) != str(sky_mode):
		map.set("sky_mode", str(sky_mode))
	if "sky_settings" in map:
		var current := map.get("sky_settings") as SpatialSkySettings
		if sky_settings == null and current != null:
			map.set("sky_settings", null)
		elif sky_settings != null and not sky_settings.matches(current):
			map.set("sky_settings", sky_settings.duplicate() as SpatialSkySettings)
	for layer in Layers.style_nodes(map):
		if layer.style_key.is_empty():
			continue
		var rule: Dictionary = layer_styles.get(layer.style_key, {})
		layer.material = rule.get("material") as Material
		layer.override_tint = rule.has("tint")
		layer.tint = rule.get("tint", Color.WHITE)
		layer.texture_repeat_m = float(rule.get("texture_repeat_m", 0.0))
		if layer is SpatialBuildingLayer3D:
			var building_layer := layer as SpatialBuildingLayer3D
			building_layer.roof_material = rule.get("roof_material") as Material
			var roofs: Array = rule.get("roof_variants", [])
			if not _same_roofs(building_layer.roof_variants, roofs):
				building_layer.roof_variants = _copy_roofs(roofs)
			building_layer.facade_variation = float(rule.get("facade_variation", -1.0))
			building_layer.facade_weathering = float(rule.get("facade_weathering", -1.0))
			building_layer.set("decorative_windows", int(rule.get("decorative_windows", 0)))
			var style := rule.get("window_style") as SpatialWindowStyle
			if style == null:
				building_layer.window_style = null
			elif not style.matches(building_layer.window_style):
				building_layer.window_style = style.copy_for_storage()
			var layout := rule.get("window_layout") as SpatialWindowLayout
			if layout == null:
				building_layer.window_layout = null
			elif not layout.matches(building_layer.window_layout):
				building_layer.window_layout = layout.copy_for_storage()
	for building in Layers.buildings(map):
		if not building.has_meta("source_id"):
			continue
		var material := individual_materials.get(str(building.get_meta("source_id"))) as Material
		if material != null:
			building.set_meta(Groups.INDIVIDUAL, material)
		elif building.has_meta(Groups.INDIVIDUAL):
			building.remove_meta(Groups.INDIVIDUAL)
	_applying = false
	if map.is_inside_tree() and map.has_method("queue_layer_style_update"):
		map.call("queue_layer_style_update")


func set_layer_field(layer: SpatialLayer3D, field: StringName) -> Error:
	if _applying or layer.style_key.is_empty():
		return OK
	var key := layer.style_key
	var previous: Dictionary = layer_styles.get(key, {})
	var rule := previous.duplicate()
	var values := layer.style_values()
	var field_key := str(field)
	if field == &"roof_variants" or field == &"roof_material":
		rule.erase("roof_variants")
		rule.erase("roof_material")
		if values.has("roof_variants"):
			if previous.has("roof_variants") and _same_roofs(previous["roof_variants"], values["roof_variants"]):
				return OK
			rule["roof_variants"] = _copy_roofs(values["roof_variants"])
		elif values.has("roof_material"):
			rule["roof_material"] = values["roof_material"]
	elif field == &"window_style" and values.has(field_key):
		var style := values[field_key] as SpatialWindowStyle
		if style.matches(previous.get(field_key) as SpatialWindowStyle):
			return OK
		rule[field_key] = style.copy_for_storage()
	elif field == &"window_layout" and values.has(field_key):
		var layout := values[field_key] as SpatialWindowLayout
		if not layout.validation_error().is_empty():
			return ERR_INVALID_PARAMETER
		if layout.matches(previous.get(field_key) as SpatialWindowLayout):
			return OK
		rule[field_key] = layout.copy_for_storage()
	else:
		if field == &"override_tint":
			field_key = "tint"
		if values.has(field_key):
			rule[field_key] = values[field_key]
		else:
			rule.erase(field_key)
	if rule == previous:
		return OK
	_store_rule(key, rule)
	var error := _save()
	if error != OK:
		_store_rule(key, previous)
	emit_changed()
	return error


func set_individual_materials(changes: Dictionary) -> Error:
	if _applying:
		return OK
	var previous := individual_materials.duplicate()
	for identity: String in changes:
		var material: Variant = changes[identity]
		if identity.is_empty() or (material != null and not material is Material):
			individual_materials = previous
			return ERR_INVALID_PARAMETER
		if material == null:
			individual_materials.erase(identity)
		else:
			individual_materials[identity] = material
	if individual_materials == previous:
		return OK
	var error := _save()
	if error != OK:
		individual_materials = previous
	emit_changed()
	return error


func set_world_sky_mode(value: StringName) -> Error:
	if _applying or sky_mode == value:
		return OK
	if value != &"day" and value != &"night":
		return ERR_INVALID_PARAMETER
	var previous := sky_mode
	sky_mode = value
	var error := _save()
	if error != OK:
		sky_mode = previous
	emit_changed()
	return error

func set_world_sky_settings(value: SpatialSkySettings) -> Error:
	if _applying or (value == null and sky_settings == null) or (value != null and value.matches(sky_settings)):
		return OK
	var previous := sky_settings
	sky_settings = value.duplicate() as SpatialSkySettings if value != null else null
	var error := _save()
	if error != OK:
		sky_settings = previous
	emit_changed()
	return error


func _store_rule(key: String, rule: Dictionary) -> void:
	if rule.is_empty():
		layer_styles.erase(key)
	else:
		layer_styles[key] = rule


func _save() -> Error:
	if resource_path.is_empty():
		return OK
	var error := ResourceSaver.save(self, resource_path)
	if error != OK:
		push_error("Spatial: не удалось сохранить банк атрибутов %s (%s)." % [
			resource_path, error_string(error)])
	return error


func _copy_roofs(variants: Array) -> Array[SpatialLayerAppearance]:
	var copies: Array[SpatialLayerAppearance] = []
	for variant: SpatialLayerAppearance in variants:
		copies.append(variant.duplicate() as SpatialLayerAppearance if variant != null else null)
	return copies


func _same_roofs(first: Array, second: Array) -> bool:
	if first.size() != second.size():
		return false
	for index in first.size():
		var a := first[index] as SpatialLayerAppearance
		var b := second[index] as SpatialLayerAppearance
		if a == b:
			continue
		if a == null or b == null or a.material != b.material or a.tint != b.tint \
				or a.override_tint != b.override_tint or a.texture_repeat_m != b.texture_repeat_m:
			return false
	return true
