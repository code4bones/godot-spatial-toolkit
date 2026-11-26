extends RefCounted
## Places ground fixtures beside rendered vehicle roads in projected source metres.

const Layers := preload("res://addons/spatial_toolkit/core/spatial_layers.gd")
const GRID_M := 40.0
const PITCH_M := 27.0
const SERVICE_PITCH_M := 54.0
const MIN_ROAD_LENGTH_M := 12.0
const MIN_SERVICE_LENGTH_M := 40.0
const MIN_LAMP_DISTANCE_M := 13.0
const SHOULDER_M := 1.45
const ROAD_MARGIN_M := 0.65
const WALL_MARGIN_M := 1.1
const WATER_MARGIN_M := 1.5
const CONDUIT_MARGIN_M := 2.6
const JUNCTION_MARGIN_M := 4.0
const DIVIDED_ROAD_RANGE_M := 15.0
const ROAD_PRIORITY := {
	"primary": 0, "secondary": 1, "tertiary": 2, "unclassified": 3,
	"residential": 3, "living_street": 3, "service": 4,
}

static func build(map: Node3D, features: Array, world_scale: float, pitch_m := PITCH_M,
		service_pitch_m := SERVICE_PITCH_M, minimum_gap_m := MIN_LAMP_DISTANCE_M) -> Array[Dictionary]:
	var lamps: Array[Dictionary] = []
	if map == null or world_scale <= 0.0:
		return lamps
	var road_ids := _rendered_ids(map.get_node_or_null("Generated/Roads"), true)
	if road_ids.is_empty():
		return lamps
	var conduits := map.get_node_or_null("StyleLayer/PathConduits") as Node3D
	var uses_conduits := conduits != null and conduits.visible
	var conduit_margin := CONDUIT_MARGIN_M
	if uses_conduits and conduits.has_method("clearance_for_lamps"):
		conduit_margin = float(conduits.call("clearance_for_lamps", CONDUIT_MARGIN_M))
	# The conduit overlay hides source paths after generating the pipes and fences.
	var path_ids := _rendered_ids(map.get_node_or_null("Generated/Paths"), not uses_conduits)
	var clearances := _load_clearances(map.scene_file_path.get_base_dir()) if uses_conduits else {}
	var road_cuts: Dictionary = clearances.get("roads", {})
	var path_cuts: Dictionary = clearances.get("paths", {})
	var edges := {}
	var polygons := {}
	var routes: Array[Dictionary] = []
	for feature: Dictionary in features:
		var id := str(feature.get("id", ""))
		var kind := str(feature.get("kind", ""))
		var geometry: Dictionary = feature.get("geometry", {})
		var geometry_type := str(geometry.get("type", ""))
		var coordinates: Array = geometry.get("coordinates", [])
		if kind in ["building", "water"]:
			var margin := WALL_MARGIN_M if kind == "building" else WATER_MARGIN_M
			if geometry_type == "Polygon":
				_index_polygon(edges, polygons, coordinates, margin)
			elif geometry_type == "MultiPolygon":
				for polygon: Array in coordinates:
					_index_polygon(edges, polygons, polygon, margin)
		elif kind == "road" and geometry_type == "LineString":
			var half_width := float(feature.get("width_m", 2.0)) * 0.5
			if road_ids.has(id) and not (road_cuts.has(id) and road_cuts[id].is_empty()):
				var tags: Dictionary = feature.get("source", {}).get("tags", {})
				var street := str(tags.get("name", "")).strip_edges().to_lower()
				var highway := str(tags.get("highway", ""))
				var route := {"id": id, "street": street, "highway": highway, "half_width": half_width,
					"oneway": str(tags.get("oneway", "")) in ["yes", "1", "-1"]}
				var points := _points(coordinates)
				_index_line(edges, points, half_width + ROAD_MARGIN_M, route)
				if _eligible(feature, tags, highway, half_width):
					route["line"] = points
					route["rank"] = int(ROAD_PRIORITY[highway]) * 2 + int(street.is_empty())
					routes.append(route)
			elif path_ids.has(id):
				var path_radius := conduit_margin if uses_conduits else half_width + ROAD_MARGIN_M
				for run: Array in path_cuts.get(id, [coordinates]):
					_index_line(edges, _points(run), path_radius)
	routes.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return a["id"] < b["id"] if a["rank"] == b["rank"] else a["rank"] < b["rank"])
	var occupied := {}
	for route: Dictionary in routes:
		var pitch := service_pitch_m if route["highway"] == "service" else pitch_m
		_place_route(lamps, route, road_cuts, edges, polygons, occupied, pitch, minimum_gap_m)
	return lamps

