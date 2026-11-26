@tool
extends "res://addons/spatial_toolkit/runtime/drone_camera.gd"
## Mouse-directed flight along the center of the view with independent keyboard thrust.

const DEFAULT_RETICLE_SCREEN_OFFSET := 24.0
const MAX_VISUAL_BANK := deg_to_rad(35.0)
const LOOK_PITCH_LIMIT := deg_to_rad(80.0)

@export_group("Reticle Flight Controls")
@export_range(1.0, 150.0, 0.5, "suffix:m/s²") var throttle_acceleration_mps2 := 18.0
@export_range(1.0, 60.0, 0.5, "suffix:m/s") var strafe_speed_mps := 12.0
@export_range(1.0, 60.0, 0.5, "suffix:m/s") var lift_speed_mps := 9.0
@export_range(1.0, 100.0, 0.5, "suffix:m/s²") var maneuver_acceleration_mps2 := 24.0
@export_group("")

var _maneuver_velocity := Vector2.ZERO
var _last_attitude := Vector2.ZERO

func _init() -> void:
	vertical_screen_offset = default_vertical_screen_offset()

func default_vertical_screen_offset() -> float:
	return DEFAULT_RETICLE_SCREEN_OFFSET

func _ready() -> void:
	super._ready()
	if not Engine.is_editor_hint() and _detached_pivot:
		_last_attitude = Vector2(_drone_yaw, _drone_pitch)
		_follow_camera(0.0)

func _physics_process(delta: float) -> void:
	if not _flight_controls_ready(delta):
		return
	_handle_pending_click()
	var throttle := float(Input.is_physical_key_pressed(KEY_W)) - float(Input.is_physical_key_pressed(KEY_S))
	var strafe := float(Input.is_physical_key_pressed(KEY_D)) - float(Input.is_physical_key_pressed(KEY_A))
	var lift := float(Input.is_physical_key_pressed(KEY_E)) - float(Input.is_physical_key_pressed(KEY_Q))
	_reticle_step(throttle, strafe, lift, delta)
	_update_reticle()

func _reticle_step(throttle: float, strafe: float, lift: float, delta: float) -> void:
	_cruise_speed_mps = clampf(_cruise_speed_mps + throttle * throttle_acceleration_mps2 * delta,
		-reverse_speed_limit_mps, forward_speed_limit_mps)
	var maneuver := Vector2(strafe, lift).limit_length()
	_maneuver_velocity = _maneuver_velocity.move_toward(maneuver * Vector2(strafe_speed_mps, lift_speed_mps),
		maneuver_acceleration_mps2 * delta)
	var right := Vector3(cos(_drone_yaw), 0.0, -sin(_drone_yaw))
	var forward := _forward() if _free_look else project_ray_normal(_reticle_center())
	_move_drone(forward * _cruise_speed_mps + right * _maneuver_velocity.x + Vector3.UP * _maneuver_velocity.y)
	_follow_camera(delta)
	if not _flight_active:
		return
	var turn := angle_difference(_last_attitude.x, _drone_yaw) / maxf(delta * deg_to_rad(turn_speed_degrees), 0.001)
	var bank := clampf(turn - strafe, -1.0, 1.0)
	_classic_bank = lerpf(_classic_bank, MAX_VISUAL_BANK * bank, 1.0 - exp(-delta * 9.0))
	_set_craft_attitude(_classic_bank)
	_set_exhaust_turn(bank)
	_update_maneuver_exhaust(maxf(absf(throttle), maneuver.length()), _last_attitude, delta)
	_last_attitude = Vector2(_drone_yaw, _drone_pitch)

func _unhandled_input(event: InputEvent) -> void:
	if Engine.is_editor_hint():
		return
	if event is InputEventMouseMotion:
		if current and _flight_active:
			_aim_with_mouse(event.relative)
			get_viewport().set_input_as_handled()
		return
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_RIGHT:
			if current and _flight_active:
				_free_look = event.pressed
				if not _free_look:
					_orbit_yaw = 0.0
					_orbit_pitch = 0.0
					_follow_camera(0.0)
				_update_reticle()
				get_viewport().set_input_as_handled()
			return
		if event.button_index == MOUSE_BUTTON_LEFT:
			if current and event.pressed and _respawn_remaining <= 0.0:
				if not _flight_active:
					_capture_mouse()
				else:
					_pending_aim = _reticle_center()
					_pending_click = true
					_pending_shot = true
				get_viewport().set_input_as_handled()
			return
	super._unhandled_input(event)

func _aim_with_mouse(relative: Vector2) -> void:
	if _free_look:
		super._look(relative)
		_orbit_pitch = clampf(_orbit_pitch, -LOOK_PITCH_LIMIT - _drone_pitch, LOOK_PITCH_LIMIT - _drone_pitch)
	else:
		_drone_yaw = wrapf(_drone_yaw - relative.x * mouse_sensitivity, -PI, PI)
		_drone_pitch = clampf(_drone_pitch - relative.y * mouse_sensitivity, -LOOK_PITCH_LIMIT, LOOK_PITCH_LIMIT)
	_follow_camera(0.0)

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

func _update_reticle() -> void:
	_pointer = _reticle_center()
	super._update_reticle()
