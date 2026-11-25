extends RefCounted
## Screen-space labels for the overview camera, sourced from rendered OSM features.

const STREET_FONT_SIZE := 15
const HOUSE_FONT_SIZE := 13
const HOUSE_MAX_METRES_PER_PIXEL := 1.0
const MAX_STREET_LABELS := 24
const MAX_HOUSE_LABELS := 100
const ROAD_PRIORITY := {
	"motorway": 8, "trunk": 7, "primary": 6, "secondary": 5, "tertiary": 4,
	"unclassified": 3, "residential": 3, "living_street": 2, "service": 1,
}
const STREET_COLOR := Color("fff3cf")
const HOUSE_COLOR := Color("f3f8fb")
const HALO_COLOR := Color("14212d")
const STREET_OFFSETS := [Vector2.ZERO, Vector2(0, -23), Vector2(0, 23)]

var _streets: Array[Dictionary] = []
var _houses: Array[Dictionary] = []
var _labels: Array[Dictionary] = []
var _font := ThemeDB.fallback_font
var _widths := {}
var _view_key: Array = []

func collect(map: Node3D, ground: Node3D, world_scale: float) -> void:
	var roads := {}
	for layer_path in ["Generated/Roads", "Generated/Paths"]:
		var layer := map.get_node_or_null(layer_path)
		if layer == null:
			continue
		for node in layer.get_children():
			var mesh := node as MeshInstance3D
			var tags := _source_tags(mesh)
			var street := _tag_text(tags, "name")
			if street.is_empty():
				continue
			roads[str(mesh.get_meta("source_id", mesh.name))] = {
				"text": street, "mesh": mesh, "priority": ROAD_PRIORITY.get(tags.get("highway"), 0),
			}
	_collect_streets(map, ground, world_scale, roads)
	var buildings := map.get_node_or_null("Generated/Buildings")
	if buildings == null:
		return
	for node in buildings.get_children():
		var mesh := node as MeshInstance3D
		var number := _tag_text(_source_tags(mesh), "addr:housenumber")
		if number.is_empty():
			continue
		var bounds := mesh.get_aabb()
		var roof := bounds.get_center()
		roof.y = bounds.end.y
		_houses.append({
			"text": number, "point": mesh.to_global(roof),
			"priority": bounds.size.x * bounds.size.z, "id": str(mesh.get_meta("source_id", mesh.name)),
		})

func _collect_streets(map: Node3D, ground: Node3D, world_scale: float, roads: Dictionary) -> void:
	var features: Array = []
	if not roads.is_empty() and not map.scene_file_path.is_empty():
		var path := map.scene_file_path.get_base_dir().path_join("export_preview.spatial.json")
		if FileAccess.file_exists(path):
			var model: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
			if model is Dictionary and model.get("features") is Array:
				features = model["features"]
	for entry in features:
		if not entry is Dictionary:
			continue
		var id := str(entry.get("id", ""))
		var geometry: Variant = entry.get("geometry")
		if not roads.has(id) or not geometry is Dictionary or geometry.get("type") != "LineString":
			continue
		var points := PackedVector3Array()
		for pair in geometry.get("coordinates", []):
			if pair is Array and pair.size() >= 2:
				var point := map.to_global(Vector3(float(pair[0]) * world_scale, 0.0, float(pair[1]) * world_scale))
				point.y = ground.global_position.y
				if point.is_finite():
					points.append(point)
		if points.size() >= 2:
			_add_street(id, roads[id], points)
			roads.erase(id)
	for id: String in roads:
		var mesh: MeshInstance3D = roads[id]["mesh"]
		_add_street(id, roads[id], PackedVector3Array([_road_mesh_anchor(mesh)]))

func _add_street(id: String, road: Dictionary, points: PackedVector3Array) -> void:
	_streets.append({"id": id, "text": road["text"], "points": points, "priority": road["priority"]})

func _road_mesh_anchor(mesh: MeshInstance3D) -> Vector3:
	var center := mesh.get_aabb().get_center()
	var faces := mesh.mesh.get_faces()
	var nearest := center
	var distance := INF
	for index in range(0, faces.size(), 3):
		var point := (faces[index] + faces[index + 1] + faces[index + 2]) / 3.0
		var squared := point.distance_squared_to(center)
		if squared < distance:
			distance = squared
			nearest = point
	return mesh.to_global(nearest)

func _source_tags(mesh: MeshInstance3D) -> Dictionary:
	if mesh == null or mesh.mesh == null or not mesh.visible:
		return {}
	var tags: Variant = mesh.get_meta("source_tags", {})
	return tags if tags is Dictionary else {}

func _tag_text(tags: Dictionary, key: String) -> String:
	var value: Variant = tags.get(key)
	return str(value).strip_edges() if value is String or value is int else ""

func draw(canvas: Control, camera: Camera3D, world_scale: float, reserved: Array[Rect2]) -> void:
	var key := [camera.global_transform, camera.size, camera.keep_aspect, canvas.size, reserved]
	if key != _view_key:
		_view_key = key
		_layout(camera, canvas.size, world_scale, reserved)
	for label in _labels:
		var text: String = label["text"]
		var text_size: int = label["font_size"]
		var baseline: Vector2 = label["baseline"]
		var street := text_size == STREET_FONT_SIZE
		if street and label.has("leader"):
			var line: Vector2 = label["leader"]
			var rect: Rect2 = label["rect"]
			var end := Vector2(line.x, clampf(line.y, rect.position.y, rect.end.y))
			canvas.draw_line(line, end, HALO_COLOR, 3.0, true)
			canvas.draw_line(line, end, STREET_COLOR, 1.0, true)
		canvas.draw_string_outline(_font, baseline, text, HORIZONTAL_ALIGNMENT_LEFT, -1,
			text_size, 5 if street else 4, HALO_COLOR)
		canvas.draw_string(_font, baseline, text, HORIZONTAL_ALIGNMENT_LEFT, -1,
			text_size, STREET_COLOR if street else HOUSE_COLOR)

