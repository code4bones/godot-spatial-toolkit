extends RefCounted
## The Classic controller's timed capture of one visible flying patrol.

signal search_started
signal target_locked

enum State { IDLE, SEARCH, TIMING, RETRY, LOCKED }
enum ClickResult { PASS, CONSUMED, FIRE }

const RANGE_M := 150.0
const ROUND_SECONDS := 1.6
const RETRY_SECONDS := 0.45
const WINDOW_FRACTIONS: Array[Vector2] = [Vector2(0.28, 0.49), Vector2(0.68, 0.88)]

var center := Vector2.ZERO
var radius := 40.0
var elapsed_fraction := 0.0
var completed_windows: Array[int] = []
var locked: bool:
	get:
		return _state == State.LOCKED
var searching: bool:
	get:
		return _state == State.SEARCH or _state == State.RETRY
var _state := State.IDLE
var _target: SpatialFlyingPatrol
var _retry_remaining := 0.0
var _shooter: RID

func _init(shooter: RID) -> void:
	_shooter = shooter

func update(camera: Camera3D, pointer: Vector2, world_mask: int, delta: float, progress_speed: float) -> bool:
	if not _visible(camera, _target, world_mask):
		clear()
		var patrol := _nearest_visible_target(camera, pointer, world_mask)
		if patrol == null:
			return false
		_select_target(camera, patrol)
		return true
	_update_square(camera)
	pointer_moved(pointer)
	if not _contains(pointer):
		return true
	if _state == State.RETRY:
		_retry_remaining = maxf(0.0, _retry_remaining - delta)
		if _retry_remaining > 0.0:
			return true
		_set_state(State.TIMING)
	elif _state == State.SEARCH:
		_set_state(State.TIMING)
	else:
		elapsed_fraction += delta * progress_speed / ROUND_SECONDS
		if elapsed_fraction >= 1.0:
			_retry()
	return true

func cycle_visible_target(camera: Camera3D, world_mask: int, step: int) -> bool:
	var candidates: Array[SpatialFlyingPatrol] = []
	for node in camera.get_tree().get_nodes_in_group(SpatialFlyingPatrol.MAP_GROUP):
		var patrol := node as SpatialFlyingPatrol
		if _visible(camera, patrol, world_mask):
			candidates.append(patrol)
	if candidates.is_empty():
		return false
	candidates.sort_custom(func(left: SpatialFlyingPatrol, right: SpatialFlyingPatrol) -> bool:
		var left_x := camera.unproject_position(left.global_position).x
		var right_x := camera.unproject_position(right.global_position).x
		if left_x == right_x:
			return left.get_instance_id() < right.get_instance_id()
		return left_x < right_x)
	var current := candidates.find(_target) if is_instance_valid(_target) else -1
	var next := 0 if step > 0 else candidates.size() - 1
	if current >= 0:
		next = wrapi(current + step, 0, candidates.size())
		if next == current:
			return false
	_select_target(camera, candidates[next])
	return true

func select_pointer_target(camera: Camera3D, pointer: Vector2, world_mask: int) -> bool:
	var candidate := _nearest_visible_target(camera, pointer, world_mask, true)
	if candidate == null or candidate == _target:
		return false
	_select_target(camera, candidate)
	return true

func _nearest_visible_target(camera: Camera3D, pointer: Vector2, world_mask: int,
		under_pointer := false) -> SpatialFlyingPatrol:
	var target: SpatialFlyingPatrol
	var nearest := INF
	for node in camera.get_tree().get_nodes_in_group(SpatialFlyingPatrol.MAP_GROUP):
		var patrol := node as SpatialFlyingPatrol
		if patrol == null or not patrol.active or patrol.is_queued_for_deletion():
			continue
		var distance := pointer.distance_squared_to(camera.unproject_position(patrol.global_position))
		if distance < nearest and _visible(camera, patrol, world_mask):
			if under_pointer and not _screen_box(camera, patrol).has_point(pointer):
				continue
			target = patrol
			nearest = distance
	return target

