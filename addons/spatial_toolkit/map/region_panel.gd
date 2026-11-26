@tool
extends VBoxContainer

signal import_requested(paths: PackedStringArray)
signal download_saved(path: String)
signal map_requested

const Queue := preload("bbox_queue.gd")
const Overpass := preload("overpass_provider.gd")
const Request := preload("res://addons/spatial_toolkit/core/spatial_http_request.gd")
const Network := preload("res://addons/spatial_toolkit/core/spatial_network_settings.gd")
const LocalPbfJob := preload("local_pbf_job.gd")
const MapProjection := preload("map_projection.gd")
const Settings := preload("res://addons/spatial_toolkit/core/spatial_project_settings.gd")
const CHECK_BUTTON := 0
const DELETE_BUTTON := 1
const LEGACY_COUNT_BATCH_SIZE := 4
enum Column { CHECK, AREA, STATUS, WIDTH, HEIGHT, BUILDINGS, ROADS, WATER, LANDUSE, PARKS, REMOVE }
enum Source { API, FILE }
const LAYER_COLUMNS := {
	"buildings": Column.BUILDINGS,
	"roads": Column.ROADS,
	"water": Column.WATER,
	"landuse": Column.LANDUSE,
	"parks": Column.PARKS,
}

var queue := Queue.new()
var map: Control
var _list: Tree
var _draw_button: Button
var _draw_mode := false
var _editing_id := 0
var _status: Label
var _fetch_button: Button
var _layers_menu: MenuButton
var _fetch_layers: Array = []
var _cancel_fetch_button: Button
var _send_button: Button
var _retry_timer: Timer
var _http: Request
var _endpoint_input: LineEdit
var _fetch_proxy: Variant = null
var _source_select: OptionButton
var _api_controls: VBoxContainer
var _file_controls: HBoxContainer
var _pbf_field: LineEdit
var _pbf_browse: Button
var _pbf_dialog: FileDialog
var _pbf_path := ""
var _pbf_header: Dictionary = {}
var _pbf_job: LocalPbfJob
var _fetch_source_key := ""
var _pending: Array[int] = []
var _current_id := 0
var _fetch_total := 0
var _request_started_ms := 0
var _writable := true
var _endpoint := Overpass.ENDPOINT
var _legacy_counts := {}
var _legacy_count_rows := {}
var _legacy_count_job: Thread

func _ready() -> void:
	set_process(false)
	size_flags_horizontal = SIZE_EXPAND_FILL
	size_flags_vertical = SIZE_EXPAND_FILL
	var split := HSplitContainer.new()
	split.name = "MapAreasSplit"
	split.size_flags_vertical = SIZE_EXPAND_FILL
	add_child(split)
	_build_area_list(split)
	_build_source_controls(split)
	_status = Label.new()
	_status.max_lines_visible = 1
	_status.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_status.mouse_filter = Control.MOUSE_FILTER_STOP
	_status.mouse_entered.connect(func() -> void: _status.tooltip_text = _status.text)
	add_child(_status)
	_http = Request.new()
	_http.timeout = 45
	_http.body_size_limit = 16 * 1024 * 1024
	_http.request_completed.connect(_on_response)
	add_child(_http)
	_pbf_job = LocalPbfJob.new()
	_pbf_job.completed.connect(_on_pbf_completed)
	add_child(_pbf_job)
	_retry_timer = Timer.new()
	_retry_timer.one_shot = true
	_retry_timer.timeout.connect(_fetch_next)
	add_child(_retry_timer)
	var error := queue.load_queue()
	if error != OK:
		_writable = false
		_status.text = atr("Could not load saved areas (%s).") % error_string(error)
	map.bbox_added.connect(_add_bbox)
	map.bbox_edited.connect(_edit_bbox)
	map.bbox_shortcut_changed.connect(_sync_draw_button)
	_restore_source()
	_refresh()

