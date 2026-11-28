@tool
extends "res://addons/spatial_toolkit/runtime/fly_camera.gd"
## Physical drone with signed wheel cruise, pointer destinations and chase view.

const Localization := preload("res://addons/spatial_toolkit/ui/editor_localization.gd")
const DEFAULT_VERTICAL_SCREEN_OFFSET := 12.0
const MAX_BANK := deg_to_rad(72.0)
const INVERT_WS_SETTING := "spatial_toolkit/flight/invert_ws"
const EXHAUST_TRAIL := preload("res://addons/spatial_toolkit/runtime/exhaust_trail.gd")
const CRASH_BURST := preload("res://addons/spatial_toolkit/runtime/drone_crash_burst.tscn")
const ENGINE_SOUND_PATH := "res://addons/spatial_toolkit/assets/audio/drone_engine.wav"
const THROTTLE_SOUND_PATH := "res://addons/spatial_toolkit/assets/audio/drone_throttle.mp3"
const LAUNCH_SOUND_PATH := "res://addons/spatial_toolkit/assets/audio/rocket_launch.mp3"
const PROJECTILE := preload("res://addons/spatial_toolkit/runtime/drone_projectile.tscn")
const Projectile := preload("res://addons/spatial_toolkit/runtime/drone_projectile.gd")
const RETICLE := preload("res://addons/spatial_toolkit/runtime/drone_reticle.gd")
const TargetLock := preload("res://addons/spatial_toolkit/runtime/drone_target_lock.gd")
const StagedTargetLock := preload("res://addons/spatial_toolkit/runtime/drone_staged_target_lock.gd")
const TargetLockHud := preload("res://addons/spatial_toolkit/runtime/drone_target_lock_hud.gd")
const ThreatHud := preload("res://addons/spatial_toolkit/runtime/drone_threat_hud.gd")
const GAMEPAD_TRIGGER_RELEASE := 0.30
const SHOT_DELAY_SECONDS := 0.2
const TARGET_CONFIRM_ACTION := &"flight_target_confirm"

enum TargetLockMode { CONTROLLER_DEFAULT, CLASSIC_TIMING, STAGED }

class DelayedShot:
	var aim: Vector3
	var guided_target: SpatialFlyingPatrol
	var remaining := SHOT_DELAY_SECONDS

	func _init(aim_point: Vector3, patrol: SpatialFlyingPatrol) -> void:
		aim = aim_point
		guided_target = patrol

const GAMEPAD_MOVE_ACTIONS: Array[StringName] = [
	&"flight_move_left", &"flight_move_right", &"flight_move_forward", &"flight_move_backward",
]
const GAMEPAD_LOOK_ACTIONS: Array[StringName] = [
	&"flight_look_left", &"flight_look_right", &"flight_look_up", &"flight_look_down",
]

@export_range(10, 180, 1) var turn_speed_degrees: float = 75.0
@export_range(0.05, 1.0, 0.01) var camera_lag_seconds: float = 0.22
@export_range(0.02, 0.3, 0.01) var edge_band: float = 0.1
@export_range(5, 100, 1) var edge_pan_degrees: float = 40.0
@export_range(10, 500, 1) var air_waypoint_distance: float = 80.0
@export_range(0.5, 10, 0.1) var surface_clearance: float = 2.0
@export_range(0.2, 5, 0.1) var arrival_radius: float = 1.0
@export_flags_3d_physics var destination_collision_mask: int = 1
@export_range(0.5, 20, 0.5) var wheel_step_mps: float = 2.0
@export_range(1, 100, 1) var reverse_speed_limit_mps: float = 10.0
@export_range(10, 500, 1) var forward_speed_limit_mps: float = 500.0
## Near clipping distance in gameplay metres for the unobstructed chase view.
## A larger value improves distant depth precision in GL Compatibility.
@export_range(0.05, 2.0, 0.01) var outdoor_near_m: float = 0.5
## Near clipping distance in gameplay metres for first person and close walls.
@export_range(0.01, 0.15, 0.01) var close_near_m: float = 0.05

@export_range(1.0, 50.0, 0.5) var crash_impact_speed_mps := 8.0
@export_range(0.5, 5.0, 0.1) var crash_respawn_delay_seconds := 1.5

@export_group("Target Lock", "target_lock_")
## Gamepad Flight uses staged capture by default. Classic uses the continuous timing round.
@export var target_lock_mode: TargetLockMode = TargetLockMode.CONTROLLER_DEFAULT
## The time to return to a LOCKED patrol and confirm its second window in staged mode.
@export_range(0.5, 45.0, 0.1, "suffix:s") var target_lock_locked_duration_seconds := 8.0
## The time to fire after reaching READY in staged mode.
@export_range(0.5, 45.0, 0.1, "suffix:s") var target_lock_ready_duration_seconds := 5.0
## Timing arc multiplier. At 0.5×, each arc lasts 3.2 seconds.
@export_range(0.25, 2.0, 0.05, "suffix:×") var target_lock_progress_speed := 0.5:
	set(value):
		target_lock_progress_speed = clampf(value, 0.25, 2.0) if is_finite(value) else 0.5
## Width of the segment that grants LOCKED in staged mode, as a percentage of the arc.
@export_range(5.0, 35.0, 1.0, "suffix:%") var target_lock_first_window_width := 21.0
## Width of the segment that grants READY in staged mode, as a percentage of the arc.
@export_range(5.0, 35.0, 1.0, "suffix:%") var target_lock_second_window_width := 20.0
## Played once when SEARCH appears.
@export var target_lock_search_audio: AudioStream
## Played when the first timing window acquires the target.
@export var target_lock_locked_audio: AudioStream
## Played when the second timing window readies a staged shot.
@export var target_lock_ready_audio: AudioStream
## Played when a shot is accepted, before the rocket launches.
@export var target_lock_fired_audio: AudioStream
@export_range(-80.0, 6.0, 0.5, "suffix:dB") var target_lock_audio_volume_db := -6.0

@export_group("Camera Framing")
## Vertical shift as a percentage of the viewport height in third person.
## Positive values place the drone lower. Zero uses the authored camera angle.
@export_range(-25.0, 25.0, 1.0, "suffix:%") var vertical_screen_offset := DEFAULT_VERTICAL_SCREEN_OFFSET:
	set(value):
		vertical_screen_offset = clampf(value, -25.0, 25.0) if is_finite(value) else default_vertical_screen_offset()
		if not Engine.is_editor_hint() and is_node_ready():
			_update_chase_framing()

