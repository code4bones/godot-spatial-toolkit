extends Node3D
## One signal train traveling through connected conduit sections.

const COLORS := [Color("38edff"), Color("ff48cd"), Color("a6ff58"), Color("ffab44")]
const SPEED_M := 58.0
const VIEW_RANGE_M := 150.0
const RING_SPACING_M := 4.0
const OFFSCREEN_GRACE_S := 0.55

var speed_mps := SPEED_M
var ring_spacing_m := RING_SPACING_M
var emission := 1.4

var _routes: Array[Dictionary]
var _connections: Dictionary
var _occupied: Dictionary
var _rings: Array[MeshInstance3D] = []
var _points := PackedVector3Array()
var _distances := PackedFloat32Array()
var _scale: float
var _ground_y: float
var _rng := RandomNumberGenerator.new()
var _timer := Timer.new()
var _material := StandardMaterial3D.new()
var _route_index := -1
var _distance: float
var _start: float
var _offscreen: float

func setup(routes: Array[Dictionary], connections: Dictionary, occupied: Dictionary,
		scale_factor: float, ground_y: float, radius: float, seed_value: int, first_delay: float) -> void:
	_routes = routes
	_connections = connections
	_occupied = occupied
	_scale = scale_factor
	_ground_y = ground_y
	_rng.seed = seed_value
	var ring := TorusMesh.new()
	ring.inner_radius = radius * 1.05
	ring.outer_radius = radius * 1.50
	ring.rings = 20
	ring.ring_segments = 12
	_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_material.emission_enabled = true
	_material.emission_energy_multiplier = emission
	ring.material = _material
	for index in 3:
		var instance := MeshInstance3D.new()
		instance.mesh = ring
		instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		instance.hide()
		add_child(instance)
		_rings.append(instance)
	set_process(false)
	_timer.one_shot = true
	_timer.timeout.connect(_launch)
	add_child(_timer)
	_timer.start(first_delay)

func _schedule() -> void:
	_timer.start(_rng.randf_range(10.0, 30.0))

func _launch() -> void:
	var camera := get_viewport().get_camera_3d()
	if camera == null:
		_schedule()
		return
	var eye := to_local(camera.global_position)
	var eye_xz := Vector2(eye.x, eye.z) / _scale
	var nearby: Array[Vector2i] = []
	var weights := PackedFloat32Array()
	for index in _routes.size():
		var route := _routes[index]
		if _occupied.has(index) or not route["bounds"].grow(VIEW_RANGE_M).has_point(eye_xz):
			continue
		var points: PackedVector3Array = route["points"]
		var best := VIEW_RANGE_M * VIEW_RANGE_M
		var focus := -1
		for point_index in points.size():
			var point := points[point_index]
			var distance := eye_xz.distance_squared_to(Vector2(point.x, point.z))
			if distance < best and _in_frame(camera, point):
				best = distance
				focus = point_index
		if focus >= 0:
			nearby.append(Vector2i(index, focus))
			weights.append(clampf(float(route["length"]), 2.0, 180.0))
	if nearby.is_empty():
		_schedule()
		return
	var choice := nearby[_rng.rand_weighted(weights)]
	_route_index = choice.x
	_occupied[_route_index] = true
	_build_run(choice, _rng.randf() < 0.5)
	_distance = _start
	_offscreen = 0.0
	_material.albedo_color = COLORS[_rng.randi_range(0, COLORS.size() - 1)]
	_material.emission = _material.albedo_color
	_update_rings()
	set_process(true)

func _build_run(choice: Vector2i, forward: bool) -> void:
	_points.clear()
	_distances.clear()
	var visited := {}
	var route_index := choice.x
	while route_index >= 0:
		visited[route_index] = true
		var route := _routes[route_index]
		var points: PackedVector3Array = route["points"]
		for offset in points.size():
			var index := offset if forward else points.size() - 1 - offset
			var point := points[index]
			if _points.is_empty():
				_distances.append(0.0)
			else:
				var span := _points[-1].distance_to(point)
				if point == _points[-1]:
					continue
				_distances.append(_distances[-1] + span)
			_points.append(point)
			if route_index == choice.x and index == choice.y:
				_start = maxf(0.0, _distances[-1] - 16.0)
		var end: Vector2 = route["end"] if forward else route["start"]
		var heading := (_points[-1] - _points[-2]).normalized()
		route_index = _continuation(end, heading, visited)
		if route_index >= 0:
			forward = _routes[route_index]["start"] == end

func _continuation(end: Vector2, heading: Vector3, visited: Dictionary) -> int:
	var chosen := -1
	var best := -INF
	for index: int in _connections[end]:
		if visited.has(index):
			continue
		var route := _routes[index]
		var points: PackedVector3Array = route["points"]
		var outgoing := points[1] - points[0] if route["start"] == end else points[-2] - points[-1]
		var score := heading.dot(outgoing.normalized()) + _rng.randf_range(0.0, 0.65)
		if score > best:
			best = score
			chosen = index
	return chosen

func _process(delta: float) -> void:
	_distance += speed_mps * delta
	if _distance > _distances[-1] + ring_spacing_m * (_rings.size() - 1):
		_finish()
		return
	var camera := get_viewport().get_camera_3d()
	if camera == null:
		_finish()
		return
	_update_rings()
	var visible_or_entering := _in_frame(camera, _sample(minf(_distances[-1], _distance + 10.0)))
	for ring in _rings:
		if ring.visible and camera.is_position_in_frustum(ring.global_position):
			visible_or_entering = true
			break
	_offscreen = 0.0 if visible_or_entering else _offscreen + delta
	if _offscreen >= OFFSCREEN_GRACE_S:
		_finish()

func _finish() -> void:
	for ring in _rings:
		ring.hide()
	_occupied.erase(_route_index)
	_route_index = -1
	set_process(false)
	_schedule()

func _in_frame(camera: Camera3D, point: Vector3) -> bool:
	return camera.is_position_in_frustum(to_global(point * _scale + Vector3.UP * _ground_y))

func _update_rings() -> void:
	for index in _rings.size():
		var ring := _rings[index]
		var distance := _distance - ring_spacing_m * index
		ring.visible = distance >= _start and distance <= _distances[-1]
		if not ring.visible:
			continue
		var point := _sample(distance)
		var axis := (_sample(minf(_distances[-1], distance + 0.65)) - _sample(maxf(0.0, distance - 0.65))).normalized()
		var across := axis.cross(Vector3.UP).normalized()
		var basis := Basis(across, axis, across.cross(axis)).scaled(Vector3.ONE * _scale)
		ring.transform = Transform3D(basis, point * _scale + Vector3.UP * _ground_y)

func _sample(distance: float) -> Vector3:
	var low := 0
	var high := _distances.size() - 1
	while high - low > 1:
		var middle := (high + low) >> 1
		if _distances[middle] < distance:
			low = middle
		else:
			high = middle
	return _points[low].lerp(_points[high], inverse_lerp(_distances[low], _distances[high], distance))
