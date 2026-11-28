extends Node3D
## An arcade rocket with a swept collision query and a fading exhaust.

const Fracture := preload("res://addons/spatial_toolkit/runtime/building_fracture.gd")
const BreakableWindow := preload("res://addons/spatial_toolkit/runtime/breakable_window.gd")
const PatrolRobot := preload("res://addons/spatial_toolkit/runtime/patrol_robot.gd")
const ProjectileRoute := preload("res://addons/spatial_toolkit/runtime/drone_projectile_route.gd")
const IMPACT := preload("res://addons/spatial_toolkit/runtime/rocket_impact.tscn")
const CRUISE_SPEED_MPS := 90.0
const MIN_LEAD_SPEED_MPS := 75.0
const LAUNCH_LEAD_MPS := 22.0
const LAUNCH_ACCEL_SECONDS := 0.24
const LIFETIME_SECONDS := 8.0
const TRACER_SECONDS := 0.045
const MAX_TRACER_LENGTH := 9.0
const EXHAUST_ORIGIN := 1.3
const FADE_SECONDS := 0.16
const IMPACT_VIEW_SECONDS := 0.75
const PATROL_IMPACT_VIEW_SECONDS := 1.0
const PATROL_IMPACT_PUSH := 0.24
const PATROL_IMPACT_VISUAL_SPEED := 0.8
const APPROACH_VIEW_SECONDS := 0.32
const GUIDANCE_SECONDS := 1.75
const GUIDANCE_TURN_RATE := PI * 0.5
const GUIDANCE_MAX_ERROR := deg_to_rad(65.0)
const ROUTE_CLEARANCE_M := 0.35
const ROUTE_REFRESH_SECONDS := 0.25
const ROUTE_RETARGET_DISTANCE_M := 8.0
const ROUTE_EXIT_ANGLE := deg_to_rad(25.0)
const STEERING_LOOKAHEAD_M := 4.0
const ROUTE_POINT_EPSILON_M := 0.0001
const PATROL_COLLISION_MASK := PatrolRobot.PROJECTILE_LAYER | SpatialFlyingPatrol.PROJECTILE_LAYER

var velocity := Vector3.ZERO
var launch_speed := CRUISE_SPEED_MPS
var collision_mask := 1
var shooter := RID()
var guided_target: SpatialFlyingPatrol
var impact_audio: AudioStream
var impact_volume_db := -6.0
var _life_remaining := LIFETIME_SECONDS
var _fade_remaining := 0.0
var _impact_view_remaining := 0.0
var _patrol_impact := false
var _patrol_impact_view := Transform3D.IDENTITY
var _has_approach_view := false
var _approach_view := Transform3D.IDENTITY
var _travelled := 0.0
var _guided_route := PackedVector3Array()
var _route_next := 0
var _route_refresh_at := 0.0
var _route_query: PhysicsShapeQueryParameters3D
@onready var _rocket := $Rocket as Node3D
@onready var _tracer := $Tracer as MeshInstance3D
@onready var _material := _tracer.material_override as ShaderMaterial

static func aimed_velocity(direction: Vector3, inherited: Vector3) -> Vector3:
	# Keep the aim line while adding a lead when the ship is already fast.
	var forward_speed := inherited.dot(direction)
	return direction * maxf(CRUISE_SPEED_MPS, forward_speed + MIN_LEAD_SPEED_MPS)

static func find_guided_aim(origin: Vector3, target: SpatialFlyingPatrol, inherited_velocity: Vector3) -> Vector3:
	if not is_instance_valid(target):
		return origin
	var direction := (target.global_position - origin).normalized()
	return _predict_aim(origin, target, aimed_velocity(direction, inherited_velocity).length(),
		LAUNCH_ACCEL_SECONDS * 0.5)

static func _predict_aim(origin: Vector3, target: SpatialFlyingPatrol, speed: float, launch_delay: float = 0.0) -> Vector3:
	var point := target.global_position
	for _sample in 3:
		var arrival_time := minf(GUIDANCE_SECONDS, origin.distance_to(point) / speed + launch_delay)
		point = target.predict_curve_position(arrival_time)
	return point

func is_in_flight() -> bool:
	return _life_remaining > 0.0 and _fade_remaining == 0.0 \
		and _impact_view_remaining == 0.0 and not is_queued_for_deletion()

func has_camera_view() -> bool:
	return is_in_flight() or _impact_view_remaining > 0.0