@export_group("Drone Audio")
## Leave empty to use the engine loop bundled with Spatial Toolkit.
@export var engine_audio: AudioStream
@export_range(-80.0, 6.0, 0.5, "suffix:dB") var engine_volume_db := -9.0
## Leave empty to use the bundled throttle sound.
@export var throttle_audio: AudioStream
@export_range(-80.0, 6.0, 0.5, "suffix:dB") var throttle_volume_db := -4.0
## Leave empty to use the bundled rocket launch sound.
@export var launch_audio: AudioStream
@export_range(-80.0, 6.0, 0.5, "suffix:dB") var launch_volume_db := -3.0
## Leave empty to use the bundled rocket impact sound.
@export var impact_audio: AudioStream
@export_range(-80.0, 6.0, 0.5, "suffix:dB") var impact_volume_db := -6.0
@export_group("Gamepad")
## Pushing the stick forward pitches the nose down when enabled.
@export var gamepad_invert_pitch := false
## Minimum stick deflection required before steering or aiming.
@export_range(0.05, 0.45, 0.01) var gamepad_stick_deadzone := 0.18
## Virtual aim speed as a fraction of the shorter viewport side per second.
@export_range(0.25, 2.0, 0.05) var gamepad_pointer_speed := 0.9
## Rate of cruise speed change from the gamepad.
@export_range(1.0, 100.0, 1.0, "suffix:m/s²") var gamepad_cruise_rate_mps2 := 18.0
@export_group("")

var _launch_sound_stream: AudioStream
var _throttle_sound: AudioStreamPlayer3D
var _engine_sound: AudioStreamPlayer3D
var _flight_ground: StaticBody3D
var _ground_contact_normal := Vector3.ZERO
var _crash_burst: CPUParticles3D
var _respawn_remaining := 0.0
var _spawn_position := Vector3.ZERO
var _spawn_attitude := Vector3.ZERO

var _classic_bank := 0.0
var _maneuver_thrust := 0.0
var _drone_yaw := 0.0
var _drone_pitch := 0.0
var _has_destination := false
var _cruise_speed_mps := 0.0
var _destination := Vector3.ZERO
var _flight_active := false
var _pointer := Vector2.ZERO
var _pending_click := false
var _pending_shot := false
var _pending_aim := Vector2.ZERO
var _delayed_shots: Array[DelayedShot] = []
var _edge_steering_armed := true
var _free_look := false
var _orbit_yaw := 0.0
var _orbit_pitch := 0.0
var _detached_pivot := false
var _follow_velocity := Vector3.ZERO
var _follow_last_position := Vector3.ZERO
var _reticle: Control
var _threat_hud: ThreatHud
var _target_lock: TargetLock
var _target_lock_hud: TargetLockHud
var _target_lock_sound: AudioStreamPlayer
var _target_cycle_step := 0
var _target_pick_requested := false
var _target_confirm_requested := false
var _staged_fire_requested := false
var _authored_camera_pitch := 0.0
var _gamepad_device := -1
var _gamepad_aim_active := false
var _gamepad_trigger_down := false

func _validate_property(property: Dictionary) -> void:
	Localization.localize_inspector_group(property)

func default_vertical_screen_offset() -> float:
	return DEFAULT_VERTICAL_SCREEN_OFFSET

func _ready() -> void:
	if Engine.is_editor_hint():
		super._ready()
		return
	_authored_camera_pitch = rotation.x
	third_person = true
	super._ready()
	if _body == null or _pivot == null:
		push_error("Drone camera requires a CharacterBody3D / CameraPivot / SpringArm3D rig")
		_flight_active = false
		return
	get_viewport().size_changed.connect(_update_chase_framing)
	Input.joy_connection_changed.connect(_on_gamepad_connection_changed)
	_drone_yaw = _pivot.global_rotation.y
	_drone_pitch = _pivot.global_rotation.x
	_spawn_position = _body.global_position
	_spawn_attitude = Vector3(_drone_pitch, _drone_yaw, 0.0)
	_install_flight_ground()
	var pose := _pivot.global_transform
	_pivot.top_level = true
	_pivot.global_transform = pose
	_detached_pivot = true
	_follow_last_position = _body.global_position
	_pointer = get_viewport().get_visible_rect().size * 0.5
	_threat_hud = ThreatHud.new()
	_threat_hud.name = "ThreatHud"
	_flight_overlay.add_child(_threat_hud)
	_reticle = Control.new()
	_reticle.set_script(RETICLE)
	_reticle.set("camera", self)
	_reticle.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_flight_overlay.add_child(_reticle)
	_update_reticle()
	_update_near_plane()

func _exit_tree() -> void:
	if not Engine.is_editor_hint() and current:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		Input.set_default_cursor_shape(Input.CURSOR_ARROW)

func _process(delta: float) -> void:
	if _threat_hud == null:
		return
	if not current or _respawn_remaining > 0.0 or not is_instance_valid(_body):
		_threat_hud.clear()
		return
	var viewport := get_viewport()
	var contacts: Array[SpatialPatrolManager.ThreatIndicator] = []
	for node in get_tree().get_nodes_in_group(SpatialPatrolManager.PURSUIT_GROUP):
		var manager := node as SpatialPatrolManager
		if manager != null and manager.get_viewport() == viewport:
			contacts.append_array(manager.threat_indicators(_body))
	if contacts.is_empty():
		_threat_hud.clear()
		return
	var center := viewport.get_visible_rect().get_center()
	var radius := 58.0
	if third_person and is_instance_valid(_craft) and _craft.is_visible_in_tree():
		var ship_position := _craft.get_global_transform_interpolated().origin
		if not is_position_behind(ship_position):
			center = unproject_position(ship_position)
			var edge := ship_position + global_basis.x.normalized() * 0.45
			radius = clampf(center.distance_to(unproject_position(edge)) + 22.0, 58.0, 122.0)
	_threat_hud.update_display(center, radius, _body.get_global_transform_interpolated().origin,
		get_global_transform_interpolated().basis, contacts, delta)

func _physics_process(delta: float) -> void:
	# SpringArm still resolves collisions while flight is paused or in overview.
	# Update before the early return so a retracted camera never keeps a large
	# outdoor near plane merely because movement input is inactive.
	if not _flight_controls_ready(delta):
		return
	_update_gamepad_cruise(delta)
	_update_gamepad_pointer(delta)
	var stick := _gamepad_stick(GAMEPAD_MOVE_ACTIONS)
	var pitch := clampf(_pitch_input() + _gamepad_pitch(stick.y), -1.0, 1.0)
	var keyboard_yaw := _keyboard_movement().x
	var yaw := clampf(keyboard_yaw + stick.x, -1.0, 1.0)
	var selected_destination := _handle_pending_click()
	var previous_attitude := Vector2(_drone_yaw, _drone_pitch)
	if not _free_look and not _gamepad_aim_active:
		_steer_at_edge(_edge_input(_pointer, get_viewport().get_visible_rect().size), delta)
	if pitch != 0 or yaw != 0 or (not _has_destination and not is_zero_approx(_cruise_speed_mps)):
		_manual_step(pitch, yaw, _cruise_speed_mps, delta)
	else:
		_flight_step(delta)
	var yaw_step := angle_difference(previous_attitude.x, _drone_yaw)
	var full_turn_step := deg_to_rad(minf(turn_speed_degrees, edge_pan_degrees)) * delta
	var bank_target := MAX_BANK * clampf(yaw_step / maxf(full_turn_step, 0.001), -1.0, 1.0)
	_classic_bank = lerpf(_classic_bank, bank_target, 1.0 - exp(-delta * 9.0))
	_set_craft_attitude(_classic_bank)
	_set_exhaust_turn(_classic_bank / MAX_BANK * 0.45)
	var demand := maxf(absf(pitch), absf(yaw)) if not selected_destination else 1.0
	_update_maneuver_exhaust(demand, previous_attitude, delta)
	_follow_camera(delta)
	_update_reticle()
	_update_target_lock(delta)