func _build_source_controls(parent: Control) -> void:
	var toolbar := VBoxContainer.new()
	toolbar.name = "SourceControls"
	toolbar.custom_minimum_size.x = 212.0 * (EditorInterface.get_editor_scale() if Engine.is_editor_hint() else 1.0)
	parent.add_child(toolbar)
	var top := HBoxContainer.new()
	toolbar.add_child(top)
	_source_select = OptionButton.new()
	_source_select.name = "SourceSelector"
	_source_select.size_flags_horizontal = SIZE_EXPAND_FILL
	_source_select.add_item(atr("Overpass API"), Source.API)
	_source_select.add_item(atr("Local PBF file"), Source.FILE)
	_source_select.item_selected.connect(_select_source)
	top.add_child(_source_select)
	_draw_button = _button("", _toggle_draw, top)
	_draw_button.name = "DrawBBox"
	_draw_button.icon = _draw_bbox_icon()
	_draw_button.toggle_mode = true
	_draw_button.accessibility_name = atr("Draw BBox")
	_api_controls = VBoxContainer.new()
	_api_controls.name = "OverpassControls"
	toolbar.add_child(_api_controls)
	var endpoint_label := Label.new()
	endpoint_label.text = atr("Overpass endpoint")
	_api_controls.add_child(endpoint_label)
	_endpoint_input = LineEdit.new()
	_endpoint_input.size_flags_horizontal = SIZE_EXPAND_FILL
	_endpoint_input.placeholder_text = "https://overpass-api.de/api/"
	_endpoint_input.tooltip_text = atr("Overpass base URL or full /interpreter URL")
	_endpoint_input.text = Overpass.ENDPOINT
	_api_controls.add_child(_endpoint_input)
	if Engine.is_editor_hint():
		var settings := EditorInterface.get_editor_settings()
		_endpoint_input.text = str(settings.get_project_metadata(
			"spatial_toolkit", "overpass_endpoint", Overpass.ENDPOINT))
		_endpoint_input.text_changed.connect(func(value: String) -> void:
			settings.set_project_metadata("spatial_toolkit", "overpass_endpoint", value))
	_file_controls = HBoxContainer.new()
	_file_controls.name = "LocalPbfControls"
	toolbar.add_child(_file_controls)
	_pbf_field = LineEdit.new()
	_pbf_field.name = "PbfPath"
	_pbf_field.editable = false
	_pbf_field.size_flags_horizontal = SIZE_EXPAND_FILL
	_pbf_field.placeholder_text = atr("Choose an OSM PBF file")
	_file_controls.add_child(_pbf_field)
	_pbf_browse = _button(atr("Browse…"), _choose_pbf, _file_controls)
	_pbf_dialog = FileDialog.new()
	_pbf_dialog.title = atr("Choose an OSM PBF file")
	_pbf_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	_pbf_dialog.access = FileDialog.ACCESS_FILESYSTEM
	_pbf_dialog.filters = PackedStringArray(["*.pbf ; OSM PBF"])
	_pbf_dialog.file_selected.connect(_set_pbf_path)
	add_child(_pbf_dialog)
	var actions := HFlowContainer.new()
	toolbar.add_child(actions)
	_setup_layer_menu(actions)
	_fetch_button = _button(atr("Fetch"), _fetch_checked, actions)
	_fetch_button.name = "FetchCheckedAreas"
	_fetch_button.tooltip_text = atr("Fetch checked areas")
	_send_button = _button(atr("Send to Spatial"), _send_checked, actions)
	_send_button.name = "SendCheckedAreas"
	_cancel_fetch_button = _button(atr("Cancel fetch"), _cancel_fetch, actions)
	_cancel_fetch_button.name = "CancelFetch"
	_cancel_fetch_button.hide()

