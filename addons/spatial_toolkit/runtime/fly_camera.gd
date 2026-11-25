extends Camera3D
## Runtime flight camera. A CharacterBody3D parent enables collision-aware flight.

@export_range(1.0, 500.0, 1.0) var speed_mps: float = 30.0
@export_range(1.0, 20.0, 0.5) var fast_multiplier: float = 4.0
@export_range(0.0001, 0.02, 0.0001) var mouse_sensitivity: float = 0.0025
@export var overview_camera_path: NodePath = NodePath("../OverviewCamera")
@export var map_legend_path: NodePath = NodePath("../PreviewLegend/Legend")
@export_range(1.0, 10.0, 0.1) var follow_distance: float = 3.0
@export_range(0.0, 2.0, 0.05) var follow_height: float = 0.1
@export_range(1.0, 500.0, 1.0) var waypoint_arrival_radius: float = 20.0
@export var third_person: bool = false:
	set(value):
		third_person = value
		if is_node_ready():
			_apply_view_mode()

const FlightMap := preload("res://addons/spatial_toolkit/runtime/flight_map.gd")

var _flight_overlay: CanvasLayer
var _body: CharacterBody3D
var _boom: SpringArm3D
var _pivot: Node3D
var _craft: Node3D
var _eye_height := 0.7
var _boom_margin := 0.12

func _ready() -> void:
	var ancestor := get_parent()
	while ancestor != null:
		if ancestor is CharacterBody3D:
			_body = ancestor
			break
		ancestor = ancestor.get_parent()
	_boom = get_parent() as SpringArm3D
	if _boom != null:
		_pivot = _boom.get_parent() as Node3D
		_eye_height = _pivot.position.y
		_boom_margin = _boom.margin
		if _body != null:
			_boom.add_excluded_object(_body.get_rid())
	if _body != null:
		_craft = _body.get_node_or_null("FlightCraft") as Node3D
	_create_flight_overlay()
	_apply_view_mode()
	get_window().focus_exited.connect(_release_mouse)
	if current:
		_capture_mouse()
		_hide_map_legend()

func _exit_tree() -> void:
	if current and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE

func _physics_process(delta: float) -> void:
	if not current or Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
		_stop_body()
		return
	var local := Vector3(
		float(Input.is_physical_key_pressed(KEY_D)) - float(Input.is_physical_key_pressed(KEY_A)),
		float(Input.is_physical_key_pressed(KEY_E) or Input.is_physical_key_pressed(KEY_SPACE)) - float(Input.is_physical_key_pressed(KEY_Q) or Input.is_physical_key_pressed(KEY_CTRL)),
		float(Input.is_physical_key_pressed(KEY_S)) - float(Input.is_physical_key_pressed(KEY_W)))
	_move_flight(local, delta, Input.is_physical_key_pressed(KEY_SHIFT))

func _move_flight(local_axes: Vector3, delta: float, boosted: bool = false) -> void:
	var direction := global_basis * Vector3(local_axes.x, 0, local_axes.z) + Vector3.UP * local_axes.y
	var boost := fast_multiplier if boosted else 1.0
	var desired_velocity := direction.normalized() * speed_mps * boost
	if _body != null:
		_body.velocity = desired_velocity
		_body.move_and_slide()
	else:
		global_position += desired_velocity * delta
	_update_craft(local_axes, delta)

func _stop_body() -> void:
	if _body != null:
		_body.velocity = Vector3.ZERO

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_TAB:
		_toggle_overview()
		get_viewport().set_input_as_handled()
		return
	if not current:
		return
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_V:
		_toggle_third_person()
		get_viewport().set_input_as_handled()
		return
	if event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		_release_mouse()
		get_viewport().set_input_as_handled()
	elif event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_LEFT:
			_capture_mouse()
		elif event.button_index == MOUSE_BUTTON_WHEEL_UP:
			speed_mps = minf(500.0, speed_mps * 1.25)
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			speed_mps = maxf(1.0, speed_mps / 1.25)
		else:
			return
		get_viewport().set_input_as_handled()
	elif event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		_look(event.relative)
		get_viewport().set_input_as_handled()

func _look(relative: Vector2) -> void:
	var look_node: Node3D = _pivot if _pivot != null else self
	look_node.rotation.y -= relative.x * mouse_sensitivity
	look_node.rotation.x = clampf(look_node.rotation.x - relative.y * mouse_sensitivity, deg_to_rad(-89.0), deg_to_rad(89.0))
	look_node.rotation.z = 0.0

func _toggle_third_person() -> void:
	if _boom != null:
		third_person = not third_person

func _apply_view_mode() -> void:
	if _boom != null:
		_boom.spring_length = follow_distance if third_person else 0.0
		_boom.margin = _boom_margin if third_person else 0.0
	if _pivot != null:
		_pivot.position.y = _eye_height + (follow_height if third_person else 0.0)
	if _craft != null:
		_craft.visible = third_person

func _update_craft(axes: Vector3, delta: float) -> void:
	if _craft == null:
		return
	var look_node: Node3D = _pivot if _pivot != null else self
	_craft.rotation.y = look_node.rotation.y
	_craft.rotation.x = lerp_angle(_craft.rotation.x, clampf(look_node.rotation.x * 0.3, -0.2, 0.2), minf(1.0, delta * 8.0))
	_craft.rotation.z = lerp_angle(_craft.rotation.z, -axes.x * 0.15, minf(1.0, delta * 8.0))

func _toggle_overview() -> void:
	var overview := get_node_or_null(overview_camera_path) as Camera3D
	if current and overview != null:
		_stop_body()
		overview.make_current()
		_release_mouse()
		_hide_map_legend()
	else:
		make_current()
		_hide_map_legend()
		_capture_mouse()

func _hide_map_legend() -> void:
	var legend := get_node_or_null(map_legend_path) as Control
	if legend != null:
		legend.hide()

func _capture_mouse() -> void:
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED

func _release_mouse() -> void:
	_stop_body()
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE

func _map_heading() -> Vector3:
	var look_node: Node3D = _pivot if _pivot != null else self
	var forward := -look_node.global_basis.z
	forward.y = 0.0
	return Vector3.FORWARD if forward.is_zero_approx() else forward.normalized()

func _create_flight_overlay() -> void:
	_flight_overlay = CanvasLayer.new()
	_flight_overlay.name = "FlightOverlay"
	_flight_overlay.layer = 2
	add_child(_flight_overlay)
	var overview := get_node_or_null(overview_camera_path) as Camera3D
	if overview == null:
		return
	var map := overview.get_parent()
	var ground := map.get_node_or_null("FlatGround") as Node3D
	if ground == null or overview.projection != Camera3D.PROJECTION_ORTHOGONAL:
		return
	var display := FlightMap.new()
	display.name = "FlightMap"
	display.flight_camera = self
	display.overview_camera = overview
	display.player = _body if _body != null else self
	display.ground = ground
	display.nose_direction = _map_heading
	display.waypoint_arrival_radius = waypoint_arrival_radius
	display.world_scale = clampf(float(map.get_meta("world_scale", 1.0)), 1.0, 100.0)
	_flight_overlay.add_child(display)
