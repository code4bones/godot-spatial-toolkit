@tool
extends TabContainer
## Presents the selected world's editable squares, their preview and feature summaries.

signal open_requested(id: String)

const ChunkInfo := preload("res://addons/spatial_toolkit/core/world_chunk_info.gd")
const ChunkPreview := preload("res://addons/spatial_toolkit/ui/world_chunk_preview.gd")

var _entries: Dictionary[String, Dictionary] = {}
var _ids := PackedStringArray()
var _selected_id := ""
var _preview_path := ""
var _status_text := ""
var _busy := false
var _reveal_pending := false
var _ui_scale := 1.0

var _filter: LineEdit
var _list: ItemList
var _empty: Label
var _preview: ChunkPreview
var _preview_title: Label
var _details_scroll: ScrollContainer
var _details: Label
var _status: Label

func _ready() -> void:
	name = "WorldChunksPanel"
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	if Engine.is_editor_hint():
		_ui_scale = EditorInterface.get_editor_scale()
	custom_minimum_size.y = 210.0 * _ui_scale
	var split := HSplitContainer.new()
	split.name = "Chunks"
	add_child(split)
	move_child(split, 0)
	var tab := get_tab_idx_from_control(split)
	set_tab_title(tab, atr("Chunks"))
	current_tab = tab
	_build_navigation(split)
	_build_content(split)
	_sync_items()
	_reveal_selected()

func set_chunks(entries: Array[Dictionary], preferred_id: String = "") -> void:
	var next: Dictionary[String, Dictionary] = {}
	for entry: Dictionary in entries:
		var id := str(entry.get("id", ""))
		if not id.is_empty():
			next[id] = {"info": entry.get("info", {}), "path": str(entry.get("path", ""))}
	var candidate := _selected_id if preferred_id.is_empty() else preferred_id
	if not next.has(candidate):
		candidate = "" if next.is_empty() else next.keys()[0]
	var changed := candidate != _selected_id
	if changed:
		_status_text = ""
	_entries = next
	_selected_id = candidate
	if is_instance_valid(_list):
		_sync_items(changed)

func select_chunk(id: String) -> void:
	if id == _selected_id or not _entries.has(id):
		return
	_selected_id = id
	_status_text = ""
	if is_instance_valid(_list):
		if _ids.has(id):
			_sync_selection(true)
			_reveal_selected()
		else:
			_filter.text = ""
			_sync_items(true)

func selected_chunk_id() -> String:
	return _selected_id

func update_chunk_info(id: String, info: Dictionary) -> void:
	if not _entries.has(id):
		return
	_entries[id]["info"] = info
	if is_instance_valid(_filter) and not _filter.text.strip_edges().is_empty():
		_sync_items()
		return
	var index := _ids.find(id)
	if index >= 0:
		_update_item(index, id)
		if id == _selected_id:
			_sync_selection()

func set_busy(value: bool) -> void:
	if _busy == value:
		return
	_busy = value
	if is_instance_valid(_list):
		_filter.editable = not value
		for index in _list.item_count:
			_list.set_item_disabled(index, value)
		_sync_selection()
		if not value:
			_reveal_when_visible()

func set_status(message: String) -> void:
	_status_text = message
	if is_instance_valid(_status):
		_status.text = message
		_status.tooltip_text = message
		_status.visible = not message.is_empty()

func _build_navigation(split: HSplitContainer) -> void:
	var navigation := VBoxContainer.new()
	navigation.name = "ChunkNavigation"
	navigation.custom_minimum_size.x = 148.0 * _ui_scale
	navigation.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	navigation.size_flags_stretch_ratio = 3.0
	split.add_child(navigation)
	_filter = LineEdit.new()
	_filter.name = "ChunkFilter"
	_filter.placeholder_text = atr("Filter chunks")
	_filter.clear_button_enabled = true
	_filter.editable = not _busy
	_filter.text_changed.connect(func(_text: String) -> void: _sync_items())
	navigation.add_child(_filter)
	_list = ItemList.new()
	_list.name = "ChunkList"
	_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_list.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_list.item_selected.connect(_select_item)
	_list.item_activated.connect(_activate_item)
	_list.visibility_changed.connect(_reveal_when_visible)
	navigation.add_child(_list)
	_empty = Label.new()
	_empty.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	navigation.add_child(_empty)

