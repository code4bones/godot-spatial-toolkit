extends Control
## Screen-space aim and destination markers; never intercepts pointer input.

var camera: Camera3D
var aim := Vector2.ZERO
var target := Vector3.ZERO
var has_target := false

func _draw() -> void:
	if camera == null or not camera.current:
		return
	var color := Color(0.4, 0.95, 1.0)
	draw_arc(aim, 8, 0, TAU, 32, Color.BLACK, 3.0, true)
	draw_arc(aim, 8, 0, TAU, 32, color, 1.5, true)
	for direction in [Vector2.RIGHT, Vector2.LEFT, Vector2.UP, Vector2.DOWN]:
		draw_line(aim + direction * 11, aim + direction * 17, color, 2, true)
	if has_target and not camera.is_position_behind(target):
		var point := camera.unproject_position(target)
		if Rect2(Vector2.ZERO, size).has_point(point):
			draw_arc(point, 12, 0, TAU, 32, Color(1, 0.75, 0.25), 2, true)
			draw_circle(point, 2, Color.WHITE)
