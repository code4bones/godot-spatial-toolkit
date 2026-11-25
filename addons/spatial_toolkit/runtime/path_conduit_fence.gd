extends RefCounted
## Reuses the supplied chain-link kit in batches along the projected pipe routes.

const SIDE_OFFSET_M := 1.65
const END_CLEARANCE_M := 3.0
const JUNCTION_CLEARANCE_M := 4.5
const SPAN_M := 5.2
const CHUNK_M := 40.0
const ROAD_CLEARANCE_M := 0.42
const WALL_CLEARANCE_M := 0.30
const PIPE_CLEARANCE_M := 0.58
const BASE_GAP_M := 0.07
const TOP_CLEARANCE_M := 0.13
const POST_WIDTH_SCALE := 1.35
const NEAR_DETAIL_M := 46.0
const MAX_VISIBILITY_M := 160.0
const CLIP_SAMPLE_M := 0.42
const MIN_SPAN_M := 0.65
const WIRE_NODE := "modular_chainlink_fence_double"
const POST_NODE := "modular_chainlink_fence_post"

var _obstacles: Dictionary
var _panel_height_m: float
var _chunks: Dictionary = {}
var _posts: Dictionary = {}
var _sources: Dictionary = {}
var _hills: Array[Dictionary] = []

func _init(features: Array, road_ids: Dictionary, neighbors: Dictionary, pipe_crown_m: float) -> void:
	_obstacles = build_spatial_index(features, road_ids, neighbors)
	_panel_height_m = pipe_crown_m + TOP_CLEARANCE_M - BASE_GAP_M

func add_route(points: PackedVector2Array, start_trim_m: float, end_trim_m: float, source_ids: Dictionary) -> void:
	var spans := plan_route(points, start_trim_m, end_trim_m, _obstacles)
	if spans.is_empty():
		return
	_sources.merge(source_ids)
	for span in spans:
		var bounds_cell := _cell((span[0] + span[1]) * 0.5)
		var chunk: Dictionary = _chunks.get_or_add(bounds_cell, {"spans": [], "posts": PackedVector2Array()})
		chunk["spans"].append(span)
		for point in span:
			var key := point.snapped(Vector2.ONE * 0.01)
			if _posts.has(key):
				continue
			_posts[key] = true
			var post_chunk: Dictionary = _chunks.get_or_add(_cell(point), {"spans": [], "posts": PackedVector2Array()})
			var posts: PackedVector2Array = post_chunk["posts"]
			posts.append(point)
			post_chunk["posts"] = posts

func add_to(host: Node3D, library: PackedScene, scale_factor: float, ground_y: float) -> Node3D:
	if _chunks.is_empty():
		return null
	var meshes := _kit_meshes(library)
	if meshes.is_empty():
		push_warning("Spatial Toolkit: chain-link fence requires the wire surface and post from the imported kit")
		return null
	_record_hills(host, scale_factor)
	var overlay := Node3D.new()
	overlay.name = "ConduitFence"
	overlay.hide()
	overlay.set_meta("asset_source", library.resource_path)
	overlay.set_meta("layout_version", 2)
	overlay.set_meta("panel_height_m", _panel_height_m)
	overlay.set_meta("max_span_m", SPAN_M)
	var ids := _sources.keys()
	ids.sort()
	overlay.set_meta("source_ids", PackedStringArray(ids))
	host.add_child(overlay)
	var panel_count := 0
	var post_count := 0
	var chunks_built := 0
	var wire: Mesh = meshes["wire"]
	var post: Mesh = meshes["post"]
	var simple_post: Mesh = meshes["simple_post"]
	var keys := _chunks.keys()
	keys.sort()
	for key: Vector2i in keys:
		var chunk: Dictionary = _chunks[key]
		var panels: Array[Transform3D] = []
		for span: PackedVector2Array in chunk["spans"]:
			var a := _world_point(span[0], scale_factor, ground_y)
			var b := _world_point(span[1], scale_factor, ground_y)
			panels.append(_panel_transform(wire.get_aabb(), a, b, scale_factor))
		var detailed: Array[Transform3D] = []
		var simple: Array[Transform3D] = []
		for point: Vector2 in chunk["posts"]:
			var foot := _world_point(point, scale_factor, ground_y)
			detailed.append(_post_transform(post.get_aabb(), foot, scale_factor, false))
			simple.append(_post_transform(simple_post.get_aabb(), foot, scale_factor, true))
		var suffix := "_%d_%d" % [key.x, key.y]
		_batch(overlay, "Wire" + suffix, wire, panels, 0.0, MAX_VISIBILITY_M * scale_factor)
		_batch(overlay, "KitPost" + suffix, post, detailed, 0.0, NEAR_DETAIL_M * scale_factor)
		_batch(overlay, "PostLOD" + suffix, simple_post, simple,
			NEAR_DETAIL_M * scale_factor, MAX_VISIBILITY_M * scale_factor)
		panel_count += panels.size()
		post_count += detailed.size()
		chunks_built += 1
		if chunks_built % 18 == 0:
			await host.get_tree().process_frame
			if not is_instance_valid(overlay) or host.is_queued_for_deletion() or not host.is_inside_tree():
				return null
	overlay.set_meta("panel_count", panel_count)
	overlay.set_meta("post_count", post_count)
	overlay.set_meta("chunk_count", chunks_built)
	return overlay

