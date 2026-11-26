@tool
extends RefCounted

const Settings := preload("res://addons/spatial_toolkit/core/spatial_project_settings.gd")
const BUCKET_COUNT := 4
const RULES := &"osm_rules"
const GROUPS := &"facade_material_groups"
const INDIVIDUAL := &"facade_individual_material"

static func group_id(building: MeshInstance3D, rules: Dictionary = {}) -> int:
	if rules.is_empty():
		rules = rules_for(building)
	var scale_factor := maxf(0.001, float(building.get_meta("world_scale", 1.0)))
	var extent := building.get_aabb().size / scale_factor
	var source: Dictionary = building.get_meta("source_dimensions_m", {})
	var height := float(source.get("height_m", extent.y))
	return _bucket(height, _height_limits(rules)) * BUCKET_COUNT \
		+ _bucket(extent.x * extent.z, _area_limits(rules))

static func rules_for(node: Node) -> Dictionary:
	if node.owner == null:
		return {}
	var generated := node.owner.get_node_or_null("Generated")
	var value: Variant = generated.get_meta(RULES, {}) if generated != null else {}
	return value if value is Dictionary else {}

static func _height_limits(rules: Dictionary) -> Array:
	return _limits(rules.get("building_height_limits_m"), Settings.OSM_HEIGHT_LIMITS.values())

static func _area_limits(rules: Dictionary) -> Array:
	return _limits(rules.get("building_area_limits_m2"), Settings.OSM_AREA_LIMITS.values())

static func _limits(values: Variant, defaults: Array) -> Array:
	if not values is Array or values.size() != BUCKET_COUNT - 1:
		return defaults
	var previous := 0.0
	for value: Variant in values:
		if not (value is float or value is int) or not is_finite(float(value)) or float(value) <= previous:
			return defaults
		previous = float(value)
	return values

static func _bucket(value: float, limits: Array) -> int:
	for index in limits.size():
		if value < limits[index]:
			return index
	return limits.size()

static func height_label(index: int, rules: Dictionary) -> String:
	return _range_label(index, _height_limits(rules))

static func area_label(index: int, rules: Dictionary) -> String:
	return _range_label(index, _area_limits(rules))

static func _range_label(index: int, limits: Array) -> String:
	if index == 0:
		return "< " + _format_limit(limits[0])
	var lower := _format_limit(limits[index - 1])
	return lower + "+" if index == limits.size() else lower + "–" + _format_limit(limits[index])

static func _format_limit(value: float) -> String:
	return String.num(value).trim_suffix(".0")

static func label(id: int, rules: Dictionary = {}) -> String:
	@warning_ignore("integer_division")
	return "%s м · %s м²" % [height_label(id / BUCKET_COUNT, rules), area_label(id % BUCKET_COUNT, rules)]

static func selected_material(map: Node3D, building: MeshInstance3D) -> Material:
	var individual := building.get_meta(INDIVIDUAL, null) as Material if building.has_meta(INDIVIDUAL) else null
	if individual != null:
		return individual
	var groups: Dictionary = map.get_meta(GROUPS, {})
	return groups.get(group_id(building)) as Material
