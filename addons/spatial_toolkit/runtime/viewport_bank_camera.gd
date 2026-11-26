@tool
extends "res://addons/spatial_toolkit/runtime/drone_camera.gd"
## Experimental keyboard steering with a square camera framing zone.

@export_range(1.0, 50.0, 0.5) var point_flight_speed_mps := 10.0
@export_range(0.05, 2.0, 0.05) var lateral_recenter_delay_seconds := 0.35
@export_range(0.45, 0.95, 0.01) var frame_limit := 0.81
@export_range(1.0, 50.0, 0.5) var bank_speed_mps := 10.0
@export_range(1.0, 50.0, 0.5) var climb_speed_mps := 9.0
@export_range(1.0, 80.0, 0.5) var steering_acceleration := 18.0

const MAX_VISUAL_PITCH_LEAD := deg_to_rad(28.0)

var _steering_velocity := Vector2.ZERO
var _bank := 0.0
var _visual_pitch_lead := 0.0
var _lateral_command := 0.0
var _track_pitch := false
var _turned_at_edge := false
var _lateral_recenter_remaining := 0.0
var _center_with_yaw := false
var _recenter_pan_elapsed := 0.0

func _physics_process(delta: float) -> void:
	if not _flight_controls_ready(delta):
		return
	var keys := Vector2(
		float(Input.is_physical_key_pressed(KEY_D)) - float(Input.is_physical_key_pressed(KEY_A)),
		_pitch_input())
	var lift := float(Input.is_physical_key_pressed(KEY_E)) - float(Input.is_physical_key_pressed(KEY_Q))
	var previous_attitude := Vector2(_drone_yaw, _drone_pitch)
	var selected_destination := _handle_pending_click()
	if selected_destination:
		_steering_velocity = Vector2.ZERO
		if is_zero_approx(_cruise_speed_mps):
			_cruise_speed_mps = point_flight_speed_mps
	if _has_destination and keys.is_zero_approx() and is_zero_approx(lift):
		_lateral_command = 0.0
		_visual_pitch_lead = 0.0
		_flight_step(delta)
		var turn_step := deg_to_rad(turn_speed_degrees) * delta
		_set_exhaust_turn(angle_difference(previous_attitude.x, _drone_yaw) / maxf(turn_step, 0.001))
	else:
		_steering_step(keys, delta, lift)
	_follow_camera(delta)
	var demand := maxf(keys.length(), absf(lift)) if not selected_destination else 1.0
	_update_maneuver_exhaust(demand, previous_attitude, delta)
	_update_reticle()

func _steering_step(axes: Vector2, delta: float, lift: float = 0.0) -> void:
	_take_manual_control()
	_lateral_command = axes.x
	if not _free_look and (not axes.is_zero_approx() or not is_zero_approx(lift)):
		_orbit_yaw = 0.0
		_orbit_pitch = 0.0
	var pitch_step := deg_to_rad(turn_speed_degrees) * delta
	if is_zero_approx(axes.y):
		_drone_pitch = rotate_toward(_drone_pitch, 0.0, pitch_step)
	else:
		_drone_pitch = wrapf(_drone_pitch + axes.y * pitch_step, -PI, PI)
		_track_pitch = true
	_steering_velocity = _steering_velocity.move_toward(
		Vector2(axes.x * bank_speed_mps, lift * climb_speed_mps), steering_acceleration * delta)
	var right := Vector3(cos(_drone_yaw), 0.0, -sin(_drone_yaw))
	_move_drone(_forward() * _cruise_speed_mps + right * _steering_velocity.x
		+ Vector3.UP * _steering_velocity.y)
	_visual_pitch_lead = lerpf(_visual_pitch_lead, MAX_VISUAL_PITCH_LEAD * axes.y,
		1.0 - exp(-delta * 9.0))
	_update_bank(-MAX_BANK * axes.x, delta)

func _update_bank(target: float, delta: float) -> void:
	_bank = lerpf(_bank, target, 1.0 - exp(-delta * 9.0))
	_update_banked_craft()

func _update_banked_craft() -> void:
	_set_craft_attitude(_bank, _visual_pitch_lead)
	_set_exhaust_turn(_bank / MAX_BANK)

