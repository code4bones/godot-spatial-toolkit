extends Control
## Runtime-only map display sharing the saved scene's World3D.

const MAP_PIXELS := 192
const CAPTURE_PIXELS := 320
const MAP_SPAN_M := 250.0
const ROTATION_RESPONSE := 14.0
const MAP_MARGIN := 18.0
const REFRESH_SECONDS := 0.125
const MAX_PROJECTILE_VIEWS := 4
const Projectile := preload("res://addons/spatial_toolkit/runtime/drone_projectile.gd")
const OverviewLabels := preload("res://addons/spatial_toolkit/runtime/overview_labels.gd")
const MARKER_COLOR := Color(0.32, 0.87, 1.0)
const MARKER_OUTLINE := Color(0.04, 0.10, 0.16)
const WAYPOINT_COLOR := Color(1.0, 0.75, 0.27)
const PATROL_COLOR := Color(1.0, 0.31, 0.37)
const WAYPOINT_HIT_RADIUS := 11.0
const WAYPOINT_MARKER_LAYER := 20
const WAYPOINT_MARKER := preload("res://addons/spatial_toolkit/runtime/waypoint_marker.tscn")
const CARDINALS := ["N", "E", "S", "W"]
const COMPASS_HALF_SPAN := 90.0
const HUD_TEXT := Color(0.88, 0.93, 0.96)
const HUD_MUTED := Color(0.62, 0.74, 0.81)

var flight_camera: Camera3D
var overview_camera: Camera3D
var player: Node3D
var ground: Node3D
var world_scale := 1.0
var nose_direction: Callable
var waypoint_arrival_radius := 20.0
var _waypoints: Array[Node3D] = []
var _waypoint_root: Node3D
var _mini_view: SubViewport
var _mini_camera: Camera3D
var _projectile_views: Array[SubViewport] = []
var _projectile_cameras: Array[Camera3D] = []
var _projectile_tiles: Array[Rect2] = []
var _refresh_in := 0.0
var _circle := PackedVector2Array()
var _circle_uv := PackedVector2Array()
var _minimap_heading := 0.0
var _minimap_center := Vector2.ZERO
var _capture_center := Vector2.ZERO
var _panel: StyleBoxFlat
var _previous_position := Vector3.ZERO
var _free_velocity := Vector3.ZERO
var _overview_labels: OverviewLabels

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	for index in 64:
		var point := Vector2.from_angle(float(index) * TAU / 64.0)
		_circle.append(point)
	_circle_uv.resize(_circle.size())
	_panel = StyleBoxFlat.new()
	_panel.bg_color = Color(0.04, 0.08, 0.12, 0.83)
	_panel.border_color = Color(0.50, 0.65, 0.73, 0.6)
	_panel.set_border_width_all(1)
	_panel.set_corner_radius_all(8)
	_previous_position = player.global_position
	_waypoint_root = Node3D.new()
	_waypoint_root.name = "WaypointMarkers"
	_waypoint_root.visible = flight_camera.current
	add_child(_waypoint_root)
	_mini_view = SubViewport.new()
	_mini_view.name = "MinimapViewport"
	_mini_view.size = Vector2i(CAPTURE_PIXELS, CAPTURE_PIXELS)
	_mini_view.world_3d = get_viewport().find_world_3d()
	_mini_view.render_target_update_mode = SubViewport.UPDATE_DISABLED
	add_child(_mini_view)
	_mini_camera = Camera3D.new()
	_mini_camera.set_cull_mask_value(WAYPOINT_MARKER_LAYER, false)
	_mini_camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	_mini_camera.size = MAP_SPAN_M * world_scale * float(CAPTURE_PIXELS) / MAP_PIXELS
	_mini_camera.rotation.x = -PI * 0.5
	_mini_camera.near = 1.0
	var environment := Environment.new()
	environment.background_mode = Environment.BG_COLOR
	environment.background_color = Color("18232d")
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.ambient_light_color = Color.WHITE
	environment.ambient_light_energy = 0.85
	_mini_camera.environment = environment
	_mini_view.add_child(_mini_camera)
	_mini_camera.make_current()

