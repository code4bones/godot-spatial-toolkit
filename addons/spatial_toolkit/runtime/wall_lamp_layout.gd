extends RefCounted
## Wall mounts for blank, accessible exterior facades in source metres.

const WindowLayout := preload("res://addons/spatial_toolkit/runtime/facade_window_layout.gd")
const WindowAtlas := preload("res://addons/spatial_toolkit/runtime/facade_window_atlas.gd")
const MOUNT_HEIGHT_M := 1.9
const MIN_WALL_LENGTH_M := 2.0
const MOUNT_HALF_SIZE_M := Vector2(0.17, 0.16)
const MIN_MOUNT_SPACING_M := 3.0
const MAX_PER_BUILDING := 2
const INDUSTRIAL_TYPES := ["industrial", "warehouse", "factory"]


static func build(map: Node3D, features: Array, world_scale: float, mount_height_m := MOUNT_HEIGHT_M,
		minimum_gap_m := MIN_MOUNT_SPACING_M, max_per_building := MAX_PER_BUILDING,
		fixture_scale := 1.0) -> Array[Dictionary]:
	var placements: Array[Dictionary] = []
	var windows := map.get_node_or_null("StyleLayer/ModularWindows")
	if windows == null or world_scale <= 0.0 or max_per_building <= 0:
		return placements
	var entries: Array = windows.get("_entries")
	var buildings := {}
	for entry: Dictionary in entries:
		var node: MeshInstance3D = entry["building"]
		buildings[str(node.get_meta("source_id", ""))] = entry
	var footprints: Array[Dictionary] = []
	var sources := {}
	for feature: Dictionary in features:
		if feature.get("kind") != "building":
			continue
		var source_id := str(feature.get("id", ""))
		var geometry: Dictionary = feature.get("geometry", {})
		var polygons := _polygons(geometry)
		if polygons.is_empty():
			continue
		if buildings.has(source_id):
			sources[source_id] = feature
		for polygon: Array in polygons:
			var outer := WindowLayout._wall_ring(polygon[0], false)
			if outer.size() < 3:
				continue
			var bounds := Rect2(outer[0], Vector2.ZERO)
			for point in outer:
				bounds = bounds.expand(point)
			var holes: Array[PackedVector2Array] = []
			for ring_index in range(1, polygon.size()):
				holes.append(WindowLayout._wall_ring(polygon[ring_index], true))
			footprints.append({"bounds": bounds, "outer": outer, "holes": holes})
	var source_ids := sources.keys()
	source_ids.sort()
	for source_id: String in source_ids:
		var source: Dictionary = sources[source_id]
		var polygons := _polygons(source["geometry"])
		var axis := WindowLayout.long_facade_axis(polygons)
		var tags: Dictionary = source["source"].get("tags", {})
		var building_type := str(tags.get("building", ""))
		if building_type in ["roof", "carport"]:
			continue
		var levels := str(tags.get("building:levels", ""))
		var industrial := (building_type in INDUSTRIAL_TYPES and levels.is_valid_float()
				and is_equal_approx(levels.to_float(), 1.0))
		if not industrial and axis == Vector2.ZERO:
			continue
		placements.append_array(_place_on_building(source_id, buildings[source_id], polygons,
			footprints, axis, industrial, world_scale, mount_height_m, minimum_gap_m, max_per_building,
			MOUNT_HALF_SIZE_M * fixture_scale))
	return placements


static func _polygons(geometry: Dictionary) -> Array:
	match geometry.get("type"):
		"Polygon":
			return [geometry["coordinates"]]
		"MultiPolygon":
			return geometry["coordinates"]
		_:
			return []