func _kit_meshes(library: PackedScene) -> Dictionary:
	var kit := library.instantiate()
	var panel_node := kit.find_child(WIRE_NODE, true, false) as MeshInstance3D
	var post_node := kit.find_child(POST_NODE, true, false) as MeshInstance3D
	var panel: Mesh = panel_node.mesh if panel_node != null else null
	var post: Mesh = post_node.mesh if post_node != null else null
	kit.free()
	if panel == null or post == null:
		return {}
	for index in panel.get_surface_count():
		var material := panel.surface_get_material(index) as StandardMaterial3D
		if material == null or not material.resource_name.ends_with("_wire"):
			continue
		var cutout := _wire_material(material)
		if cutout == null:
			return {}
		# Keep the kit's low-poly textured wire plane. Its separate geometry
		# surface contains thousands of frame and fastener triangles per panel.
		var wire := ArrayMesh.new()
		wire.add_surface_from_arrays(panel.surface_get_primitive_type(index), panel.surface_get_arrays(index))
		wire.surface_set_material(0, cutout)
		var simple_post := CylinderMesh.new()
		simple_post.radial_segments = 6
		simple_post.rings = 1
		simple_post.top_radius = 0.067
		simple_post.bottom_radius = 0.067
		simple_post.height = _panel_height_m + 0.22
		simple_post.material = post.surface_get_material(0)
		return {"wire": wire, "post": post, "simple_post": simple_post}
	return {}

func _wire_material(original: StandardMaterial3D) -> StandardMaterial3D:
	if original.albedo_texture == null:
		return null
	var image := original.albedo_texture.get_image()
	if image == null or image.is_empty():
		return null
	if image.is_compressed() and image.decompress() != OK:
		return null
	image.clear_mipmaps()
	image.convert(Image.FORMAT_RGBA8)
	var pixels := image.get_data()
	# The supplied JPEG stores the open wire diamonds as black RGB.
	for index in range(0, pixels.size(), 4):
		var brightness := maxi(pixels[index], maxi(pixels[index + 1], pixels[index + 2]))
		pixels[index + 3] = clampi((brightness - 15) * 11, 0, 255)
	var cutout := Image.create_from_data(image.get_width(), image.get_height(), false, Image.FORMAT_RGBA8, pixels)
	cutout.generate_mipmaps()
	var material := original.duplicate() as StandardMaterial3D
	material.albedo_texture = ImageTexture.create_from_image(cutout)
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
	material.alpha_scissor_threshold = 0.22
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	return material