func _flight_controls_ready(delta: float) -> bool:
	if Engine.is_editor_hint():
		return false
	_update_near_plane()
	if _respawn_remaining > 0.0:
		_clear_target_lock()
		_respawn_remaining = maxf(0.0, _respawn_remaining - delta)
		if is_zero_approx(_respawn_remaining):
			_respawn_drone()
		return false
	if not current or not _flight_active or _body == null:
		_clear_target_lock()
		_delayed_shots.clear()
		_stop_body()
		return false
	_update_delayed_shots(delta)
	return true

func _install_flight_ground() -> void:
	var overview := get_node_or_null(overview_camera_path)
	if overview == null:
		return
	var ground := overview.get_parent().get_node_or_null("FlatGround") as MeshInstance3D
	if ground == null or ground.mesh == null:
		return
	var bounds := ground.mesh.get_aabb()
	if bounds.size.x <= 0.0 or bounds.size.z <= 0.0:
		return
	var shape := BoxShape3D.new()
	var ground_scale := ground.global_basis.get_scale().abs()
	shape.size = Vector3(bounds.size.x * ground_scale.x, 2.0, bounds.size.z * ground_scale.z)
	var surface := bounds.get_center()
	surface.y = bounds.end.y
	var collision := CollisionShape3D.new()
	collision.shape = shape
	collision.position.y = -shape.size.y * 0.5
	_flight_ground = StaticBody3D.new()
	_flight_ground.name = "FlightGround"
	_flight_ground.top_level = true
	_flight_ground.collision_mask = 0
	_flight_ground.add_child(collision)
	add_child(_flight_ground)
	_flight_ground.global_transform = Transform3D(ground.global_basis.orthonormalized(), ground.to_global(surface))

func _manual_step(pitch_input: float, yaw_input: float, forward_speed: float, delta: float) -> void:
	if _take_manual_control():
		forward_speed = _cruise_speed_mps
	_cancel_destination()
	var turn := deg_to_rad(turn_speed_degrees) * delta
	_drone_pitch = clampf(_drone_pitch + pitch_input * turn, deg_to_rad(-80), deg_to_rad(80))
	_drone_yaw -= yaw_input * turn
	var signed_speed := clampf(forward_speed, -reverse_speed_limit_mps, forward_speed_limit_mps)
	_move_drone(_forward() * signed_speed)
	_set_craft_attitude(_classic_bank)

func _pitch_input() -> float:
	var pitch := -_keyboard_movement().y
	var inverted := bool(ProjectSettings.get_setting(INVERT_WS_SETTING, false))
	if _body != null and _body.has_method("is_pitch_input_inverted"):
		inverted = bool(_body.call("is_pitch_input_inverted"))
	return -pitch if inverted else pitch

func _adjust_cruise_speed(notches: float) -> void:
	_change_cruise_speed(notches * wheel_step_mps)

func _change_cruise_speed(change_mps: float, pulse_exhaust := true) -> void:
	var previous_speed := absf(_cruise_speed_mps)
	_cruise_speed_mps = clampf(_cruise_speed_mps + change_mps, -reverse_speed_limit_mps, forward_speed_limit_mps)
	if absf(_cruise_speed_mps) > previous_speed:
		_play_throttle_sound()
		if pulse_exhaust and _craft != null:
			for child in _craft.get_children():
				if child is EXHAUST_TRAIL:
					child.boost()

func _set_exhaust_turn(turn: float) -> void:
	if _craft == null:
		return
	var port := _craft.get_node_or_null("PortTrail") as EXHAUST_TRAIL
	var starboard := _craft.get_node_or_null("StarboardTrail") as EXHAUST_TRAIL
	if port != null:
		port.set_turn_thrust(-turn)
	if starboard != null:
		starboard.set_turn_thrust(turn)

func _update_maneuver_exhaust(demand: float, previous_attitude: Vector2, delta: float) -> void:
	var yaw_step := absf(angle_difference(previous_attitude.x, _drone_yaw))
	var pitch_step := absf(angle_difference(previous_attitude.y, _drone_pitch))
	var full_step := deg_to_rad(minf(turn_speed_degrees, edge_pan_degrees)) * delta
	var turn := maxf(yaw_step, pitch_step) / maxf(full_step, 0.001)
	var target := clampf(maxf(demand, turn), 0.0, 1.0)
	var thrust := lerpf(_maneuver_thrust, target, 1.0 - exp(-delta * 12.0))
	_set_maneuver_thrust(thrust)

func _set_maneuver_thrust(thrust: float) -> void:
	_maneuver_thrust = thrust
	if _craft == null:
		return
	for child in _craft.get_children():
		if child is EXHAUST_TRAIL:
			child.set_maneuver_thrust(thrust)

func _play_throttle_sound() -> void:
	if _body == null:
		return
	if _throttle_sound == null:
		var stream := _flight_sound(throttle_audio, THROTTLE_SOUND_PATH)
		if stream == null:
			return
		_throttle_sound = AudioStreamPlayer3D.new()
		_throttle_sound.name = "ThrottleSound"
		_throttle_sound.position = Vector3.UP * _eye_height
		_throttle_sound.stream = stream
		_throttle_sound.volume_db = throttle_volume_db
		_throttle_sound.unit_size = 6.0
		_throttle_sound.max_distance = 100.0
		_body.add_child(_throttle_sound, true)
	if not _throttle_sound.playing:
		_throttle_sound.play()

func _take_manual_control() -> bool:
	if not _has_destination:
		return false
	# Transfer actual longitudinal speed before steering changes the nose.
	# This also preserves reduced speed while approaching a point or obstacle.
	var actual_speed := _body.velocity.dot(_forward()) if _body != null else 0.0
	_cruise_speed_mps = clampf(actual_speed, -reverse_speed_limit_mps, forward_speed_limit_mps)
	_cancel_destination()
	return true

func _map_heading() -> Vector3:
	return Vector3(-sin(_drone_yaw), 0.0, -cos(_drone_yaw))

func _forward() -> Vector3:
	return -Basis.from_euler(Vector3(_drone_pitch, _drone_yaw, 0)).z

func _set_destination(point: Vector3, _kind: String = "surface") -> void:
	if not point.is_finite():
		return
	if _has_destination:
		_take_manual_control()
	_destination = point
	_has_destination = true
	_orbit_yaw = 0.0
	_orbit_pitch = 0.0
	# A click at the viewport edge must not immediately override its own target.
	# Re-arm steering when the pointer returns to the central area.
	_edge_steering_armed = false

func _cancel_destination(_reason: String = "") -> void:
	_has_destination = false

