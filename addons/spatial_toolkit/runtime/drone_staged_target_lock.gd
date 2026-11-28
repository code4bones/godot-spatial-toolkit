extends "res://addons/spatial_toolkit/runtime/drone_target_lock.gd"
## Stores each patrol's capture separately from the current aiming attempt.

signal target_ready

const WINDOW_LIMITS := Vector2(0.18, 0.94)
const WINDOW_CENTER_GAP := 0.16

enum Phase { LOCKED, READY }

class Capture:
	var patrol: SpatialFlyingPatrol
	var phase := Phase.LOCKED
	var duration: float
	var remaining: float

	func _init(target: SpatialFlyingPatrol, seconds: float) -> void:
		patrol = target
		duration = seconds
		remaining = seconds

var timing := false
var showing_search: bool:
	get:
		return is_instance_valid(_target) and _capture_for_selection() == null
var timing_window := Vector2.ZERO

var _captures: Dictionary[int, Capture] = {}
var _last_ready_id := 0
var _random := RandomNumberGenerator.new()

func _init(shooter: RID) -> void:
	super(shooter)
	_random.randomize()

func advance(camera: Camera3D, pointer: Vector2, world_mask: int, delta: float,
		progress_speed: float, aiming: bool, cycle_step: int, window_widths: Vector2, pick_under_reticle := false) -> void:
	var had_capture := _capture_for_selection() != null
	_expire_captures(delta)
	if not aiming:
		_reset_timing()
		return
	if (pick_under_reticle and select_pointer_target(camera, pointer, world_mask)) \
			or (cycle_step != 0 and cycle_visible_target(camera, world_mask, cycle_step)):
		return
	if not _visible(camera, _target, world_mask):
		_target = null
		_reset_timing()
		var patrol := _nearest_visible_target(camera, pointer, world_mask)
		if patrol != null:
			_select_target(camera, patrol)
		return
	_update_square(camera)
	var capture := _capture_for_selection()
	if had_capture and capture == null:
		_reset_timing()
		search_started.emit()
		return
	if capture != null and capture.phase == Phase.READY:
		return
	if not _contains(pointer):
		pointer_moved(pointer)
		return
	if not timing:
		var width := window_widths.x if capture == null else window_widths.y
		timing_window = _roll_window(width)
		timing = true
		return
	elapsed_fraction += delta * progress_speed / ROUND_SECONDS
	if elapsed_fraction >= 1.0:
		_fail_window()

func _roll_window(width: float) -> Vector2:
	var half_width := clampf(width, 0.05, 0.35) * 0.5 if is_finite(width) else 0.1
	var earliest := WINDOW_LIMITS.x + half_width
	var latest := WINDOW_LIMITS.y - half_width
	var midpoint: float
	if timing_window == Vector2.ZERO:
		midpoint = _random.randf_range(earliest, latest)
	else:
		# Sample both allowed intervals, excluding centers too close to the last window.
		var previous := (timing_window.x + timing_window.y) * 0.5
		var early_end := clampf(previous - WINDOW_CENTER_GAP, earliest, latest)
		var late_start := clampf(previous + WINDOW_CENTER_GAP, earliest, latest)
		var early_span := early_end - earliest
		var offset := _random.randf_range(0.0, early_span + latest - late_start)
		midpoint = late_start + offset - early_span
		if early_span > 0.0 and offset <= early_span:
			midpoint = earliest + offset
	return Vector2(midpoint - half_width, midpoint + half_width)

func confirm_window(pointer: Vector2, locked_seconds: float, ready_seconds: float) -> void:
	if not timing or not is_instance_valid(_target) or not _contains(pointer):
		return
	var window := timing_window
	if elapsed_fraction < window.x or elapsed_fraction >= window.y:
		_fail_window()
		return
	var id := _target.get_instance_id()
	var capture := _captures.get(id) as Capture
	_reset_timing()
	if capture == null:
		_captures[id] = Capture.new(_target, locked_seconds)
		target_locked.emit()
	else:
		capture.phase = Phase.READY
		capture.duration = ready_seconds
		capture.remaining = ready_seconds
		_last_ready_id = id
		target_ready.emit()

func take_ready_target() -> SpatialFlyingPatrol:
	var capture := _ready_capture()
	if capture == null:
		return null
	var patrol := capture.patrol
	_forget(patrol.get_instance_id())
	if _target == patrol:
		_reset_timing()
	return patrol

func display_statuses(camera: Camera3D, world_mask: int) -> Dictionary:
	var markers: Array[Dictionary] = []
	var unseen_status := {}
	var priority := _ready_capture()
	if priority == null:
		priority = _capture_for_selection()
	if priority == null and not _captures.is_empty():
		priority = _captures.values()[0]
	for capture: Capture in _captures.values():
		var status := {
			"label": "READY" if capture.phase == Phase.READY else "LOCKED",
			"remaining": capture.remaining / capture.duration,
		}
		if _visible(camera, capture.patrol, world_mask):
			var bounds := _screen_box(camera, capture.patrol)
			status["center"] = bounds.get_center()
			status["radius"] = bounds.size.x * 0.5
			markers.append(status)
		elif capture == priority:
			unseen_status = status
	return {"markers": markers, "unseen_status": unseen_status}

func pointer_moved(pointer: Vector2) -> void:
	if timing and not _contains(pointer):
		_fail_window()

func clear() -> void:
	super.clear()
	_captures.clear()
	_last_ready_id = 0
	_reset_timing()

func _select_target(camera: Camera3D, patrol: SpatialFlyingPatrol) -> void:
	_target = patrol
	_update_square(camera)
	_reset_timing()
	if _capture_for_selection() == null:
		search_started.emit()

func _expire_captures(delta: float) -> void:
	for id: int in _captures.keys():
		var capture := _captures[id]
		capture.remaining -= delta
		if capture.remaining <= 0.0 or not is_instance_valid(capture.patrol) \
				or not capture.patrol.active or capture.patrol.is_queued_for_deletion():
			_forget(id)

func _forget(id: int) -> void:
	_captures.erase(id)
	if id == _last_ready_id:
		_last_ready_id = 0

func _capture_for_selection() -> Capture:
	return _captures.get(_target.get_instance_id()) as Capture if is_instance_valid(_target) else null

func _ready_capture() -> Capture:
	var selected := _capture_for_selection()
	if selected != null and selected.phase == Phase.READY:
		return selected
	if _captures.has(_last_ready_id):
		return _captures[_last_ready_id]
	for capture: Capture in _captures.values():
		if capture.phase == Phase.READY:
			return capture
	return null

func _fail_window() -> void:
	_reset_timing()
	if _capture_for_selection() == null:
		search_started.emit()

func _reset_timing() -> void:
	timing = false
	elapsed_fraction = 0.0