func _record_hills(host: Node3D, scale_factor: float) -> void:
	var style := host.get_parent()
	if style == null:
		return
	var possible_hills := style.get_children()
	var relief := style.get_node_or_null("LandscapeRelief")
	if relief != null:
		possible_hills.append_array(relief.get_children())
	for node: Node in possible_hills:
		if not node is Node3D or not node.has_method("_height"):
			continue
		var center := host.to_local(node.global_position) / scale_factor
		_hills.append({"node": node, "center": Vector2(center.x, center.z), "radius": float(node.radius_m)})

func _world_point(point: Vector2, scale_factor: float, ground_y: float) -> Vector3:
	var height := 0.0
	for hill: Dictionary in _hills:
		var delta: Vector2 = point - hill["center"]
		if delta.length_squared() < hill["radius"] * hill["radius"]:
			height = maxf(height, float(hill["node"].call("_height", delta)))
	return Vector3(point.x * scale_factor, ground_y + height * scale_factor, point.y * scale_factor)

func _panel_transform(bounds: AABB, a: Vector3, b: Vector3, scale_factor: float) -> Transform3D:
	var span := b - a
	var normal := span.cross(Vector3.UP).normalized()
	var basis := Basis(span / bounds.size.x, Vector3.UP * _panel_height_m * scale_factor / bounds.size.y,
		normal * scale_factor)
	var anchor := Vector3(bounds.position.x, bounds.position.y, bounds.get_center().z)
	return Transform3D(basis, a + Vector3.UP * BASE_GAP_M * scale_factor - basis * anchor)

func _post_transform(bounds: AABB, foot: Vector3, scale_factor: float, simple: bool) -> Transform3D:
	var height_scale := (_panel_height_m + 0.22) / bounds.size.y
	var basis := Basis.from_scale(Vector3(POST_WIDTH_SCALE, height_scale, POST_WIDTH_SCALE) * scale_factor)
	var center := bounds.get_center() if simple else Vector3.ZERO
	var anchor := Vector3(center.x, bounds.position.y, center.z)
	return Transform3D(basis, foot - basis * anchor - Vector3.UP * 0.04 * scale_factor)

func _batch(overlay: Node3D, label: String, mesh: Mesh, transforms: Array[Transform3D],
		near_m: float, far_m: float) -> void:
	if transforms.is_empty():
		return
	var multimesh := MultiMesh.new()
	multimesh.transform_format = MultiMesh.TRANSFORM_3D
	multimesh.mesh = mesh
	multimesh.instance_count = transforms.size()
	var buffer := PackedFloat32Array()
	buffer.resize(transforms.size() * 12)
	for index in transforms.size():
		var pose := transforms[index]
		var offset := index * 12
		for row in 3:
			buffer[offset + row * 4] = pose.basis.x[row]
			buffer[offset + row * 4 + 1] = pose.basis.y[row]
			buffer[offset + row * 4 + 2] = pose.basis.z[row]
			buffer[offset + row * 4 + 3] = pose.origin[row]
	multimesh.buffer = buffer
	var node := MultiMeshInstance3D.new()
	node.name = label
	node.multimesh = multimesh
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	node.visibility_range_begin = near_m
	node.visibility_range_end = far_m
	overlay.add_child(node)

static func build_spatial_index(features: Array, road_ids: Dictionary, neighbors: Dictionary) -> Dictionary:
	var cells := {}
	for feature: Dictionary in features:
		var geometry: Dictionary = feature.get("geometry", {})
		var coordinates: Array = geometry.get("coordinates", [])
		if feature.get("kind") in ["building", "water"]:
			var polygons := [coordinates] if geometry.get("type") == "Polygon" else coordinates
			for polygon: Array in polygons:
				_index_polygon(cells, polygon)
		elif road_ids.has(feature.get("id")) and geometry.get("type") == "LineString":
			var radius := float(feature.get("width_m", 2.0)) * 0.5 + ROAD_CLEARANCE_M
			for index in range(1, coordinates.size()):
				_index_edge(cells, _point(coordinates[index - 1]), _point(coordinates[index]), radius)
	for a: Vector2 in neighbors:
		for b: Vector2 in neighbors[a]:
			if a.x < b.x or (a.x == b.x and a.y < b.y):
				_index_edge(cells, a, b, PIPE_CLEARANCE_M)
	return cells

