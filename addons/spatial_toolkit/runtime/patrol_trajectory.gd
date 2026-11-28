class_name SpatialPatrolTrajectory
extends RefCounted
## Rounds graph waypoints into swept, piecewise-linear Bezier samples.

const POINT_EPSILON_M := 0.0001
const MAX_SAMPLE_DISTANCE_M := 0.8
const MAX_CORNER_SAMPLES := 128
const MIN_TURN_ANGLE := PI / 90.0
const MAX_TURN_ANGLE := PI * 11.0 / 12.0
const MAX_HEADING_STEP := PI / 36.0
const STOP_TURN_DOT := 0.965925826289
const ROUND_ATTEMPTS := 5

static func smooth(waypoints: PackedVector3Array, turn_distance_m: float,
		is_segment_clear: Callable) -> Dictionary:
	var result := {"points": PackedVector3Array(), "rounded_turns": 0,
		"waypoint_indices": PackedInt32Array()}
	if not is_segment_clear.is_valid():
		return result
	var route := PackedVector3Array()
	var waypoint_indices := PackedInt32Array()
	for point: Vector3 in waypoints:
		if not point.is_finite():
			return result
		if route.is_empty() or point != route[-1]:
			route.append(point)
		waypoint_indices.append(route.size() - 1)
	if route.is_empty() or not _path_clear(route, is_segment_clear):
		return result
	if route.size() < 3 or not is_finite(turn_distance_m) or turn_distance_m <= 0.0:
		result["points"] = route
		result["waypoint_indices"] = waypoint_indices
		return result

	var points := PackedVector3Array([route[0]])
	var sample_indices := PackedInt32Array([0])
	var rounded_turns := 0
	for index in range(1, route.size() - 1):
		var curve := _round_corner(points[-1], route[index - 1], route[index],
			route[index + 1], turn_distance_m, is_segment_clear)
		if curve.is_empty():
			points.append(route[index])
		else:
			points.append_array(curve)
			rounded_turns += 1
		# A waypoint event occurs after the curve has joined the outgoing edge.
		sample_indices.append(points.size() - 1)
	points.append(route[-1])
	sample_indices.append(points.size() - 1)
	for index in waypoint_indices.size():
		waypoint_indices[index] = sample_indices[waypoint_indices[index]]
	return {"points": points, "rounded_turns": rounded_turns, "waypoint_indices": waypoint_indices}

static func _round_corner(tail: Vector3, before: Vector3, corner: Vector3, after: Vector3,
		turn_distance_m: float, is_segment_clear: Callable) -> PackedVector3Array:
	var incoming := corner - before
	var outgoing := after - corner
	var incoming_length := incoming.length()
	var outgoing_length := outgoing.length()
	var trim := minf(turn_distance_m, 0.45 * minf(incoming_length, outgoing_length))
	if trim <= POINT_EPSILON_M:
		return PackedVector3Array()
	var entry_direction := incoming / incoming_length
	var exit_direction := outgoing / outgoing_length
	var angle := acos(clampf(entry_direction.dot(exit_direction), -1.0, 1.0))
	if angle < MIN_TURN_ANGLE or angle >= MAX_TURN_ANGLE:
		return PackedVector3Array()

	# A cubic approximation of the circular fillet, tangent to both graph edges.
	var handle_ratio := (4.0 / 3.0) * tan(angle * 0.25) / tan(angle * 0.5)
	for _attempt in ROUND_ATTEMPTS:
		var entry := corner - entry_direction * trim
		var exit_point := corner + exit_direction * trim
		var entry_handle := entry + entry_direction * (trim * handle_ratio)
		var exit_handle := exit_point - exit_direction * (trim * handle_ratio)
		var derivative_bound := 3.0 * maxf(trim * handle_ratio,
			entry_handle.distance_to(exit_handle))
		var sample_count := ceilf(maxf(angle / MAX_HEADING_STEP,
			derivative_bound / MAX_SAMPLE_DISTANCE_M))
		if sample_count <= MAX_CORNER_SAMPLES and _segment_clear(tail, entry, is_segment_clear):
			var curve := PackedVector3Array([entry])
			for step in range(1, int(sample_count)):
				curve.append(entry.bezier_interpolate(entry_handle, exit_handle,
					exit_point, float(step) / sample_count))
			curve.append(exit_point)
			if _path_clear(curve, is_segment_clear) and _segment_clear(exit_point, after, is_segment_clear):
				return curve
		trim *= 0.5
		if trim <= POINT_EPSILON_M:
			break
	return PackedVector3Array()

static func speed_profile(points: PackedVector3Array, cruise_speed: float,
		acceleration: float, lateral_acceleration: float, entry_speed: float = 0.0,
		exit_speed: float = 0.0) -> PackedFloat32Array:
	var speeds := PackedFloat32Array()
	speeds.resize(points.size())
	if points.size() < 2 or not is_finite(cruise_speed) or cruise_speed <= 0.0 \
			or not is_finite(acceleration) or acceleration <= 0.0 \
			or not is_finite(lateral_acceleration) or lateral_acceleration <= 0.0:
		return speeds
	for point: Vector3 in points:
		if not point.is_finite():
			return speeds

	speeds[0] = clampf(entry_speed, 0.0, cruise_speed) if is_finite(entry_speed) else 0.0
	speeds[-1] = clampf(exit_speed, 0.0, cruise_speed) if is_finite(exit_speed) else 0.0
	for index in range(1, points.size() - 1):
		speeds[index] = _corner_speed(points[index - 1], points[index], points[index + 1],
			cruise_speed, lateral_acceleration)
	# Propagate braking and acceleration caps, including tighter endpoint limits.
	for index in range(1, speeds.size()):
		var distance := points[index - 1].distance_to(points[index])
		speeds[index] = minf(speeds[index],
			sqrt(speeds[index - 1] * speeds[index - 1] + 2.0 * acceleration * distance))
	for index in range(speeds.size() - 2, -1, -1):
		var distance := points[index].distance_to(points[index + 1])
		speeds[index] = minf(speeds[index],
			sqrt(speeds[index + 1] * speeds[index + 1] + 2.0 * acceleration * distance))
	return speeds

static func _corner_speed(before: Vector3, point: Vector3, after: Vector3,
		cruise_speed: float, lateral_acceleration: float) -> float:
	var incoming := point - before
	var outgoing := after - point
	if incoming.length() <= POINT_EPSILON_M or outgoing.length() <= POINT_EPSILON_M:
		return 0.0
	var direction_in := incoming.normalized()
	var direction_out := outgoing.normalized()
	# Unrounded sharp corners require a stop so the controller can turn in place.
	if direction_in.dot(direction_out) < STOP_TURN_DOT:
		return 0.0
	# Circumcircle radius of three consecutive samples bounds speed on a curve.
	var sine := direction_in.cross(direction_out).length()
	if sine <= 0.000001:
		return cruise_speed
	var radius := before.distance_to(after) / (2.0 * sine)
	return minf(cruise_speed, sqrt(lateral_acceleration * radius))

static func _path_clear(points: PackedVector3Array, is_segment_clear: Callable) -> bool:
	for index in range(1, points.size()):
		if not _segment_clear(points[index - 1], points[index], is_segment_clear):
			return false
	return true

static func _segment_clear(start: Vector3, finish: Vector3, is_segment_clear: Callable) -> bool:
	return start.is_finite() and finish.is_finite() and (finish - start).is_finite() \
		and (start == finish or bool(is_segment_clear.call(start, finish)))
