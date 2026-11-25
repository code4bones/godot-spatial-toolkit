extends RefCounted
## Source-metre facade runs with vertically repeatable residential and industrial bays.

const CORNER_CLEARANCE_M := 1.6
const MIN_ROOM_PITCH_M := 2.75
const MAX_JOIN_DEVIATION_M := 0.015
const MAX_JOIN_TURN := 0.001
const MIN_EDGE_M := 0.001


static func build(polygons: Array, long_axis: Vector2, industrial: bool, seed: int,
		window_half_width_m: float) -> Array[Dictionary]:
	var walls: Array[Dictionary] = []
	for polygon: Array in polygons:
		for ring_index in polygon.size():
			var ring := _wall_ring(polygon[ring_index], ring_index > 0)
			if ring.size() < 3:
				continue
			var start := _strongest_corner(ring)
			var a := ring[start]
			var b := ring[(start + 1) % ring.size()]
			var deviation := 0.0
			for offset in range(2, ring.size() + 1):
				var next := ring[(start + offset) % ring.size()]
				var tangent := (b - a).normalized()
				var onward := (next - b).normalized()
				# Bound accumulated drift so gentle bends cannot form one straight run.
				var combined := (next - a).normalized()
				var next_deviation := deviation + absf((b - a).cross(combined))
				if tangent.dot(onward) > 0.0 and absf(tangent.cross(onward)) <= MAX_JOIN_TURN \
						and next_deviation <= MAX_JOIN_DEVIATION_M:
					b = next
					deviation = next_deviation
					continue
				_append_wall(walls, a, b, long_axis, industrial, seed, window_half_width_m)
				a = b
				b = next
				deviation = 0.0
			_append_wall(walls, a, b, long_axis, industrial, seed, window_half_width_m)
	return walls


static func _wall_ring(coordinates: Array, courtyard: bool) -> PackedVector2Array:
	var ring := PackedVector2Array()
	for coordinate: Array in coordinates:
		var point := Vector2(float(coordinate[0]), float(coordinate[1]))
		if ring.is_empty() or point.distance_squared_to(ring[-1]) > MIN_EDGE_M * MIN_EDGE_M:
			ring.append(point)
	if ring.size() > 1 and ring[0].distance_squared_to(ring[-1]) <= MIN_EDGE_M * MIN_EDGE_M:
		ring.resize(ring.size() - 1)
	# Orient both exterior and courtyard walls with the outward face on the right.
	if ring.size() >= 3 and Geometry2D.is_polygon_clockwise(ring) != courtyard:
		ring.reverse()
	return ring


static func _strongest_corner(ring: PackedVector2Array) -> int:
	var start := 0
	var strongest := -1
	for index in ring.size():
		var incoming := ring[index] - ring[(index + ring.size() - 1) % ring.size()]
		var outgoing := ring[(index + 1) % ring.size()] - ring[index]
		var turn := roundi(absf(incoming.angle_to(outgoing)) * 100000.0)
		if turn > strongest or (turn == strongest and _before(ring[index], ring[start])):
			start = index
			strongest = turn
	return start


static func _before(a: Vector2, b: Vector2) -> bool:
	return a.y < b.y if a.x == b.x else a.x < b.x


static func _append_wall(walls: Array[Dictionary], a: Vector2, b: Vector2, long_axis: Vector2,
		industrial: bool, seed: int, window_half_width_m: float) -> void:
	var edge := b - a
	var length := edge.length()
	if length < MIN_EDGE_M:
		return
	var normal := Vector2(edge.y, -edge.x) / length
	var narrow_end := absf(normal.dot(long_axis)) > 0.58
	var inset := maxf(CORNER_CLEARANCE_M, 2.0 * window_half_width_m) + window_half_width_m
	var usable_width := length - 2.0 * inset
	if usable_width < (0.0 if narrow_end else 1.0):
		return
	var centers := PackedFloat32Array()
	var groups := PackedInt32Array()
	var room_pitch := maxf(MIN_ROOM_PITCH_M, 2.0 * window_half_width_m + 1.15)
	if narrow_end:
		var pitch := maxf(room_pitch, 6.0) if industrial else room_pitch
		if usable_width >= pitch:
			centers.append_array(PackedFloat32Array([(length - pitch) * 0.5, (length + pitch) * 0.5]))
			groups.append_array(PackedInt32Array([0, 0]))
		else:
			centers.append(length * 0.5)
			groups.append(0)
	elif industrial:
		var pitch := maxf(6.0 + float(posmod(seed, 4)) * 0.48, room_pitch)
		var count := 1 + floori(usable_width / pitch)
		var first := (length - float(count - 1) * pitch) * 0.5
		for bay in count:
			centers.append(first + float(bay) * pitch)
			groups.append(bay)
	else:
		var nominal_section := maxf(11.0 + float(posmod(seed, 5)) * 0.47, room_pitch * 3.8)
		var sections := maxi(1, roundi(usable_width / nominal_section))
		var section_width := usable_width / float(sections)
		for bay in sections:
			var pattern := posmod(seed + bay, 5)
			var count := 1
			if section_width >= 2.0 * room_pitch:
				count = 2
				if section_width >= 3.15 * room_pitch and pattern in [0, 2, 3]:
					count = 3
			var bay_center := inset + (float(bay) + 0.5) * section_width
			if count == 2 and pattern in [1, 4]:
				# Move the pair towards one side, leaving a service/staircore strip.
				var slack := section_width - float(count) * room_pitch
				bay_center += minf(0.7, slack * 0.25) * (-1.0 if pattern == 1 else 1.0)
			var first := bay_center - float(count - 1) * room_pitch * 0.5
			for room in count:
				centers.append(first + float(room) * room_pitch)
				groups.append(bay)
	var reverse := _before(b, a)
	walls.append({"a": b if reverse else a, "b": a if reverse else b, "normal": normal,
		"centers": centers, "groups": groups, "narrow_end": narrow_end})
