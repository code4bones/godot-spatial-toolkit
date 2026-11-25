@tool
extends Resource
## Portable editor assignments. Generated meshes and per-map preview scripts stay in the scene.

const VERSION := 1
const Groups := preload("res://addons/spatial_toolkit/core/facade_groups.gd")
const Colors := preload("res://addons/spatial_toolkit/core/facade_colors.gd")
const Ground := preload("res://addons/spatial_toolkit/core/ground_styles.gd")
const Roofs := preload("res://addons/spatial_toolkit/core/roof_styles.gd")
const Style := preload("res://addons/spatial_toolkit/core/map_style_module.gd")
const Night := preload("res://addons/spatial_toolkit/runtime/night_city_style.gd")

@export_storage var format_version := 0
@export_storage var facade_materials: Dictionary = {}
@export_storage var facade_colors: Dictionary = {}
@export_storage var building_materials: Dictionary = {}
@export_storage var roof_materials: Dictionary = {}
@export_storage var ground_styles: Dictionary = {}
@export_storage var sky_mode: StringName = Night.DAY

func capture(map: Node3D) -> void:
	format_version = VERSION
	facade_materials = map.get_meta(Groups.GROUPS, {}).duplicate(true)
	facade_colors = map.get_meta(Colors.RULES, {}).duplicate(true)
	roof_materials = map.get_meta(Roofs.SLOTS, {}).duplicate(true)
	ground_styles = map.get_meta(Ground.RULES, {}).duplicate(true)
	sky_mode = Night.mode_for(map)
	building_materials.clear()
	var buildings := map.get_node_or_null("Generated/Buildings")
	if buildings != null:
		for node in buildings.get_children():
			if node is MeshInstance3D and node.has_meta(Groups.INDIVIDUAL):
				var id := str(node.get_meta("source_id", ""))
				if not id.is_empty():
					building_materials[id] = node.get_meta(Groups.INDIVIDUAL)

func validation_error() -> String:
	if format_version != VERSION:
		return "Версия профиля оформления не поддерживается · %d" % format_version
	if sky_mode not in [Night.DAY, Night.NIGHT]:
		return "Некорректный режим неба в профиле оформления."
	if not _valid_material_slots(facade_materials, Groups.AREA_LABELS.size() * Groups.HEIGHT_LABELS.size()) \
			or not _valid_material_slots(roof_materials, Roofs.DEFAULTS.size()):
		return "Некорректные материалы групп фасадов или крыш в профиле."
	for id in building_materials:
		if not id is String or id.is_empty() or not building_materials[id] is Material:
			return "Некорректное назначение материала отдельному зданию."
	for type in facade_colors:
		if not type is String or type.is_empty() or not facade_colors[type] is Color:
			return "Некорректный цвет фасада в профиле."
	for slot in ground_styles:
		if not slot is int or slot < 0 or slot >= Ground.LABELS.size() or not ground_styles[slot] is Dictionary:
			return "Некорректная группа поверхностей земли в профиле."
		var rule: Dictionary = ground_styles[slot]
		var material: Variant = rule.get("material")
		var tint: Variant = rule.get("color")
		if (material != null and (not material is Resource or not Ground.supports_material(material))) \
				or (tint != null and not tint is Color):
			return "Некорректный материал или цвет земли в профиле."
	return ""

func requires_daylight() -> bool:
	return not facade_materials.is_empty() or not facade_colors.is_empty() \
			or not building_materials.is_empty() or not roof_materials.is_empty()

func _valid_material_slots(rules: Dictionary, count: int) -> bool:
	for slot in rules:
		if not slot is int or slot < 0 or slot >= count or not rules[slot] is Material:
			return false
	return true

func apply_to_new_map(map: Node3D) -> Dictionary:
	map.set_meta(Night.MODE, sky_mode)
	for entry in [[Groups.GROUPS, facade_materials], [Colors.RULES, facade_colors],
			[Roofs.SLOTS, roof_materials], [Ground.RULES, ground_styles]]:
		if not entry[1].is_empty():
			map.set_meta(entry[0], entry[1].duplicate(true))
	var remaining := building_materials.duplicate()
	var facade_count := 0
	var roof_count := 0
	var buildings := map.get_node_or_null("Generated/Buildings")
	if buildings != null:
		for node in buildings.get_children():
			var building := node as MeshInstance3D
			if building == null or building.mesh == null:
				continue
			var source_id := str(building.get_meta("source_id", ""))
			if building_materials.has(source_id):
				building.set_meta(Groups.INDIVIDUAL, building_materials[source_id])
				remaining.erase(source_id)
			var actual := Groups.selected_material(map, building)
			if actual != null:
				var facade_updates := Style.facade_updates(building, actual)
				facade_count += int(not facade_updates.is_empty())
				for update in facade_updates:
					building.set(update["property"], update["material"])
			var roof := roof_materials.get(Roofs.variant_id(building)) as Material
			if roof != null:
				var roof_updates := Roofs.updates(building, roof)
				roof_count += int(not roof_updates.is_empty())
				for update in roof_updates:
					building.set(update["property"], update["material"])
	var colors_by_type := Colors.groups(map) if not facade_colors.is_empty() else {}
	for type in facade_colors:
		for change in Colors.changes(colors_by_type.get(type, []), facade_colors[type]):
			change["building"].set(change["property"], change["material"])
	var scale_factor := float(map.get_meta("world_scale", 1.0))
	var ground_count := 0
	for slot: int in ground_styles:
		var rule: Dictionary = ground_styles[slot]
		var overrides := Ground.surface_overrides(Ground.targets(map, slot), slot,
			rule.get("material"), rule.get("color"), scale_factor)
		for mesh: MeshInstance3D in overrides:
			mesh.material_override = overrides[mesh]
		ground_count += overrides.size()
	var missing := remaining.keys()
	missing.sort()
	return {"path": resource_path, "format_version": format_version, "facades": facade_count,
		"roofs": roof_count, "ground_surfaces": ground_count, "sky_mode": str(sky_mode),
		"matched_building_materials": building_materials.size() - missing.size(),
		"unmatched_building_ids": missing}
