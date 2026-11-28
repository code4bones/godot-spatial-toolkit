@tool
extends Control

signal bbox_added(bbox: Dictionary)
signal bbox_edited(id: int, bbox: Dictionary)
signal bbox_shortcut_changed
signal view_changed
signal tile_status(message: String)
signal selection_feedback(message: String)

const Mercator := preload("map_projection.gd")
const GeoJSONOverlay := preload("geojson_overlay.gd")
const TileProvider := preload("tile_provider.gd")
const TileCache := preload("tile_cache.gd")
const Request := preload("res://addons/spatial_toolkit/core/spatial_http_request.gd")
const Network := preload("res://addons/spatial_toolkit/core/spatial_network_settings.gd")
const TILE_SIZE := 256.0
const MAX_REQUESTS := 4
const MAX_TEXTURES := 128
const NO_EDIT_HANDLE := -2
const MOVE_HANDLE := -1
const CITYGML_COVERAGE_COLOR := Color("c393ff")

# Keep the center in doubles so high-zoom cursor anchoring survives editor builds
# with single-precision vectors.
var center_x := 0.5
var center_y := 0.5
var zoom := 2
var provider: TileProvider
var overlay: GeoJSONOverlay
var _textures: Dictionary = {}
var _failed: Dictionary = {}
var _active: Dictionary = {}
var _tile_proxy: Variant = null
var _visible: Array[Vector3i] = []
var _tiles_restricted := false
var _tile_coverage: Dictionary = {}
var _follow_tile_coverage := false
var _dragging := false
var bbox_mode := false
var bbox_drawing_enabled := true:
	set(value):
		bbox_drawing_enabled = value
		if not value:
			_end_bbox_drag()
var regions: Array[Dictionary] = []
var citygml_dataset: Dictionary = {}
var _citygml_reference_bounds: Dictionary = {}
var _bbox_drag := false
var _bbox_shortcut_active := false
var _bbox_start := Vector2.ZERO
var _bbox_end := Vector2.ZERO
var _edit_id := 0
var _edit_handle := NO_EDIT_HANDLE
var _edit_start := Vector2.ZERO
var _edit_original := Rect2()
var _edit_preview := Rect2()

func _ready() -> void:
	clip_contents = true
	set_process_input(false)
	_tile_proxy = Network.proxy_for(Network.MAP_EXPLORER)
	if Network.is_available():
		Network.changes().changed.connect(_on_network_settings_changed)
	resized.connect(_sync_layout)
	_sync_layout()

func set_provider(value: TileProvider) -> void:
	_cancel_requests()
	_textures.clear()
	_failed.clear()
	provider = value
	_refresh()

func _on_network_settings_changed() -> void:
	if _update_tile_proxy():
		_refresh()

func _update_tile_proxy() -> bool:
	var proxy: Variant = Network.proxy_for(Network.MAP_EXPLORER)
	if proxy == _tile_proxy:
		return false
	_tile_proxy = proxy
	_cancel_requests()
	_failed.clear()
	if provider != null:
		tile_status.emit("")
	return true

func set_tile_coverage(bbox: Dictionary, restricted: bool) -> void:
	_tiles_restricted = restricted
	_tile_coverage = _project_bbox(bbox) if restricted and _is_valid_tile_coverage(bbox) else {}
	_follow_tile_coverage = not _tile_coverage.is_empty()
	_sync_layout()

func set_citygml_dataset(dataset: Dictionary, reference_bounds: Dictionary = {}) -> void:
	citygml_dataset = dataset.duplicate(true)
	_citygml_reference_bounds = reference_bounds.duplicate()
	queue_redraw()

func _is_valid_tile_coverage(bbox: Dictionary) -> bool:
	for side in ["west", "north", "east", "south"]:
		var coordinate: Variant = bbox.get(side)
		if not (coordinate is int or coordinate is float) or not is_finite(float(coordinate)):
			return false
	var longitude_span := float(bbox["east"]) - float(bbox["west"])
	return (
		absf(bbox["west"]) <= 180.0 and absf(bbox["east"]) <= 180.0
		and -90.0 <= bbox["south"] and bbox["south"] < bbox["north"] and bbox["north"] <= 90.0
		and longitude_span != 0.0 and longitude_span != -360.0
	)

