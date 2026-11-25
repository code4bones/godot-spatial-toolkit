@tool
extends RefCounted

const Mercator := preload("map_projection.gd")

var paths: Array[Dictionary] = []
var bounds := Rect2()
var feature_count := 0
var skipped := 0
var error := ""

func read(path: String) -> void:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		error = "Could not open GeoJSON (%s)." % error_string(FileAccess.get_open_error())
		return
	var json := JSON.new()
	if json.parse(file.get_as_text()) != OK:
		error = "Invalid JSON on line %d: %s" % [json.get_error_line(), json.get_error_message()]
		return
	var data: Variant = json.data
	if not data is Dictionary:
		error = "Expected a GeoJSON object."
		return
	if data.get("type") == "FeatureCollection":
		var features: Variant = data.get("features")
		if not features is Array:
			error = "Expected an array of GeoJSON features."
			return
		for feature: Variant in features:
			_add_feature(feature)
	else:
		_add_feature(data)
	if paths.is_empty():
		error = "No valid polygon or line geometry found."

func _add_feature(feature: Variant) -> void:
	var before := paths.size()
	if feature is Dictionary:
		_add_geometry(feature.get("geometry") if feature.get("type") == "Feature" else feature)
	if paths.size() > before:
		feature_count += 1
	else:
		skipped += 1

func _add_geometry(geometry: Variant) -> void:
	if not geometry is Dictionary:
		return
	var coordinates: Variant = geometry.get("coordinates")
	if not coordinates is Array:
		return
	match geometry.get("type"):
		"LineString":
			_add_path(coordinates, false)
		"MultiLineString", "Polygon":
			for part: Variant in coordinates:
				_add_path(part, geometry.get("type") == "Polygon")
		"MultiPolygon":
			for polygon: Variant in coordinates:
				if polygon is Array:
					for ring: Variant in polygon:
						_add_path(ring, true)

func _add_path(coordinates: Variant, closed: bool) -> void:
	if not coordinates is Array or coordinates.size() < (4 if closed else 2):
		return
	if closed and coordinates.front() != coordinates.back():
		return
	var points := PackedVector2Array()
	points.resize(coordinates.size())
	var origin_x := 0.0
	var origin_y := 0.0
	var previous_x := 0.0
	var path_bounds := Rect2()
	for index in coordinates.size():
		var coordinate: Variant = coordinates[index]
		if not coordinate is Array or coordinate.size() < 2:
			return
		if not (coordinate[0] is float or coordinate[0] is int) or not (
				coordinate[1] is float or coordinate[1] is int):
			return
		var longitude: float = coordinate[0]
		var latitude: float = coordinate[1]
		if not is_finite(longitude) or not is_finite(latitude) or absf(longitude) > 180.0 or absf(latitude) > 90.0:
			return
		var x := Mercator.longitude_to_x(longitude)
		var y := Mercator.latitude_to_y(latitude)
		var projected := Vector2(x, y)
		if index == 0:
			origin_x = x
			origin_y = y
			path_bounds = Rect2(projected, Vector2.ZERO)
		else:
			path_bounds = path_bounds.expand(projected)
			# Draw the short segment across the seam and wrap the result on screen.
			if absf(x - previous_x) > 0.5 and absf(x - previous_x) < 1.0:
				x += roundf(previous_x - x)
			elif previous_x < 0.0 or previous_x > 1.0:
				x += roundf(previous_x - x)
		previous_x = x
		points[index] = Vector2(x - origin_x, y - origin_y)
	var local_bounds := Rect2(points[0], Vector2.ZERO)
	for point in points:
		local_bounds = local_bounds.expand(point)
	bounds = path_bounds if paths.is_empty() else bounds.merge(path_bounds)
	paths.append({"x": origin_x, "y": origin_y, "points": points, "bounds": local_bounds})
