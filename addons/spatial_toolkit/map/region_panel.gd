@tool
extends VBoxContainer

signal map_requested
signal import_requested(path: String)
signal preview_requested(path: String)

const Queue := preload("bbox_queue.gd")
const Overpass := preload("overpass_provider.gd")
const ProxyTransport := preload("overpass_proxy.gd")
const CHECK_BUTTON := 0
const DELETE_BUTTON := 1

var queue := Queue.new()
var map: Control
var _list: Tree
var _draw_button: Button
var _editing_id := 0
var _status: Label
var _fetch_button: Button
var _layers_menu: MenuButton
var _fetch_layers: Array = []
var _cancel_fetch_button: Button
var _preview_button: Button
var _send_button: Button
var _retry_timer: Timer
var _http: HTTPRequest
var _proxy_enabled: CheckBox
var _proxy_input: LineEdit
var _endpoint_input: LineEdit
var _proxy: ProxyTransport
var _pending: Array[int] = []
var _current_id := 0
var _fetch_total := 0
var _request_started_ms := 0
var _writable := true
var _endpoint := Overpass.ENDPOINT

func _ready() -> void:
	custom_minimum_size.x = 280
	var tools := HBoxContainer.new()
	add_child(tools)
	_draw_button = _button("", _toggle_draw, tools)
	_draw_button.icon = _draw_bbox_icon()
	_draw_button.toggle_mode = true
	_draw_button.tooltip_text = "Draw BBox"
	_draw_button.accessibility_name = "Draw BBox"
	_list = Tree.new()
	_list.columns = 3
	_list.set_column_expand(0, false)
	_list.set_column_custom_minimum_width(0, 28)
	_list.hide_root = true
	_list.select_mode = Tree.SELECT_ROW
	_list.size_flags_vertical = SIZE_EXPAND_FILL
	_list.item_activated.connect(_activate_selected)
	_list.item_selected.connect(_update_source_buttons)
	_list.button_clicked.connect(_on_row_button)
	add_child(_list)
	var endpoint_label := Label.new()
	endpoint_label.text = "Overpass endpoint"
	add_child(endpoint_label)
	_endpoint_input = LineEdit.new()
	_endpoint_input.placeholder_text = "https://overpass-api.de/api/"
	_endpoint_input.tooltip_text = "Overpass base URL or full /interpreter URL"
	_endpoint_input.text = Overpass.ENDPOINT
	add_child(_endpoint_input)
	_proxy_enabled = CheckBox.new()
	_proxy_enabled.text = "Use HTTP proxy"
	add_child(_proxy_enabled)
	_proxy_input = LineEdit.new()
	_proxy_input.placeholder_text = "http://login:pass@server:port"
	_proxy_input.tooltip_text = "Optional proxy saved in local editor settings for this project"
	_proxy_input.secret = false
	_proxy_input.max_length = 2048
	add_child(_proxy_input)
	if Engine.is_editor_hint():
		var settings := EditorInterface.get_editor_settings()
		_proxy_input.text = str(settings.get_project_metadata("spatial_toolkit", "overpass_proxy", ""))
		_proxy_enabled.button_pressed = bool(settings.get_project_metadata(
			"spatial_toolkit", "overpass_proxy_enabled", not _proxy_input.text.is_empty()))
		_proxy_enabled.toggled.connect(func(enabled: bool) -> void:
			settings.set_project_metadata("spatial_toolkit", "overpass_proxy_enabled", enabled))
		_endpoint_input.text = str(settings.get_project_metadata(
			"spatial_toolkit", "overpass_endpoint", Overpass.ENDPOINT))
		_proxy_input.text_changed.connect(func(value: String) -> void:
			settings.set_project_metadata("spatial_toolkit", "overpass_proxy", value))
		_endpoint_input.text_changed.connect(func(value: String) -> void:
			settings.set_project_metadata("spatial_toolkit", "overpass_endpoint", value))
	_setup_layer_menu()
	_fetch_button = _button("Fetch checked areas", _fetch_checked)
	_cancel_fetch_button = _button("Cancel fetch", _cancel_fetch)
	_cancel_fetch_button.hide()
	_preview_button = _button("Preview downloaded GeoJSON", func() -> void: _use_current(preview_requested))
	_send_button = _button("Send selected to Spatial import", func() -> void: _use_current(import_requested))
	_status = Label.new()
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	add_child(_status)
	_http = HTTPRequest.new()
	_http.timeout = 45
	_http.body_size_limit = 16 * 1024 * 1024
	_http.request_completed.connect(_on_response)
	add_child(_http)
	_proxy = ProxyTransport.new()
	_proxy.completed.connect(func(result: int, code: int, body: PackedByteArray) -> void:
		_on_response(result, code, PackedStringArray(), body))
	add_child(_proxy)
	_retry_timer = Timer.new()
	_retry_timer.one_shot = true
	_retry_timer.timeout.connect(_fetch_next)
	add_child(_retry_timer)
	var error := queue.load_queue()
	if error != OK:
		_writable = false
		_status.text = "Could not load saved areas (%s)." % error_string(error)
	map.bbox_added.connect(_add_bbox)
	map.bbox_edited.connect(_edit_bbox)
	_refresh()