func _notification(what: int) -> void:
	if not is_node_ready():
		return
	if what == NOTIFICATION_VISIBILITY_CHANGED or what == NOTIFICATION_WM_WINDOW_FOCUS_OUT:
		_dragging = false
		_end_bbox_drag()
		_edit_handle = NO_EDIT_HANDLE
		queue_redraw()
	if what == NOTIFICATION_VISIBILITY_CHANGED:
		_sync_layout()

func _sync_layout() -> void:
	if _follow_tile_coverage and is_visible_in_tree() and size.x > 0.0 and size.y > 0.0:
		_fit_projected_bbox(_tile_coverage, true)
	else:
		_refresh()

func go_to(longitude: float, latitude: float, zoom_level: int = -1) -> void:
	if zoom_level >= 0:
		zoom = clampi(zoom_level, 0, 19)
	_set_center(Mercator.longitude_to_x(longitude), Mercator.latitude_to_y(latitude))

func change_zoom(delta: int, anchor: Vector2) -> void:
	var next := clampi(zoom + delta, 0, 19)
	if next == zoom:
		return
	var offset := anchor - size * 0.5
	var before := _world_size()
	zoom = next
	var factor := 1.0 / before - 1.0 / _world_size()
	_set_center(center_x + offset.x * factor, center_y + offset.y * factor)

func fit_overlay() -> void:
	if overlay == null:
		return
	var extent := overlay.bounds
	var available := (size - Vector2(48, 48)).max(Vector2.ONE)
	var span := extent.size.max(Vector2(1e-12, 1e-12))
	var scale := minf(available.x / span.x, available.y / span.y) / TILE_SIZE
	zoom = clampi(floori(log(scale) / log(2.0)), 0, 19)
	var center := extent.get_center()
	_set_center(center.x, center.y)

func fit_bbox(bbox: Dictionary) -> void:
	_fit_projected_bbox(_project_bbox(bbox))

func _project_bbox(bbox: Dictionary) -> Dictionary:
	var west := Mercator.longitude_to_x(bbox["west"])
	var east := Mercator.longitude_to_x(bbox["east"])
	if east < west:
		east += 1.0
	return {
		"west": west,
		"east": east,
		"north": Mercator.latitude_to_y(bbox["north"]),
		"south": Mercator.latitude_to_y(bbox["south"]),
	}

func _fit_projected_bbox(bbox: Dictionary, follow_tile_coverage: bool = false) -> void:
	var west: float = bbox["west"]
	var east: float = bbox["east"]
	var north: float = bbox["north"]
	var south: float = bbox["south"]
	var available := (size - Vector2(48, 48)).max(Vector2.ONE)
	var scale := minf(available.x / maxf(east - west, 1e-12),
		available.y / maxf(south - north, 1e-12)) / TILE_SIZE
	zoom = clampi(floori(log(scale) / log(2.0)), 0, 19)
	_set_center((west + east) * 0.5, (north + south) * 0.5, follow_tile_coverage)

func _set_center(x: float, y: float, follow_tile_coverage: bool = false) -> void:
	_follow_tile_coverage = follow_tile_coverage
	center_x = fposmod(x, 1.0)
	center_y = clampf(y, 0.0, 1.0)
	_refresh()
	view_changed.emit()

func _world_size() -> float:
	return TILE_SIZE * (1 << zoom)

func set_bbox_edit(id: int) -> void:
	if _edit_id != id:
		_edit_id = id
		_edit_handle = NO_EDIT_HANDLE
		queue_redraw()

func _edit_input(event: InputEvent) -> bool:
	if _edit_id == 0:
		return false
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			for entry in regions:
				if int(entry["id"]) != _edit_id:
					continue
				var box := _region_rect(entry["bbox"])
				# Use the world copy under the pointer on wide views.
				box.position.x += roundf((event.position.x - box.get_center().x) /
					_world_size()) * _world_size()
				var corners := _corners(box)
				for index in corners.size():
					if corners[index].distance_to(event.position) <= 9.0:
						_edit_handle = index
						break
				if _edit_handle == NO_EDIT_HANDLE and box.has_point(event.position):
					_edit_handle = MOVE_HANDLE
				if _edit_handle != NO_EDIT_HANDLE:
					_edit_start = event.position
					_edit_original = box
					_edit_preview = box
					_dragging = false
				return _edit_handle != NO_EDIT_HANDLE
		elif _edit_handle != NO_EDIT_HANDLE:
			_update_edit_preview(event.position)
			_edit_handle = NO_EDIT_HANDLE
			if _edit_preview != _edit_original and _edit_preview.size.x < _world_size():
				var bbox := _screen_bbox(_edit_preview)
				if bbox["north"] > bbox["south"] and bbox["east"] != bbox["west"]:
					bbox_edited.emit(_edit_id, bbox)
			queue_redraw()
			return true
	elif _edit_handle != NO_EDIT_HANDLE:
		if event is InputEventMouseMotion:
			_update_edit_preview(event.position)
			queue_redraw()
		return true
	return false

