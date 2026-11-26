extends RefCounted
## Packs one layout for the painted facade and streamed 3D frames.

const WIDTH_M := SpatialWindowLayout.DEFAULT_WIDTH_M
const SILL_M := SpatialWindowLayout.DEFAULT_SILL_M
const HEADROOM_M := SpatialWindowLayout.DEFAULT_CEILING_CLEARANCE_M
const MAX_HEIGHT_M := SpatialWindowLayout.DEFAULT_MAX_HEIGHT_M
const WALL_TOLERANCE_M := 0.025
const EMPTY_CENTER := -10000.0

static func build(mesh: Mesh, runs: Array[Dictionary], scale_factor: float,
		floor_height: float, wall_height: float, first_level := 1, lighting_seed := 0,
		physical_openings: Array = [], pack_texture := true, settings: SpatialWindowLayout = null) -> Dictionary:
	if settings == null:
		settings = SpatialWindowLayout.new()
	var height := maxf(0.0, minf(settings.max_height_m, floor_height - settings.sill_m - settings.ceiling_clearance_m))
	if first_level == 0:
		# The base of a one-storey facade also needs a frame height of masonry.
		height = minf(height, settings.sill_m)
	var vertical := Vector2(settings.sill_m + height * 0.5, height * 0.5)
	var last_level := floori((wall_height - settings.sill_m - 2.0 * height + 0.001) / floor_height)
	if first_level == 0:
		last_level = mini(last_level, 0)
	var walls: Array[Dictionary] = []
	if height <= 0.0 or last_level < first_level or runs.is_empty():
		return {"walls": walls, "vertical": vertical, "texture": null, "first_level": first_level,
			"light_offset": -1, "width_m": settings.width_m}
	var triangles := _vertical_triangles(mesh, scale_factor)
	var lights := PackedColorArray()
	var sections := 0
	for run in runs:
		var start: Vector2 = run["a"]
		var edge: Vector2 = run["b"] - start
		var tangent := edge.normalized()
		var normal: Vector2 = run["normal"]
		var side := int(normal.x < 0.0) if absf(normal.x) > absf(normal.y) else 2 + int(normal.y < 0.0)
		var length_m := edge.length()
		var faces := _wall_triangles(triangles, start, tangent, normal, length_m)
		if faces.is_empty():
			continue
		var openings := _wall_openings(physical_openings, start, tangent, normal, scale_factor)
		var centers: PackedFloat32Array = run["centers"]
		var groups: PackedInt32Array = run["groups"]
		var basis := Basis(Vector3.UP.cross(Vector3(normal.x, 0.0, normal.y)),
			Vector3.UP, Vector3(normal.x, 0.0, normal.y))
		var windows: Array[Dictionary] = []
		var stride := ceili(length_m)
		var texels := PackedColorArray()
		var rows: Array[PackedVector2Array] = []
		for level in range(first_level, last_level + 1):
			var row := PackedVector2Array()
			var y := level * floor_height + vertical.x
			for index in centers.size():
				var along := centers[index]
				var center := Vector2(along, y)
				var half := Vector2(settings.width_m * 0.5, vertical.y)
				if not _supports_window(faces, center, half) or _overlaps_opening(openings, Rect2(center - half, half * 2.0)):
					continue
				var section := posmod(sections + groups[index], 1024)
				row.append(Vector2(along, section))
			rows.append(row)
		if run["narrow_end"]:
			_limit_end_rows(rows)
		for index in rows.size():
			var row := rows[index]
			var level := index + first_level
			var y := level * floor_height + vertical.x
			var lit_row := PackedVector2Array()
			for window in row:
				var point := start + tangent * window.x
				var light := _section_light(int(window.y), level, lighting_seed * 4 + side, settings.lit_section_fraction)
				lit_row.append(Vector2(window.x, lights.size()))
				lights.append(Color(light.r, light.g, light.b, window.y))
				windows.append({"frame": Transform3D(basis, Vector3(point.x, y, point.y)),
					"address": Vector2(window.y, level), "light": light})
			if pack_texture:
				_append_row(texels, lit_row, stride)
		sections += groups[-1] + 1
		if not windows.is_empty():
			var wall := {"a": start, "b": run["b"], "normal": normal, "length": length_m, "windows": windows}
			if pack_texture:
				wall["texels"] = texels
			walls.append(wall)
	var packed := _texture(walls, last_level, lights) if pack_texture else {"texture": null, "light_offset": -1}
	return {"walls": walls, "vertical": vertical, "texture": packed["texture"],
		"first_level": first_level, "light_offset": packed["light_offset"], "width_m": settings.width_m}