func _flight_step(delta: float) -> void:
	if not _has_destination:
		_stop_body()
		return
	var offset := _destination - _body.global_position
	var distance := offset.length()
	if distance <= arrival_radius:
		_cruise_speed_mps = 0.0
		_cancel_destination()
		_stop_body()
		return
	var direction := offset / distance
	var travel_sign := -1.0 if _cruise_speed_mps < 0 else 1.0
	var nose_direction := direction * travel_sign
	var desired_yaw := atan2(-nose_direction.x, -nose_direction.z)
	var desired_pitch := clampf(asin(clampf(nose_direction.y, -1, 1)), deg_to_rad(-80), deg_to_rad(80))
	var step := deg_to_rad(turn_speed_degrees) * delta
	_drone_yaw = rotate_toward(_drone_yaw, desired_yaw, step)
	_drone_pitch = move_toward(_drone_pitch, desired_pitch, step)
	# Keep the selected signed speed across modes; only approach braking lowers it.
	var speed := minf(minf(absf(_cruise_speed_mps), distance * 1.5), maxf(0, distance - arrival_radius * 0.5) / maxf(delta, 0.001))
	_cruise_speed_mps = speed * travel_sign
	var alignment := _forward().dot(nose_direction)
	var velocity := Vector3.ZERO
	if alignment > 0.7:
		velocity = _forward() * _cruise_speed_mps * alignment
	_move_drone(velocity)
	_set_craft_attitude(0.0)
func _move_drone(velocity: Vector3) -> void:
	if _body == null:
		return
	_ground_contact_normal = Vector3.ZERO
	_body.velocity = velocity
	_body.move_and_slide()
	var impact: KinematicCollision3D
	var impact_speed := 0.0
	var ground_normal := Vector3.ZERO
	var ground_impact_speed := 0.0
	var hit_steep_terrain := false
	for index in _body.get_slide_collision_count():
		var contact := _body.get_slide_collision(index)
		var normal := contact.get_normal()
		var speed := -velocity.dot(normal)
		if speed <= 0.0:
			continue
		var collider := contact.get_collider() as Node
		if collider != null and (collider == _flight_ground or collider.is_in_group(&"spatial_terrain")):
			if normal.y >= maxf(0.001, cos(_body.floor_max_angle)):
				if speed > ground_impact_speed:
					ground_normal = normal
					ground_impact_speed = speed
			else:
				hit_steep_terrain = true
			continue
		if speed > impact_speed:
			impact = contact
			impact_speed = speed
	if impact != null and impact_speed >= crash_impact_speed_mps:
		_crash(impact.get_position(), impact.get_normal())
	elif impact != null or hit_steep_terrain:
		_cruise_speed_mps = 0.0
		_cancel_destination()
		_stop_body()
	elif not ground_normal.is_zero_approx():
		_glide_along_ground(velocity, ground_normal)

func _glide_along_ground(velocity: Vector3, normal: Vector3) -> void:
	var course := _forward().slide(normal)
	# A vertical dive has no forward projection on flat ground.
	if course.is_zero_approx():
		course = _map_heading().slide(normal)
	course = course.normalized()
	_drone_yaw = atan2(-course.x, -course.z)
	_drone_pitch = asin(clampf(course.y, -1.0, 1.0))
	_ground_contact_normal = normal
	_cancel_destination()
	var slide := velocity.slide(normal)
	_body.velocity = course * _cruise_speed_mps if slide.is_zero_approx() else slide

func _crash(point: Vector3, normal: Vector3) -> void:
	_respawn_remaining = crash_respawn_delay_seconds
	_release_mouse()
	if _craft != null:
		_craft.hide()
	if _crash_burst == null:
		_crash_burst = CRASH_BURST.instantiate() as CPUParticles3D
		add_child(_crash_burst)
	var axis := Vector3.RIGHT if absf(normal.dot(Vector3.FORWARD)) > 0.99 else Vector3.FORWARD
	var right := normal.cross(axis).normalized()
	_crash_burst.global_transform = Transform3D(Basis(right, normal, right.cross(normal)), point + normal * 0.1)
	_crash_burst.restart()

func _respawn_drone() -> void:
	_body.global_position = _spawn_position
	_body.reset_physics_interpolation()
	var display := _flight_overlay.get_node_or_null("FlightMap") as FlightMap
	if display != null:
		display.reset_travel_sample()
	_drone_pitch = _spawn_attitude.x
	_drone_yaw = _spawn_attitude.y
	_orbit_yaw = 0.0
	_orbit_pitch = 0.0
	_follow_last_position = _spawn_position
	_follow_velocity = Vector3.ZERO
	_pivot.global_position = _spawn_position + Vector3.UP * (_eye_height + (follow_height if third_person else 0.0))
	_pivot.global_rotation = _spawn_attitude
	_pivot.reset_physics_interpolation()
	_set_craft_attitude(0.0)
	if _craft != null:
		_craft.visible = third_person
	if current and get_window().has_focus():
		_capture_mouse()

func _set_craft_attitude(bank: float, pitch_lead: float = 0.0) -> void:
	if _craft == null:
		return
	if not _ground_contact_normal.is_zero_approx():
		_craft.global_basis = Basis.looking_at(_forward(), _ground_contact_normal)
		return
	var attitude := Basis.from_euler(Vector3(_drone_pitch + pitch_lead, _drone_yaw, bank))
	# Tip the top toward the chase view as the ship rolls onto its wing.
	_craft.global_basis = attitude * Basis(Vector3.RIGHT, absf(bank) * 0.48)

func _handle_pending_click() -> bool:
	if not _pending_click:
		return false
	_pending_click = false
	if _pending_shot:
		_pending_shot = false
		if _uses_staged_target_lock():
			_staged_fire_requested = true
			return false
		var guided_target: SpatialFlyingPatrol
		if _target_lock != null:
			match _target_lock.handle_fire_click(_pending_aim, self, destination_collision_mask):
				TargetLock.ClickResult.CONSUMED:
					return false
				TargetLock.ClickResult.FIRE:
					guided_target = _target_lock.take_firing_target()
		_queue_delayed_shot(_pick_destination(_pending_aim)["aim"], guided_target)
		return false
	var pick := _pick_destination(_pending_aim)
	_set_destination(pick["position"], str(pick["kind"]))
	_play_throttle_sound()
	return true

func _queue_delayed_shot(aim: Vector3, patrol: SpatialFlyingPatrol) -> void:
	_delayed_shots.append(DelayedShot.new(aim, patrol))
	_play_target_lock_sound(target_lock_fired_audio)

func _update_delayed_shots(delta: float) -> void:
	for shot in _delayed_shots:
		shot.remaining -= delta
	while not _delayed_shots.is_empty() and _delayed_shots.front().remaining <= 0.000001:
		var shot: DelayedShot = _delayed_shots.pop_front()
		var patrol := shot.guided_target
		if not is_instance_valid(patrol) or patrol.is_queued_for_deletion() or not patrol.active:
			patrol = null
		_fire_projectile(shot.aim, patrol)