func _select_target(camera: Camera3D, patrol: SpatialFlyingPatrol) -> void:
	_target = patrol
	_update_square(camera)
	_reset_attempt(State.IDLE)
	_reset_attempt(State.SEARCH)

func _update_square(camera: Camera3D) -> void:
	var bounds := _screen_box(camera, _target)
	center = bounds.get_center()
	radius = bounds.size.x * 0.5

func _screen_box(camera: Camera3D, patrol: SpatialFlyingPatrol) -> Rect2:
	var position := patrol.global_position
	var screen := camera.unproject_position(position)
	var edge := position + camera.global_basis.x.normalized() * patrol.agent_radius_m
	var half_size := Vector2.ONE * clampf(screen.distance_to(camera.unproject_position(edge)) + 28.0, 38.0, 82.0)
	return Rect2(screen - half_size, half_size * 2.0)

func pointer_moved(pointer: Vector2) -> void:
	if _state != State.IDLE and _state != State.SEARCH and not _contains(pointer):
		_reset_attempt(State.SEARCH)

func _contains(pointer: Vector2) -> bool:
	var offset := (pointer - center).abs()
	return offset.x <= radius and offset.y <= radius

func handle_fire_click(screen: Vector2, camera: Camera3D, world_mask: int) -> ClickResult:
	if _state == State.IDLE:
		return ClickResult.PASS
	if searching:
		return ClickResult.CONSUMED
	if not _contains(screen):
		_reset_attempt(State.SEARCH)
		return ClickResult.CONSUMED
	if not _visible(camera, _target, world_mask):
		_retry()
		return ClickResult.CONSUMED
	for index in WINDOW_FRACTIONS.size():
		var window := WINDOW_FRACTIONS[index]
		if elapsed_fraction >= window.x and elapsed_fraction < window.y:
			if index < completed_windows.size():
				return ClickResult.CONSUMED
			if index > completed_windows.size():
				break
			if index == WINDOW_FRACTIONS.size() - 1:
				return ClickResult.FIRE
			completed_windows.append(index)
			_set_state(State.LOCKED)
			return ClickResult.CONSUMED
	_retry()
	return ClickResult.CONSUMED

func take_firing_target() -> SpatialFlyingPatrol:
	var target := _target
	_retry(false)
	return target

func clear() -> void:
	_reset_attempt(State.IDLE)
	_target = null

func _retry(announce_search := true) -> void:
	_reset_attempt(State.RETRY, announce_search)
	_retry_remaining = RETRY_SECONDS

func _reset_attempt(state: State, announce := true) -> void:
	elapsed_fraction = 0.0
	completed_windows.clear()
	_retry_remaining = 0.0
	_set_state(state, announce)

func _set_state(state: State, announce := true) -> void:
	var was_searching := searching
	var was_locked := locked
	_state = state
	if announce and searching and not was_searching:
		search_started.emit()
	elif announce and locked and not was_locked:
		target_locked.emit()

func _visible(camera: Camera3D, candidate: Variant, world_mask: int) -> bool:
	# A displayed patrol may be destroyed by an earlier shot between frames.
	if not is_instance_valid(candidate):
		return false
	var target := candidate as SpatialFlyingPatrol
	if not target.active or target.is_queued_for_deletion() or not target.is_visible_for_player_aim():
		return false
	var origin := camera.global_position
	var point := target.global_position
	if origin.distance_squared_to(point) > RANGE_M * RANGE_M or camera.is_position_behind(point) \
			or not camera.get_viewport().get_visible_rect().has_point(camera.unproject_position(point)):
		return false
	var query := PhysicsRayQueryParameters3D.create(origin, point, world_mask, [_shooter, target.get_rid()])
	query.hit_from_inside = true
	return camera.get_world_3d().direct_space_state.intersect_ray(query).is_empty()