static func _rendered_ids(container: Node, visible_only: bool) -> Dictionary:
	var ids := {}
	for mesh in Layers.meshes(container):
		# Conduits hide their source meshes. Their parent groups still control
		# which paths can have an overlay to reserve space for.
		var visible_node: Node3D = mesh if visible_only else mesh.get_parent() as Node3D
		if mesh.has_meta("source_id") and visible_node.is_visible_in_tree():
			ids[str(mesh.get_meta("source_id"))] = true
	return ids

static func _load_clearances(directory: String) -> Dictionary:
	var path := directory.path_join("building_clearances.json")
	if not FileAccess.file_exists(path):
		return {}
	var value: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	return value if value is Dictionary and value.get("version") == 1 else {}

static func _eligible(feature: Dictionary, tags: Dictionary, highway: String, half_width: float) -> bool:
	return str(feature.get("id", "")).begins_with("way/") and half_width >= 1.2 \
		and feature.get("status", "existing") == "existing" and ROAD_PRIORITY.has(highway) \
		and str(tags.get("bridge", "no")) == "no" and str(tags.get("tunnel", "no")) == "no" \
		and tags.get("access", "") not in ["no", "customers"] \
		and tags.get("service", "") not in ["parking_aisle", "driveway", "drive-through"] \
		and tags.get("junction", "") not in ["roundabout", "circular"]

static func _points(coordinates: Array) -> PackedVector2Array:
	var points := PackedVector2Array()
	for coordinate: Array in coordinates:
		var point := Vector2(float(coordinate[0]), float(coordinate[1]))
		if points.is_empty() or not points[-1].is_equal_approx(point):
			points.append(point)
	return points

static func _index_line(cells: Dictionary, line: PackedVector2Array, radius: float,
		road: Dictionary = {}) -> void:
	for index in range(1, line.size()):
		_index_edge(cells, line[index - 1], line[index], radius, road)

static func _index_edge(cells: Dictionary, a: Vector2, b: Vector2, radius: float,
		road: Dictionary = {}) -> void:
	var padding := radius if road.is_empty() else maxf(radius + JUNCTION_MARGIN_M, DIVIDED_ROAD_RANGE_M)
	var bounds := Rect2(a, Vector2.ZERO).expand(b).grow(padding)
	_index(cells, bounds, {"a": a, "b": b, "radius": radius, "road": road})

static func _index_polygon(edges: Dictionary, polygons: Dictionary, coordinates: Array, margin: float) -> void:
	var rings: Array[PackedVector2Array] = []
	for ring: Array in coordinates:
		var points := _points(ring)
		if points.size() > 1 and points[0].is_equal_approx(points[-1]):
			points.resize(points.size() - 1)
		if points.size() < 3:
			continue
		rings.append(points)
		for index in points.size():
			_index_edge(edges, points[index], points[(index + 1) % points.size()], margin)
	if rings.is_empty():
		return
	var bounds := Rect2(rings[0][0], Vector2.ZERO)
	for point: Vector2 in rings[0]:
		bounds = bounds.expand(point)
	_index(polygons, bounds, rings)

static func _cell(point: Vector2) -> Vector2i:
	return Vector2i(floori(point.x / GRID_M), floori(point.y / GRID_M))

static func _index(cells: Dictionary, bounds: Rect2, item: Variant) -> void:
	var first := _cell(bounds.position)
	var last := _cell(bounds.end)
	for x in range(first.x, last.x + 1):
		for z in range(first.y, last.y + 1):
			cells.get_or_add(Vector2i(x, z), []).append(item)

