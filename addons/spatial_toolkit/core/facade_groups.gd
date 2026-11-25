@tool
extends RefCounted

const HEIGHT_LIMITS := [10.0, 24.0, 55.0]
const AREA_LIMITS := [250.0, 900.0, 2500.0]
const HEIGHT_LABELS := ["< 10", "10–24", "24–55", "55+"]
const AREA_LABELS := ["< 250", "250–900", "900–2500", "2500+"]
const GROUPS := &"facade_material_groups"
const INDIVIDUAL := &"facade_individual_material"

static func group_id(building: MeshInstance3D) -> int:
	var scale_factor := maxf(0.001, float(building.get_meta("world_scale", 1.0)))
	var extent := building.get_aabb().size / scale_factor
	var source: Dictionary = building.get_meta("source_dimensions_m", {})
	var height := float(source.get("height_m", extent.y))
	return _bucket(height, HEIGHT_LIMITS) * AREA_LABELS.size() \
		+ _bucket(extent.x * extent.z, AREA_LIMITS)

static func _bucket(value: float, limits: Array) -> int:
	for index in limits.size():
		if value < limits[index]:
			return index
	return limits.size()

static func label(id: int) -> String:
	return "%s м · %s м²" % [HEIGHT_LABELS[id / AREA_LABELS.size()], AREA_LABELS[id % AREA_LABELS.size()]]

static func selected_material(map: Node3D, building: MeshInstance3D) -> Material:
	var individual := building.get_meta(INDIVIDUAL, null) as Material if building.has_meta(INDIVIDUAL) else null
	if individual != null:
		return individual
	var groups: Dictionary = map.get_meta(GROUPS, {})
	return groups.get(group_id(building)) as Material