func _build_content(split: HSplitContainer) -> void:
	var content := HBoxContainer.new()
	content.name = "ChunkContent"
	content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	content.size_flags_stretch_ratio = 7.0
	split.add_child(content)
	_preview = ChunkPreview.new()
	_preview.name = "ChunkPreview"
	_preview.custom_minimum_size.x = 172.0 * _ui_scale
	_preview.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_preview.size_flags_vertical = Control.SIZE_EXPAND_FILL
	content.add_child(_preview)
	_preview_title = Label.new()
	_preview_title.name = "ChunkPreviewTitle"
	_preview_title.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_preview_title.auto_translate_mode = Node.AUTO_TRANSLATE_MODE_DISABLED
	_preview_title.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_preview_title.add_theme_color_override("font_outline_color", Color(0.0, 0.0, 0.0, 0.85))
	_preview_title.add_theme_constant_override("outline_size", roundi(3.0 * _ui_scale))
	_preview.add_child(_preview_title)
	_preview_title.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
	_preview_title.offset_left = 8.0 * _ui_scale
	_preview_title.offset_right = -8.0 * _ui_scale
	_preview_title.offset_top = 6.0 * _ui_scale
	var info := VBoxContainer.new()
	info.name = "ChunkInfo"
	info.custom_minimum_size.x = 184.0 * _ui_scale
	info.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	content.add_child(info)
	_details_scroll = ScrollContainer.new()
	_details_scroll.name = "ChunkInfoScroll"
	_details_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_details_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	info.add_child(_details_scroll)
	_details = Label.new()
	_details.name = "ChunkDetails"
	_details.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_details.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_details_scroll.add_child(_details)
	_status = Label.new()
	_status.name = "ChunkStatus"
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status.max_lines_visible = 2
	_status.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	info.add_child(_status)

func _sync_items(reset_details_scroll := false) -> void:
	var ids := PackedStringArray()
	var query := _filter.text.strip_edges()
	for id: String in _entries:
		if query.is_empty() or _matches_filter(id, query):
			ids.append(id)
	if not ids.has(_selected_id):
		_selected_id = "" if ids.is_empty() else ids[0]
		_status_text = ""
		reset_details_scroll = true
	if ids != _ids:
		_list.clear()
		_ids = ids
		for id: String in _ids:
			var index := _list.add_item("")
			_list.set_item_metadata(index, id)
			_list.set_item_auto_translate_mode(index, Node.AUTO_TRANSLATE_MODE_DISABLED)
			_list.set_item_disabled(index, _busy)
	for index in _ids.size():
		_update_item(index, _ids[index])
	_list.visible = not _ids.is_empty()
	_empty.visible = _ids.is_empty()
	if _empty.visible:
		_empty.text = atr("Select or create a world in Spatial.") if _entries.is_empty() \
			else atr("No chunks match the filter.")
	_sync_selection(reset_details_scroll)
	if reset_details_scroll:
		_reveal_selected()

func _matches_filter(id: String, query: String) -> bool:
	if id.containsn(query):
		return true
	var info: Dictionary = _entries[id]["info"]
	var names: Variant = info.get("names", {})
	if not names is Dictionary:
		return false
	for labels: Variant in names.values():
		if labels is Array or labels is PackedStringArray:
			for label: Variant in labels:
				if label is String and label.containsn(query):
					return true
	return false

func _update_item(index: int, id: String) -> void:
	var feature_name := ChunkInfo.title(_entries[id]["info"])
	var label := id if feature_name.is_empty() else "%s · %s" % [id, feature_name]
	_list.set_item_text(index, label)
	_list.set_item_tooltip(index, label)

func _sync_selection(reset_details_scroll := false) -> void:
	var index := _ids.find(_selected_id)
	if index >= 0 and not _busy:
		_list.select(index)
	var entry: Dictionary = _entries.get(_selected_id, {})
	var info: Dictionary = entry.get("info", {})
	var feature_name := ChunkInfo.title(info)
	_preview_title.text = _selected_id if feature_name.is_empty() else feature_name
	_preview_title.visible = index >= 0
	_details.text = ChunkInfo.describe(info) if not info.is_empty() else atr("Details will appear after opening the square.")
	_details_scroll.visible = index >= 0
	if reset_details_scroll:
		_details_scroll.scroll_vertical = 0
	var path := str(entry.get("path", ""))
	if path != _preview_path:
		_preview_path = path
		_preview.set_scene_path(path)
	set_status(_status_text)

func _select_item(index: int) -> void:
	if not _busy:
		select_chunk(_ids[index])

func _activate_item(index: int) -> void:
	if not _busy:
		var id := _ids[index]
		select_chunk(id)
		open_requested.emit(id)

func _reveal_selected() -> void:
	_reveal_pending = not _selected_id.is_empty()
	_reveal_when_visible()

func _reveal_when_visible() -> void:
	if not _reveal_pending or _busy or not _list.is_visible_in_tree():
		return
	var id := _selected_id
	_reveal_pending = false
	await get_tree().process_frame
	if id == _selected_id:
		if _list.is_visible_in_tree() and not _busy:
			_list.ensure_current_is_visible()
		else:
			_reveal_pending = true