func _follow_camera(delta: float) -> void:
	if not third_person:
		_track_pitch = false
		_turned_at_edge = false
		_lateral_recenter_remaining = 0.0
		_center_with_yaw = false
		_recenter_pan_elapsed = 0.0
		super._follow_camera(delta)
		return
	var body_position := _body.global_position
	var displacement_since_frame := body_position - _follow_last_position
	_follow_last_position = body_position
	var eye := body_position + Vector3.UP * (_eye_height + follow_height)
	var right := _pivot.global_basis.x.normalized()
	var horizontal_back := right.cross(Vector3.UP).normalized()
	var yaw := atan2(-right.z, right.x)
	var prior_yaw := yaw
	var back := _pivot.global_basis.z.normalized()
	var pitch := atan2(-back.y, back.dot(horizontal_back))
	var advance := horizontal_back * (eye - _pivot.global_position).dot(horizontal_back)
	var stationary_eye := eye - advance
	var extent := get_viewport().get_visible_rect().size
	var center := extent * 0.5
	center.y += extent.y * _chase_vertical_offset()
	var half_side := minf(extent.x, extent.y) * 0.5 * frame_limit
	var min_y := maxf(0.0, center.y - half_side)
	var max_y := minf(extent.y, center.y + half_side)
	if _has_destination:
		_turned_at_edge = false
		_lateral_recenter_remaining = 0.0
		_center_with_yaw = false
	elif not is_zero_approx(_lateral_command):
		_lateral_recenter_remaining = lateral_recenter_delay_seconds
		_center_with_yaw = false
	elif _turned_at_edge:
		_turned_at_edge = false
		_lateral_recenter_remaining = 0.0
		_center_with_yaw = true
	elif _lateral_recenter_remaining > 0.0:
		_lateral_recenter_remaining = maxf(0.0, _lateral_recenter_remaining - delta)
		_center_with_yaw = is_zero_approx(_lateral_recenter_remaining)
	if half_side > 0.0 and not is_position_behind(stationary_eye):
		var screen := unproject_position(stationary_eye)
		_turn_at_horizontal_edge(screen.x - center.x, half_side, delta)
		if screen.y < min_y or screen.y > max_y:
			_track_pitch = true
	var weight := 1.0 - exp(-delta / camera_lag_seconds)
	var camera_origin := global_position
	var target_yaw := _drone_yaw + _orbit_yaw
	var course := Vector3(sin(_drone_yaw), 0.0, cos(_drone_yaw))
	var cruise_advance := course * displacement_since_frame.dot(course)
	var aim := eye - (camera_origin + cruise_advance)
	# Let the boom orbit the ship during pitch tracking. Holding the old
	# camera position here would preserve the extra distance after a loop.
	var orbiting := _free_look or not is_zero_approx(_orbit_yaw) or not is_zero_approx(_orbit_pitch)
	var pan_to_ship := _center_with_yaw and not _track_pitch and not orbiting \
		and Vector2(aim.x, aim.z).length_squared() > 0.01 \
		and back.dot(horizontal_back) > 0.1
	if pan_to_ship:
		target_yaw = atan2(-aim.x, -aim.z)
		_recenter_pan_elapsed += delta
		var ramp := smoothstep(0.0, 0.25, _recenter_pan_elapsed)
		var max_step := deg_to_rad(35.0) * ramp * delta
		yaw = rotate_toward(yaw, lerp_angle(yaw, target_yaw, weight), max_step)
	else:
		_recenter_pan_elapsed = 0.0
		yaw = lerp_angle(yaw, target_yaw, weight)
	_track_pitch = _track_pitch or _has_destination or orbiting
	var tail_weight := 1.0 - exp(-delta * 3.0 / camera_lag_seconds)
	if _track_pitch:
		pitch = lerp_angle(pitch, _drone_pitch + _orbit_pitch, tail_weight)
	# Build the orbit basis directly so the camera can stay inverted.
	_pivot.global_basis = Basis.from_euler(Vector3(pitch, yaw, 0.0))
	if pan_to_ship:
		_drone_yaw = wrapf(yaw, -PI, PI)
		var turn_rate := angle_difference(prior_yaw, yaw) / maxf(delta, 0.001)
		_update_bank(MAX_BANK * clampf(turn_rate / deg_to_rad(35.0), -1.0, 1.0), delta)
		# Compensate the spring arm's orbit so yaw pans around the camera itself.
		_pivot.global_position += camera_origin - global_position

	# Frame with the final camera orientation and keep the horizontal axis
	# tied to yaw as the boom passes through vertical.
	horizontal_back = Vector3(sin(yaw), 0.0, cos(yaw))
	advance = cruise_advance if pan_to_ship else horizontal_back * (eye - _pivot.global_position).dot(horizontal_back)
	stationary_eye = eye - advance
	var camera_pose := get_camera_transform()
	var depth := (camera_pose.origin - stationary_eye).dot(camera_pose.basis.z)
	var desired := eye
	if depth > near and half_side > 0.0:
		desired = _pivot.global_position + advance
		var screen := unproject_position(stationary_eye)
		var bounded := screen.clamp(Vector2(center.x - half_side, min_y), Vector2(center.x + half_side, max_y))
		if _has_destination or orbiting:
			bounded.x = lerpf(bounded.x, center.x, weight)
		if _track_pitch:
			bounded.y = lerpf(bounded.y, center.y, tail_weight)
		if screen.distance_squared_to(bounded) > 0.01:
			desired += stationary_eye - project_position(bounded, depth)
	var offset := (desired - eye).limit_length(follow_distance * 1.5)
	_pivot.global_position = eye + _sweep_camera_offset(eye, offset)
	if _track_pitch and not _has_destination and absf(_drone_pitch) < 0.01 and absf(pitch) < 0.005:
		if absf(_pivot.global_position.y - eye.y) < 0.05:
			_track_pitch = false

func _turn_at_horizontal_edge(horizontal_offset: float, half_side: float, delta: float) -> void:
	if _free_look or horizontal_offset * _lateral_command <= 0.0:
		return
	# Blend in the turn just inside the framing limit so a corner does not
	# repeatedly engage and disengage as the camera catches up.
	var edge_weight := smoothstep(0.90, 1.0, absf(horizontal_offset) / half_side)
	if edge_weight <= 0.0:
		return
	_turned_at_edge = true
	var turn := deg_to_rad(turn_speed_degrees) * _lateral_command * edge_weight * delta
	_drone_yaw = wrapf(_drone_yaw - turn, -PI, PI)
	_update_banked_craft()

func _release_mouse() -> void:
	_steering_velocity = Vector2.ZERO
	_bank = 0.0
	_track_pitch = false
	_visual_pitch_lead = 0.0
	_lateral_command = 0.0
	_turned_at_edge = false
	_lateral_recenter_remaining = 0.0
	_center_with_yaw = false
	_recenter_pan_elapsed = 0.0
	super._release_mouse()
