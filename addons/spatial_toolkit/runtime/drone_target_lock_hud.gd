extends Control
## Read-only display of the target timing challenge and acquired lock.

const CLOCK_ORIGIN := -PI * 0.5
const OUTLINE := Color(0.025, 0.045, 0.065, 0.88)
const TIMER := Color(0.56, 0.92, 1.0)
const WINDOW := Color(1.0, 0.72, 0.27)
const READY := Color(0.5, 1.0, 0.73)
const COMPLETED := Color(0.2, 0.91, 0.54)
const LABEL_FONT_SIZE := 14

var _center := Vector2.ZERO
var _radius := 32.0
var _elapsed := 0.0
var _windows: Array[Vector2] = []
var _completed_windows: Array[int] = []
var _locked := false
var _searching := false
var _staged := false
var _timing := false
var _stage_window := Vector2.ZERO
var _stage_markers: Array[Dictionary] = []
var _unseen_status: Dictionary = {}

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	hide()

func update_display(center: Vector2, radius: float, elapsed_fraction: float,
		windows: Array[Vector2], completed_windows: Array[int], locked: bool,
		searching: bool = false) -> void:
	_staged = false
	_center = center
	_radius = maxf(radius, 18.0)
	_elapsed = clampf(elapsed_fraction, 0.0, 1.0)
	if _windows != windows:
		_windows = windows.duplicate()
	if _completed_windows != completed_windows:
		_completed_windows = completed_windows.duplicate()
	_locked = locked
	_searching = searching
	show()
	queue_redraw()

func update_staged_display(center: Vector2, radius: float, elapsed_fraction: float, window: Vector2,
		timing: bool, searching: bool, markers: Array[Dictionary], unseen_status: Dictionary) -> void:
	_staged = true
	_center = center
	_radius = maxf(radius, 18.0)
	_elapsed = clampf(elapsed_fraction, 0.0, 1.0)
	_stage_window = window
	_timing = timing
	_searching = searching
	_stage_markers = markers
	_unseen_status = unseen_status
	visible = _searching or _timing or not _stage_markers.is_empty() or not _unseen_status.is_empty()
	queue_redraw()

func _draw() -> void:
	if _staged:
		_draw_staged()
		return
	if _searching:
		_draw_search_square()
		_draw_label("SEARCH", TIMER)
		return
	var timer_radius := _radius - 6.0
	_draw_range(timer_radius, _elapsed, 1.0, TIMER, 2.5)
	for index in _windows.size():
		var window := _windows[index]
		var completed := _completed_windows.has(index)
		var active := _elapsed >= window.x and _elapsed < window.y
		var color := COMPLETED if completed else (READY if active else WINDOW)
		_draw_range(timer_radius, window.x, window.y, color, 5.0)
	if _locked:
		_draw_locked()

func _draw_staged() -> void:
	if _searching:
		_draw_search_square()
		_draw_label("SEARCH", TIMER)
	if _timing:
		var timer_radius := _radius - 6.0
		_draw_range(timer_radius, _elapsed, 1.0, TIMER, 2.5)
		var active := _elapsed >= _stage_window.x and _elapsed < _stage_window.y
		_draw_range(timer_radius, _stage_window.x, _stage_window.y, READY if active else WINDOW, 5.0)
	for marker in _stage_markers:
		var center: Vector2 = marker["center"]
		var radius := maxf(float(marker["radius"]), 18.0)
		var label: String = marker["label"]
		var color := READY if label == "READY" else WINDOW
		_draw_target_corners(center, radius, color)
		var label_y := _draw_target_label(center, radius, label, color)
		var bar_y := maxf(center.y + radius + 7.0, label_y + 6.0)
		_draw_expiry_bar(center.x, bar_y, radius * 1.25, float(marker["remaining"]), color)
	if not _unseen_status.is_empty():
		var label: String = _unseen_status["label"]
		var color := READY if label == "READY" else WINDOW
		var center_x := size.x * 0.5
		var bar_y := size.y - 28.0
		_draw_centered_text(Vector2(center_x, bar_y - 6.0), label, color)
		_draw_expiry_bar(center_x, bar_y, 128.0, float(_unseen_status["remaining"]), color)