func _fire_projectile(target: Vector3, guided_target: SpatialFlyingPatrol = null) -> void:
	var muzzle := _body.global_position + Vector3.UP * (_eye_height - 0.16) + _forward() * 0.27
	if _craft != null:
		var mount := _craft.get_node_or_null("RocketMount") as Marker3D
		if mount != null:
			muzzle = mount.global_position
	var inherited := Vector3.ZERO if _body.velocity.is_zero_approx() else _body.get_real_velocity()
	var direction := (target - muzzle).normalized()
	if direction.is_zero_approx() and is_instance_valid(guided_target):
		direction = (guided_target.global_position - muzzle).normalized()
	if direction.is_zero_approx():
		return
	var projectile := PROJECTILE.instantiate() as Projectile
	projectile.guided_target = guided_target
	projectile.velocity = Projectile.aimed_velocity(direction, inherited)
	projectile.launch_speed = maxf(0.0, inherited.dot(direction)) + Projectile.LAUNCH_LEAD_MPS
	projectile.collision_mask = destination_collision_mask
	projectile.shooter = _body.get_rid()
	projectile.impact_audio = impact_audio
	projectile.impact_volume_db = impact_volume_db
	add_child(projectile, true)
	var up := Vector3.RIGHT if absf(direction.y) > 0.99 else Vector3.UP
	projectile.global_transform = Transform3D(Basis.looking_at(direction, up), muzzle)
	projectile.prepare_target(inherited)
	projectile.reset_physics_interpolation()
	_play_launch_sound(muzzle)

func _update_target_lock(delta: float) -> void:
	var staged_mode := _uses_staged_target_lock()
	if _free_look and not staged_mode:
		_clear_target_lock()
		return
	_ensure_target_lock(staged_mode)
	if staged_mode:
		_update_staged_target_lock(_target_lock as StagedTargetLock, delta)
		return
	var switched := (_target_pick_requested and _target_lock.select_pointer_target(self, _pointer, destination_collision_mask)) \
		or (_target_cycle_step != 0 and _target_lock.cycle_visible_target(self, destination_collision_mask, _target_cycle_step))
	_target_cycle_step = 0
	_target_pick_requested = false
	if switched or _target_lock.update(self, _pointer, destination_collision_mask, delta, target_lock_progress_speed):
		_target_lock_hud.update_display(_target_lock.center, _target_lock.radius,
			_target_lock.elapsed_fraction, TargetLock.WINDOW_FRACTIONS, _target_lock.completed_windows,
			_target_lock.locked, _target_lock.searching)
	else:
		_target_lock_hud.hide()

func _uses_staged_target_lock() -> bool:
	return target_lock_mode == TargetLockMode.STAGED or (
		target_lock_mode == TargetLockMode.CONTROLLER_DEFAULT and _defaults_to_staged_target_lock())

func _defaults_to_staged_target_lock() -> bool:
	return false

func _ensure_target_lock(staged_mode: bool) -> void:
	if _target_lock != null and (_target_lock is StagedTargetLock) == staged_mode:
		return
	if staged_mode:
		var staged := StagedTargetLock.new(_body.get_rid())
		staged.target_ready.connect(func() -> void: _play_target_lock_sound(target_lock_ready_audio))
		_target_lock = staged
	else:
		_target_lock = TargetLock.new(_body.get_rid())
	_target_lock.search_started.connect(func() -> void: _play_target_lock_sound(target_lock_search_audio))
	_target_lock.target_locked.connect(func() -> void: _play_target_lock_sound(target_lock_locked_audio))
	if _target_lock_hud == null:
		_target_lock_hud = TargetLockHud.new()
		_target_lock_hud.name = "TargetLockHud"
		_flight_overlay.add_child(_target_lock_hud)

func _update_staged_target_lock(staged: StagedTargetLock, delta: float) -> void:
	var window_widths := Vector2(target_lock_first_window_width, target_lock_second_window_width) * 0.01
	staged.advance(self, _pointer, destination_collision_mask, delta, target_lock_progress_speed,
		not _free_look, _target_cycle_step, window_widths, _target_pick_requested)
	_target_cycle_step = 0
	_target_pick_requested = false
	if _target_confirm_requested and not _free_look:
		staged.confirm_window(_pointer, maxf(0.05, target_lock_locked_duration_seconds),
			maxf(0.05, target_lock_ready_duration_seconds))
	_target_confirm_requested = false
	if _staged_fire_requested:
		var patrol := staged.take_ready_target()
		if patrol != null:
			_queue_delayed_shot(patrol.global_position, patrol)
	_staged_fire_requested = false
	var statuses := staged.display_statuses(self, destination_collision_mask)
	_target_lock_hud.update_staged_display(staged.center, staged.radius, staged.elapsed_fraction, staged.timing_window,
		staged.timing, not _free_look and staged.showing_search, statuses["markers"], statuses["unseen_status"])

func _clear_target_lock() -> void:
	_target_cycle_step = 0
	_target_pick_requested = false
	_target_confirm_requested = false
	_staged_fire_requested = false
	if _target_lock != null:
		_target_lock.clear()
		_target_lock_hud.hide()

func _play_target_lock_sound(stream: AudioStream) -> void:
	if stream == null:
		return
	if _target_lock_sound == null:
		_target_lock_sound = AudioStreamPlayer.new()
		_target_lock_sound.name = "TargetLockSound"
		add_child(_target_lock_sound)
	_target_lock_sound.stream = stream
	_target_lock_sound.volume_db = target_lock_audio_volume_db
	_target_lock_sound.play()

func _play_launch_sound(muzzle: Vector3) -> void:
	if _launch_sound_stream == null:
		_launch_sound_stream = _flight_sound(launch_audio, LAUNCH_SOUND_PATH)
	if _launch_sound_stream == null:
		return
	var sound := AudioStreamPlayer3D.new()
	sound.name = "RocketLaunchSound"
	sound.top_level = true
	sound.stream = _launch_sound_stream
	sound.unit_size = 6.0
	sound.max_distance = 140.0
	sound.volume_db = launch_volume_db
	add_child(sound, true)
	sound.global_position = muzzle
	sound.finished.connect(sound.queue_free, CONNECT_ONE_SHOT)
	sound.play()

func _pick_destination(screen: Vector2) -> Dictionary:
	var origin := project_ray_origin(screen)
	var direction := project_ray_normal(screen)
	var query := PhysicsRayQueryParameters3D.create(origin, origin + direction * 20000, destination_collision_mask)
	if _body != null:
		query.exclude = [_body.get_rid()]
	var hit := get_world_3d().direct_space_state.intersect_ray(query)
	if not hit.is_empty():
		var kind := "ground" if hit["collider"] == _flight_ground else "surface"
		var point: Vector3 = hit["position"]
		return {"position": point + hit["normal"] * surface_clearance, "aim": point, "kind": kind}
	# Keep plane picking available for standalone rigs and outside the map mesh.
	if direction.y < -0.0001:
		var distance := -origin.y / direction.y
		if distance > 0 and distance < 20000:
			var point := origin + direction * distance
			return {"position": point + Vector3.UP * surface_clearance, "aim": point, "kind": "ground"}
	var air := origin + direction * air_waypoint_distance
	return {"position": air, "aim": air, "kind": "air"}

