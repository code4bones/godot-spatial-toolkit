extends CharacterBody3D
## Traversal on the static collision shell of a map.

const FlightInput := preload("res://addons/spatial_toolkit/runtime/flight_input.gd")
const SpiderModel := preload("res://addons/spatial_toolkit/runtime/spider_model.gd")
const RADIUS := 0.35
const SKIN := 0.025
const CONTACT := RADIUS + SKIN
const SNAP := 0.16
const EDGE_SAMPLE := 0.045
const SPAWN_REACH := 20000.0
const CHASE_OFFSET := Vector3(0.0, 0.55, 2.65)
const CHASE_PITCH := deg_to_rad(8.0)
const CHASE_RADIUS := 0.18
const MIN_MODEL_DISTANCE := 0.85

@export var walk_speed_mps := 5.0
@export var climb_speed_mps := 4.0
@export var mouse_sensitivity := 0.0025
@export var stick_look_radians_per_second := 2.4

var active := false
var view: Camera3D
var third_person := false
var surface_normal := Vector3.UP
var _forward := Vector3.FORWARD
var _pitch := 0.0
var _attached := false
var _spawned := false
var _controlling := false
var _shape: SphereShape3D
var _chase_query: PhysicsShapeQueryParameters3D
var _chase_distance := 0.0
var _model: SpiderModel
var _turn_points := PackedVector3Array()
var _turn_start := Vector3.UP
var _turn_end := Vector3.UP
var _turn_length := 0.0

func _ready() -> void:
	FlightInput.ensure_actions()
	top_level = true
	motion_mode = MOTION_MODE_FLOATING
	collision_layer = 0
	_shape = SphereShape3D.new()
	_shape.radius = RADIUS
	var collision := CollisionShape3D.new()
	collision.shape = _shape
	add_child(collision)
	view = Camera3D.new()
	view.name = "SpiderCamera"
	view.near = 0.05
	view.top_level = true
	add_child(view)
	var chase_shape := SphereShape3D.new()
	chase_shape.radius = CHASE_RADIUS
	_chase_query = PhysicsShapeQueryParameters3D.new()
	_chase_query.shape = chase_shape
	_chase_query.exclude = [get_rid()]
	set_physics_process(false)
	get_window().focus_exited.connect(_release_controls)

func activate_below(origin: Vector3, heading: Vector3) -> bool:
	if not _spawned:
		var ground := _support_ray(origin, origin + Vector3.DOWN * SPAWN_REACH)
		if ground.is_empty() or Vector3(ground.normal).dot(Vector3.UP) < 0.5:
			return false
		var center: Vector3 = ground.position + ground.normal * CONTACT
		var query := PhysicsShapeQueryParameters3D.new()
		query.shape = _shape
		query.transform = Transform3D(Basis.IDENTITY, center)
		query.collision_mask = collision_mask
		query.exclude = [get_rid()]
		if not get_world_3d().direct_space_state.intersect_shape(query, 1).is_empty():
			return false
		global_position = center
		var direction := heading.slide(Vector3.UP)
		_forward = direction.normalized() if direction.length_squared() > 0.0001 else Vector3.FORWARD
		_align_to(ground.normal)
		_attached = true
		_spawned = true
	active = true
	set_physics_process(true)
	_update_view(1.0)
	view.make_current()
	return true

func deactivate() -> void:
	active = false
	set_physics_process(false)
	if _model != null:
		_model.hide()
	_release_controls()

func capture_controls() -> void:
	_controlling = true
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED

func _release_controls() -> void:
	if active or _controlling:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	_controlling = false

func _exit_tree() -> void:
	_release_controls()