static func _place_route(lamps: Array[Dictionary], route: Dictionary, cuts: Dictionary,
		edges: Dictionary, polygons: Dictionary, occupied: Dictionary, pitch_m: float,
		minimum_gap_m: float) -> void:
	var line: PackedVector2Array = route["line"]
	var length := 0.0
	var ends := PackedFloat64Array()
	for index in range(1, line.size()):
		length += line[index - 1].distance_to(line[index])
		ends.append(length)
	var is_service: bool = route["highway"] == "service"
	if length < (MIN_SERVICE_LENGTH_M if is_service else MIN_ROAD_LENGTH_M):
		return
	var id: String = route["id"]
	var pitch := maxf(1.0, pitch_m)
	var count := maxi(1, roundi(length / pitch))
	var start := (length - (count - 1) * pitch) * 0.5
	var shoulder: float = route["half_width"] + SHOULDER_M
	for station in count:
		var distance := start + station * pitch
		var segment := ends.bsearch(distance)
		var direction := (line[segment + 1] - line[segment]).normalized()
		var center := line[segment + 1] - direction * (ends[segment] - distance)
		if (cuts.has(id) and not _on_remaining_road(center, cuts[id])) \
				or _near_junction(center, direction, route, edges):
			continue
		var preferred_side := -1.0 if posmod(id.hash() + station, 2) == 0 else 1.0
		for side: float in [preferred_side, -preferred_side]:
			var offset := direction.orthogonal() * side
			var point := center + offset * shoulder
			if _inside_polygon(point, polygons) or _too_near_edge(point, edges) \
					or _in_median(center, direction, offset, route, edges) or _near_lamp(point, occupied, minimum_gap_m):
				continue
			lamps.append({"position": Vector3(point.x, 0.0, point.y),
				"normal": Vector3(-offset.x, 0.0, -offset.y), "source_id": id})
			var extent := Vector2.ONE * minimum_gap_m
			_index(occupied, Rect2(point - extent, extent * 2.0), point)
			break

static func _on_remaining_road(center: Vector2, triangles: Array) -> bool:
	for triangle: Array in triangles:
		var points := _points(triangle)
		if points.size() == 3 and Geometry2D.point_is_inside_triangle(center, points[0], points[1], points[2]):
			return true
	return false

static func _near_junction(center: Vector2, direction: Vector2, route: Dictionary, edges: Dictionary) -> bool:
	for edge: Dictionary in edges.get(_cell(center), []):
		var other: Dictionary = edge["road"]
		if other.is_empty() or other["id"] == route["id"]:
			continue
		var a: Vector2 = edge["a"]
		var b: Vector2 = edge["b"]
		var margin: float = other["half_width"] + JUNCTION_MARGIN_M
		if absf((b - a).normalized().dot(direction)) < 0.87 \
				and center.distance_squared_to(Geometry2D.get_closest_point_to_segment(center, a, b)) < margin * margin:
			return true
	return false

static func _in_median(center: Vector2, direction: Vector2, outward: Vector2,
		route: Dictionary, edges: Dictionary) -> bool:
	for edge: Dictionary in edges.get(_cell(center), []):
		var other: Dictionary = edge["road"]
		if other.is_empty() or other["id"] == route["id"]:
			continue
		var same_street: bool = not route["street"].is_empty() and route["street"] == other["street"]
		var paired: bool = route["oneway"] and other["oneway"] and route["highway"] == other["highway"]
		if not (same_street or paired):
			continue
		var a: Vector2 = edge["a"]
		var b: Vector2 = edge["b"]
		if absf((b - a).normalized().dot(direction)) < 0.92:
			continue
		var delta := Geometry2D.get_closest_point_to_segment(center, a, b) - center
		var between := delta.dot(outward)
		if between >= route["half_width"] and delta.length_squared() < DIVIDED_ROAD_RANGE_M * DIVIDED_ROAD_RANGE_M \
				and absf(delta.dot(direction)) < ROAD_MARGIN_M + between * 0.35:
			return true
	return false

static func _inside_polygon(point: Vector2, polygons: Dictionary) -> bool:
	for rings: Array in polygons.get(_cell(point), []):
		if not Geometry2D.is_point_in_polygon(point, rings[0]):
			continue
		var inside_hole := false
		for index in range(1, rings.size()):
			if Geometry2D.is_point_in_polygon(point, rings[index]):
				inside_hole = true
				break
		if not inside_hole:
			return true
	return false

static func _too_near_edge(point: Vector2, edges: Dictionary) -> bool:
	for edge: Dictionary in edges.get(_cell(point), []):
		var radius: float = edge["radius"]
		var nearest := Geometry2D.get_closest_point_to_segment(point, edge["a"], edge["b"])
		if point.distance_squared_to(nearest) < radius * radius:
			return true
	return false

static func _near_lamp(point: Vector2, occupied: Dictionary, minimum_gap_m: float) -> bool:
	for other: Vector2 in occupied.get(_cell(point), []):
		if point.distance_squared_to(other) < minimum_gap_m * minimum_gap_m:
			return true
	return false