func _setup_layer_menu() -> void:
	_layers_menu = MenuButton.new()
	add_child(_layers_menu)
	var popup := _layers_menu.get_popup()
	popup.hide_on_checkable_item_selection = false
	var settings := EditorInterface.get_editor_settings() if Engine.is_editor_hint() else null
	var enabled: Array = Overpass.DEFAULT_LAYERS
	if settings != null:
		var stored: Variant = settings.get_project_metadata("spatial_toolkit", "overpass_layers", enabled)
		if stored is Array:
			enabled = stored
	var keys := Overpass.LAYERS.keys()
	for index in keys.size():
		var key: String = keys[index]
		popup.add_check_item(Overpass.LAYERS[key]["label"], index)
		popup.set_item_checked(index, key in enabled)
	popup.id_pressed.connect(func(index: int) -> void:
		popup.toggle_item_checked(index)
		if settings != null:
			settings.set_project_metadata("spatial_toolkit", "overpass_layers", _selected_layers())
		_update_layer_menu())
	_update_layer_menu()

func _selected_layers() -> Array:
	var selected: Array = []
	var popup := _layers_menu.get_popup()
	var keys := Overpass.LAYERS.keys()
	for index in keys.size():
		if popup.is_item_checked(index):
			selected.append(keys[index])
	return selected

func _update_layer_menu() -> void:
	var selected := _selected_layers()
	_layers_menu.text = "Fetch layers (%d/%d)" % [selected.size(), Overpass.LAYERS.size()]
	var labels := PackedStringArray()
	for key: String in selected:
		labels.append(Overpass.LAYERS[key]["label"])
	_layers_menu.tooltip_text = ", ".join(labels) if not labels.is_empty() else "Select layers for Fetch"

func _button(caption: String, callback: Callable, parent: Control = null) -> Button:
	var button := Button.new()
	button.text = caption
	button.pressed.connect(callback)
	(parent if parent != null else self).add_child(button)
	return button

func _add_bbox(bbox: Dictionary) -> void:
	if not _writable or bbox["north"] <= bbox["south"] or bbox["east"] == bbox["west"]:
		return
	queue.entries.append({"id": queue.next_id, "bbox": bbox, "checked": false, "scene": ""})
	queue.next_id += 1
	if not _save():
		queue.entries.pop_back()
	_refresh()

func _find(id: int) -> Dictionary:
	for entry in queue.entries:
		if int(entry["id"]) == id:
			return entry
	return {}

func _draw_bbox_icon() -> Texture2D:
	var bitmap := Image.create_empty(16, 16, false, Image.FORMAT_RGBA8)
	var ink := get_theme_color("font_color", "Button")
	for edge in [2, 13]:
		bitmap.fill_rect(Rect2i(2, edge, 12, 1), ink)
		bitmap.fill_rect(Rect2i(edge, 2, 1, 12), ink)
	for x in [1, 12]:
		for y in [1, 12]:
			bitmap.fill_rect(Rect2i(x, y, 3, 3), ink)
	return ImageTexture.create_from_image(bitmap)

func _check_icon(checked: bool) -> Texture2D:
	return _list.get_theme_icon("checked" if checked else "unchecked", "CheckBox")