static func plan_route(points: PackedVector2Array, start_trim_m: float, end_trim_m: float,
		obstacles: Dictionary) -> Array[PackedVector2Array]:
	var spans: Array[PackedVector2Array] = []
	var route := _trimmed(points, start_trim_m, end_trim_m)
	if route.size() < 2:
		return spans
	for side in [-1.0, 1.0]:
		for line in _offset_runs(route, SIDE_OFFSET_M * side):
			for index in range(1, line.size()):
				var a := line[index - 1]
				var b := line[index]
				if a.distance_to(b) < MIN_SPAN_M:
					continue
				_place_clear_spans(spans, a, b, obstacles)
	return spans

static func _point(coordinate: Array) -> Vector2:
	return Vector2(float(coordinate[0]), float(coordinate[1]))

static func _cell(point: Vector2) -> Vector2i:
	return Vector2i(floori(point.x / CHUNK_M), floori(point.y / CHUNK_M))

static func _index_edge(cells: Dictionary, a: Vector2, b: Vector2, radius: float) -> void:
	var bounds := Rect2(a, Vector2.ZERO).expand(b).grow(radius)
	_index(cells, bounds, {"a": a, "b": b, "radius": radius, "bounds": bounds})

static func _index_polygon(cells: Dictionary, polygon: Array) -> void:
	var rings: Array[PackedVector2Array] = []
	var bounds := Rect2()
	for ring: Array in polygon:
		var points := PackedVector2Array()
		for coordinate: Array in ring:
			var point := _point(coordinate)
			if rings.is_empty() and points.is_empty():
				bounds.position = point
			bounds = bounds.expand(point)
			points.append(point)
		if points.size() > 1 and points[0].is_equal_approx(points[-1]):
			points.resize(points.size() - 1)
		if points.size() >= 3:
			rings.append(points)
	if rings.is_empty():
		return
	_index(cells, bounds, {"rings": rings, "bounds": bounds})
	# Local perimeter edges handle crossings and wall distance independently of
	# containment, so even a long shoreline only tests its nearby segments.
	for ring in rings:
		for index in ring.size():
			_index_edge(cells, ring[index], ring[(index + 1) % ring.size()], WALL_CLEARANCE_M)

static func _index(cells: Dictionary, bounds: Rect2, obstacle: Dictionary) -> void:
	var first := _cell(bounds.position)
	var last := _cell(bounds.end)
	for x in range(first.x, last.x + 1):
		for z in range(first.y, last.y + 1):
			cells.get_or_add(Vector2i(x, z), []).append(obstacle)

static func _blocked(a: Vector2, b: Vector2, obstacles: Dictionary) -> bool:
	var bounds := Rect2(a, Vector2.ZERO).expand(b).grow(0.001)
	var first := _cell(bounds.position)
	var last := _cell(bounds.end)
	for x in range(first.x, last.x + 1):
		for z in range(first.y, last.y + 1):
			for item: Dictionary in obstacles.get(Vector2i(x, z), []):
				if not item["bounds"].intersects(bounds):
					continue
				if item.has("rings"):
					if _inside_polygon(a, item["rings"]):
						return true
				else:
					var radius: float = item["radius"]
					if _edge_distance_squared(a, b, item["a"], item["b"]) <= radius * radius:
						return true
	return false

static func _inside_polygon(point: Vector2, rings: Array[PackedVector2Array]) -> bool:
	if not Geometry2D.is_point_in_polygon(point, rings[0]):
		return false
	for index in range(1, rings.size()):
		if Geometry2D.is_point_in_polygon(point, rings[index]):
			return false
	return true