func _layout(camera: Camera3D, screen_size: Vector2, world_scale: float, reserved: Array[Rect2] = []) -> void:
	_labels.clear()
	var viewport := Rect2(Vector2.ZERO, screen_size).grow(-8.0)
	if not viewport.has_area():
		return
	var street_candidates: Array[Dictionary] = []
	for street in _streets:
		var text: String = street["text"]
		var width := _text_width(text, STREET_FONT_SIZE)
		var center := _street_point(camera, street["points"], viewport, width)
		if not center.is_finite():
			continue
		street_candidates.append(_candidate(text, STREET_FONT_SIZE, width, center,
			street["priority"], street["id"], viewport.get_center()))
	_place_candidates(street_candidates, MAX_STREET_LABELS, true, viewport, reserved)
	var pixels := screen_size.x if camera.keep_aspect == Camera3D.KEEP_WIDTH else screen_size.y
	if camera.size / maxf(pixels * world_scale, 1.0) > HOUSE_MAX_METRES_PER_PIXEL:
		return
	var house_candidates: Array[Dictionary] = []
	for house in _houses:
		var point: Vector3 = house["point"]
		if camera.is_position_behind(point):
			continue
		var anchor := camera.unproject_position(point)
		var priority: float = house["priority"]
		for marker in reserved:
			if marker.grow(3.0).has_point(anchor):
				priority = maxf(priority, 1.0e10 - anchor.distance_squared_to(marker.get_center()) * 1000.0)
		var center := anchor + Vector2(0.0, -10.0)
		var text: String = house["text"]
		var candidate := _candidate(text, HOUSE_FONT_SIZE, _text_width(text, HOUSE_FONT_SIZE),
			center, priority, house["id"], viewport.get_center())
		if viewport.encloses(candidate["rect"]):
			house_candidates.append(candidate)
	_place_candidates(house_candidates, MAX_HOUSE_LABELS, false, viewport, reserved)

func _street_point(camera: Camera3D, points: PackedVector3Array, viewport: Rect2, width: float) -> Vector2:
	var anchors := viewport.grow_individual(-width * 0.5 - 4.0, -12.0, -width * 0.5 - 4.0, -12.0)
	if not anchors.has_area() or points.is_empty():
		return Vector2.INF
	var middle := anchors.get_center()
	var result := Vector2.INF
	var distance := INF
	var previous := camera.unproject_position(points[0])
	if points.size() == 1:
		return previous if anchors.has_point(previous) and not camera.is_position_behind(points[0]) else result
	for index in range(1, points.size()):
		var current := camera.unproject_position(points[index])
		if not camera.is_position_behind(points[index - 1]) and not camera.is_position_behind(points[index]):
			var closest := Geometry2D.get_closest_point_to_segment(middle, previous, current)
			var squared := closest.distance_squared_to(middle)
			if anchors.has_point(closest) and squared < distance:
				result = closest
				distance = squared
		previous = current
	return result

func _text_width(text: String, text_size: int) -> float:
	if not _widths.has(text_size):
		_widths[text_size] = {}
	var cache: Dictionary = _widths[text_size]
	if not cache.has(text):
		cache[text] = _font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, text_size).x
	return cache[text]

func _candidate(text: String, text_size: int, width: float, center: Vector2, priority: float,
		id: String, view_center: Vector2) -> Dictionary:
	var height := _font.get_height(text_size)
	var top_left := center - Vector2(width, height) * 0.5
	return {"text": text, "font_size": text_size, "priority": priority, "id": id,
		"distance": center.distance_squared_to(view_center),
		"rect": Rect2(top_left, Vector2(width, height)).grow(4.0),
		"baseline": top_left + Vector2(0.0, _font.get_ascent(text_size))}

func _place_candidates(candidates: Array[Dictionary], limit: int, street: bool,
		viewport: Rect2, reserved: Array[Rect2]) -> void:
	candidates.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		if a["priority"] != b["priority"]:
			return a["priority"] > b["priority"]
		if a["distance"] != b["distance"]:
			return a["distance"] < b["distance"]
		return a["id"] < b["id"])
	var shown := {}
	var count := 0
	for candidate in candidates:
		var text: String = candidate["text"]
		if street and shown.has(text):
			continue
		var offsets := STREET_OFFSETS if street else [Vector2.ZERO]
		if not street and reserved.any(func(marker: Rect2) -> bool: return marker.intersects(candidate["rect"])):
			offsets = [Vector2(0.0, -12.0)]
		var placed := _place_candidate(candidate, offsets, viewport, reserved)
		if not placed:
			continue
		if street:
			shown[text] = true
		count += 1
		if count >= limit:
			break

func _place_candidate(candidate: Dictionary, offsets: Array, viewport: Rect2, reserved: Array[Rect2]) -> bool:
	var bounds: Rect2 = candidate["rect"]
	for offset: Vector2 in offsets:
		var rect := Rect2(bounds.position + offset, bounds.size)
		if not viewport.encloses(rect) or reserved.any(func(marker: Rect2) -> bool: return rect.intersects(marker)) \
				or _labels.any(func(label: Dictionary) -> bool: return rect.intersects(label["rect"])):
			continue
		candidate["rect"] = rect
		candidate["baseline"] += offset
		if not offset.is_zero_approx():
			candidate["leader"] = bounds.get_center()
		_labels.append(candidate)
		return true
	return false