func _on_row_button(item: TreeItem, column: int, button_id: int, mouse_button: int) -> void:
	if mouse_button != MOUSE_BUTTON_LEFT or not _writable:
		return
	var id := int(item.get_metadata(0))
	if button_id == CHECK_BUTTON:
		var entry := _find(id)
		var previous: bool = entry["checked"]
		entry["checked"] = not previous
		if not _save():
			entry["checked"] = previous
		item.set_button(column, 0, _check_icon(entry["checked"]))
		_refresh_map_regions()
	elif button_id == DELETE_BUTTON:
		_delete_area.call_deferred(id)

func _toggle_draw() -> void:
	map.bbox_mode = _draw_button.button_pressed
	_draw_button.tooltip_text = "Draw BBox active" if map.bbox_mode else "Draw BBox"
	_draw_button.modulate = Color(0.49, 0.81, 1.0) if map.bbox_mode else Color.WHITE
	if map.bbox_mode:
		_editing_id = 0
		map_requested.emit()
	_update_source_buttons()

func _activate_selected() -> void:
	var id := _selected_id()
	var entry := _find(id)
	if entry.is_empty():
		return
	map_requested.emit()
	map.fit_bbox(entry["bbox"])
	if _writable and not _fetch_button.disabled:
		_editing_id = id
		_draw_button.set_pressed_no_signal(false)
		_toggle_draw()

func _delete_area(id: int) -> void:
	var entry := _find(id)
	if entry.is_empty() or not _writable or _fetch_button.disabled:
		return
	var index := queue.entries.find(entry)
	queue.entries.remove_at(index)
	if not _save():
		queue.entries.insert(index, entry)
	else:
		_status.text = "Area %d removed from the list." % id
	_refresh()

func _edit_bbox(id: int, bbox: Dictionary) -> void:
	var entry := _find(id)
	if entry.is_empty() or not _writable or _fetch_button.disabled or entry["bbox"] == bbox:
		return
	var previous := entry.duplicate()
	entry["bbox"] = bbox
	entry["revision"] = int(entry.get("revision", 0)) + 1
	entry["scene"] = ""
	entry.erase("error")
	if not _save():
		entry.assign(previous)
	else:
		_status.text = "Area %d updated. Fetch its new bounds when ready." % id
	_refresh()

func _data_path(entry: Dictionary) -> String:
	return Queue.data_path(int(entry["id"]), int(entry.get("revision", 0)))

func _save() -> bool:
	var error := queue.save_queue() if _writable else ERR_FILE_CORRUPT
	if error != OK:
		_status.text = "Could not save areas (%s)." % error_string(error)
	return error == OK

func _selected_id() -> int:
	var item := _list.get_selected()
	return 0 if item == null else int(item.get_metadata(0))

func _refresh() -> void:
	var selected := _selected_id()
	_list.clear()
	var root := _list.create_item()
	for entry in queue.entries:
		var id := int(entry["id"])
		var row := _list.create_item(root)
		row.set_metadata(0, id)
		row.add_button(0, _check_icon(entry["checked"]), CHECK_BUTTON, not _writable,
			"Toggle this area for Fetch")
		row.set_text(1, "Area %d" % id)
		var path: String = entry.get("scene", "")
		var state := "Planned"
		if not path.is_empty() and FileAccess.file_exists(path):
			state = "Imported"
		elif FileAccess.file_exists(_data_path(entry)):
			state = "Downloaded"
		elif _current_id == id:
			state = "Fetching…"
		elif entry.has("error"):
			state = "Retry"
		row.set_text(2, state)
		row.add_button(2, get_theme_icon("close", "Window"), DELETE_BUTTON,
			not _writable or _fetch_button.disabled, "Remove area from the list")
		var box: Dictionary = entry["bbox"]
		row.set_tooltip_text(1, "S %.6f · W %.6f · N %.6f · E %.6f\nDouble-click to fit and edit." % [
			box["south"], box["west"], box["north"], box["east"]])
		row.set_tooltip_text(2, str(entry.get("error", path)))
		if selected == id:
			row.select(0)
	_refresh_map_regions()
	_update_source_buttons()

func _refresh_map_regions() -> void:
	map.regions.clear()
	for entry in queue.entries:
		var region := entry.duplicate()
		region["imported"] = FileAccess.file_exists(str(entry.get("scene", "")))
		map.regions.append(region)
	map.queue_redraw()