func camera_view_transform() -> Transform3D:
	if _patrol_impact and _impact_view_remaining > 0.0:
		var elapsed := PATROL_IMPACT_VIEW_SECONDS - _impact_view_remaining
		return _approach_view.interpolate_with(_patrol_impact_view,
			smoothstep(0.0, PATROL_IMPACT_VIEW_SECONDS, elapsed))
	if _has_approach_view or _impact_view_remaining > 0.0:
		return _approach_view
	var pose := get_global_transform_interpolated()
	pose.origin -= pose.basis.z * 0.08
	return pose

func prepare_target(inherited := Vector3.ZERO) -> void:
	if is_instance_valid(guided_target):
		var start := global_position
		var forecast := find_guided_aim(start, guided_target, inherited)
		var aim := _visible_guided_aim(start, forecast)
		if not aim.is_finite() and _plan_guided_route(start, forecast, 0.0):
			aim = _guided_route[_route_next]
		if aim.is_finite():
			var direction := (aim - start).normalized()
			velocity = aimed_velocity(direction, inherited)
			launch_speed = maxf(0.0, inherited.dot(direction)) + LAUNCH_LEAD_MPS
			_face_direction(direction)
		return
	var estimated_range := velocity.length() * LIFETIME_SECONDS
	var query := PhysicsRayQueryParameters3D.create(global_position,
		global_position + velocity.normalized() * estimated_range,
		collision_mask | PATROL_COLLISION_MASK, [shooter])
	var target := get_world_3d().direct_space_state.intersect_ray(query)
	if not target.is_empty():
		Fracture.for_hit(target["collider"])

func _physics_process(delta: float) -> void:
	if not is_in_flight():
		_impact_view_remaining = maxf(0.0, _impact_view_remaining - delta)
		_fade_remaining = maxf(0.0, _fade_remaining - delta)
		_material.set_shader_parameter("fade", _fade_remaining / FADE_SECONDS)
		if _fade_remaining <= 0.0 and _impact_view_remaining <= 0.0:
			queue_free()
		return

	var start := global_position
	var step := minf(delta, _life_remaining)
	var age := LIFETIME_SECONDS - _life_remaining
	_update_guidance(start, age, step)
	var acceleration := smoothstep(0.0, LAUNCH_ACCEL_SECONDS, age + step * 0.5)
	var speed := lerpf(launch_speed, velocity.length(), acceleration)
	var movement := _advance_swept(start, speed * step)
	var finish: Vector3 = movement["position"]
	var hit: Dictionary = movement["hit"]
	_update_approach_view(start, velocity.normalized(), speed, hit)
	if not hit.is_empty():
		finish = hit["position"]
		var collider: Object = hit["collider"]
		_patrol_impact = collider is SpatialFlyingPatrol
		_impact_view_remaining = PATROL_IMPACT_VIEW_SECONDS if _patrol_impact else IMPACT_VIEW_SECONDS
		if _patrol_impact:
			_prepare_patrol_impact_view(finish)
		if collider is PatrolRobot or collider is SpatialFlyingPatrol:
			collider.destroy()
		elif collider is BreakableWindow:
			collider.shatter()
		else:
			var fracture := Fracture.for_hit(collider)
			if fracture != null:
				fracture.hit(finish, hit["normal"])
		_show_impact(finish, hit["normal"])
	global_position = finish
	_update_tracer()
	_life_remaining -= step
	if not hit.is_empty() or _life_remaining <= 0.0:
		_rocket.hide()
		_fade_remaining = FADE_SECONDS