func _update_edit_preview(position: Vector2) -> void:
	var delta := position - _edit_start
	if delta.length_squared() < 4.0:
		_edit_preview = _edit_original
		return
	var world_top := size.y * 0.5 - center_y * _world_size()
	var world_bottom := world_top + _world_size()
	if _edit_handle == MOVE_HANDLE:
		_edit_preview.position = _edit_original.position + delta
		_edit_preview.position.y = clampf(_edit_preview.position.y, world_top,
			world_bottom - _edit_original.size.y)
		return
	var corners := _corners(_edit_original)
	var fixed := corners[(_edit_handle + 2) % 4]
	var moving := corners[_edit_handle] + delta
	moving.y = clampf(moving.y, world_top, world_bottom)
	var box := Rect2(fixed, moving - fixed).abs()
	if box.size.x >= 4.0 and box.size.y >= 4.0 and box.size.x < _world_size():
		_edit_preview = box

func _corners(box: Rect2) -> Array[Vector2]:
	return [box.position, Vector2(box.end.x, box.position.y), box.end,
		Vector2(box.position.x, box.end.y)]

func is_bbox_shortcut_active() -> bool:
	return _bbox_shortcut_active

func _set_bbox_shortcut_active(active: bool) -> void:
	if _bbox_shortcut_active != active:
		_bbox_shortcut_active = active
		bbox_shortcut_changed.emit()

func _end_bbox_drag() -> void:
	if not _bbox_drag:
		return
	_bbox_drag = false
	set_process_input(false)
	_set_bbox_shortcut_active(false)
	queue_redraw()

func _input(event: InputEvent) -> void:
	# Listen for the modifier release even while the map has no keyboard focus.
	if event is InputEventKey:
		var modifier := KEY_META if OS.has_feature("macos") else KEY_CTRL
		if event.keycode == modifier or event.physical_keycode == modifier:
			_set_bbox_shortcut_active(event.pressed)

func _bbox_input(event: InputEvent) -> bool:
	var mouse := event as InputEventMouseButton
	if _bbox_drag:
		if mouse != null and mouse.button_index == MOUSE_BUTTON_LEFT and not mouse.pressed:
			var end_position := mouse.position.clamp(Vector2.ZERO, size)
			var rect := Rect2(_bbox_start, end_position - _bbox_start).abs()
			_end_bbox_drag()
			if rect.size.x >= 4.0 and rect.size.y >= 4.0 and rect.size.x < _world_size():
				bbox_added.emit(_screen_bbox(rect))
		elif event is InputEventMouseMotion:
			_bbox_end = event.position.clamp(Vector2.ZERO, size)
			queue_redraw()
		return true
	if not bbox_drawing_enabled or mouse == null:
		return false
	var shortcut := mouse.is_command_or_control_pressed()
	if mouse.button_index == MOUSE_BUTTON_LEFT and mouse.pressed and (bbox_mode or shortcut):
		_dragging = false
		_bbox_start = mouse.position
		_bbox_end = mouse.position
		_bbox_drag = true
		set_process_input(shortcut)
		_set_bbox_shortcut_active(shortcut)
		queue_redraw()
		return true
	return false

func _gui_input(event: InputEvent) -> void:
	if _bbox_input(event) or _edit_input(event):
		accept_event()
		return
	if event is InputEventMouseButton:
		match event.button_index:
			MOUSE_BUTTON_LEFT, MOUSE_BUTTON_MIDDLE:
				_dragging = event.pressed
			MOUSE_BUTTON_WHEEL_UP:
				if event.pressed:
					change_zoom(1, event.position)
			MOUSE_BUTTON_WHEEL_DOWN:
				if event.pressed:
					change_zoom(-1, event.position)
			_:
				return
		accept_event()
	elif event is InputEventMouseMotion and _dragging:
		if not (event.button_mask & (MOUSE_BUTTON_MASK_LEFT | MOUSE_BUTTON_MASK_MIDDLE)):
			_dragging = false
			return
		_set_center(center_x - event.relative.x / _world_size(),
			center_y - event.relative.y / _world_size())
		accept_event()