func _build_area_list(parent: Control) -> void:
	var ui_scale := EditorInterface.get_editor_scale() if Engine.is_editor_hint() else 1.0
	_list = Tree.new()
	_list.name = "AreaList"
	parent.add_child(_list)
	for key in ["h_separation", "item_margin", "inner_item_margin_left", "inner_item_margin_right", "button_margin"]:
		_list.add_theme_constant_override(key, roundi(2.0 * ui_scale))
	for state in ["title_button_normal", "title_button_hover", "title_button_pressed"]:
		var heading := _list.get_theme_stylebox(state).duplicate() as StyleBox
		heading.set_content_margin(SIDE_LEFT, 3.0 * ui_scale)
		heading.set_content_margin(SIDE_RIGHT, 3.0 * ui_scale)
		_list.add_theme_stylebox_override(state, heading)
	_list.columns = Column.size()
	_list.set_column_titles_visible(true)
	_list.set_column_title(Column.AREA, atr("Area"))
	_list.set_column_title(Column.STATUS, atr("Status"))
	_list.set_column_title(Column.WIDTH, atr("Width (m)"))
	_list.set_column_title(Column.HEIGHT, atr("Height (m)"))
	for layer: String in LAYER_COLUMNS:
		_list.set_column_title(LAYER_COLUMNS[layer], atr(Overpass.LAYERS[layer]["label"]))
	var checkbox_width := maxi(_check_icon(true).get_width(), _check_icon(false).get_width())
	var button_widths := {Column.CHECK: checkbox_width, Column.REMOVE: get_theme_icon("close", "Window").get_width()}
	var button_padding := _list.get_theme_stylebox("button_pressed").get_minimum_size().x \
		+ _list.get_theme_constant("button_margin") + _list.get_theme_constant("h_separation")
	for column: int in button_widths:
		_list.set_column_custom_minimum_width(column, ceili(int(button_widths[column]) + button_padding))
		_list.set_column_clip_content(column, true)
		_list.set_column_expand(column, false)
	# Tree includes header text in each minimum, even when row contents are clipped.
	var column_width := roundi(56.0 * ui_scale)
	for column in range(Column.AREA, Column.REMOVE):
		_list.set_column_title_alignment(column, HORIZONTAL_ALIGNMENT_CENTER)
		_list.set_column_clip_content(column, true)
		_list.set_column_expand(column, false)
		column_width = maxi(column_width, _list.get_column_width(column))
	for column in range(Column.AREA, Column.REMOVE):
		_list.set_column_custom_minimum_width(column, column_width)
		_list.set_column_expand(column, true)
		_list.set_column_expand_ratio(column, 1)
	_list.hide_root = true
	_list.hide_folding = true
	_list.select_mode = Tree.SELECT_ROW
	_list.size_flags_vertical = SIZE_EXPAND_FILL
	_list.size_flags_horizontal = SIZE_EXPAND_FILL
	_list.item_activated.connect(_edit_selected)
	_list.item_selected.connect(_update_source_buttons)
	_list.button_clicked.connect(_on_row_button)

func _restore_source() -> void:
	var source_id := Source.API
	if Engine.is_editor_hint():
		var settings := EditorInterface.get_editor_settings()
		if int(settings.get_project_metadata("spatial_toolkit", "osm_source", Source.API)) == Source.FILE:
			source_id = Source.FILE
		_pbf_path = str(settings.get_project_metadata("spatial_toolkit", "osm_pbf_path", ""))
	_update_pbf_field()
	_select_source(source_id)

func _select_source(source_id: int) -> void:
	if _fetch_button.disabled or not source_id in [Source.API, Source.FILE]:
		return
	if _writable:
		_status.text = ""
	_source_select.select(source_id)
	var local := source_id == Source.FILE
	_api_controls.visible = not local
	_file_controls.visible = local
	if Engine.is_editor_hint():
		EditorInterface.get_editor_settings().set_project_metadata("spatial_toolkit", "osm_source", source_id)
	if local:
		_read_pbf_bounds()
	else:
		map.set_tile_coverage({}, false)

func _choose_pbf() -> void:
	var samples := ProjectSettings.globalize_path("res://samples")
	if not _pbf_path.is_empty():
		_pbf_dialog.current_path = _pbf_path
	elif DirAccess.dir_exists_absolute(samples):
		_pbf_dialog.current_dir = samples
	_pbf_dialog.popup_centered_ratio(0.7)

func _set_pbf_path(path: String) -> void:
	if _fetch_button.disabled:
		return
	if _writable:
		_status.text = ""
	_pbf_path = ProjectSettings.globalize_path(path) if not path.is_empty() else ""
	_update_pbf_field()
	if Engine.is_editor_hint():
		EditorInterface.get_editor_settings().set_project_metadata("spatial_toolkit", "osm_pbf_path", _pbf_path)
	if _source_select.get_selected_id() == Source.FILE:
		_read_pbf_bounds()

func _update_pbf_field() -> void:
	_pbf_field.text = _pbf_path.get_file()
	_pbf_field.tooltip_text = _pbf_path