func _update_guidance(start: Vector3, age: float, step: float) -> void:
	if not is_instance_valid(guided_target) or not guided_target.active:
		guided_target = null
		_guided_route.clear()
		return
	var has_graph := guided_target.navigation_root() != null
	var guidance_time := LIFETIME_SECONDS if has_graph else GUIDANCE_SECONDS
	if age >= guidance_time:
		guided_target = null
		_guided_route.clear()
		return
	var speed := velocity.length()
	if is_zero_approx(speed):
		return
	var heading := velocity / speed
	var forecast := _predict_aim(start, guided_target, speed)
	var aim := _visible_guided_aim(start, forecast)
	if aim.is_finite():
		var desired := (aim - start).normalized()
		var angle := heading.angle_to(desired)
		var turn_limit := GUIDANCE_MAX_ERROR if _guided_route.is_empty() else ROUTE_EXIT_ANGLE
		if angle <= turn_limit:
			var turn := GUIDANCE_TURN_RATE * minf(step, guidance_time - age)
			var direction := desired if angle <= turn else heading.slerp(desired, turn / angle)
			# Check ahead along the turn before leaving a checked route near a corner.
			var reach := minf(maxf(speed * step, STEERING_LOOKAHEAD_M), start.distance_to(aim))
			if _unobstructed(start, start + direction * reach):
				_guided_route.clear()
				velocity = direction * speed
				_face_direction(direction)
				return
	if has_graph and age >= _route_refresh_at and (_guided_route.is_empty() \
			or _guided_route[-1].distance_to(forecast) >= ROUTE_RETARGET_DISTANCE_M):
		_plan_guided_route(start, forecast, age)
	elif not has_graph and aim.is_finite():
		# The short direct lock still drops when a target passes outside its turn cone.
		if heading.angle_to((aim - start).normalized()) > GUIDANCE_MAX_ERROR:
			guided_target = null

func _visible_guided_aim(start: Vector3, forecast: Vector3) -> Vector3:
	if _unobstructed(start, forecast):
		return forecast
	var current := guided_target.global_position
	return current if current != forecast and _unobstructed(start, current) else Vector3.INF

func _unobstructed(start: Vector3, finish: Vector3) -> bool:
	if not finish.is_finite() or finish.is_equal_approx(start):
		return false
	var sight := PhysicsRayQueryParameters3D.create(start, finish, collision_mask,
		[shooter, guided_target.get_rid()])
	sight.hit_from_inside = true
	return get_world_3d().direct_space_state.intersect_ray(sight).is_empty()

func _plan_guided_route(start: Vector3, destination: Vector3, age: float) -> bool:
	_route_refresh_at = age + ROUTE_REFRESH_SECONDS
	var graph_root := guided_target.navigation_root()
	if graph_root == null or not destination.is_finite():
		return false
	var route := _route_to(graph_root, start, destination)
	var current := guided_target.global_position
	if route.is_empty() and destination.distance_to(current) > 1.0:
		route = _route_to(graph_root, start, current)
	if route.size() < 2:
		return false
	_guided_route = route
	_route_next = 1
	return true

func _route_to(graph_root: Node3D, start: Vector3, destination: Vector3) -> PackedVector3Array:
	var graph := guided_target.navigation_graph_for(start, destination)
	return ProjectileRoute.plan(graph, graph_root, start, destination, ROUTE_CLEARANCE_M,
		velocity.length() * _life_remaining, _route_segment_clear)

func _route_segment_clear(start: Vector3, finish: Vector3) -> bool:
	if _route_query == null:
		_route_query = PhysicsShapeQueryParameters3D.new()
		var shape := SphereShape3D.new()
		shape.radius = ROUTE_CLEARANCE_M
		_route_query.shape = shape
		_route_query.collision_mask = collision_mask
	_route_query.exclude = [shooter, guided_target.get_rid()]
	_route_query.transform = Transform3D(Basis.IDENTITY, start)
	_route_query.motion = Vector3.ZERO
	var space := get_world_3d().direct_space_state
	if not space.intersect_shape(_route_query, 1).is_empty():
		return false
	_route_query.motion = finish - start
	var fractions := space.cast_motion(_route_query)
	return fractions.size() == 2 and fractions[0] >= 1.0

func _face_direction(direction: Vector3) -> void:
	var up := Vector3.UP if absf(direction.dot(Vector3.UP)) < 0.99 else Vector3.FORWARD
	global_basis = Basis.looking_at(direction, up)

func _advance_swept(start: Vector3, distance: float) -> Dictionary:
	var position := start
	var hit: Dictionary = {}
	var query := PhysicsRayQueryParameters3D.create(start, start, collision_mask | PATROL_COLLISION_MASK, [shooter])
	query.hit_from_inside = true
	var space := get_world_3d().direct_space_state
	while distance > ROUTE_POINT_EPSILON_M and not velocity.is_zero_approx():
		var length := distance
		var following := _route_next < _guided_route.size()
		var direction := velocity.normalized()
		var reached_sample := false
		if following:
			var offset := _guided_route[_route_next] - position
			var span := offset.length()
			if span <= ROUTE_POINT_EPSILON_M:
				_route_next += 1
				if _route_next == _guided_route.size():
					_guided_route.clear()
					break
				continue
			direction = offset / span
			velocity = direction * velocity.length()
			_face_direction(direction)
			length = minf(span, distance)
			reached_sample = span <= distance
		query.from = position
		query.to = _guided_route[_route_next] if reached_sample else position + direction * length
		hit = space.intersect_ray(query)
		var end: Vector3 = query.to if hit.is_empty() else hit["position"]
		_travelled += position.distance_to(end)
		position = end
		if not hit.is_empty():
			break
		distance -= length
		if reached_sample:
			_route_next += 1
			if _route_next == _guided_route.size():
				_guided_route.clear()
				break
	return {"position": position, "hit": hit}