func _edge_input(screen: Vector2, size: Vector2) -> Vector2:
	if size.x <= 0 or size.y <= 0:
		return Vector2.ZERO
	var centered := screen / size * 2.0 - Vector2.ONE
	var threshold := 1.0 - edge_band * 2.0
	return Vector2(signf(centered.x) * clampf((absf(centered.x) - threshold) / (1.0 - threshold), 0, 1), signf(centered.y) * clampf((absf(centered.y) - threshold) / (1.0 - threshold), 0, 1))

func _steer_at_edge(edge: Vector2, delta: float) -> void:
	if edge.is_zero_approx():
		_edge_steering_armed = true
		return
	if not _edge_steering_armed:
		return
	_orbit_yaw = 0.0
	_orbit_pitch = 0.0
	_take_manual_control()
	_cancel_destination()
	var turn := deg_to_rad(edge_pan_degrees) * delta
	_drone_yaw = wrapf(_drone_yaw - edge.x * turn, -PI, PI)
	_drone_pitch = clampf(_drone_pitch - edge.y * turn, deg_to_rad(-80), deg_to_rad(80))
	_set_craft_attitude(_classic_bank)

func _follow_camera(delta: float) -> void:
	if _pivot == null or _body == null:
		return
	var eye := _body.global_position + Vector3.UP * (_eye_height + (follow_height if third_person else 0.0))
	var weight := 1.0 - exp(-delta / camera_lag_seconds) if third_person else 1.0
	var displacement := _body.global_position - _follow_last_position
	_follow_last_position = _body.global_position
	var measured_velocity := displacement / maxf(delta, 0.001)
	# Discontinuities from teleporting/repositioning are not flight acceleration.
	if displacement.length() > forward_speed_limit_mps * maxf(delta, 0.001) * 2.0 + follow_distance:
		measured_velocity = Vector3.ZERO
		_follow_velocity = Vector3.ZERO
	_follow_velocity = _follow_velocity.lerp(measured_velocity, weight)
	# Advect with the ship's actual motion before closing the remaining gap.
	# Lag is transient under acceleration; constant cruise has zero steady gap.
	var predicted := _pivot.global_position + _follow_velocity * delta
	var desired := predicted.lerp(eye, weight)
	var offset := (desired - eye).limit_length(follow_distance * 0.75) if third_person else Vector3.ZERO
	# Keep most positional lag along the view axis. Large sideways/upward lag
	# throws a nearby miniature ship out of frame during vertical movement.
	var view_axis := -_pivot.global_basis.z.normalized()
	var along_view := view_axis * offset.dot(view_axis)
	var framing_margin := minf(0.15, maxf(0.02, _boom.get_hit_length() * 0.05))
	offset = along_view + (offset - along_view).limit_length(framing_margin)
	_pivot.global_position = eye + _sweep_camera_offset(eye, offset)
	var look := _pivot.global_rotation
	look.y = lerp_angle(look.y, _drone_yaw + _orbit_yaw, weight)
	look.x = lerp_angle(look.x, clampf(_drone_pitch + _orbit_pitch, deg_to_rad(-85), deg_to_rad(85)), weight)
	look.z = 0
	_pivot.global_rotation = look

func _sweep_camera_offset(eye: Vector3, offset: Vector3) -> Vector3:
	# Protect the movable pivot as well as the existing swept spring arm.
	if offset.is_zero_approx():
		return offset
	var query := PhysicsShapeQueryParameters3D.new()
	var sphere := SphereShape3D.new()
	sphere.radius = 0.16
	query.shape = sphere
	query.transform = Transform3D(Basis.IDENTITY, eye)
	query.motion = offset
	query.collision_mask = destination_collision_mask
	query.exclude = [_body.get_rid()]
	var fractions := get_world_3d().direct_space_state.cast_motion(query)
	return offset * fractions[0] if fractions.size() == 2 else offset

func _apply_view_mode() -> void:
	var point := _pivot.global_position if _detached_pivot and _pivot != null else Vector3.ZERO
	super._apply_view_mode()
	if _detached_pivot:
		_pivot.global_position = point
	_update_near_plane()
	_update_chase_framing()

func _chase_vertical_offset() -> float:
	return vertical_screen_offset * 0.01 if third_person and projection == PROJECTION_PERSPECTIVE else 0.0

func _update_chase_framing() -> void:
	# Map generation sets the view mode before the runtime rig is initialized.
	if _boom == null or not is_inside_tree():
		return
	var offset := _chase_vertical_offset()
	var tilt := 0.0
	if not is_zero_approx(offset):
		# A pitch at the optical center shifts the view without moving the swept boom.
		var half_height := get_camera_projection().get_viewport_half_extents().y
		tilt = atan(2.0 * offset * half_height / near)
	rotation.x = _authored_camera_pitch + tilt

func _update_near_plane() -> void:
	var close := maxf(0.001, close_near_m) if is_finite(close_near_m) else 0.05
	var outdoor := maxf(close, outdoor_near_m) if is_finite(outdoor_near_m) else maxf(close, 0.5)
	if not third_person or _boom == null:
		near = close
		return
	var hit_length := _boom.get_hit_length()
	if not is_finite(hit_length):
		near = close
		return
	var distance := maxf(0.0, hit_length)
	var safe_near := clampf(distance * 0.2, close, outdoor)
	if distance < _boom.spring_length - 0.001:
		# The shortened arm can still be metres long, but its camera is only a
		# sweep-radius away from the obstacle. Stay inside that protected gap;
		# reducing immediately avoids a clipped wall on the contraction frame.
		if _boom.shape is SphereShape3D:
			var sweep := _boom.shape as SphereShape3D
			safe_near = minf(safe_near, maxf(close, sweep.radius * 0.5))
		else:
			safe_near = close
	near = safe_near

func _fires_on_left_click(space_held: bool) -> bool:
	return not space_held

func _has_lift_controls() -> bool:
	return false

func _gamepad_uses_virtual_pointer() -> bool:
	return true

func _gamepad_can_select_destination() -> bool:
	return true

func _gamepad_pitch(vertical_axis: float) -> float:
	return vertical_axis if gamepad_invert_pitch else -vertical_axis

func _keyboard_movement() -> Vector2:
	return _keyboard_vector(GAMEPAD_MOVE_ACTIONS)

func _keyboard_vector(actions: Array[StringName]) -> Vector2:
	return Vector2(
		FlightInput.keyboard_mouse_strength(actions[1]) - FlightInput.keyboard_mouse_strength(actions[0]),
		FlightInput.keyboard_mouse_strength(actions[3]) - FlightInput.keyboard_mouse_strength(actions[2]))

func _lift_input() -> float:
	return _flight_action_strength(&"flight_lift_up") - _flight_action_strength(&"flight_lift_down")

func _look_input() -> Vector2:
	return (_keyboard_vector(GAMEPAD_LOOK_ACTIONS) + _gamepad_stick(GAMEPAD_LOOK_ACTIONS)).limit_length()