func _read_pbf_bounds(apply_coverage := true) -> void:
	var previous: Dictionary = _pbf_header.get("bbox", {})
	_pbf_header = {}
	if not _pbf_path.is_empty():
		var result := LocalPbfJob.read_header(_pbf_path)
		if result.has("error"):
			_status.text = atr("Could not read the PBF coverage. %s") % atr(str(result["error"]))
		else:
			_pbf_header = result
	var coverage: Dictionary = _pbf_header.get("bbox", {})
	if apply_coverage or coverage != previous:
		map.set_tile_coverage(coverage, true)

func _setup_layer_menu(toolbar: Control) -> void:
	_layers_menu = MenuButton.new()
	_layers_menu.name = "FetchLayers"
	_layers_menu.icon = get_theme_icon("option", "OptionButton")
	if Engine.is_editor_hint():
		var theme := EditorInterface.get_editor_theme()
		if theme.has_icon("AnimationFilter", "EditorIcons"):
			_layers_menu.icon = theme.get_icon("AnimationFilter", "EditorIcons")
	toolbar.add_child(_layers_menu)
	var popup := _layers_menu.get_popup()
	popup.hide_on_checkable_item_selection = false
	var keys := Overpass.LAYERS.keys()
	for index in keys.size():
		var key: String = keys[index]
		popup.add_check_item(atr(Overpass.LAYERS[key]["label"]), index)
	popup.id_pressed.connect(_toggle_overpass_layer)
	_layers_menu.about_to_popup.connect(_update_layer_menu)
	ProjectSettings.settings_changed.connect(_update_layer_menu)
	_update_layer_menu()

func _toggle_overpass_layer(index: int) -> void:
	var layer: String = Overpass.LAYERS.keys()[index]
	var error := Settings.set_overpass_layer(layer, layer not in _selected_layers())
	if error != OK:
		_status.text = atr("Could not save Overpass layers (%s).") % error_string(error)
	_update_layer_menu()

func _selected_layers() -> Array[String]:
	return Settings.overpass_layers()

func _update_layer_menu() -> void:
	var selected := _selected_layers()
	var popup := _layers_menu.get_popup()
	var keys := Overpass.LAYERS.keys()
	for index in keys.size():
		popup.set_item_checked(index, keys[index] in selected)
	var caption := atr("Fetch layers (%d/%d)") % [selected.size(), Overpass.LAYERS.size()]
	var labels := PackedStringArray()
	for key: String in selected:
		labels.append(atr(Overpass.LAYERS[key]["label"]))
	_layers_menu.accessibility_name = caption
	_layers_menu.tooltip_text = "%s\n%s" % [caption,
		", ".join(labels) if not labels.is_empty() else atr("Select layers for Fetch")]

func _button(caption: String, callback: Callable, parent: Control) -> Button:
	var button := Button.new()
	button.text = caption
	button.pressed.connect(callback)
	parent.add_child(button)
	return button

func _add_bbox(bbox: Dictionary) -> void:
	if not _writable or _fetch_button.disabled or bbox["north"] <= bbox["south"] or bbox["east"] == bbox["west"]:
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
	var id := int(item.get_metadata(Column.CHECK))
	if column == Column.CHECK and button_id == CHECK_BUTTON:
		var entry := _find(id)
		var previous: bool = entry["checked"]
		entry["checked"] = not previous
		if not _save():
			entry["checked"] = previous
		item.set_button(column, 0, _check_icon(entry["checked"]))
		_refresh_map_regions()
		_update_source_buttons()
	elif column == Column.REMOVE and button_id == DELETE_BUTTON:
		_delete_area.call_deferred(id)

func _toggle_draw() -> void:
	_draw_mode = _draw_button.button_pressed
	if _draw_mode and _writable and not _fetch_button.disabled:
		_editing_id = 0
		map_requested.emit()
	_update_source_buttons()

func _edit_selected() -> void:
	var id := _selected_id()
	if id == 0 or not _writable or _fetch_button.disabled:
		return
	_editing_id = id
	_draw_mode = false
	var map_was_visible := map.is_visible_in_tree()
	map_requested.emit()
	if map_was_visible:
		map.fit_bbox(_find(id)["bbox"])
	else:
		_fit_editing_area_after_layout(id)
	_update_source_buttons()

func _fit_editing_area_after_layout(id: int) -> void:
	await get_tree().process_frame
	if id == _editing_id and not _fetch_button.disabled and map.is_visible_in_tree():
		map.fit_bbox(_find(id)["bbox"])

