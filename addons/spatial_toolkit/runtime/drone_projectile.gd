extends Node3D
## An arcade rocket with a swept collision query and a fading exhaust.

const Fracture := preload("res://addons/spatial_toolkit/runtime/building_fracture.gd")
const BreakableWindow := preload("res://addons/spatial_toolkit/runtime/breakable_window.gd")
const PatrolRobot := preload("res://addons/spatial_toolkit/runtime/patrol_robot.gd")
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
const APPROACH_VIEW_SECONDS := 0.32

var velocity := Vector3.ZERO
var launch_speed := CRUISE_SPEED_MPS
var collision_mask := 1
var shooter := RID()
var impact_audio: AudioStream
var impact_volume_db := -6.0
var _life_remaining := LIFETIME_SECONDS
var _fade_remaining := 0.0
var _impact_view_remaining := 0.0
var _has_approach_view := false
var _approach_view := Transform3D.IDENTITY
var _travelled := 0.0
@onready var _rocket := $Rocket as Node3D
@onready var _tracer := $Tracer as MeshInstance3D
@onready var _material := _tracer.material_override as ShaderMaterial

static func aimed_velocity(direction: Vector3, inherited: Vector3) -> Vector3:
	# Keep the aim line while adding a lead when the ship is already fast.
	var forward_speed := inherited.dot(direction)
	return direction * maxf(CRUISE_SPEED_MPS, forward_speed + MIN_LEAD_SPEED_MPS)

func is_in_flight() -> bool:
	return _life_remaining > 0.0 and _fade_remaining == 0.0 \
		and _impact_view_remaining == 0.0 and not is_queued_for_deletion()

func has_camera_view() -> bool:
	return is_in_flight() or _impact_view_remaining > 0.0

func camera_view_transform() -> Transform3D:
	if _has_approach_view or _impact_view_remaining > 0.0:
		return _approach_view
	var pose := get_global_transform_interpolated()
	pose.origin -= pose.basis.z * 0.08
	return pose

func prepare_target() -> void:
	var estimated_range := velocity.length() * LIFETIME_SECONDS
	var query := PhysicsRayQueryParameters3D.create(global_position,
		global_position + velocity.normalized() * estimated_range,
		collision_mask | PatrolRobot.PROJECTILE_LAYER, [shooter])
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
	var acceleration := smoothstep(0.0, LAUNCH_ACCEL_SECONDS, age + step * 0.5)
	var speed := lerpf(launch_speed, velocity.length(), acceleration)
	var forward := velocity.normalized()
	var finish := start + forward * speed * step
	var query := PhysicsRayQueryParameters3D.create(start, finish,
		collision_mask | PatrolRobot.PROJECTILE_LAYER, [shooter])
	query.hit_from_inside = true
	var hit := get_world_3d().direct_space_state.intersect_ray(query)
	_update_approach_view(start, forward, speed, hit)
	if not hit.is_empty():
		finish = hit["position"]
		_impact_view_remaining = IMPACT_VIEW_SECONDS
		var collider: Object = hit["collider"]
		if collider is PatrolRobot:
			collider.destroy()
		elif collider is BreakableWindow:
			collider.shatter()
		else:
			var fracture := Fracture.for_hit(collider)
			if fracture != null:
				fracture.hit(finish, hit["normal"])
		_show_impact(finish, hit["normal"])
	global_position = finish
	_travelled += start.distance_to(finish)
	_update_tracer()
	_life_remaining -= step
	if not hit.is_empty() or _life_remaining <= 0.0:
		_rocket.hide()
		_fade_remaining = FADE_SECONDS

func _update_approach_view(start: Vector3, forward: Vector3, speed: float, hit: Dictionary) -> void:
	var space := get_world_3d().direct_space_state
	var target := hit
	if target.is_empty() and not forward.is_zero_approx():
		var distance := minf(_life_remaining, APPROACH_VIEW_SECONDS) * speed
		var prediction := PhysicsRayQueryParameters3D.create(start, start + forward * distance,
			collision_mask | PatrolRobot.PROJECTILE_LAYER, [shooter])
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
	get_parent().add_child(impact, true)
	impact.global_transform = Transform3D(Basis(right, surface_up, right.cross(surface_up)), point)

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