static func _place_on_building(source_id: String, entry: Dictionary, polygons: Array,
		footprints: Array[Dictionary], axis: Vector2, industrial: bool, world_scale: float,
		mount_height_m: float, minimum_gap_m: float, max_per_building: int,
		mount_half_size_m: Vector2) -> Array[Dictionary]:
	var placements: Array[Dictionary] = []
	var candidates: Array[Dictionary] = []
	for polygon: Array in polygons:
		# Courtyard rings still count as holes when checking nearby building volumes.
		var outer := WindowLayout._wall_ring(polygon[0], false)
		for index in outer.size():
			var a := outer[index]
			var b := outer[(index + 1) % outer.size()]
			var edge := b - a
			var length_m := edge.length()
			if length_m < MIN_WALL_LENGTH_M:
				continue
			var tangent := edge / length_m
			var normal := Vector2(tangent.y, -tangent.x)
			if not industrial and absf(normal.dot(axis)) <= 0.58:
				continue
			if _has_windows(entry["walls"], a, tangent, normal, length_m):
				continue
			var point := a.lerp(b, 0.5)
			if not _clear_outside(footprints, point, tangent, normal):
				continue
			candidates.append({"start": a, "point": point, "tangent": tangent,
				"normal": normal, "length": length_m})
	if candidates.is_empty():
		return placements
	candidates.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		if a["length"] != b["length"]:
			return a["length"] > b["length"]
		return WindowLayout._before(a["point"], b["point"]))
	var building: MeshInstance3D = entry["building"]
	var triangles := WindowAtlas._vertical_triangles(building.mesh, world_scale)
	for candidate: Dictionary in candidates:
		var length_m: float = candidate["length"]
		var faces := WindowAtlas._wall_triangles(triangles, candidate["start"],
			candidate["tangent"], candidate["normal"], length_m)
		if not WindowAtlas._supports_window(faces, Vector2(length_m * 0.5, mount_height_m), mount_half_size_m):
			continue
		var point: Vector2 = candidate["point"]
		var normal: Vector2 = candidate["normal"]
		var position := Vector3(point.x, mount_height_m, point.y)
		if placements.any(func(mount: Dictionary) -> bool:
			return position.distance_to(mount["position"]) < minimum_gap_m):
			continue
		placements.append({"position": position, "normal": Vector3(normal.x, 0.0, normal.y),
			"source_id": source_id})
		if placements.size() >= max_per_building:
			break
	return placements


static func _has_windows(walls: Array, start: Vector2, tangent: Vector2, normal: Vector2, length_m: float) -> bool:
	for wall: Dictionary in walls:
		var window_normal: Vector2 = wall["normal"]
		if window_normal.dot(normal) < 0.995:
			continue
		var window_start: Vector2 = wall["a"] - start
		var window_end: Vector2 = wall["b"] - start
		if maxf(absf(window_start.dot(normal)), absf(window_end.dot(normal))) > WindowAtlas.WALL_TOLERANCE_M:
			continue
		var first := window_start.dot(tangent)
		var last := window_end.dot(tangent)
		var overlap := minf(length_m, maxf(first, last)) - maxf(0.0, minf(first, last))
		if overlap > WindowAtlas.WALL_TOLERANCE_M:
			return true
	return false


static func _clear_outside(footprints: Array[Dictionary], point: Vector2, tangent: Vector2, normal: Vector2) -> bool:
	var probes := PackedVector2Array()
	for depth: float in [0.08, 0.32, 0.62]:
		for off_center: float in [-0.30, 0.0, 0.30]:
			probes.append(point + normal * depth + tangent * off_center)
	for footprint: Dictionary in footprints:
		var bounds: Rect2 = footprint["bounds"]
		if not bounds.grow(0.70).has_point(point):
			continue
		var outer: PackedVector2Array = footprint["outer"]
		var holes: Array[PackedVector2Array] = footprint["holes"]
		for probe in probes:
			if not Geometry2D.is_point_in_polygon(probe, outer):
				continue
			if not holes.any(func(hole: PackedVector2Array) -> bool:
				return Geometry2D.is_point_in_polygon(probe, hole)):
				return false
	return true