static func _edge_distance_squared(a: Vector2, b: Vector2, c: Vector2, d: Vector2) -> float:
	if Geometry2D.segment_intersects_segment(a, b, c, d) != null:
		return 0.0
	return minf(minf(a.distance_squared_to(Geometry2D.get_closest_point_to_segment(a, c, d)),
		b.distance_squared_to(Geometry2D.get_closest_point_to_segment(b, c, d))),
		minf(c.distance_squared_to(Geometry2D.get_closest_point_to_segment(c, a, b)),
			d.distance_squared_to(Geometry2D.get_closest_point_to_segment(d, a, b))))

static func _trimmed(points: PackedVector2Array, start_trim_m: float, end_trim_m: float) -> PackedVector2Array:
	if points.size() < 2:
		return PackedVector2Array()
	var distances := PackedFloat32Array([0.0])
	for index in range(1, points.size()):
		distances.append(distances[-1] + points[index - 1].distance_to(points[index]))
	var end := distances[-1] - end_trim_m
	var result := PackedVector2Array()
	if end - start_trim_m < MIN_SPAN_M:
		return result
	for index in range(1, points.size()):
		var low := maxf(distances[index - 1], start_trim_m)
		var high := minf(distances[index], end)
		if high - low <= 0.0001:
			continue
		var length_m := distances[index] - distances[index - 1]
		if result.is_empty():
			result.append(points[index - 1].lerp(points[index], (low - distances[index - 1]) / length_m))
		result.append(points[index - 1].lerp(points[index], (high - distances[index - 1]) / length_m))
	return result

static func _offset_runs(route: PackedVector2Array, offset: float) -> Array[PackedVector2Array]:
	var runs: Array[PackedVector2Array] = []
	var closed := route.size() > 3 and route[0].is_equal_approx(route[-1])
	var count := route.size() - int(closed)
	var line := PackedVector2Array()
	for index in count:
		var point := route[index]
		var back := point - route[posmod(index - 1, count)]
		var front := route[(index + 1) % count] - point
		if not closed and index == 0:
			back = front
		elif not closed and index == count - 1:
			front = back
		var incoming := back.normalized().orthogonal()
		var outgoing := front.normalized().orthogonal()
		var bisector := (incoming + outgoing).normalized()
		var alignment := bisector.dot(outgoing)
		var join := bisector * (offset / maxf(0.01, alignment))
		if alignment < 0.56 or absf(join.dot(front.normalized())) > minf(back.length(), front.length()) * 0.48:
			var retreat := minf(0.35, back.length() * 0.35)
			line.append(point + incoming * offset - back.normalized() * retreat)
			runs.append(line)
			var advance := minf(0.35, front.length() * 0.35)
			line = PackedVector2Array([point + outgoing * offset + front.normalized() * advance])
		else:
			line.append(point + join)
	if closed and not runs.is_empty():
		line.append_array(runs.pop_front())
	elif closed:
		line.append(line[0])
	runs.append(line)
	return runs

static func _place_clear_spans(spans: Array[PackedVector2Array], a: Vector2, b: Vector2, obstacles: Dictionary) -> void:
	# Clip in short intervals so road passages stay open without discarding whole panels.
	if not _blocked(a, b, obstacles):
		_add_panels(spans, a, b)
		return
	var steps := ceili(a.distance_to(b) / CLIP_SAMPLE_M)
	var clear_start := a
	for index in steps:
		var start := a.lerp(b, float(index) / steps)
		var end := a.lerp(b, float(index + 1) / steps)
		if _blocked(start, end, obstacles):
			_add_panels(spans, clear_start, start)
			clear_start = end
	_add_panels(spans, clear_start, b)

static func _add_panels(spans: Array[PackedVector2Array], a: Vector2, b: Vector2) -> void:
	var length_m := a.distance_to(b)
	if length_m < MIN_SPAN_M:
		return
	var count := ceili(length_m / SPAN_M)
	for index in count:
		spans.append(PackedVector2Array([a.lerp(b, float(index) / count),
			a.lerp(b, float(index + 1) / count)]))