func _delete_area(id: int) -> void:
	var entry := _find(id)
	if entry.is_empty() or not _writable or _fetch_button.disabled:
		return
	var index := queue.entries.find(entry)
	queue.entries.remove_at(index)
	if not _save():
		queue.entries.insert(index, entry)
	else:
		_legacy_counts.erase(_data_path(entry))
		_status.text = atr("Area %d removed from the list.") % id
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
	entry.erase("layer_counts")
	if not _save():
		entry.assign(previous)
	else:
		_legacy_counts.erase(_data_path(previous))
		_status.text = atr("Area %d updated. Fetch its new bounds when ready.") % id
	_refresh()

func _data_path(entry: Dictionary) -> String:
	return Queue.data_path(int(entry["id"]), int(entry.get("revision", 0)))

func downloaded_sources() -> PackedStringArray:
	var paths := PackedStringArray()
	for entry in queue.entries:
		var path := _data_path(entry)
		if FileAccess.file_exists(path):
			paths.append(path)
	return paths

func _save() -> bool:
	var error := queue.save_queue() if _writable else ERR_FILE_CORRUPT
	if error != OK:
		_status.text = atr("Could not save areas (%s).") % error_string(error)
	return error == OK

func _selected_id() -> int:
	var item := _list.get_selected()
	return 0 if item == null else int(item.get_metadata(Column.CHECK))

func _refresh() -> void:
	var selected := _selected_id()
	_list.clear()
	_legacy_count_rows.clear()
	var root := _list.create_item()
	for entry in queue.entries:
		var id := int(entry["id"])
		var row := _list.create_item(root)
		row.set_metadata(Column.CHECK, id)
		row.add_button(Column.CHECK, _check_icon(entry["checked"]), CHECK_BUTTON, not _writable,
			atr("Toggle this area for Fetch and Send"))
		row.set_text(Column.AREA, atr("Area %d") % id)
		var box: Dictionary = entry["bbox"]
		var dimensions := MapProjection.bbox_size_m(box)
		row.set_text(Column.WIDTH, str(roundi(dimensions.x)))
		row.set_text(Column.HEIGHT, str(roundi(dimensions.y)))
		row.set_text_alignment(Column.WIDTH, HORIZONTAL_ALIGNMENT_CENTER)
		row.set_text_alignment(Column.HEIGHT, HORIZONTAL_ALIGNMENT_CENTER)
		var data_path := _data_path(entry)
		var downloaded := FileAccess.file_exists(data_path)
		_update_count_cells(row, _area_layer_counts(row, entry, data_path) if downloaded else {})
		var path: String = entry.get("scene", "")
		var state := atr("Planned")
		if _current_id == id or (_fetch_button.disabled and _source_select.get_selected_id() == Source.FILE and id in _pending):
			state = atr("Fetching…")
		elif not path.is_empty() and FileAccess.file_exists(path):
			state = atr("Imported")
		elif downloaded:
			state = atr("Downloaded")
		elif entry.has("error"):
			state = atr("Retry")
		row.set_text(Column.STATUS, state)
		row.set_text_overrun_behavior(Column.STATUS, TextServer.OVERRUN_TRIM_ELLIPSIS)
		row.add_button(Column.REMOVE, get_theme_icon("close", "Window"), DELETE_BUTTON,
			not _writable or _fetch_button.disabled, atr("Remove area from the list"))
		row.set_tooltip_text(Column.AREA, atr("S %.6f · W %.6f · N %.6f · E %.6f\nDouble-click to edit this area on the map.") % [
			box["south"], box["west"], box["north"], box["east"]])
		var detail := atr(str(entry["error"])) if entry.has("error") else path
		row.set_tooltip_text(Column.STATUS, "%s\n%s" % [state, detail] if not detail.is_empty() else state)
		if selected == id:
			row.select(Column.CHECK)
	_refresh_map_regions()
	_update_source_buttons()
	_start_legacy_count_batch()

func _area_layer_counts(row: TreeItem, entry: Dictionary, path: String) -> Dictionary:
	var saved: Variant = entry.get("layer_counts")
	if saved is Dictionary:
		return saved
	if _legacy_counts.has(path):
		return _legacy_counts[path]
	var layers: Variant = entry.get("layers", Overpass.DEFAULT_LAYERS)
	_legacy_count_rows[path] = {"row": row,
		"layers": layers.duplicate() if layers is Array else Overpass.DEFAULT_LAYERS.duplicate()}
	return {}