func _screen_bbox(rect: Rect2) -> Dictionary:
	var start := rect.position - size * 0.5
	var end := rect.end - size * 0.5
	var world_size := _world_size()
	return {
		"west": Mercator.x_to_longitude(center_x + start.x / world_size),
		"east": Mercator.x_to_longitude(center_x + end.x / world_size),
		"north": Mercator.y_to_latitude(center_y + start.y / world_size),
		"south": Mercator.y_to_latitude(center_y + end.y / world_size),
	}

func _positions() -> Array[Vector2i]:
	var count := 1 << zoom
	var half_tiles := size / (2.0 * TILE_SIZE)
	var positions: Array[Vector2i] = []
	if _tiles_restricted and _tile_coverage.is_empty():
		return positions
	for y in range(maxi(0, floori(center_y * count - half_tiles.y)),
			mini(count, ceili(center_y * count + half_tiles.y))):
		for x in range(floori(center_x * count - half_tiles.x),
				ceili(center_x * count + half_tiles.x)):
			var position := Vector2i(x, y)
			if not _tiles_restricted or not _tile_fragments(position).is_empty():
				positions.append(position)
	return positions

func _tile_fragments(position: Vector2i) -> Array[Rect2]:
	var count := 1 << zoom
	var y_min := clampf(_tile_coverage["north"] * count - position.y, 0.0, 1.0)
	var y_max := clampf(_tile_coverage["south"] * count - position.y, 0.0, 1.0)
	var fragments: Array[Rect2] = []
	if y_max <= y_min:
		return fragments
	var x := posmod(position.x, count)
	var west: float = _tile_coverage["west"] * count - x
	var east: float = _tile_coverage["east"] * count - x
	# A date-line crossing can contribute two separate strips to the z0 tile.
	for shift in [0, count]:
		var x_min := clampf(west - shift, 0.0, 1.0)
		var x_max := clampf(east - shift, 0.0, 1.0)
		if x_max > x_min:
			fragments.append(Rect2(x_min, y_min, x_max - x_min, y_max - y_min))
	return fragments

func _key(position: Vector2i) -> Vector3i:
	return Vector3i(posmod(position.x, 1 << zoom), position.y, zoom)

func _refresh() -> void:
	queue_redraw()
	_visible.clear()
	if not is_visible_in_tree() or size.x <= 0.0 or size.y <= 0.0:
		_cancel_requests()
		return
	var count := 1 << zoom
	var tile_center := Vector2(center_x * count, center_y * count)
	var positions := _positions()
	positions.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
		return (Vector2(a) + Vector2(0.5, 0.5)).distance_squared_to(tile_center) < (
			Vector2(b) + Vector2(0.5, 0.5)).distance_squared_to(tile_center))
	for position in positions:
		var key := _key(position)
		if not _visible.has(key):
			_visible.append(key)
	for key in _active.keys():
		if not _visible.has(key):
			_drop_request(key)
	for key in _failed.keys():
		if not _visible.has(key):
			_failed.erase(key)
	_pump()

func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), Color(0.10, 0.12, 0.15))
	var count := 1 << zoom
	for position in _positions():
		var offset := Vector2(position.x - center_x * count, position.y - center_y * count)
		var rect := Rect2(size * 0.5 + offset * TILE_SIZE, Vector2.ONE * TILE_SIZE)
		_draw_tile(position, rect)
	_draw_overlay()
	var citygml_coverage: Dictionary = citygml_dataset.get("coverage", {})
	if not citygml_coverage.is_empty():
		_draw_region(_region_rect(citygml_coverage), CITYGML_COVERAGE_COLOR, false)
	elif _citygml_reference_bounds:
		_draw_region(_region_rect(_citygml_reference_bounds), CITYGML_COVERAGE_COLOR, false, true)
	for entry in regions:
		var color := Color(0.36, 0.73, 1.0) if entry.get("checked", false) else Color(0.94, 0.65, 0.25)
		if entry.get("imported", false):
			color = Color(0.31, 0.88, 0.56)
		var editing := int(entry["id"]) == _edit_id
		var box := _edit_preview if editing and _edit_handle != NO_EDIT_HANDLE else _region_rect(entry["bbox"])
		_draw_region(box, color, editing)
	if _bbox_drag:
		draw_rect(Rect2(_bbox_start, _bbox_end - _bbox_start).abs(), Color.WHITE, false, 2.0)