func _unhandled_input(event: InputEvent) -> void:
	if not active or not view.current:
		return
	if FlightInput.event_pressed(event, &"flight_release_controls"):
		_release_controls()
	elif FlightInput.event_pressed(event, &"flight_toggle_view"):
		third_person = not third_person
	elif FlightInput.event_pressed(event, &"flight_toggle_controls"):
		if _controlling:
			_release_controls()
		else:
			capture_controls()
	elif FlightInput.event_pressed(event, &"flight_primary_click") and not _controlling:
		capture_controls()
	elif event is InputEventMouseMotion and _controlling:
		_look(event.relative * mouse_sensitivity)
	else:
		return
	get_viewport().set_input_as_handled()

func _physics_process(delta: float) -> void:
	var axes := Vector2.ZERO
	if _controlling and view.current:
		var look := Input.get_vector(&"flight_look_left", &"flight_look_right", &"flight_look_up", &"flight_look_down")
		_look(look * stick_look_radians_per_second * delta)
		axes = Input.get_vector(&"flight_move_left", &"flight_move_right", &"flight_move_backward", &"flight_move_forward")
	var before := global_position
	step_surface(axes, delta)
	_update_view(1.0 - exp(-15.0 * delta), global_position - before, delta)

## Positive X moves right, positive Y moves forward in the local surface plane.
func step_surface(axes: Vector2, delta: float) -> void:
	if not _turn_points.is_empty():
		_advance_corner(climb_speed_mps * delta)
		return
	if not _attached:
		_fall(delta)
		return
	var speed := walk_speed_mps if surface_normal.y > 0.7 else climb_speed_mps
	var direction := _forward.cross(surface_normal) * axes.x + _forward * axes.y
	var motion := direction.limit_length() * speed * delta
	var hit := move_and_collide(motion) if not motion.is_zero_approx() else null
	if hit != null and hit.get_collider() is StaticBody3D and direction.dot(hit.get_normal()) < -0.20:
		var normal := hit.get_normal()
		_align_to(normal)
		move_and_collide(normal * SKIN)
		return
	var support := _support_ray(global_position, global_position - surface_normal * (CONTACT + SNAP))
	if not support.is_empty() and Vector3(support.normal).dot(surface_normal) > 0.5:
		var center: Vector3 = support.position + support.normal * CONTACT
		move_and_collide(center - global_position)
		_align_to(support.normal)
	elif direction.is_zero_approx() or not _start_corner(direction.normalized(), motion.length()):
		_attached = false
		velocity = Vector3.ZERO

func _start_corner(direction: Vector3, step: float) -> bool:
	var probe := global_position - surface_normal * (CONTACT + SNAP) + direction * CONTACT
	var face := _support_ray(probe, probe - direction * (CONTACT + step + SNAP))
	if face.is_empty():
		return false
	var next_normal: Vector3 = face.normal
	var facing := next_normal.dot(surface_normal)
	if next_normal.dot(direction) < 0.35 or facing < -0.5 or facing > 0.92:
		return false
	var old_plane := Plane(surface_normal, global_position - surface_normal * CONTACT)
	var new_plane := Plane(next_normal, face.position)
	var cross_section := Plane(surface_normal.cross(next_normal).normalized(), global_position)
	var intersection: Variant = old_plane.intersect_3(new_plane, cross_section)
	if intersection == null:
		return false
	var edge: Vector3 = intersection
	if old_plane.project(global_position).distance_to(edge) > step + EDGE_SAMPLE:
		return false
	# Check both surfaces next to the same edge before sweeping round it.
	var before := edge - next_normal.slide(surface_normal).normalized() * EDGE_SAMPLE
	var after := edge - surface_normal.slide(next_normal).normalized() * EDGE_SAMPLE
	if not _has_support(before, surface_normal) or not _has_support(after, next_normal):
		return false
	var pivot := edge + (surface_normal + next_normal) * (CONTACT / (1.0 + facing))
	var target := after + next_normal * CONTACT
	if test_move(global_transform, pivot - global_position) \
			or test_move(Transform3D(global_basis, pivot), target - pivot):
		return false
	_turn_points = PackedVector3Array([pivot, target])
	_turn_start = surface_normal
	_turn_end = next_normal
	_turn_length = global_position.distance_to(pivot) + pivot.distance_to(target)
	return true