func _update_count_cells(row: TreeItem, counts: Dictionary) -> void:
	for layer: String in LAYER_COLUMNS:
		var column: int = LAYER_COLUMNS[layer]
		var count: Variant = counts.get(layer)
		var available: bool = (count is int or count is float) and is_finite(float(count)) \
			and count >= 0 and count == int(count)
		row.set_text(column, str(int(count)) if available else "—")
		row.set_text_alignment(column, HORIZONTAL_ALIGNMENT_CENTER)

func _start_legacy_count_batch() -> void:
	if _legacy_count_job != null or _legacy_count_rows.is_empty():
		return
	var paths := {}
	for path: String in _legacy_count_rows:
		paths[path] = _legacy_count_rows[path]["layers"]
		if paths.size() == LEGACY_COUNT_BATCH_SIZE:
			break
	var worker := Thread.new()
	if worker.start(_read_legacy_counts.bind(paths)) == OK:
		_legacy_count_job = worker
		set_process(true)

static func _read_legacy_counts(paths: Dictionary) -> Dictionary:
	var counts := {}
	for path: String in paths:
		var document := JSON.new()
		if document.parse(FileAccess.get_file_as_string(path)) == OK and document.data is Dictionary:
			counts[path] = Overpass.count_features_by_layer(document.data, paths[path])
		else:
			counts[path] = {}
	return counts

func _process(_delta: float) -> void:
	if _legacy_count_job.is_alive():
		return
	var counts: Dictionary = _legacy_count_job.wait_to_finish()
	_legacy_count_job = null
	set_process(false)
	for path: String in counts:
		if not _legacy_count_rows.has(path):
			continue
		var row: TreeItem = _legacy_count_rows[path]["row"]
		_legacy_count_rows.erase(path)
		_legacy_counts[path] = counts[path]
		_update_count_cells(row, counts[path])
	_start_legacy_count_batch()

func _exit_tree() -> void:
	set_process(false)
	if _legacy_count_job != null:
		_legacy_count_job.wait_to_finish()
		_legacy_count_job = null

func _refresh_map_regions() -> void:
	map.regions.clear()
	for entry in queue.entries:
		var region := entry.duplicate()
		region["imported"] = FileAccess.file_exists(str(entry.get("scene", "")))
		map.regions.append(region)
	map.queue_redraw()

func _update_source_buttons() -> void:
	var id := _selected_id()
	if id != _editing_id:
		_editing_id = 0
	var can_edit := _writable and not _fetch_button.disabled
	_draw_button.disabled = not can_edit
	map.set_bbox_edit(_editing_id if can_edit else 0)
	map.bbox_drawing_enabled = can_edit
	map.bbox_mode = can_edit and _draw_mode
	_sync_draw_button()
	_send_button.disabled = _checked_sources().is_empty()
	_send_button.tooltip_text = atr("Check one or more downloaded areas to send to Spatial.") if _send_button.disabled else ""

func _sync_draw_button() -> void:
	var pressed: bool = _draw_mode or map.is_bbox_shortcut_active()
	_draw_button.set_pressed_no_signal(pressed)
	var active := pressed and not _draw_button.disabled
	var label := atr("Draw BBox active") if active else atr("Draw BBox")
	var key := "⌘" if OS.has_feature("macos") else "Ctrl"
	_draw_button.tooltip_text = "%s\n%s" % [label, atr("Hold %s and drag with the left mouse button.") % key]
	_draw_button.modulate = Color(0.49, 0.81, 1.0) if active else Color.WHITE

func _checked_sources() -> PackedStringArray:
	var paths := PackedStringArray()
	for entry in queue.entries:
		if entry["checked"]:
			var path := _data_path(entry)
			if FileAccess.file_exists(path):
				paths.append(path)
	return paths

func _send_checked() -> void:
	var paths := _checked_sources()
	if not paths.is_empty():
		import_requested.emit(paths)

func _log(message: String) -> void:
	print("[Map Explorer] ", message)

