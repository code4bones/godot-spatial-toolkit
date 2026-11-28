extends SpatialFlyingPatrol
## Switches presentation detail independently of the patrol's motion and sensing.

const ExhaustTrail := preload("res://addons/spatial_toolkit/runtime/exhaust_trail.gd")
const RENDER_HYSTERESIS_M := 25.0

@onready var _hull: Node3D = $Visual/MicroShip
@onready var _camera_boom: SpringArm3D = $Visual/CameraBoom
@onready var _follow_camera: Camera3D = $Visual/CameraBoom/PatrolCamera
@onready var _marker: Label3D = $Marker

var _emitting_trails: Array[ExhaustTrail] = []
var _full_detail := true

func _ready() -> void:
	super._ready()
	for child in _hull.get_children():
		var trail := child as ExhaustTrail
		if trail != null and trail.emitting:
			_emitting_trails.append(trail)
	update_presentation(get_viewport().get_camera_3d(), 0.0, false)

func update_presentation(camera: Camera3D, render_distance_m: float, keep_overview_marker: bool) -> void:
	var following := camera == _follow_camera
	var camera_mode := Node.PROCESS_MODE_INHERIT if following else Node.PROCESS_MODE_DISABLED
	if _camera_boom.process_mode != camera_mode:
		_camera_boom.process_mode = camera_mode
	var draw_hull := following or camera == null or not is_finite(render_distance_m) or render_distance_m <= 0.0
	if not draw_hull:
		var threshold := render_distance_m
		if not _full_detail:
			threshold -= minf(RENDER_HYSTERESIS_M, render_distance_m * 0.25)
		draw_hull = global_position.distance_squared_to(camera.global_position) <= threshold * threshold
	if draw_hull != _full_detail:
		_set_full_detail(draw_hull)
	_marker.visible = not following and (draw_hull or keep_overview_marker)

func is_visible_for_player_aim() -> bool:
	return is_instance_valid(_hull) and _hull.is_visible_in_tree()

func _set_full_detail(enabled: bool) -> void:
	_full_detail = enabled
	_hull.visible = enabled
	_hull.process_mode = Node.PROCESS_MODE_INHERIT if enabled else Node.PROCESS_MODE_DISABLED
	for trail in _emitting_trails:
		if enabled:
			trail._reset_bend()
			trail.restart()
		else:
			trail.emitting = false