func _gamepad_stick(actions: Array[StringName], linear_horizontal := false) -> Vector2:
	if _gamepad_device < 0:
		return Vector2.ZERO
	var axes := Vector2(
		FlightInput.joy_strength(actions[1], _gamepad_device) - FlightInput.joy_strength(actions[0], _gamepad_device),
		FlightInput.joy_strength(actions[3], _gamepad_device) - FlightInput.joy_strength(actions[2], _gamepad_device))
	var strength := axes.length()
	var deadzone := gamepad_stick_deadzone
	if not is_zero_approx(axes.x):
		deadzone = maxf(deadzone, InputMap.action_get_deadzone(actions[0 if axes.x < 0.0 else 1]))
	if not is_zero_approx(axes.y):
		deadzone = maxf(deadzone, InputMap.action_get_deadzone(actions[2 if axes.y < 0.0 else 3]))
	if strength <= deadzone or deadzone >= 1.0:
		return Vector2.ZERO
	var response := clampf(inverse_lerp(deadzone, 1.0, strength), 0.0, 1.0)
	var curved := pow(response, 1.5)
	return axes.normalized() * Vector2(response if linear_horizontal else curved, curved)

func _gamepad_action_strength(action: StringName) -> float:
	return FlightInput.joy_strength(action, _gamepad_device) if _gamepad_device >= 0 else 0.0

func _flight_action_down(action: StringName) -> bool:
	return _flight_action_strength(action) > 0.0

func _flight_action_strength(action: StringName) -> float:
	var joy := _gamepad_action_strength(action)
	var active_joy := joy if joy > InputMap.action_get_deadzone(action) else 0.0
	return maxf(FlightInput.keyboard_mouse_strength(action), active_joy)

func _uses_gamepad_cruise() -> bool:
	return true

func _update_gamepad_cruise(delta: float) -> void:
	var confirm := _uses_staged_target_lock() and _flight_action_down(TARGET_CONFIRM_ACTION)
	var change := float(not confirm and _flight_action_down(&"flight_cruise_increase")) - float(_flight_action_down(&"flight_cruise_decrease"))
	if not is_zero_approx(change):
		_change_cruise_speed(change * gamepad_cruise_rate_mps2 * delta)

func _update_gamepad_pointer(delta: float) -> void:
	if _free_look:
		return
	var keys := _keyboard_vector(GAMEPAD_LOOK_ACTIONS)
	var stick := (keys + (_gamepad_stick(GAMEPAD_LOOK_ACTIONS) if _gamepad_aim_active else Vector2.ZERO)).limit_length()
	if stick.is_zero_approx():
		return
	if not _gamepad_aim_active:
		_use_gamepad_aim(_gamepad_device)
	var bounds := get_viewport().get_visible_rect()
	var pixels_per_second := minf(bounds.size.x, bounds.size.y) * gamepad_pointer_speed
	_pointer = (_pointer + stick * pixels_per_second * delta).clamp(bounds.position,
		(bounds.end - Vector2.ONE).max(bounds.position))
	if _target_lock != null:
		_target_lock.pointer_moved(_pointer)

func _use_gamepad_aim(device: int) -> void:
	if _gamepad_device != device:
		_gamepad_device = device
		_gamepad_trigger_down = false
	if not _gamepad_aim_active and _gamepad_uses_virtual_pointer() and _flight_active and not _free_look:
		Input.mouse_mode = Input.MOUSE_MODE_HIDDEN if OS.has_feature("web") else Input.MOUSE_MODE_CONFINED_HIDDEN
	_gamepad_aim_active = true

func _use_mouse_aim() -> void:
	if _gamepad_aim_active and _gamepad_uses_virtual_pointer() and _flight_active and not _free_look:
		Input.mouse_mode = _pointer_mouse_mode()
	_gamepad_aim_active = false

func _on_gamepad_connection_changed(device: int, connected: bool) -> void:
	if connected or device != _gamepad_device:
		return
	_gamepad_device = -1
	_gamepad_trigger_down = false
	if current and _gamepad_aim_active:
		_release_mouse()

func _queue_flight_click(aim: Vector2, fire: bool) -> void:
	_pending_aim = aim
	_pending_click = true
	_pending_shot = fire

func _recenter_aim() -> void:
	_pointer = get_viewport().get_visible_rect().get_center()
	if _target_lock != null:
		_target_lock.pointer_moved(_pointer)

func _input(event: InputEvent) -> void:
	if Engine.is_editor_hint() or _body == null:
		return
	if event is InputEventMouse and current:
		_use_mouse_aim()
		return
	if not (event is InputEventJoypadMotion or event is InputEventJoypadButton):
		return
	var fire_threshold := maxf(InputMap.action_get_deadzone(&"flight_fire"), 0.001)
	if event.device == _gamepad_device and _gamepad_trigger_down \
			and _gamepad_action_strength(&"flight_fire") <= minf(GAMEPAD_TRIGGER_RELEASE, fire_threshold * 0.55):
		_gamepad_trigger_down = false
	if FlightInput.event_pressed(event, &"flight_toggle_overview"):
		var overview := get_node_or_null(overview_camera_path) as Camera3D
		if overview != null and (current or overview.current):
			_toggle_overview()
			if current:
				_use_gamepad_aim(event.device)
			get_viewport().set_input_as_handled()
		return
	if not current or _respawn_remaining > 0.0:
		return
	if FlightInput.event_matches(event, &"flight_fire") \
			and FlightInput.joy_strength(&"flight_fire", event.device) >= fire_threshold:
		if _flight_active and (event.device != _gamepad_device or not _gamepad_trigger_down):
			_use_gamepad_aim(event.device)
			_gamepad_trigger_down = true
			_queue_flight_click(_pointer, true)
		get_viewport().set_input_as_handled()
		return
	if _handle_flight_action(event, true) or (_flight_active and _gamepad_continuous_event(event)):
		if _flight_active:
			_use_gamepad_aim(event.device)
		get_viewport().set_input_as_handled()

func _gamepad_continuous_event(event: InputEvent) -> bool:
	var actions := GAMEPAD_MOVE_ACTIONS + GAMEPAD_LOOK_ACTIONS + [
		&"flight_lift_up", &"flight_lift_down", &"flight_bank_lift_up", &"flight_bank_lift_down", &"flight_click_modifier",
	]
	if _uses_gamepad_cruise():
		actions.append_array([&"flight_cruise_increase", &"flight_cruise_decrease"])
	for action: StringName in actions:
		if FlightInput.event_matches(event, action) \
				and FlightInput.joy_strength(action, event.device) > InputMap.action_get_deadzone(action):
			return true
	return false