func _advance_corner(budget: float) -> void:
	while budget > 0.0 and not _turn_points.is_empty():
		var offset := _turn_points[0] - global_position
		var distance := offset.length()
		if distance > 0.0001 and move_and_collide(offset.limit_length(budget)) != null:
			_turn_points.clear()
			_attached = false
			velocity = Vector3.ZERO
			return
		if distance > budget:
			break
		_turn_points.remove_at(0)
		budget -= distance
	if _turn_points.is_empty():
		_align_to(_turn_end)
	else:
		var left := global_position.distance_to(_turn_points[0])
		if _turn_points.size() == 2:
			left += _turn_points[0].distance_to(_turn_points[1])
		_align_to(_turn_start.slerp(_turn_end, clampf(1.0 - left / _turn_length, 0.0, 1.0)))

func _fall(delta: float) -> void:
	velocity += get_gravity() * delta
	var hit := move_and_collide(velocity * delta)
	if hit == null:
		return
	var normal := hit.get_normal()
	velocity = velocity.slide(normal)
	if hit.get_collider() is StaticBody3D and normal.y > 0.35:
		_align_to(normal)
		move_and_collide(normal * SKIN)
		_attached = true
		velocity = Vector3.ZERO

func _has_support(point: Vector3, normal: Vector3) -> bool:
	var hit := _support_ray(point + normal * CONTACT, point - normal * EDGE_SAMPLE)
	return not hit.is_empty() and Vector3(hit.normal).dot(normal) > 0.95 \
		and Vector3(hit.position).distance_to(point) <= EDGE_SAMPLE

func _support_ray(from: Vector3, to: Vector3) -> Dictionary:
	var query := PhysicsRayQueryParameters3D.create(from, to, collision_mask, [get_rid()])
	var hit := get_world_3d().direct_space_state.intersect_ray(query)
	return hit if hit.get("collider") is StaticBody3D else {}

func _align_to(normal: Vector3) -> void:
	_forward = (Quaternion(surface_normal, normal) * _forward).slide(normal).normalized()
	surface_normal = normal

func _look(amount: Vector2) -> void:
	_forward = _forward.rotated(surface_normal, -amount.x)
	_pitch = clampf(_pitch - amount.y, deg_to_rad(-85.0), deg_to_rad(85.0))

func _update_view(weight: float, travel := Vector3.ZERO, delta := 0.0) -> void:
	var heading := Basis.looking_at(_forward, surface_normal)
	var tilt := maxf(_pitch - CHASE_PITCH, deg_to_rad(-85.0)) if third_person else _pitch
	var target := heading * Basis(Vector3.RIGHT, tilt)
	var orientation := view.global_basis.slerp(target, weight).orthonormalized()
	var eye := global_position
	if third_person:
		if _model == null:
			_model = SpiderModel.new()
			_model.name = "SpiderModel"
			add_child(_model)
		var offset := orientation * CHASE_OFFSET
		_chase_query.transform = Transform3D(Basis.IDENTITY, eye)
		_chase_query.motion = offset
		_chase_query.collision_mask = collision_mask
		var space := get_world_3d().direct_space_state
		var fractions := space.cast_motion(_chase_query)
		var clear_distance := offset.length() * (fractions[0] if fractions.size() == 2 else 1.0)
		# Pull in immediately at a wall and ease back out after it clears.
		_chase_distance = minf(clear_distance, lerpf(_chase_distance, clear_distance, weight))
		eye += offset.normalized() * _chase_distance
		_model.visible = _chase_distance >= MIN_MODEL_DISTANCE
		_model.global_basis = heading
		_model.animate(heading.inverse() * travel, delta)
	else:
		_chase_distance = 0.0
		if _model != null:
			_model.hide()
	view.global_transform = Transform3D(orientation, eye)