static func _wall_openings(samples: Array, start: Vector2, tangent: Vector2,
		normal: Vector2, scale_factor: float) -> Array[Rect2]:
	var openings: Array[Rect2] = []
	for sample: Dictionary in samples:
		var outward: Array = sample["normal"]
		if normal.dot(Vector2(outward[0], outward[2])) < 0.995:
			continue
		var center: Array = sample["center"]
		var delta := Vector2(center[0], center[2]) / scale_factor - start
		if absf(delta.dot(normal)) > WALL_TOLERANCE_M:
			continue
		var half := Vector2(sample["width_m"], sample["height_m"]) / (2.0 * scale_factor)
		openings.append(Rect2(Vector2(delta.dot(tangent), float(center[1]) / scale_factor) - half, half * 2.0))
	return openings

static func _overlaps_opening(openings: Array[Rect2], window: Rect2) -> bool:
	for opening in openings:
		if opening.intersects(window):
			return true
	return false

static func _section_light(section: int, level: int, facade: int,
		probability := SpatialWindowLayout.DEFAULT_LIT_SECTION_FRACTION) -> Color:
	var key := section + 1
	if probability <= 0.0 or _light_hash(key, level, facade) > probability:
		return Color(0.0, 0.0, 0.0)
	var tone := smoothstep(0.30, 0.85, _light_hash(key + 83, level, facade))
	var intensity := lerpf(0.45, 0.95, _light_hash(key + 241, level, facade))
	var color := Color(1.0, 0.52, 0.24).lerp(Color(0.71, 0.85, 1.0), tone)
	return Color(color.r * intensity, color.g * intensity, color.b * intensity)

static func _light_hash(section: int, level: int, facade: int) -> float:
	# Match the 32-bit shader hash used by older saved section layouts.
	var value := ((section * 1597334677) ^ (level * 3812015801) ^ (facade * 2798796415)) & 0xffffffff
	value = ((value ^ (value >> 16)) * 2246822519) & 0xffffffff
	return float((value ^ (value >> 13)) & 65535) / 65536.0

static func _limit_end_rows(rows: Array[PackedVector2Array]) -> void:
	var occupied := PackedInt32Array()
	var paired := -1
	var midpoint := float(rows.size() - 1) * 0.5
	for index in rows.size():
		if rows[index].is_empty():
			continue
		occupied.append(index)
		if rows[index].size() == 2 and (paired < 0 or absf(index - midpoint) < absf(paired - midpoint)):
			paired = index
	if occupied.is_empty():
		return
	# Favor a horizontal pair on a central floor. Narrower ends can stack two windows.
	var first := paired if paired >= 0 else occupied[floori(float(occupied.size() - 1) / 3.0)]
	var last := paired if paired >= 0 else occupied[ceili(float(occupied.size() - 1) * 2.0 / 3.0)]
	for index in occupied:
		if index != first and index != last:
			rows[index] = PackedVector2Array()

static func _vertical_triangles(mesh: Mesh, scale_factor: float) -> Array[PackedVector3Array]:
	var triangles: Array[PackedVector3Array] = []
	for surface in mesh.get_surface_count():
		var arrays := mesh.surface_get_arrays(surface)
		if not arrays[Mesh.ARRAY_NORMAL] is PackedVector3Array:
			continue
		var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
		var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX] if arrays[Mesh.ARRAY_INDEX] != null else PackedInt32Array()
		for offset in range(0, vertices.size() if indices.is_empty() else indices.size(), 3):
			var a := offset if indices.is_empty() else indices[offset]
			if absf(normals[a].y) > 0.05:
				continue
			var b := offset + 1 if indices.is_empty() else indices[offset + 1]
			var c := offset + 2 if indices.is_empty() else indices[offset + 2]
			triangles.append(PackedVector3Array([vertices[a] / scale_factor, vertices[b] / scale_factor,
				vertices[c] / scale_factor, normals[a]]))
	return triangles

