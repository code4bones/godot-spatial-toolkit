@tool
extends EditorPlugin

const Dock := preload("res://addons/spatial_toolkit/ui/map_import_dock.gd")
const ImportService := preload("res://addons/spatial_toolkit/core/map_import_service.gd")
const BakeService := preload("res://addons/spatial_toolkit/core/scene_bake_service.gd")
const StyleService := preload("res://addons/spatial_toolkit/core/world_style_service.gd")
const MapExplorer := preload("res://addons/spatial_toolkit/map/map_explorer.gd")
const FacadeDock := preload("res://addons/spatial_toolkit/ui/facade_material_dock.gd")

var _map_explorer: MapExplorer
var _style_service: Node
var _bake_service: Node
var _dock: Dock
var _facade_dock: FacadeDock
var _service: Node

func _enter_tree() -> void:
	_service = ImportService.new()
	_service.name = "MapImportService"
	add_child(_service)
	_bake_service = BakeService.new()
	_bake_service.name = "SceneBakeService"
	add_child(_bake_service)
	_style_service = StyleService.new()
	_style_service.name = "WorldStyleService"
	add_child(_style_service)
	_dock = Dock.new()
	_dock.setup(_service, get_editor_interface(), _bake_service, _style_service, get_undo_redo())
	add_control_to_dock(DOCK_SLOT_RIGHT_UL, _dock)
	scene_changed.connect(_dock.refresh_scene)
	_map_explorer = MapExplorer.new()
	_map_explorer.hide()
	get_editor_interface().get_editor_main_screen().add_child(_map_explorer)
	_map_explorer.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_map_explorer.size_flags_vertical = Control.SIZE_EXPAND_FILL
	var areas := _map_explorer.region_panel
	areas.get_parent().remove_child(areas)
	areas.name = "Map Areas"
	add_control_to_dock(DOCK_SLOT_RIGHT_UL, areas)
	areas.map_requested.connect(func() -> void:
		get_editor_interface().set_main_screen_editor("Map Explorer"))
	_map_explorer.region_import_requested.connect(_prepare_region_import)
	_dock.source_imported.connect(_map_explorer.region_panel.record_import)
	_facade_dock = FacadeDock.new()
	_facade_dock.setup(get_editor_interface(), get_undo_redo())
	add_control_to_dock(DOCK_SLOT_RIGHT_UL, _facade_dock)
	scene_changed.connect(_facade_dock.refresh_scene)

func _prepare_region_import(path: String) -> void:
	if _dock.prepare_source(path):
		get_editor_interface().set_main_screen_editor("3D")

func _has_main_screen() -> bool:
	return true

func _get_plugin_name() -> String:
	return "Map Explorer"

func _make_visible(visible: bool) -> void:
	if is_instance_valid(_map_explorer):
		_map_explorer.visible = visible

func _exit_tree() -> void:
	if is_instance_valid(_facade_dock):
		remove_control_from_docks(_facade_dock)
		_facade_dock.queue_free()
	if is_instance_valid(_map_explorer):
		var areas := _map_explorer.region_panel
		if is_instance_valid(areas):
			remove_control_from_docks(areas)
			areas.queue_free()
		_map_explorer.queue_free()
	if is_instance_valid(_style_service):
		_style_service.shutdown()
		_style_service.queue_free()
	if is_instance_valid(_bake_service):
		_bake_service.shutdown()
		_bake_service.queue_free()
	if is_instance_valid(_service):
		_service.shutdown()
		_service.queue_free()
	if is_instance_valid(_dock):
		remove_control_from_docks(_dock)
		_dock.queue_free()