func _update_approach_view(start: Vector3, forward: Vector3, speed: float, hit: Dictionary) -> void:
	var space := get_world_3d().direct_space_state
	var target := hit
	if target.is_empty() and not forward.is_zero_approx():
		var distance := minf(_life_remaining, APPROACH_VIEW_SECONDS) * speed
		var prediction := PhysicsRayQueryParameters3D.create(start, start + forward * distance,
			collision_mask | PATROL_COLLISION_MASK, [shooter])
		target = space.intersect_ray(prediction)
	_has_approach_view = not target.is_empty()
	if not _has_approach_view:
		return
	var point: Vector3 = target["position"]
	var span := start.distance_to(point)
	var basis := global_basis.orthonormalized()
	var eye := start + basis.z * maxf(6.0, span * 0.30) \
		+ basis.x * maxf(4.0, span * 0.28) + basis.y * maxf(3.0, span * 0.18)
	# Keep the camera on the same side of nearby geometry as the rocket.
	var sight := PhysicsRayQueryParameters3D.create(start, eye, collision_mask, [shooter])
	var obstruction := space.intersect_ray(sight)
	if not obstruction.is_empty():
		var wall: Vector3 = obstruction["position"]
		eye = wall.move_toward(start, 0.2)
	var focus := start.lerp(point, 0.58)
	if not eye.is_equal_approx(focus):
		_approach_view = Transform3D(Basis.looking_at(focus - eye, basis.y), eye)

func _show_impact(point: Vector3, normal: Vector3) -> void:
	var surface_up := normal if not normal.is_zero_approx() else -velocity.normalized()
	var axis := Vector3.RIGHT if absf(surface_up.z) > 0.99 else Vector3.FORWARD
	var right := surface_up.cross(axis).normalized()
	var impact := IMPACT.instantiate() as Node3D
	impact.sound_override = impact_audio
	impact.volume_db = impact_volume_db
	if _patrol_impact:
		impact.visual_speed = PATROL_IMPACT_VISUAL_SPEED
	get_parent().add_child(impact, true)
	impact.global_transform = Transform3D(Basis(right, surface_up, right.cross(surface_up)), point)

func _prepare_patrol_impact_view(point: Vector3) -> void:
	var start := _approach_view.origin
	var eye := start.lerp(point, PATROL_IMPACT_PUSH)
	# The full camera move stays on the near side of any wall along its path.
	var sight := PhysicsRayQueryParameters3D.create(start, eye, collision_mask, [shooter])
	sight.hit_from_inside = true
	var obstruction := get_world_3d().direct_space_state.intersect_ray(sight)
	if not obstruction.is_empty():
		var wall: Vector3 = obstruction["position"]
		eye = wall.move_toward(start, 0.2)
	_patrol_impact_view = _approach_view
	var direction := (point - eye).normalized()
	if not direction.is_zero_approx():
		var up := _approach_view.basis.y
		if absf(direction.dot(up)) > 0.99:
			up = _approach_view.basis.x
		_patrol_impact_view = Transform3D(Basis.looking_at(direction, up), eye)

func _update_tracer() -> void:
	# Reveal the rocket from the mount and keep its exhaust on the flown path.
	var body_length := minf(_travelled, EXHAUST_ORIGIN)
	_rocket.scale.z = maxf(0.05, body_length / EXHAUST_ORIGIN)
	var speed_length := minf(velocity.length() * TRACER_SECONDS, MAX_TRACER_LENGTH)
	var length := minf(_travelled - body_length, speed_length)
	_tracer.visible = length > 0.03
	if _tracer.visible:
		_tracer.scale.y = length
		_tracer.position.z = body_length + length * 0.5