func _update_source_buttons() -> void:
	var id := _selected_id()
	var entry := _find(id)
	var has_selection := not entry.is_empty()
	if not has_selection or id != _editing_id:
		_editing_id = 0
	map.set_bbox_edit(_editing_id if _writable and not _fetch_button.disabled else 0)
	var ready := has_selection and FileAccess.file_exists(_data_path(entry))
	var tooltip := ""
	if not ready:
		tooltip = "Select an area with status Downloaded or Imported."
	_preview_button.disabled = not ready
	_send_button.disabled = not ready
	_preview_button.tooltip_text = tooltip
	_send_button.tooltip_text = tooltip

func _use_current(action: Signal) -> void:
	var id := _selected_id()
	var entry := _find(id)
	if not entry.is_empty() and FileAccess.file_exists(_data_path(entry)):
		var destination := "Spatial" if action == import_requested else "preview"
		if action == preview_requested:
			map_requested.emit()
		_log("Area %d: sending downloaded GeoJSON to %s." % [id, destination])
		action.emit(_data_path(entry))
	else:
		_status.text = "Select a downloaded area."

func _log(message: String) -> void:
	print("[Map Explorer] ", message)

func _configured_proxy() -> String:
	return _proxy_input.text.strip_edges() if _proxy_enabled.button_pressed else ""

func _fetch_checked() -> void:
	if _fetch_button.disabled or not _writable:
		return
	var proxy_url := _configured_proxy()
	if _proxy_enabled.button_pressed and proxy_url.is_empty():
		_status.text = "Enter an HTTP proxy address or disable the proxy."
		_log(_status.text)
		return
	var endpoint := Overpass.normalize_endpoint(_endpoint_input.text)
	if endpoint.is_empty() or (not proxy_url.is_empty() and not endpoint.begins_with("https://")):
		_status.text = "Enter a valid Overpass URL. HTTPS is required when using a proxy."
		_log(_status.text)
		return
	_endpoint = endpoint
	_fetch_layers = _selected_layers()
	if _fetch_layers.is_empty():
		_status.text = "Select at least one layer to fetch."
		_log(_status.text)
		return
	for entry in queue.entries:
		var id := int(entry["id"])
		if entry["checked"] and (not FileAccess.file_exists(_data_path(entry))
				or entry.get("layers", Overpass.DEFAULT_LAYERS) != _fetch_layers):
			_pending.append(id)
	if _pending.is_empty():
		_status.text = "Check an area that needs the selected layers."
		_log("No checked areas need downloading.")
		return
	_fetch_total = _pending.size()
	_log("Starting fetch batch: %d area(s), layers: %s." % [
		_fetch_total, ", ".join(PackedStringArray(_fetch_layers))])
	_fetch_button.disabled = true
	_layers_menu.disabled = true
	_update_source_buttons()
	_proxy_enabled.disabled = true
	_proxy_input.editable = false
	_endpoint_input.editable = false
	_cancel_fetch_button.show()
	_fetch_next()

func _fetch_next() -> void:
	while not _pending.is_empty():
		var id: int = _pending.pop_front()
		var entry := _find(id)
		var box: Dictionary = entry["bbox"]
		if Overpass.area_km2(box) > 25.0:
			_record_error(id, "Exceeds the 25 km² request limit. Draw a smaller area.")
			continue
		var body := "data=" + Overpass.query(box, _fetch_layers).uri_encode()
		var proxy_url := _configured_proxy()
		var route := "Overpass" if proxy_url.is_empty() else "Overpass via proxy"
		_request_started_ms = Time.get_ticks_msec()
		_log("Area %d: sending request to %s (%d/%d)." % [
			id, route, _fetch_total - _pending.size(), _fetch_total])
		var error: Error
		if proxy_url.is_empty():
			error = _http.request(_endpoint, PackedStringArray([
				"Content-Type: application/x-www-form-urlencoded", "User-Agent: GodotSpatialToolkit/0.7.0"]),
				HTTPClient.METHOD_POST, body)
		else:
			error = _proxy.start(proxy_url, _endpoint, body, int(_http.timeout))
		if error == OK:
			_current_id = id
			_status.text = "Fetching Area %d from %s (%d/%d, up to %d seconds)…" % [
				id, route, _fetch_total - _pending.size(), _fetch_total, int(_http.timeout)]
			_refresh()
			return
		_record_error(id, "Could not start Overpass request (%s)." % error_string(error))
		break
	_finish_fetch()
	_refresh()

