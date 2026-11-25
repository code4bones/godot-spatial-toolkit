@tool
extends Control

signal bbox_added(bbox: Dictionary)
signal bbox_edited(id: int, bbox: Dictionary)
signal view_changed
signal tile_status(message: String)

const Mercator := preload("map_projection.gd")
const GeoJSONOverlay := preload("geojson_overlay.gd")
const TileProvider := preload("tile_provider.gd")
const TileCache := preload("tile_cache.gd")
const TILE_SIZE := 256.0
const MAX_REQUESTS := 4
const MAX_TEXTURES := 128
const NO_EDIT_HANDLE := -2
const MOVE_HANDLE := -1

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
var _visible: Array[Vector3i] = []
var _dragging := false
var bbox_mode := false
var regions: Array[Dictionary] = []
var _bbox_drag := false
var _bbox_start := Vector2.ZERO
var _bbox_end := Vector2.ZERO
var _edit_id := 0
var _edit_handle := NO_EDIT_HANDLE
var _edit_start := Vector2.ZERO
var _edit_original := Rect2()
var _edit_preview := Rect2()

func _ready() -> void:
	clip_contents = true
	resized.connect(_refresh)

func set_provider(value: TileProvider) -> void:
	_cancel_requests()
	_textures.clear()
	_failed.clear()
	provider = value
	_refresh()

func _notification(what: int) -> void:
	if what == NOTIFICATION_VISIBILITY_CHANGED and is_node_ready():
		_dragging = false
		_bbox_drag = false
		_edit_handle = NO_EDIT_HANDLE
		_refresh()

func go_to(longitude: float, latitude: float) -> void:
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
	var west := Mercator.longitude_to_x(bbox["west"])
	var east := Mercator.longitude_to_x(bbox["east"])
	if east < west:
		east += 1.0
	var north := Mercator.latitude_to_y(bbox["north"])
	var south := Mercator.latitude_to_y(bbox["south"])
	var available := (size - Vector2(48, 48)).max(Vector2.ONE)
	var scale := minf(available.x / maxf(east - west, 1e-12),
		available.y / maxf(south - north, 1e-12)) / TILE_SIZE
	zoom = clampi(floori(log(scale) / log(2.0)), 0, 19)
	_set_center((west + east) * 0.5, (north + south) * 0.5)

func _set_center(x: float, y: float) -> void:
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

func _gui_input(event: InputEvent) -> void:
	if _edit_input(event):
		accept_event()
		return
	if bbox_mode and event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			_bbox_start = event.position
			_bbox_end = event.position
			_bbox_drag = true
		elif _bbox_drag:
			_bbox_end = event.position.clamp(Vector2.ZERO, size)
			_bbox_drag = false
			var rect := Rect2(_bbox_start, _bbox_end - _bbox_start).abs()
			if rect.size.x >= 4.0 and rect.size.y >= 4.0 and rect.size.x < _world_size():
				bbox_added.emit(_screen_bbox(rect))
		queue_redraw()
		accept_event()
		return
	if _bbox_drag:
		if event is InputEventMouseMotion:
			_bbox_end = event.position.clamp(Vector2.ZERO, size)
			queue_redraw()
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
	for y in range(maxi(0, floori(center_y * count - half_tiles.y)),
			mini(count, ceili(center_y * count + half_tiles.y))):
		for x in range(floori(center_x * count - half_tiles.x),
				ceili(center_x * count + half_tiles.x)):
			positions.append(Vector2i(x, y))
	return positions

func _key(position: Vector2i) -> Vector3i:
	return Vector3i(posmod(position.x, 1 << zoom), position.y, zoom)

func _refresh() -> void:
	queue_redraw()
	if not is_inside_tree() or not is_visible_in_tree():
		_cancel_requests()
		return
	var count := 1 << zoom
	var tile_center := Vector2(center_x * count, center_y * count)
	var positions := _positions()
	positions.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
		return (Vector2(a) + Vector2(0.5, 0.5)).distance_squared_to(tile_center) < (
			Vector2(b) + Vector2(0.5, 0.5)).distance_squared_to(tile_center))
	_visible.clear()
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
		var key := _key(position)
		if _textures.has(key):
			draw_texture_rect(_textures[key], rect, false)
		elif provider != null:
			draw_rect(rect.grow(-1), Color(0.17, 0.20, 0.25))
	_draw_overlay()
	for entry in regions:
		var color := Color(0.36, 0.73, 1.0) if entry.get("checked", false) else Color(0.94, 0.65, 0.25)
		if entry.get("imported", false):
			color = Color(0.31, 0.88, 0.56)
		var editing := int(entry["id"]) == _edit_id
		var box := _edit_preview if editing and _edit_handle != NO_EDIT_HANDLE else _region_rect(entry["bbox"])
		_draw_region(box, color, editing)
	if _bbox_drag:
		draw_rect(Rect2(_bbox_start, _bbox_end - _bbox_start).abs(), Color.WHITE, false, 2.0)

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

func _draw_region(box: Rect2, color: Color, editing: bool) -> void:
	var scale := _world_size()
	for copy in range(ceili(-box.end.x / scale), floori((size.x - box.position.x) / scale) + 1):
		var visible_box := Rect2(box.position + Vector2(copy * scale, 0), box.size)
		draw_rect(visible_box, Color(color, 0.15))
		draw_rect(visible_box, Color.WHITE if editing else color, false, 2.0)
		if editing:
			for corner in _corners(visible_box):
				draw_rect(Rect2(corner - Vector2(4, 4), Vector2(8, 8)), Color.WHITE)

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
		var request := HTTPRequest.new()
		request.timeout = 10.0
		request.body_size_limit = 2 * 1024 * 1024
		request.use_threads = true
		add_child(request)
		_active[key] = request
		request.request_completed.connect(_tile_completed.bind(key, request, url, cached))
		var error := request.request(url, headers)
		if error != OK:
			_drop_request(key)
			_failed[key] = true
			tile_status.emit("Tile request failed (%s)" % error_string(error))

func _drop_request(key: Vector3i) -> void:
	var request: HTTPRequest = _active[key]
	_active.erase(key)
	request.cancel_request()
	request.queue_free()

func _cancel_requests() -> void:
	for key in _active.keys():
		_drop_request(key)

func _tile_completed(result: int, code: int, headers: PackedStringArray,
		body: PackedByteArray, key: Vector3i, request: HTTPRequest, url: String,
		cached: Dictionary) -> void:
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
			tile_status.emit("Could not decode tile image")
	else:
		_failed[key] = true
		tile_status.emit("Tile request failed (HTTP %d, result %d)" % [code, result])
	queue_redraw()
	_pump()

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