func _process(delta: float) -> void:
	var position := player.global_position
	if not player is CharacterBody3D and delta > 0.0:
		var velocity := (position - _previous_position) / delta if flight_camera.current else Vector3.ZERO
		_free_velocity = _free_velocity.lerp(velocity, minf(delta * 12.0, 1.0))
	_waypoint_root.visible = flight_camera.current
	_update_projectile_views()
	if flight_camera.current:
		_remove_reached_waypoints(_previous_position, position)
		var course := deg_to_rad(_bearing(_map_course()))
		_minimap_heading = lerp_angle(_minimap_heading, course,
			1.0 - exp(-ROTATION_RESPONSE * delta)) if _refresh_in != 0.0 else course
		_minimap_center = Vector2(position.x, position.z)
		_refresh_in -= delta
		var padding := (_mini_camera.size - MAP_SPAN_M * world_scale) * 0.48
		if not _projectile_tiles.is_empty():
			_refresh_in = -REFRESH_SECONDS
			_mini_view.render_target_update_mode = SubViewport.UPDATE_DISABLED
		elif _refresh_in <= 0.0 or _minimap_center.distance_squared_to(_capture_center) > padding * padding:
			_refresh_in = REFRESH_SECONDS
			_capture_center = _minimap_center
			var altitude := maxf(500.0 * world_scale, overview_camera.far * 0.25)
			_mini_camera.global_position = Vector3(position.x,
				maxf(position.y, ground.global_position.y) + altitude, position.z)
			_mini_camera.far = _mini_camera.global_position.y - ground.global_position.y + altitude
			_mini_view.render_target_update_mode = SubViewport.UPDATE_ONCE
	else:
		_refresh_in = 0.0
		_mini_view.render_target_update_mode = SubViewport.UPDATE_DISABLED
		if overview_camera.current and _overview_labels == null:
			_overview_labels = OverviewLabels.new()
			_overview_labels.collect(overview_camera.get_parent() as Node3D, ground, world_scale)
	_previous_position = position
	queue_redraw()

func _update_projectile_views() -> void:
	var rockets: Array[Projectile] = []
	if flight_camera.current:
		for child in flight_camera.get_children():
			var rocket := child as Projectile
			if rocket != null and rocket.has_camera_view():
				rockets.append(rocket)
	_projectile_tiles.clear()
	var count := mini(rockets.size(), MAX_PROJECTILE_VIEWS)
	var rect := _map_rect()
	if rect.size.x <= 4.0:
		count = 0
	for index in count:
		if index == _projectile_views.size():
			var viewport := SubViewport.new()
			viewport.world_3d = _mini_view.world_3d
			viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
			add_child(viewport)
			_projectile_views.append(viewport)
			var camera := Camera3D.new()
			camera.near = 0.05
			camera.far = flight_camera.far
			viewport.add_child(camera)
			camera.make_current()
			_projectile_cameras.append(camera)
		var tile := _projectile_tile(rect, count, index)
		_projectile_tiles.append(tile)
		var viewport := _projectile_views[index]
		viewport.size = Vector2i(tile.size.round()).max(Vector2i(2, 2))
		viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
		var rocket := rockets[rockets.size() - count + index]
		_projectile_cameras[index].global_transform = rocket.camera_view_transform()
	for index in range(count, _projectile_views.size()):
		_projectile_views[index].render_target_update_mode = SubViewport.UPDATE_DISABLED

func _projectile_tile(rect: Rect2, count: int, index: int) -> Rect2:
	if count == 1:
		return rect
	var height := rect.size.y * 0.5
	if count == 2 or (count == 3 and index == 0):
		return Rect2(rect.position + Vector2(0, height * index), Vector2(rect.size.x, height))
	var cell := index - 1 if count == 3 else index
	var row := 1 if count == 3 else cell / 2
	var half := rect.size * 0.5
	return Rect2(rect.position + Vector2((cell % 2) * half.x, row * half.y), half)

func reset_travel_sample() -> void:
	_previous_position = player.global_position
	_free_velocity = Vector3.ZERO

func _map_rect() -> Rect2:
	var side := minf(MAP_PIXELS, minf(size.x, size.y) * 0.32)
	return Rect2(Vector2(size.x - side - MAP_MARGIN, MAP_MARGIN), Vector2(side, side))