func _fetch_checked() -> void:
	if _fetch_button.disabled or not _writable:
		return
	var local := _source_select.get_selected_id() == Source.FILE
	if local:
		if _pbf_path.is_empty():
			_status.text = atr("Choose an OSM PBF file.")
			return
		_read_pbf_bounds(false)
		if _pbf_header.is_empty():
			return
		_fetch_source_key = "pbf:%s:%s:%s" % [
			_pbf_path, str(_pbf_header.get("size", "")), str(_pbf_header.get("mtime_ns", ""))]
	elif not _configure_overpass():
		return
	_fetch_layers = _selected_layers()
	if _fetch_layers.is_empty():
		var message := "Select at least one layer to fetch."
		_status.text = atr(message)
		_log(message)
		return
	for entry in queue.entries:
		var saved_key := str(entry.get("source_key", "" if local else _fetch_source_key))
		if entry["checked"] and (not FileAccess.file_exists(_data_path(entry))
				or entry.get("layers", Overpass.DEFAULT_LAYERS) != _fetch_layers
				or saved_key != _fetch_source_key):
			_pending.append(int(entry["id"]))
	if _pending.is_empty():
		_status.text = atr("Check an area that needs the selected layers.")
		_log("No checked areas need downloading.")
		return
	_fetch_total = _pending.size()
	_log("Starting fetch batch: %d area(s), layers: %s." % [
		_fetch_total, ", ".join(PackedStringArray(_fetch_layers))])
	_fetch_button.disabled = true
	_layers_menu.disabled = true
	_source_select.disabled = true
	_pbf_browse.disabled = true
	_update_source_buttons()
	_endpoint_input.editable = false
	_cancel_fetch_button.show()
	if local:
		_start_pbf_fetch()
	else:
		_fetch_next()

func _configure_overpass() -> bool:
	_fetch_proxy = null
	var proxy: Variant = Network.proxy_for(Network.OVERPASS)
	if proxy is String and proxy.is_empty():
		var message := Network.SETTINGS_PATH
		_status.text = atr(message)
		_log(message)
		return false
	var endpoint := Overpass.normalize_endpoint(_endpoint_input.text)
	if endpoint.is_empty() or (proxy != null and not endpoint.begins_with("https://")):
		var message := "Enter a valid Overpass URL. HTTPS is required when using a proxy."
		_status.text = atr(message)
		_log(message)
		return false
	_endpoint = endpoint
	_fetch_proxy = proxy
	_fetch_source_key = "api"
	return true

func _start_pbf_fetch() -> void:
	var regions: Array[Dictionary] = []
	for id in _pending:
		regions.append({"id": id, "bbox": _find(id)["bbox"]})
	var error := _pbf_job.start({"path": _pbf_path, "regions": regions, "layers": _fetch_layers})
	if error != OK:
		_status.text = atr("Could not start local PBF extraction. %s") % error_string(error)
		_finish_fetch()
	else:
		_status.text = atr("Extracting %d area(s) from %s…") % [_fetch_total, _pbf_path.get_file()]
	_refresh()

func _on_pbf_completed(result: Dictionary, directory: String) -> void:
	if result.has("error"):
		_status.text = atr("Local PBF extraction failed. %s") % atr(str(result["error"]))
		_log(_status.text)
	else:
		var outputs := {}
		for output: Variant in result.get("regions", []):
			if output is Dictionary:
				outputs[int(output.get("id", 0))] = output
		for id in _pending:
			_apply_pbf_output(id, outputs.get(id, {}), directory)
	_finish_fetch()
	_refresh()

func _apply_pbf_output(id: int, output: Dictionary, directory: String) -> void:
	if output.has("error"):
		_record_error(id, str(output["error"]))
		return
	var filename := "area_%d.json" % id
	var path := directory.path_join(filename)
	if output.get("file") != filename or not FileAccess.file_exists(path):
		_record_error(id, "No output was produced for this area.")
		return
	var data: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if not data is Dictionary or not data.get("features") is Array or not data.get("source") is Dictionary:
		_record_error(id, "The PBF extractor returned invalid GeoJSON.")
	elif data["features"].is_empty():
		_record_error(id, "No usable features in the selected layers (%d skipped).", [data["source"]["skipped"]])
	else:
		_save_download(id, data)