static func _wall_triangles(triangles: Array[PackedVector3Array], start: Vector2, tangent: Vector2,
		normal: Vector2, length_m: float) -> Array[PackedVector2Array]:
	var faces: Array[PackedVector2Array] = []
	for triangle in triangles:
		if Vector2(triangle[3].x, triangle[3].z).dot(normal) < 0.995:
			continue
		var face := PackedVector2Array()
		for index in 3:
			var vertex := triangle[index]
			var delta := Vector2(vertex.x, vertex.z) - start
			if absf(delta.dot(normal)) > WALL_TOLERANCE_M:
				break
			face.append(Vector2(delta.dot(tangent), vertex.y))
		if face.size() == 3 and absf((face[1] - face[0]).cross(face[2] - face[0])) > 0.0001 \
				and maxf(face[0].x, maxf(face[1].x, face[2].x)) >= 0.0 \
				and minf(face[0].x, minf(face[1].x, face[2].x)) <= length_m:
			faces.append(face)
	return faces

static func _supports_window(faces: Array[PackedVector2Array], center: Vector2, half: Vector2) -> bool:
	# Leave a full frame width and height on the actual mesh, including clipped wall edges.
	var inset := half * 3.0
	for offset in [Vector2.ZERO, -half, half, Vector2(-half.x, half.y), Vector2(half.x, -half.y),
		-inset, inset, Vector2(-inset.x, inset.y), Vector2(inset.x, -inset.y),
		Vector2(0.0, -inset.y), Vector2(0.0, inset.y)]:
		var point: Vector2 = center + offset
		var supported := false
		for face in faces:
			# Include triangle boundaries, such as a window centered on the mesh diagonal.
			var a := (face[1] - face[0]).cross(point - face[0])
			var b := (face[2] - face[1]).cross(point - face[1])
			var c := (face[0] - face[2]).cross(point - face[2])
			if minf(a, minf(b, c)) >= -0.0001 or maxf(a, maxf(b, c)) <= 0.0001:
				supported = true
				break
		if not supported:
			return false
	return true

static func _append_row(texels: PackedColorArray, windows: PackedVector2Array, stride: int) -> void:
	# A metre-wide bucket needs only the neighbors of its midpoint. The layout
	# keeps centers over two metres apart, so this also covers either bucket edge.
	var next := 0
	var empty := Vector2(EMPTY_CENTER, 0.0)
	for metre in stride:
		while next < windows.size() and windows[next].x < float(metre) + 0.5:
			next += 1
		var left := windows[next - 1] if next > 0 else empty
		var right := windows[next] if next < windows.size() else empty
		texels.append(Color(left.x, right.x, left.y, right.y))

static func _texture(walls: Array[Dictionary], last_level: int, lights: PackedColorArray) -> Dictionary:
	if walls.is_empty():
		return {"texture": null, "light_offset": -1}
	var buckets := PackedColorArray()
	var headers := PackedColorArray()
	for wall in walls:
		var start: Vector2 = wall["a"]
		var normal: Vector2 = wall["normal"]
		var tangent: Vector2 = (wall["b"] - start).normalized()
		var sign_of_normal := 1.0 if normal.dot(Vector2(tangent.y, -tangent.x)) > 0.0 else -1.0
		headers.append(Color(start.x, start.y, tangent.x, tangent.y))
		headers.append(Color(wall["length"], walls.size() * 2 + buckets.size(), last_level, sign_of_normal))
		buckets.append_array(wall["texels"])
		wall.erase("texels")
	headers.append_array(buckets)
	var light_offset := headers.size()
	headers.append_array(lights)
	var width := mini(256, headers.size())
	var image := Image.create_empty(width, ceili(float(headers.size()) / width), false, Image.FORMAT_RGBAF)
	for index in headers.size():
		@warning_ignore("integer_division")
		image.set_pixel(index % width, index / width, headers[index])
	return {"texture": ImageTexture.create_from_image(image), "light_offset": light_offset}