func _flight_velocity() -> Vector3:
	if player is CharacterBody3D:
		return Vector3.ZERO if player.velocity.is_zero_approx() else player.get_real_velocity()
	return _free_velocity

func _map_course() -> Vector3:
	var velocity := _flight_velocity()
	velocity.y = 0.0
	if velocity.length_squared() > 0.0625:
		return velocity.normalized()
	return nose_direction.call()

func _altitude() -> float:
	return player.global_position.y - ground.global_position.y

static func _bearing(direction: Vector3) -> float:
	return rad_to_deg(atan2(direction.x, -direction.z))

static func _bearing_offset(bearing: float, heading: float) -> float:
	return wrapf(bearing - heading, -180.0, 180.0)

func _screen_nose(camera: Camera3D) -> Vector2:
	var nose: Vector3 = nose_direction.call()
	var basis := camera.global_basis
	return Vector2(basis.x.dot(nose), -basis.y.dot(nose)).normalized()

func _unhandled_input(event: InputEvent) -> void:
	if not overview_camera.current or not event is InputEventMouseButton:
		return
	if event.button_index != MOUSE_BUTTON_LEFT or not event.pressed:
		return
	if not Rect2(Vector2.ZERO, size).has_point(event.position):
		return
	_toggle_waypoint(event.position)
	get_viewport().set_input_as_handled()

func _toggle_waypoint(screen: Vector2) -> void:
	var nearest := -1
	var distance := WAYPOINT_HIT_RADIUS * WAYPOINT_HIT_RADIUS
	for index in _waypoints.size():
		var waypoint := _waypoints[index].global_position
		if overview_camera.is_position_behind(waypoint):
			continue
		var squared := overview_camera.unproject_position(waypoint).distance_squared_to(screen)
		if squared <= distance:
			nearest = index
			distance = squared
	if nearest >= 0:
		_remove_waypoint(nearest)
	else:
		var plane := Plane(Vector3.UP, ground.global_position.y)
		var point: Variant = plane.intersects_ray(
			overview_camera.project_ray_origin(screen), overview_camera.project_ray_normal(screen))
		if point is Vector3:
			add_waypoint(point)
	queue_redraw()

func add_waypoint(point: Vector3) -> void:
	if not point.is_finite():
		return
	var marker := WAYPOINT_MARKER.instantiate() as Node3D
	_waypoint_root.add_child(marker)
	marker.global_position = point
	_waypoints.append(marker)
	queue_redraw()

func _remove_waypoint(index: int) -> void:
	var marker := _waypoints[index]
	_waypoints.remove_at(index)
	marker.hide()
	marker.queue_free()

func _remove_reached_waypoints(previous: Vector3, current: Vector3) -> void:
	# Map waypoints mark ground areas, so arrival uses horizontal distance.
	# Test the travelled segment to catch crossings between frames at high speed.
	var start := Vector2(previous.x, previous.z)
	var finish := Vector2(current.x, current.z)
	var radius_squared := waypoint_arrival_radius * waypoint_arrival_radius
	for index in range(_waypoints.size() - 1, -1, -1):
		var waypoint := _waypoints[index].global_position
		var target := Vector2(waypoint.x, waypoint.z)
		var closest := Geometry2D.get_closest_point_to_segment(target, start, finish)
		if target.distance_squared_to(closest) <= radius_squared:
			_remove_waypoint(index)

func _draw() -> void:
	if flight_camera == null or _mini_view == null:
		return
	if flight_camera.current:
		if _projectile_tiles.is_empty():
			_draw_minimap()
		else:
			for index in _projectile_tiles.size():
				var tile := _projectile_tiles[index]
				draw_rect(tile, MARKER_OUTLINE)
				draw_texture_rect(_projectile_views[index].get_texture(), tile.grow(-1.0), false)
		_draw_compass()
		_draw_telemetry()
	elif overview_camera.current:
		_draw_patrols()
		if _overview_labels != null:
			_overview_labels.draw(self, overview_camera, world_scale, _overview_marker_bounds())
		_draw_overview_waypoints()
		_draw_overview_player()