func _handle_flight_action(event: InputEvent, gamepad: bool) -> bool:
	if FlightInput.event_pressed(event, &"flight_release_controls"):
		_release_mouse()
	elif FlightInput.event_pressed(event, &"flight_toggle_controls"):
		if _flight_active:
			_release_mouse()
		else:
			_capture_mouse()
	elif FlightInput.event_pressed(event, &"flight_toggle_view"):
		_toggle_third_person()
	elif _free_look_event(event, gamepad):
		var held := FlightInput.joy_strength(&"flight_free_look", event.device) > InputMap.action_get_deadzone(&"flight_free_look") \
			if gamepad else event.is_pressed()
		_set_free_look(held)
	elif FlightInput.event_pressed(event, &"flight_primary_click"):
		if not _flight_active:
			_capture_mouse()
		else:
			var point := _event_aim(event)
			_queue_flight_click(point, _fires_on_left_click(_flight_action_down(&"flight_click_modifier")))
			if not _pending_shot:
				_pointer = point
	elif FlightInput.event_pressed(event, &"flight_destination"):
		if not _flight_active:
			_capture_mouse()
		elif _gamepad_can_select_destination():
			_queue_flight_click(_event_aim(event), false)
	elif not _flight_active:
		return false
	elif _uses_staged_target_lock() and FlightInput.event_pressed(event, TARGET_CONFIRM_ACTION):
		_target_confirm_requested = true
	elif _target_lock != null and not _free_look and FlightInput.event_pressed(event, &"flight_target_left"):
		_target_cycle_step -= 1
	elif _target_lock != null and not _free_look and FlightInput.event_pressed(event, &"flight_target_right"):
		_target_cycle_step += 1
	elif not gamepad and FlightInput.event_pressed(event, &"flight_fire"):
		_queue_flight_click(_event_aim(event), true)
	elif FlightInput.event_pressed(event, &"flight_stop"):
		_cruise_speed_mps = 0.0
		_cancel_destination()
		_stop_body()
	elif FlightInput.event_pressed(event, &"flight_center_aim"):
		_recenter_aim()
	elif FlightInput.event_pressed(event, &"flight_speed_step_up"):
		_adjust_cruise_speed(1)
	elif FlightInput.event_pressed(event, &"flight_speed_step_down"):
		_adjust_cruise_speed(-1)
	else:
		return false
	return true

func _free_look_event(event: InputEvent, gamepad: bool) -> bool:
	if gamepad:
		return FlightInput.joy_event_is_bound(event, &"flight_free_look")
	return FlightInput.event_matches(event, &"flight_free_look")

func _set_free_look(pressed: bool) -> void:
	_free_look = pressed and _flight_active
	if _flight_active:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED if _free_look else _pointer_mouse_mode()
		if not _free_look and not OS.has_feature("web"):
			get_viewport().warp_mouse(_pointer)
	# Dragging the view near an edge must not steer on button release.
	_edge_steering_armed = false
	_update_reticle()

func _event_aim(event: InputEvent) -> Vector2:
	if event is InputEventMouseButton:
		return event.position
	return _pointer

func _pointer_motion(event: InputEventMouseMotion) -> void:
	if _free_look:
		_look(event.relative)
	else:
		_pointer = event.position
		if _target_lock != null:
			_target_lock.pointer_moved(_pointer)

func _unhandled_input(event: InputEvent) -> void:
	if Engine.is_editor_hint() or event is InputEventJoypadButton or event is InputEventJoypadMotion:
		return
	if FlightInput.event_pressed(event, &"flight_toggle_overview"):
		_toggle_overview()
		get_viewport().set_input_as_handled()
		return
	if not current or _respawn_remaining > 0.0:
		return
	if _handle_flight_action(event, false):
		get_viewport().set_input_as_handled()
	elif event is InputEventMouseMotion and _flight_active:
		_pointer_motion(event)
		get_viewport().set_input_as_handled()
	elif _flight_active:
		for action in GAMEPAD_MOVE_ACTIONS:
			if FlightInput.event_pressed(event, action):
				_play_throttle_sound()
				return
		if _has_lift_controls() and (FlightInput.event_pressed(event, &"flight_lift_up") \
				or FlightInput.event_pressed(event, &"flight_lift_down")):
			_play_throttle_sound()

func _look(relative: Vector2) -> void:
	if not _free_look:
		return
	_orbit_yaw = wrapf(_orbit_yaw - relative.x * mouse_sensitivity, -PI, PI)
	_orbit_pitch = clampf(_orbit_pitch - relative.y * mouse_sensitivity, -1.4, 1.4)

func _start_engine_sound() -> void:
	# A headless scene has no listening viewport for continuous cockpit audio.
	if _body == null or not _flight_active or not current or DisplayServer.get_name() == "headless":
		return
	if _engine_sound == null:
		var source := _flight_sound(engine_audio, ENGINE_SOUND_PATH)
		if source == null:
			return
		var loop := source.duplicate() as AudioStream
		if loop is AudioStreamWAV:
			if loop.loop_end <= loop.loop_begin:
				loop.loop_end = roundi(loop.get_length() * loop.mix_rate)
			loop.loop_mode = AudioStreamWAV.LOOP_FORWARD
		elif loop is AudioStreamMP3 or loop is AudioStreamOggVorbis:
			loop.loop = true
		_engine_sound = AudioStreamPlayer3D.new()
		_engine_sound.name = "EngineSound"
		_engine_sound.position = Vector3.UP * _eye_height
		_engine_sound.stream = loop
		_engine_sound.volume_db = engine_volume_db
		_engine_sound.unit_size = 6.0
		_engine_sound.max_distance = 120.0
		_body.add_child(_engine_sound, true)
	if not _engine_sound.playing:
		_engine_sound.play()

func _flight_sound(assigned: AudioStream, path: String) -> AudioStream:
	if assigned != null:
		return assigned
	return load(path) as AudioStream if ResourceLoader.exists(path, "AudioStream") else null

func _capture_mouse() -> void:
	if _respawn_remaining > 0.0:
		return
	_flight_active = true
	_start_engine_sound.call_deferred()
	Input.mouse_mode = _pointer_mouse_mode()
	Input.set_default_cursor_shape(Input.CURSOR_CROSS)
	_pointer = get_viewport().get_visible_rect().size * 0.5
	_update_reticle()

func _pointer_mouse_mode() -> Input.MouseMode:
	return Input.MOUSE_MODE_VISIBLE if OS.has_feature("web") else Input.MOUSE_MODE_CONFINED

func _release_mouse() -> void:
	_gamepad_aim_active = false
	_clear_target_lock()
	_classic_bank = 0.0
	_set_craft_attitude(0.0)
	_set_exhaust_turn(0.0)
	_set_maneuver_thrust(0.0)
	_flight_active = false
	if is_instance_valid(_engine_sound):
		_engine_sound.stop()
	_cruise_speed_mps = 0.0
	_free_look = false
	_pending_click = false
	_pending_shot = false
	_delayed_shots.clear()
	if _target_lock_sound != null:
		_target_lock_sound.stop()
	_cancel_destination()
	_stop_body()
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	Input.set_default_cursor_shape(Input.CURSOR_ARROW)
	_update_reticle()

func _update_reticle() -> void:
	if _reticle == null:
		return
	_reticle.visible = current and _flight_active and not _free_look
	_reticle.size = get_viewport().get_visible_rect().size
	_reticle.set("aim", _pointer)
	_reticle.set("target", _destination)
	_reticle.set("has_target", _has_destination)
	_reticle.queue_redraw()