func _draw_tile(position: Vector2i, tile: Rect2) -> void:
	var texture: Texture2D = _textures.get(_key(position))
	var fragments: Array[Rect2] = [Rect2(Vector2.ZERO, Vector2.ONE)]
	if _tiles_restricted:
		fragments = _tile_fragments(position)
	for fragment in fragments:
		var target := Rect2(tile.position + fragment.position * TILE_SIZE, fragment.size * TILE_SIZE)
		if texture != null:
			var texture_size := texture.get_size()
			var source := Rect2(fragment.position * texture_size, fragment.size * texture_size)
			draw_texture_rect_region(texture, target, source)
		elif provider != null:
			var placeholder := target.intersection(tile.grow(-1))
			if placeholder.has_area():
				draw_rect(placeholder, Color(0.17, 0.20, 0.25))

func _region_rect(bbox: Dictionary) -> Rect2:
	var west := Mercator.longitude_to_x(bbox["west"]) - center_x
	var east := Mercator.longitude_to_x(bbox["east"]) - center_x
	if east < west:
		east += 1.0
	var north := Mercator.latitude_to_y(bbox["north"]) - center_y
	var south := Mercator.latitude_to_y(bbox["south"]) - center_y
	var scale := _world_size()
	var copy := roundf(-(west + east) * 0.5)
	return Rect2(size * 0.5 + Vector2((west + copy) * scale, north * scale),
		Vector2((east - west) * scale, (south - north) * scale))

func _draw_region(box: Rect2, color: Color, editing: bool, reference: bool = false) -> void:
	var scale := _world_size()
	for copy in range(ceili(-box.end.x / scale), floori((size.x - box.position.x) / scale) + 1):
		var visible_box := Rect2(box.position + Vector2(copy * scale, 0), box.size)
		draw_rect(visible_box, Color(color, 0.12 if reference else 0.15))
		if reference:
			var corners := _corners(visible_box)
			for index in corners.size():
				draw_dashed_line(corners[index], corners[(index + 1) % corners.size()], color, 2.0, 7.0)
			_draw_coverage_label(visible_box, color)
		else:
			draw_rect(visible_box, Color.WHITE if editing else color, false, 2.0)
		if editing:
			for corner in _corners(visible_box):
				draw_rect(Rect2(corner - Vector2(4, 4), Vector2(8, 8)), Color.WHITE)

func _draw_coverage_label(box: Rect2, color: Color) -> void:
	var font := get_theme_default_font()
	var font_size := get_theme_default_font_size()
	var title := atr("3D model extent")
	var padding := Vector2(6, 3)
	var label_size := font.get_string_size(title, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size) + padding * 2
	var visible_box := box.intersection(Rect2(Vector2.ZERO, size)).grow(-5.0)
	if visible_box.size.x < label_size.x or visible_box.size.y < label_size.y:
		return
	draw_rect(Rect2(visible_box.position, label_size), Color(0.10, 0.12, 0.15, 0.92))
	var baseline := visible_box.position + padding + Vector2(0, font.get_ascent(font_size))
	draw_string(font, baseline, title, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, color)

func _draw_overlay() -> void:
	if overlay == null:
		return
	var world_size := _world_size()
	var viewport := Rect2(Vector2.ZERO, size).grow(2.0)
	var half := size * 0.5
	var line_color := Color(0.37, 0.88, 0.93)
	for path in overlay.paths:
		var position := path["bounds"] as Rect2
		var x: float = path["x"] - center_x
		var y: float = path["y"] - center_y
		var first := ceili(-half.x / world_size - x - position.end.x)
		var last := floori(half.x / world_size - x - position.position.x)
		for copy in range(first, last + 1):
			var offset := half + Vector2((x + copy) * world_size, y * world_size)
			var screen_bounds := Rect2(offset + position.position * world_size,
				position.size * world_size)
			if not viewport.intersects(screen_bounds.grow(1.0)):
				continue
			draw_set_transform(offset, 0.0, Vector2.ONE * world_size)
			draw_polyline(path["points"], line_color)
	draw_set_transform(Vector2.ZERO)