func _draw_minimap() -> void:
	var rect := _map_rect()
	var center := rect.get_center()
	var radius := rect.size.x * 0.5
	var half_span := MAP_SPAN_M * world_scale * 0.5
	draw_circle(center, radius + 3.0, MARKER_OUTLINE, true, -1.0, true)
	# Render a wider north-up area at the existing cadence. The visible crop moves
	# and rotates in 2D every frame, so neither motion waits on a 3D refresh.
	var uv_center := Vector2(0.5, 0.5) + (_minimap_center - _capture_center) / _mini_camera.size
	for index in _circle.size():
		_circle_uv[index] = uv_center + _circle[index].rotated(_minimap_heading) * (half_span / _mini_camera.size)
	draw_set_transform(center, 0.0, Vector2.ONE * radius)
	draw_polygon(_circle, PackedColorArray([Color.WHITE]), _circle_uv, _mini_view.get_texture())
	draw_set_transform(Vector2.ZERO)
	draw_circle(center, radius, HUD_MUTED, false, 1.0, true)
	_draw_patrols(rect)
	for waypoint in _waypoints:
		_draw_waypoint(_minimap_waypoint_position(waypoint.global_position, rect), 6.0)
	_draw_player(center, _screen_nose(_mini_camera).rotated(-_minimap_heading))

func _minimap_waypoint_position(waypoint: Vector3, rect: Rect2) -> Vector2:
	var radius := maxf(rect.size.x * 0.5 - 7.0, 0.0)
	return rect.get_center() + _minimap_offset(waypoint, rect).limit_length(radius)

func _minimap_offset(position: Vector3, rect: Rect2) -> Vector2:
	var offset := Vector2(position.x, position.z) - _minimap_center
	var pixels_per_metre := rect.size.x / (MAP_SPAN_M * world_scale)
	return offset.rotated(-_minimap_heading) * pixels_per_metre

func _draw_patrols(minimap := Rect2()) -> void:
	var overview_rect := Rect2(Vector2.ZERO, size).grow(-7.0)
	for patrol: Node3D in get_tree().get_nodes_in_group(&"spatial_road_patrol"):
		if patrol.get_viewport() != get_viewport() or patrol.is_queued_for_deletion():
			continue
		var position := patrol.global_position
		if minimap.has_area():
			var radius := maxf(minimap.size.x * 0.5 - 7.0, 0.0)
			var offset := _minimap_offset(position, minimap)
			_draw_patrol(minimap.get_center() + offset.limit_length(radius),
				offset.length_squared() <= radius * radius)
		elif not overview_camera.is_position_behind(position):
			var screen := overview_camera.unproject_position(position)
			if overview_rect.has_point(screen):
				_draw_patrol(screen, true)

func _draw_patrol(point: Vector2, filled: bool) -> void:
	var rect := Rect2(point - Vector2(4, 4), Vector2(8, 8))
	draw_rect(rect.grow(1.5), MARKER_OUTLINE)
	draw_rect(rect, PATROL_COLOR, filled, -1.0 if filled else 1.5)

func _compass_width() -> float:
	var side := _map_rect().size.x + MAP_MARGIN + 8.0
	return minf(minf(size.x * 0.42, 420.0), maxf(64.0, size.x - 2.0 * side))

func _draw_compass() -> void:
	var width := _compass_width()
	var rect := Rect2(Vector2((size.x - width) * 0.5, MAP_MARGIN), Vector2(width, 56.0))
	draw_style_box(_panel, rect)
	var heading := _bearing(nose_direction.call())
	var px_per_degree := (width * 0.5 - 12.0) / COMPASS_HALF_SPAN
	var center_x := rect.get_center().x
	var font := ThemeDB.fallback_font
	draw_line(Vector2(center_x, rect.position.y + 1.0),
		Vector2(center_x, rect.position.y + 11.0), MARKER_COLOR, 2.0, true)
	for tick in range(0, 360, 15):
		var offset := _bearing_offset(tick, heading)
		if absf(offset) > COMPASS_HALF_SPAN:
			continue
		var x := center_x + offset * px_per_degree
		var cardinal := tick % 90 == 0
		var height := 8.0 if cardinal else 4.0
		draw_line(Vector2(x, rect.position.y + 17.0 - height), Vector2(x, rect.position.y + 17.0),
			HUD_TEXT if cardinal else HUD_MUTED, 1.0, true)
		if cardinal:
			var text: String = CARDINALS[floori(tick / 90.0)]
			draw_string(font, Vector2(x - font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, 14).x * 0.5,
				rect.position.y + 34.0), text, HORIZONTAL_ALIGNMENT_LEFT, -1, 14, HUD_TEXT)
	for waypoint in _waypoints:
		var direction := waypoint.global_position - player.global_position
		direction.y = 0.0
		if direction.length_squared() > 0.01:
			var offset := clampf(_bearing_offset(_bearing(direction), heading),
				-COMPASS_HALF_SPAN, COMPASS_HALF_SPAN)
			_draw_waypoint(Vector2(center_x + offset * px_per_degree, rect.position.y + 45.0), 4.0)

