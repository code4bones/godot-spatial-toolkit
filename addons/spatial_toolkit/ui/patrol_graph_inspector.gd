@tool
extends EditorInspectorPlugin

const FlightGraphLocator := preload("res://addons/spatial_toolkit/ui/flight_graph_locator.gd")
const Graph := preload("res://addons/spatial_toolkit/runtime/patrol_graph.gd")
const Localization := preload("res://addons/spatial_toolkit/ui/editor_localization.gd")
const MANIFEST_PROPERTY := &"graph_manifest_path"

func _can_handle(object: Object) -> bool:
	return object is SpatialPatrolManager or object is SpatialFlyingPatrol

func _parse_property(object: Object, _type: Variant.Type, property: String, _hint: PropertyHint,
		_hint_text: String, usage: int, _wide: bool) -> bool:
	if property != MANIFEST_PROPERTY or (usage & PROPERTY_USAGE_READ_ONLY) != 0:
		return false
	add_property_editor(property, GraphPathProperty.new(object is SpatialPatrolManager))
	return true

class GraphPathProperty extends EditorProperty:
	var _path := LineEdit.new()
	var _browse := Button.new()
	var _clear := Button.new()
	var _status := Label.new()
	var _quick_load: Button
	var _dialog: EditorFileDialog

	func _init(can_quick_load: bool) -> void:
		var layout := VBoxContainer.new()
		add_child(layout)
		set_bottom_editor(layout)
		var row := HBoxContainer.new()
		layout.add_child(row)
		_path.editable = false
		_path.context_menu_enabled = true
		_path.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(_path)
		_browse.name = "BrowseFlightGraph"
		_browse.text = Localization.translate(&"Choose Flight Graph")
		_browse.pressed.connect(_open_dialog)
		row.add_child(_browse)
		add_focusable(_browse)
		_clear.text = "×"
		_clear.tooltip_text = Localization.translate(&"Clear Flight Graph")
		_clear.pressed.connect(_set_path.bind(""))
		row.add_child(_clear)
		add_focusable(_clear)
		if can_quick_load:
			_quick_load = Button.new()
			_quick_load.name = "QuickLoadFlightGraph"
			_quick_load.text = Localization.translate(&"Quick Load Flight Graph")
			_quick_load.tooltip_text = Localization.translate(&"Use the published flight graph for this baked map.")
			_quick_load.pressed.connect(_load_for_map)
			layout.add_child(_quick_load)
			add_focusable(_quick_load)
		_status.name = "QuickLoadFlightGraphStatus"
		_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		_status.hide()
		layout.add_child(_status)

	func _update_property() -> void:
		var path := str(get_edited_object().get(get_edited_property()))
		_path.text = path
		_path.tooltip_text = path
		_clear.disabled = path.is_empty() or is_read_only()

	func _set_read_only(read_only: bool) -> void:
		_browse.disabled = read_only
		_clear.disabled = read_only or _path.text.is_empty()
		if _quick_load != null:
			_quick_load.disabled = read_only

	func _open_dialog() -> void:
		if _dialog == null:
			_dialog = EditorFileDialog.new()
			_dialog.name = "FlightGraphFileDialog"
			_dialog.file_mode = EditorFileDialog.FILE_MODE_OPEN_FILE
			_dialog.access = EditorFileDialog.ACCESS_RESOURCES
			_dialog.title = Localization.translate(&"Choose Flight Graph")
			_dialog.add_filter("*.flight_graph.json", Localization.translate(&"Flight graph manifest"))
			_dialog.add_filter("manifest.json", Localization.translate(&"Legacy flight graph manifest"))
			_dialog.file_selected.connect(_select_file)
			add_child(_dialog)
		if not _path.text.is_empty() and FileAccess.file_exists(_path.text):
			_dialog.current_path = _path.text
		else:
			var scene := EditorInterface.get_edited_scene_root()
			if scene != null and not scene.scene_file_path.is_empty():
				_dialog.current_dir = scene.scene_file_path.get_base_dir()
		_dialog.popup_centered_ratio(0.65)

	func _select_file(path: String) -> void:
		if not Graph.read_manifest(path)["error"].is_empty():
			_show_error(Localization.translate(&"Select a valid flight graph manifest."))
			return
		_set_path(path)

	func _load_for_map() -> void:
		var manager := get_edited_object() as SpatialPatrolManager
		if manager == null:
			return
		var manifest := FlightGraphLocator.find_for_map(manager.get_node_or_null(manager.map_root_path))
		if manifest.is_empty():
			_show_error(Localization.translate(&"No flight graph for this map. Use Spatial → Build Flight Graph."))
			return
		_set_path(manifest)

	func _set_path(path: String) -> void:
		_status.hide()
		if is_read_only() or path == _path.text:
			return
		emit_changed(get_edited_property(), path)
		_update_property()

	func _show_error(message: String) -> void:
		_status.text = message
		_status.show()