func _pump() -> void:
	if provider == null:
		return
	_update_tile_proxy()
	for key in _visible:
		if _active.size() >= MAX_REQUESTS:
			break
		if _active.has(key) or _textures.has(key) or _failed.has(key):
			continue
		var url := provider.tile_url(key)
		var cached := TileCache.read_tile(url) if provider.template == TileProvider.OSM_URL else {}
		var headers := PackedStringArray(["User-Agent: GodotSpatialToolkit/0.7.0"])
		if not cached.is_empty():
			if float(cached.get("expires", 0)) > Time.get_unix_time_from_system():
				if _store_texture(key, cached["body"]):
					queue_redraw()
					continue
				cached.clear()
			for pair in [["etag", "If-None-Match"], ["last-modified", "If-Modified-Since"]]:
				var value: String = cached.get("headers", {}).get(pair[0], "")
				if not value.is_empty():
					headers.append("%s: %s" % [pair[1], value])
		var proxy: Variant = _tile_proxy
		if proxy is String and proxy.is_empty():
			_failed[key] = true
			tile_status.emit(atr(Network.SETTINGS_PATH))
			continue
		var request := Request.new()
		request.timeout = 10.0
		request.body_size_limit = 2 * 1024 * 1024
		request.use_threads = true
		add_child(request)
		_active[key] = request
		request.request_completed.connect(_tile_completed.bind(key, request, url, cached, proxy != null))
		var error := request.request(url, headers, HTTPClient.METHOD_GET, "", proxy)
		if error != OK:
			_drop_request(key)
			_failed[key] = true
			tile_status.emit(atr("Tile request failed (%s)") % error_string(error))

func _drop_request(key: Vector3i) -> void:
	var request: Request = _active[key]
	_active.erase(key)
	request.cancel_request()
	request.queue_free()

func _cancel_requests() -> void:
	for key in _active.keys():
		_drop_request(key)

func _tile_completed(result: int, code: int, headers: PackedStringArray,
		body: PackedByteArray, key: Vector3i, request: Request, url: String,
		cached: Dictionary, using_proxy: bool) -> void:
	if _active.get(key) != request:
		return
	_active.erase(key)
	request.queue_free()
	if result == HTTPRequest.RESULT_SUCCESS and (code == 200 or (code == 304 and not cached.is_empty())):
		var image_bytes: PackedByteArray = cached["body"] if code == 304 else body
		if _store_texture(key, image_bytes):
			if provider.template == TileProvider.OSM_URL:
				TileCache.store_tile(url, image_bytes, headers, cached if code == 304 else {})
		else:
			_failed[key] = true
			tile_status.emit(atr("Could not decode tile image"))
	else:
		_failed[key] = true
		tile_status.emit(_tile_error(result, code, using_proxy))
	queue_redraw()
	_pump()

func _tile_error(result: int, code: int, using_proxy: bool) -> String:
	if code == 407:
		return atr("Proxy authentication failed (HTTP 407). Check the login and password.")
	if using_proxy:
		match result:
			HTTPRequest.RESULT_REQUEST_FAILED:
				return atr("Invalid proxy URL. Use http://login:pass@server:port.")
			HTTPRequest.RESULT_CANT_CONNECT:
				return atr("Could not connect to the tile server through the proxy.")
			HTTPRequest.RESULT_TLS_HANDSHAKE_ERROR:
				return atr("TLS verification failed through the proxy.")
	return atr("Tile request failed (HTTP %d, result %d)") % [code, result]

func _store_texture(key: Vector3i, body: PackedByteArray) -> bool:
	var image := Image.new()
	var error := image.load_png_from_buffer(body)
	if error != OK:
		error = image.load_jpg_from_buffer(body)
	if error != OK:
		error = image.load_webp_from_buffer(body)
	if error != OK:
		return false
	_textures[key] = ImageTexture.create_from_image(image)
	for old_key in _textures.keys():
		if _textures.size() <= MAX_TEXTURES:
			break
		if not _visible.has(old_key):
			_textures.erase(old_key)
	return true
