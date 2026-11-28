@tool
extends "res://addons/spatial_toolkit/runtime/reticle_flight_camera.gd"
## Gamepad flight with continuous pitch, independent camera orbit and persistent aim.

const ACCELERATE_ACTION := &"flight_gamepad_accelerate"
const BRAKE_ACTION := &"flight_gamepad_brake"
const ORBIT_ACTION := &"flight_gamepad_orbit"
const FREE_AIM_ACTION := &"flight_free_aim"
const SELECT_TARGET_ACTION := &"flight_gamepad_select_target"
const DESTINATION_ACTION := &"flight_gamepad_destination"
const GROUND_CAMERA_SETTLE_ANGLE := deg_to_rad(0.2)

@export_group("Gamepad Maneuver")
@export_range(1.0, 300.0, 1.0, "suffix:m/s²") var button_acceleration_mps2 := 80.0
@export_range(1.0, 300.0, 1.0, "suffix:m/s²") var button_braking_mps2 := 120.0
@export_range(1.0, 300.0, 1.0, "suffix:m/s²") var strafe_acceleration_mps2 := 120.0
@export_range(0.0, 75.0, 1.0, "degrees") var max_bank_angle_degrees := 60.0
@export_group("")

var _aim_offset := Vector2.ZERO
var _free_aim_active := false
var _wait_for_look_neutral := false
var _resume_when_focused := false
var _camera_attitude := Quaternion.IDENTITY
var _settling_ground_camera := false

func default_strafe_speed_mps() -> float:
	return 32.0

func _gamepad_can_select_destination() -> bool:
	return true

func _defaults_to_staged_target_lock() -> bool:
	return true

func _ready() -> void:
	super._ready()
	if not Engine.is_editor_hint():
		get_window().focus_entered.connect(_on_window_focus_entered)
		_set_boost_exhaust(false)

func _physics_process(delta: float) -> void:
	if not _flight_controls_ready(delta):
		_set_boost_exhaust(false)
		return
	var destination_selected := _handle_pending_click() and _has_destination
	var movement := _gamepad_stick(GAMEPAD_MOVE_ACTIONS, true)
	var look := _look_input()
	# A stick still held from aiming must not move the reticle or cancel the new course.
	_wait_for_look_neutral = (destination_selected or _wait_for_look_neutral) and not look.is_zero_approx()
	if _wait_for_look_neutral:
		look = Vector2.ZERO
	var free_aim := _gamepad_free_aim_held()
	var keyboard := _keyboard_movement()
	var throttle := clampf(-keyboard.y - movement.y, -1.0, 1.0)
	var strafe := clampf(keyboard.x + movement.x, -1.0, 1.0)
	var lift := _lift_input()
	if not is_zero_approx(strafe) or not is_zero_approx(lift) or (not free_aim and not _free_look and not look.is_zero_approx()):
		_take_manual_control()
	if not look.is_zero_approx():
		if free_aim and not _free_look:
			_move_free_aim(look, delta)
		else:
			_aim_with_gamepad(look, delta)
	if _has_destination:
		_update_reticle_throttle(throttle, delta)
		_flight_step(delta)
		_follow_camera(delta)
		if destination_selected:
			_recenter_aim()
		_last_attitude = Vector2(_drone_yaw, _drone_pitch)
	else:
		_reticle_step(throttle, strafe, lift, delta)
	_update_reticle()
	_update_target_lock(delta)

func _handle_flight_action(event: InputEvent, gamepad: bool) -> bool:
	if FlightInput.event_pressed(event, SELECT_TARGET_ACTION):
		if not _flight_active:
			_capture_mouse()
		elif not _free_look:
			_target_pick_requested = true
		return true
	if FlightInput.event_matches(event, ACCELERATE_ACTION) or FlightInput.event_matches(event, BRAKE_ACTION) \
			or FlightInput.event_matches(event, FREE_AIM_ACTION):
		return true
	if FlightInput.event_pressed(event, DESTINATION_ACTION):
		if not _flight_active:
			_capture_mouse()
		elif not _free_look:
			_queue_flight_click(_event_aim(event), false)
		return true
	var orbit_event := FlightInput.joy_event_is_bound(event, ORBIT_ACTION) if gamepad else FlightInput.event_matches(event, ORBIT_ACTION)
	if orbit_event:
		var held := FlightInput.joy_strength(ORBIT_ACTION, event.device) > InputMap.action_get_deadzone(ORBIT_ACTION) \
			if gamepad else FlightInput.keyboard_mouse_strength(ORBIT_ACTION) > 0.0
		_set_free_look(held)
		return true
	return super._handle_flight_action(event, gamepad)