func _fetch_next() -> void:
	while not _pending.is_empty():
		var id: int = _pending.pop_front()
		var entry := _find(id)
		var box: Dictionary = entry["bbox"]
		if Overpass.area_km2(box) > 25.0:
			_record_error(id, "Exceeds the 25 km² request limit. Draw a smaller area.")
			continue
		var body := "data=" + Overpass.query(box, _fetch_layers).uri_encode()
		var route := "Overpass" if _fetch_proxy == null else "Overpass via proxy"
		_request_started_ms = Time.get_ticks_msec()
		_log("Area %d: sending request to %s (%d/%d)." % [
			id, route, _fetch_total - _pending.size(), _fetch_total])
		var error := _http.request(_endpoint, PackedStringArray([
			"Content-Type: application/x-www-form-urlencoded", "User-Agent: GodotSpatialToolkit/0.7.0"]),
			HTTPClient.METHOD_POST, body, _fetch_proxy)
		if error == OK:
			_current_id = id
			_status.text = atr("Fetching Area %d from %s (%d/%d, up to %d seconds)…") % [
				id, atr(route), _fetch_total - _pending.size(), _fetch_total, int(_http.timeout)]
			_refresh()
			return
		_record_error(id, "Could not start Overpass request (%s).", [error_string(error)])
		break
	_finish_fetch()
	_refresh()

func _finish_fetch() -> void:
	_pending.clear()
	_fetch_proxy = null
	_fetch_button.disabled = false
	_layers_menu.disabled = false
	_source_select.disabled = false
	_pbf_browse.disabled = false
	_endpoint_input.editable = true
	_cancel_fetch_button.hide()
	_update_source_buttons()

func _cancel_fetch() -> void:
	_retry_timer.stop()
	_current_id = 0
	_http.cancel_request()
	_pbf_job.cancel()
	_finish_fetch()
	var message := "Fetch cancelled. Downloaded files are still available."
	_status.text = atr(message)
	_log(message)
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
			_record_error(id, str(data["error"]), [], "Overpass returned invalid or incomplete data.")
		elif data["features"].is_empty():
			_record_error(id, "No usable features in the selected layers (%d skipped).", [data["source"]["skipped"]])
		else:
			_save_download(id, data)
	else:
		var message: String
		var arguments := []
		var using_proxy := _fetch_proxy != null
		if result == HTTPRequest.RESULT_TIMEOUT or code == 504:
			message = "Overpass did not respond in time. Retry this area later."
		elif code == 502 or code == 503:
			message = "Overpass endpoint returned HTTP %d. Retry later or change the endpoint."
			arguments = [code]
		elif code == 429:
			message = "Overpass rate limit reached. Retry this area later."
		elif code == 407:
			message = "Proxy authentication failed (HTTP 407). Check the login and password."
		elif using_proxy and result == HTTPRequest.RESULT_REQUEST_FAILED:
			message = "Invalid proxy URL. Use http://login:pass@server:port."
		elif using_proxy and result == HTTPRequest.RESULT_CANT_CONNECT:
			message = "Could not connect to Overpass through the proxy."
		elif using_proxy and result == HTTPRequest.RESULT_TLS_HANDSHAKE_ERROR:
			message = "TLS verification failed through the proxy."
		else:
			message = "Overpass failed (HTTP %d, result %d). Retry later."
			arguments = [code, result]
		_record_error(id, message, arguments)
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
	entry["layer_counts"] = Overpass.count_features_by_layer(data, _fetch_layers)
	entry["source_key"] = _fetch_source_key
	if replacing:
		entry["revision"] = revision
		entry["scene"] = ""
	if not _save():
		entry.assign(before)
		DirAccess.remove_absolute(path)
		return
	_legacy_counts.erase(_data_path(before))
	var message := "Area %d: %d features extracted (%d skipped)." if _source_select.get_selected_id() == Source.FILE \
		else "Area %d: %d features downloaded (%d skipped)."
	var arguments := [id, data["features"].size(), data["source"]["skipped"]]
	_status.text = atr(message) % arguments
	_log(message % arguments)
	download_saved.emit(path)

func _record_error(id: int, message: String, arguments: Array = [], output_message := "") -> void:
	var english := message if arguments.is_empty() else message % arguments
	_log("Area %d: %s" % [id, english if output_message.is_empty() else output_message])
	# Queue errors are also read outside the editor and can contain provider details.
	_find(id)["error"] = english
	if _save():
		var translated := atr(message)
		if not arguments.is_empty():
			translated = translated % arguments
		_status.text = atr("Area %d: %s") % [id, translated]

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