func _finish_fetch() -> void:
	_pending.clear()
	_fetch_button.disabled = false
	_layers_menu.disabled = false
	_proxy_enabled.disabled = false
	_proxy_input.editable = true
	_endpoint_input.editable = true
	_cancel_fetch_button.hide()
	_update_source_buttons()

func _cancel_fetch() -> void:
	_retry_timer.stop()
	_current_id = 0
	_http.cancel_request()
	_proxy.cancel()
	_finish_fetch()
	_status.text = "Fetch cancelled. Downloaded files are still available."
	_log(_status.text)
	_refresh()

func _on_response(result: int, code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	var id := _current_id
	if id == 0:
		return
	_current_id = 0
	var elapsed := (Time.get_ticks_msec() - _request_started_ms) / 1000.0
	_log("Area %d: HTTP %d, transport result %d, %d bytes, %.2f s." % [
		id, code, result, body.size(), elapsed])
	if result == HTTPRequest.RESULT_SUCCESS and code == 200:
		var data := Overpass.convert(body, _find(id)["bbox"], _endpoint, _fetch_layers)
		if data.has("error"):
			_record_error(id, str(data["error"]), "Overpass returned invalid or incomplete data.")
		elif data["features"].is_empty():
			_record_error(id, "No usable features in the selected layers (%d skipped)." % data["source"]["skipped"])
		else:
			_save_download(id, data)
	else:
		var message := "Overpass failed (HTTP %d, result %d). Retry later." % [code, result]
		if result == HTTPRequest.RESULT_TIMEOUT or code == 504:
			message = "Overpass did not respond in time. Retry this area later."
		elif code == 502 or code == 503:
			message = "Overpass endpoint returned HTTP %d. Retry later or change the endpoint." % code
		elif code == 429:
			message = "Overpass rate limit reached. Retry this area later."
		elif code == 407:
			message = "Proxy authentication failed (HTTP 407). Check the login and password."
		elif not _configured_proxy().is_empty():
			if result == HTTPRequest.RESULT_REQUEST_FAILED:
				message = "Invalid proxy URL. Use http://login:pass@server:port."
			elif result == HTTPRequest.RESULT_CANT_CONNECT:
				message = "Could not connect to Overpass through the proxy."
			elif result == HTTPRequest.RESULT_TLS_HANDSHAKE_ERROR:
				message = "TLS verification failed through the proxy."
		_record_error(id, message)
		_pending.clear()
	if _pending.is_empty():
		_finish_fetch()
	else:
		_retry_timer.start(1.0)
	_refresh()

func _save_download(id: int, data: Dictionary) -> void:
	var entry := _find(id)
	var before := entry.duplicate()
	var revision := int(entry.get("revision", 0))
	var replacing := FileAccess.file_exists(_data_path(entry))
	if replacing:
		while FileAccess.file_exists(Queue.data_path(id, revision)):
			revision += 1
	var path := Queue.data_path(id, revision)
	var file := FileAccess.open(path + ".tmp", FileAccess.WRITE)
	if file == null:
		_record_error(id, "Could not write GeoJSON.")
		return
	file.store_string(JSON.stringify(data))
	var error := file.get_error()
	file.close()
	if error != OK or DirAccess.rename_absolute(path + ".tmp", path) != OK:
		_record_error(id, "Could not save GeoJSON.")
		return
	entry.erase("error")
	entry["layers"] = _fetch_layers.duplicate()
	if replacing:
		entry["revision"] = revision
		entry["scene"] = ""
	if not _save():
		entry.assign(before)
		DirAccess.remove_absolute(path)
		return
	_status.text = "Area %d: %d features downloaded (%d skipped)." % [
		id, data["features"].size(), data["source"]["skipped"]]
	_log(_status.text)

func _record_error(id: int, message: String, output_message := "") -> void:
	_log("Area %d: %s" % [id, message if output_message.is_empty() else output_message])
	_find(id)["error"] = message
	if _save():
		_status.text = "Area %d: %s" % [id, message]

func record_import(source: String, scene: String) -> void:
	var absolute := ProjectSettings.globalize_path(source)
	for entry in queue.entries:
		if ProjectSettings.globalize_path(_data_path(entry)) == absolute:
			var previous: String = entry["scene"]
			entry["scene"] = scene
			if not _save():
				entry["scene"] = previous
			else:
				_log("Area %d: scene saved at %s." % [entry["id"], scene])
			_refresh()
			return