func _flight_pitch(pitch: float) -> float:
	return wrapf(pitch, -PI, PI)

func _aim_orbit(relative: Vector2) -> void:
	_look(relative)

func _reticle_course() -> Vector3:
	return _forward()

func _update_maneuver_velocity(target: Vector2, delta: float) -> void:
	_maneuver_velocity.x = move_toward(_maneuver_velocity.x, target.x, strafe_acceleration_mps2 * delta)
	_maneuver_velocity.y = move_toward(_maneuver_velocity.y, target.y, maneuver_acceleration_mps2 * delta)

func _max_visual_bank() -> float:
	return deg_to_rad(max_bank_angle_degrees)

func _follow_camera(delta: float) -> void:
	var course := Quaternion.from_euler(Vector3(_drone_pitch, _drone_yaw, 0.0))
	var ground_contact := not _ground_contact_normal.is_zero_approx()
	if delta > 0.0 and ground_contact:
		_settling_ground_camera = true
	if not _settling_ground_camera:
		_camera_attitude = course
	elif delta > 0.0:
		var weight := 1.0 - exp(-delta / camera_lag_seconds)
		_camera_attitude = _camera_attitude.slerp(course, weight).normalized()
		if _camera_attitude.angle_to(course) <= GROUND_CAMERA_SETTLE_ANGLE:
			_camera_attitude = course
			_settling_ground_camera = ground_contact
	var attitude := Basis(_camera_attitude)
	var orbit := Basis.from_euler(Vector3(_orbit_pitch, _orbit_yaw, 0.0))
	_pivot.global_basis = attitude * orbit * Basis(Vector3.RIGHT, -rotation.x)
	var eye_height := _eye_height + (follow_height if third_person else 0.0)
	_pivot.global_position = _body.global_position + attitude.y * eye_height

func _update_reticle_throttle(throttle: float, delta: float) -> float:
	var rate := gamepad_cruise_rate_mps2
	var brake := _flight_action_strength(BRAKE_ACTION)
	var boosting := false
	if brake > 0.0:
		throttle = -brake
		rate = button_braking_mps2
	elif throttle > 0.0 and _flight_action_down(ACCELERATE_ACTION) \
			and _gamepad_stick(GAMEPAD_MOVE_ACTIONS, true).y < 0.0:
		boosting = true
		rate = button_acceleration_mps2
	var speed := clampf(_cruise_speed_mps + throttle * rate * delta, 0.0, forward_speed_limit_mps)
	_change_cruise_speed(speed - _cruise_speed_mps, false)
	_set_boost_exhaust(boosting)
	return throttle

func _set_boost_exhaust(boosting: bool) -> void:
	if not is_instance_valid(_craft):
		return
	for child in _craft.get_children():
		if child is EXHAUST_TRAIL:
			if boosting and not child.emitting:
				child.restart()
			child.emitting = boosting
			child.visible = boosting
			if boosting:
				child.boost()

func _on_window_focus_exited() -> void:
	_resume_when_focused = current and _flight_active
	super._on_window_focus_exited()

func _on_window_focus_entered() -> void:
	if _resume_when_focused and current:
		_capture_mouse()
	_resume_when_focused = false

func _release_mouse() -> void:
	_settling_ground_camera = false
	super._release_mouse()
	_wait_for_look_neutral = false
	_set_boost_exhaust(false)

func _uses_gamepad_cruise() -> bool:
	return false

func _gamepad_free_aim_held() -> bool:
	var strength := maxf(FlightInput.keyboard_mouse_strength(FREE_AIM_ACTION), _gamepad_action_strength(FREE_AIM_ACTION))
	var threshold := maxf(InputMap.action_get_deadzone(FREE_AIM_ACTION), 0.001)
	_free_aim_active = strength > minf(GAMEPAD_TRIGGER_RELEASE, threshold * 0.55) if _free_aim_active else strength >= threshold
	return _free_aim_active

func _move_free_aim(stick: Vector2, delta: float) -> void:
	var view_size := get_viewport().get_visible_rect().size
	var short_side := minf(view_size.x, view_size.y)
	if short_side <= 0.0:
		return
	var margin := minf(18.0, short_side * 0.25)
	var point := _reticle_aim() + stick * (short_side * gamepad_pointer_speed * delta)
	point = point.clamp(Vector2.ONE * margin, view_size - Vector2.ONE * margin)
	_aim_offset = (point - _reticle_center()) / view_size

func _reticle_aim() -> Vector2:
	return _reticle_center() + _aim_offset * get_viewport().get_visible_rect().size

func _recenter_aim() -> void:
	_aim_offset = Vector2.ZERO
	super._recenter_aim()
