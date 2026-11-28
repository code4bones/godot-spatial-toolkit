@tool
extends "res://addons/spatial_toolkit/runtime/drone_camera.gd"
## Center-reticle flight with independent lateral and vertical thrust.

const DEFAULT_RETICLE_SCREEN_OFFSET := 24.0
const DEFAULT_STRAFE_SPEED_MPS := 12.0
const MAX_VISUAL_BANK := deg_to_rad(35.0)
const LOOK_PITCH_LIMIT := deg_to_rad(80.0)

@export_group("Reticle Flight Controls")
@export_range(1.0, 150.0, 0.5, "suffix:m/s²") var throttle_acceleration_mps2 := 18.0
@export_range(1.0, 60.0, 0.5, "suffix:m/s") var strafe_speed_mps := DEFAULT_STRAFE_SPEED_MPS
@export_range(1.0, 60.0, 0.5, "suffix:m/s") var lift_speed_mps := 9.0
@export_range(1.0, 100.0, 0.5, "suffix:m/s²") var maneuver_acceleration_mps2 := 24.0
@export_group("")

var _maneuver_velocity := Vector2.ZERO
var _last_attitude := Vector2.ZERO

func _init() -> void:
	vertical_screen_offset = default_vertical_screen_offset()
	strafe_speed_mps = default_strafe_speed_mps()

func default_vertical_screen_offset() -> float:
	return DEFAULT_RETICLE_SCREEN_OFFSET

func default_strafe_speed_mps() -> float:
	return DEFAULT_STRAFE_SPEED_MPS

func _has_lift_controls() -> bool:
	return true

func _gamepad_can_select_destination() -> bool:
	return false

func _gamepad_uses_virtual_pointer() -> bool:
	return false

func _fires_on_left_click(_modifier_held: bool) -> bool:
	return true

func _ready() -> void:
	super._ready()
	if not Engine.is_editor_hint() and _detached_pivot:
		_last_attitude = Vector2(_drone_yaw, _drone_pitch)
		_follow_camera(0.0)

func _physics_process(delta: float) -> void:
	if not _flight_controls_ready(delta):
		return
	_handle_pending_click()
	_update_gamepad_cruise(delta)
	var aim := _look_input()
	if not aim.is_zero_approx():
		_aim_with_gamepad(aim, delta)
	var maneuver := _gamepad_stick(GAMEPAD_MOVE_ACTIONS)
	var keyboard := _keyboard_movement()
	var throttle := -keyboard.y
	var strafe := keyboard.x
	var lift := _lift_input()
	strafe = clampf(strafe + maneuver.x, -1.0, 1.0)
	lift = clampf(lift - maneuver.y, -1.0, 1.0)
	_reticle_step(throttle, strafe, lift, delta)
	_update_reticle()

func _reticle_step(throttle: float, strafe: float, lift: float, delta: float) -> void:
	var throttle_demand := _update_reticle_throttle(throttle, delta)
	var maneuver := Vector2(strafe, lift).limit_length()
	_update_maneuver_velocity(maneuver * Vector2(strafe_speed_mps, lift_speed_mps), delta)
	var right := Vector3(cos(_drone_yaw), 0.0, -sin(_drone_yaw))
	_move_drone(_reticle_course() * _cruise_speed_mps + right * _maneuver_velocity.x + Vector3.UP * _maneuver_velocity.y)
	_follow_camera(delta)
	if not _flight_active:
		return
	var turn := angle_difference(_last_attitude.x, _drone_yaw) / maxf(delta * deg_to_rad(turn_speed_degrees), 0.001)
	var bank := clampf(turn - strafe, -1.0, 1.0)
	_classic_bank = lerpf(_classic_bank, _max_visual_bank() * bank, 1.0 - exp(-delta * 9.0))
	_set_craft_attitude(_classic_bank)
	_set_exhaust_turn(bank)
	_update_maneuver_exhaust(maxf(absf(throttle_demand), maneuver.length()), _last_attitude, delta)
	_last_attitude = Vector2(_drone_yaw, _drone_pitch)

func _update_maneuver_velocity(target: Vector2, delta: float) -> void:
	_maneuver_velocity = _maneuver_velocity.move_toward(target, maneuver_acceleration_mps2 * delta)

func _update_reticle_throttle(throttle: float, delta: float) -> float:
	_cruise_speed_mps = clampf(_cruise_speed_mps + throttle * throttle_acceleration_mps2 * delta,
		-reverse_speed_limit_mps, forward_speed_limit_mps)
	return throttle

func _reticle_course() -> Vector3:
	return _forward() if _free_look else project_ray_normal(_reticle_center())

func _max_visual_bank() -> float:
	return MAX_VISUAL_BANK

func _aim_with_gamepad(stick: Vector2, delta: float) -> void:
	var turn_radians := deg_to_rad(turn_speed_degrees) * delta
	stick.y = -_gamepad_pitch(stick.y)
	_aim_with_mouse(stick * (turn_radians / maxf(mouse_sensitivity, 0.0001)))

func _set_free_look(pressed: bool) -> void:
	_free_look = pressed and _flight_active
	if not _free_look:
		_orbit_yaw = 0.0
		_orbit_pitch = 0.0
		_follow_camera(0.0)
	_update_reticle()

func _event_aim(_event: InputEvent) -> Vector2:
	return _reticle_aim()

func _pointer_motion(event: InputEventMouseMotion) -> void:
	_aim_with_mouse(event.relative)

func _aim_with_mouse(relative: Vector2) -> void:
	if _free_look:
		_aim_orbit(relative)
	else:
		_drone_yaw = wrapf(_drone_yaw - relative.x * mouse_sensitivity, -PI, PI)
		_drone_pitch = _flight_pitch(_drone_pitch - relative.y * mouse_sensitivity)
	_follow_camera(0.0)

func _aim_orbit(relative: Vector2) -> void:
	_look(relative)
	_orbit_pitch = clampf(_orbit_pitch, -LOOK_PITCH_LIMIT - _drone_pitch, LOOK_PITCH_LIMIT - _drone_pitch)

func _flight_pitch(pitch: float) -> float:
	return clampf(pitch, -LOOK_PITCH_LIMIT, LOOK_PITCH_LIMIT)

func _update_chase_framing() -> void:
	super._update_chase_framing()
	if _detached_pivot:
		_follow_camera(0.0)

func _follow_camera(_delta: float) -> void:
	# Keep the aim unchanged by the camera's local framing tilt.
	_pivot.global_rotation = Vector3(_drone_pitch + _orbit_pitch - rotation.x, _drone_yaw + _orbit_yaw, 0.0)
	_pivot.global_position = _body.global_position + Vector3.UP * (_eye_height + (follow_height if third_person else 0.0))

func _respawn_drone() -> void:
	super._respawn_drone()
	_last_attitude = Vector2(_drone_yaw, _drone_pitch)
	_follow_camera(0.0)

func _capture_mouse() -> void:
	super._capture_mouse()
	if _flight_active:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED

func _release_mouse() -> void:
	_maneuver_velocity = Vector2.ZERO
	_orbit_yaw = 0.0
	_orbit_pitch = 0.0
	super._release_mouse()
	if _detached_pivot:
		_follow_camera(0.0)

func _reticle_center() -> Vector2:
	return get_viewport().get_visible_rect().size * 0.5

func _reticle_aim() -> Vector2:
	return _reticle_center()

func _update_reticle() -> void:
	_pointer = _reticle_aim()
	super._update_reticle()
