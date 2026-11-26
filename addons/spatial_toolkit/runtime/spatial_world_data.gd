@tool
class_name SpatialWorldData
extends RefCounted
## Logical world data in map-local gameplay metres. Use map.to_global() for scene coordinates.
## Load explicitly when gameplay needs roads or buildings.

const DEFAULT_FILE := "world_data.json"

var data: Dictionary = {}
var source_path := ""

static func load_for_map(map: Node3D) -> SpatialWorldData:
	if map == null:
		return null
	var directory := map.scene_file_path.get_base_dir()
	var declared: Variant = map.get_meta("world_data_path", "")
	var path := str(declared) if declared is String else ""
	if not path.is_empty() and not path.is_absolute_path():
		path = directory.path_join(path) if not directory.is_empty() else ""
	# A copied scene uses the sidecar next to it even when its metadata names the old folder.
	var sibling := directory.path_join(DEFAULT_FILE) if not directory.is_empty() else ""
	if (path.is_empty() or path.get_file() == DEFAULT_FILE) and FileAccess.file_exists(sibling):
		path = sibling
	if path.is_empty() or not FileAccess.file_exists(path):
		path = sibling
	return load_file(path)

static func load_file(path: String) -> SpatialWorldData:
	if path.strip_edges().is_empty() or not FileAccess.file_exists(path):
		return null
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		push_warning("Spatial Toolkit could not read world data: " + path)
		return null
	var parser := JSON.new()
	if parser.parse(file.get_as_text()) != OK or not parser.data is Dictionary:
		push_warning("Spatial Toolkit world data is not a JSON object: " + path)
		return null
	var decoded: Dictionary = parser.data
	var axes: Variant = decoded.get("axes")
	if decoded.get("schema") != 1 or decoded.get("units") != "gameplay_meters" \
			or not decoded.get("roads") is Dictionary or not decoded.get("buildings") is Dictionary \
			or not axes is Dictionary or axes.get("x") != "east" \
			or axes.get("y") != "up" or axes.get("z") != "south" \
			or not _finite_number(decoded.get("world_scale")) or float(decoded["world_scale"]) <= 0.0:
		push_warning("Spatial Toolkit world data has an unsupported schema or coordinate system: " + path)
		return null
	var result := SpatialWorldData.new()
	result.data = decoded
	result.source_path = path.simplify_path()
	return result

func road_ids() -> PackedStringArray:
	return _ids("roads")

func building_ids() -> PackedStringArray:
	return _ids("buildings")

func get_road(source_id: String) -> Dictionary:
	return _record("roads", source_id)

func get_building(source_id: String) -> Dictionary:
	return _record("buildings", source_id)

func road_points(source_id: String) -> PackedVector3Array:
	var coordinates: Variant = get_road(source_id).get("points")
	var result := PackedVector3Array()
	if not coordinates is Array:
		return result
	for coordinate: Variant in coordinates:
		if not coordinate is Array or coordinate.size() != 3 \
				or not _finite_number(coordinate[0]) or not _finite_number(coordinate[1]) \
				or not _finite_number(coordinate[2]):
			return PackedVector3Array()
		var point := Vector3(coordinate[0], coordinate[1], coordinate[2])
		if not point.is_finite():
			return PackedVector3Array()
		result.append(point)
	return result

func building_bounds(source_id: String) -> AABB:
	var bounds: Variant = get_building(source_id).get("bounds")
	if not bounds is Array or bounds.size() != 6:
		return AABB()
	for component: Variant in bounds:
		if not _finite_number(component):
			return AABB()
	var minimum := Vector3(bounds[0], bounds[1], bounds[2])
	var maximum := Vector3(bounds[3], bounds[4], bounds[5])
	if not minimum.is_finite() or not maximum.is_finite() or not (maximum - minimum).is_finite() \
			or maximum.x < minimum.x or maximum.y < minimum.y or maximum.z < minimum.z:
		return AABB()
	return AABB(minimum, maximum - minimum)

func _ids(section: String) -> PackedStringArray:
	var records: Variant = data.get(section, {})
	var result := PackedStringArray()
	if records is Dictionary:
		for source_id: Variant in records:
			if source_id is String:
				result.append(source_id)
	result.sort()
	return result

func _record(section: String, source_id: String) -> Dictionary:
	var records: Variant = data.get(section, {})
	var record: Variant = records.get(source_id) if records is Dictionary else null
	return record if record is Dictionary else {}

static func _finite_number(value: Variant) -> bool:
	return (value is int or value is float) and is_finite(float(value))
