@tool
extends RefCounted

static func position_list(geometry: Variant) -> Array:
	var positions: Array = []
	if not geometry is Array:
		return positions
	for point: Variant in geometry:
		if not point is Dictionary or not _number(point.get("lon")) or not _number(point.get("lat")):
			return []
		var longitude: float = point["lon"]
		var latitude: float = point["lat"]
		if absf(longitude) > 180.0 or absf(latitude) > 90.0:
			return []
		positions.append([longitude, latitude])
	return positions

static func _number(value: Variant) -> bool:
	return (value is float or value is int) and is_finite(float(value))

static func closed(positions: Array) -> bool:
	return positions.size() >= 4 and positions.front() == positions.back()

static func polygons(members: Variant) -> Array:
	if not members is Array:
		return []
	var outer: Array = []
	var inner: Array = []
	for member: Variant in members:
		if not member is Dictionary or member.get("type") != "way":
			continue
		var role: String = str(member.get("role", ""))
		if role not in ["outer", "inner", ""]:
			continue
		var positions := position_list(member.get("geometry"))
		if positions.size() < 2:
			return []
		(inner if role == "inner" else outer).append(positions)
	var shells := _join(outer)
	var holes := _join(inner)
	if shells.is_empty() or (not inner.is_empty() and holes.is_empty()):
		return []
	var result: Array = []
	var shell_sizes: Array[float] = []
	for shell: Array in shells:
		result.append([shell])
		shell_sizes.append(absf(_signed_area(shell)))
	for hole: Array in holes:
		var owner := -1
		var best := INF
		for index in shells.size():
			if shell_sizes[index] < best and _contains(shells[index], hole.front()):
				owner = index
				best = shell_sizes[index]
		if owner == -1:
			# A missing or unassignable hole must not silently become solid area.
			return []
		result[owner].append(hole)
	return result

static func _join(parts: Array) -> Array:
	var rings: Array = []
	var edges: Dictionary = {}
	var used: Dictionary = {}
	for index in parts.size():
		var part: Array = parts[index]
		if closed(part):
			rings.append(part)
			used[index] = true
			continue
		for point: Array in [part.front(), part.back()]:
			var key := _position_key(point)
			if not edges.has(key):
				edges[key] = []
			edges[key].append(index)
	for candidates: Array in edges.values():
		if candidates.size() != 2:
			return []
	for index in parts.size():
		if used.has(index):
			continue
		used[index] = true
		var ring: Array = parts[index].duplicate()
		while ring.front() != ring.back():
			var choices: Array = edges[_position_key(ring.back())]
			var next: int = choices[0] if not used.has(choices[0]) else choices[1]
			if used.has(next):
				return []
			used[next] = true
			var segment: Array = parts[next].duplicate()
			if segment.front() != ring.back():
				segment.reverse()
			ring.append_array(segment.slice(1))
		if not closed(ring):
			return []
		rings.append(ring)
	return rings

static func _position_key(position: Array) -> String:
	return "%.9f,%.9f" % [position[0], position[1]]

static func _signed_area(ring: Array) -> float:
	var sum := 0.0
	var origin: Array = ring[0]
	for i in range(1, ring.size()):
		var a: Array = ring[i - 1]
		var b: Array = ring[i]
		var ax := wrapf(float(a[0]) - float(origin[0]), -180.0, 180.0)
		var bx := wrapf(float(b[0]) - float(origin[0]), -180.0, 180.0)
		sum += ax * (float(b[1]) - float(origin[1])) - bx * (float(a[1]) - float(origin[1]))
	return sum * 0.5

static func _contains(ring: Array, point: Array) -> bool:
	var local := PackedVector2Array()
	for position: Array in ring:
		local.append(Vector2(wrapf(float(position[0]) - float(point[0]), -180.0, 180.0),
			float(position[1]) - float(point[1])))
	return Geometry2D.is_point_in_polygon(Vector2.ZERO, local)