func _draw_expiry_bar(center_x: float, top: float, width: float, remaining: float, color: Color) -> void:
	var bar_width := minf(width, maxf(0.0, size.x - 12.0))
	var x := clampf(center_x - bar_width * 0.5, 6.0, maxf(6.0, size.x - bar_width - 6.0))
	var y := clampf(top, 4.0, maxf(4.0, size.y - 9.0))
	var track := Rect2(x, y, bar_width, 4.0)
	draw_rect(track.grow(1.0), OUTLINE)
	draw_rect(Rect2(track.position, Vector2(track.size.x * clampf(remaining, 0.0, 1.0), track.size.y)), color)

func _draw_range(radius: float, begin: float, end: float, color: Color, width: float) -> void:
	if begin >= end:
		return
	var first := CLOCK_ORIGIN + begin * TAU
	var last := CLOCK_ORIGIN + end * TAU
	var vertices := maxi(2, ceili((end - begin) * 64.0))
	draw_arc(_center, radius, first, last, vertices, OUTLINE, width + 2.0, true)
	draw_arc(_center, radius, first, last, vertices, color, width, true)

func _draw_search_square() -> void:
	var corners := PackedVector2Array([
		_center + Vector2(-_radius, -_radius), _center + Vector2(_radius, -_radius),
		_center + Vector2(_radius, _radius), _center + Vector2(-_radius, _radius),
		_center + Vector2(-_radius, -_radius)
	])
	draw_polyline(corners, OUTLINE, 4.0, true)
	draw_polyline(corners, TIMER, 1.5, true)

func _draw_locked() -> void:
	_draw_target_corners(_center, _radius, READY)
	_draw_label("TARGET LOCKED", READY)

func _draw_target_corners(center: Vector2, radius: float, color: Color) -> void:
	var corner_length := clampf(radius * 0.32, 8.0, 16.0)
	for corner: Vector2 in [Vector2(-1, -1), Vector2(1, -1), Vector2(1, 1), Vector2(-1, 1)]:
		var point := center + corner * radius
		var lines := PackedVector2Array([
			point - Vector2(corner.x * corner_length, 0), point,
			point - Vector2(0, corner.y * corner_length)
		])
		draw_polyline(lines, OUTLINE, 5.0, true)
		draw_polyline(lines, color, 2.0, true)

func _draw_label(label: String, color: Color) -> void:
	_draw_target_label(_center, _radius, label, color)

func _draw_target_label(center: Vector2, radius: float, label: String, color: Color) -> float:
	var font := get_theme_default_font()
	var ascent := font.get_ascent(LABEL_FONT_SIZE)
	var y := center.y - radius - 8.0
	if y < ascent + 4.0:
		y = center.y + radius + ascent + 6.0
	_draw_centered_text(Vector2(center.x, y), label, color)
	return y

func _draw_centered_text(label_position: Vector2, label: String, color: Color) -> void:
	var font := get_theme_default_font()
	var text_width := font.get_string_size(label, HORIZONTAL_ALIGNMENT_LEFT, -1, LABEL_FONT_SIZE).x
	var x := clampf(label_position.x - text_width * 0.5, 4.0, maxf(4.0, size.x - text_width - 4.0))
	var baseline := Vector2(x, label_position.y)
	draw_string_outline(font, baseline, label, HORIZONTAL_ALIGNMENT_LEFT, -1, LABEL_FONT_SIZE, 3, OUTLINE)
	draw_string(font, baseline, label, HORIZONTAL_ALIGNMENT_LEFT, -1, LABEL_FONT_SIZE, color)