func _draw_telemetry() -> void:
	var width := 150.0
	var top := MAP_MARGIN
	if (size.x - _compass_width()) * 0.5 < MAP_MARGIN + width + 8.0:
		top += 64.0
	var rect := Rect2(Vector2(MAP_MARGIN, top), Vector2(width, 106.0))
	draw_style_box(_panel, rect)
	var font := ThemeDB.fallback_font
	var x := rect.position.x + 12.0
	var y := rect.position.y
	draw_string(font, Vector2(x, y + 18.0), "Скорость", HORIZONTAL_ALIGNMENT_LEFT, -1, 13, HUD_MUTED)
	draw_string(font, Vector2(x, y + 41.0), "%.1f м/с" % _flight_velocity().length(),
		HORIZONTAL_ALIGNMENT_LEFT, -1, 21, HUD_TEXT)
	draw_line(Vector2(x, y + 52.0), Vector2(rect.end.x - 12.0, y + 52.0), Color(HUD_MUTED, 0.45))
	draw_string(font, Vector2(x, y + 71.0), "Высота", HORIZONTAL_ALIGNMENT_LEFT, -1, 13, HUD_MUTED)
	draw_string(font, Vector2(x, y + 94.0), "%.1f м" % _altitude(),
		HORIZONTAL_ALIGNMENT_LEFT, -1, 21, HUD_TEXT)

func _draw_overview_waypoints() -> void:
	var visible_rect := Rect2(Vector2.ZERO, size).grow(-7.0)
	for marker in _waypoints:
		var waypoint := marker.global_position
		if overview_camera.is_position_behind(waypoint):
			continue
		var screen := overview_camera.unproject_position(waypoint)
		if visible_rect.has_point(screen):
			_draw_waypoint(screen, 6.0)

func _overview_marker_bounds() -> Array[Rect2]:
	var bounds: Array[Rect2] = []
	for marker in _waypoints:
		var center := overview_camera.unproject_position(marker.global_position)
		bounds.append(Rect2(center - Vector2(7, 7), Vector2(14, 14)))
	var center := overview_camera.unproject_position(player.global_position)
	bounds.append(Rect2(center - Vector2(10, 10), Vector2(20, 20)))
	return bounds

func _draw_waypoint(point: Vector2, length: float) -> void:
	var diamond := PackedVector2Array([
		point + Vector2.UP * length, point + Vector2.RIGHT * length,
		point + Vector2.DOWN * length, point + Vector2.LEFT * length])
	draw_colored_polygon(diamond, WAYPOINT_COLOR)
	diamond.append(diamond[0])
	draw_polyline(diamond, MARKER_OUTLINE, 1.5, true)

func _draw_overview_player() -> void:
	if overview_camera.is_position_behind(player.global_position):
		return
	var screen := overview_camera.unproject_position(player.global_position)
	var inset := Rect2(Vector2.ZERO, size).grow(-16.0)
	if inset.has_point(screen):
		_draw_player(screen, _screen_nose(overview_camera))
	elif inset.has_area():
		var edge := screen.clamp(inset.position, inset.end)
		_draw_player(edge, (screen - edge).normalized())

func _draw_player(point: Vector2, forward: Vector2) -> void:
	if forward.is_zero_approx():
		forward = Vector2.UP
	var side := forward.orthogonal()
	var triangle := PackedVector2Array([
		point + forward * 13.0, point - forward * 6.0 + side * 7.0,
		point - forward * 6.0 - side * 7.0])
	draw_colored_polygon(triangle, MARKER_COLOR)
	triangle.append(triangle[0])
	draw_polyline(triangle, MARKER_OUTLINE, 2.0, true)
