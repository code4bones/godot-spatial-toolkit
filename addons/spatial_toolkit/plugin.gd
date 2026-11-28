@tool
extends EditorPlugin

const Dock := preload("res://addons/spatial_toolkit/ui/map_import_dock.gd")
const ChunkWorldService := preload("res://addons/spatial_toolkit/core/chunk_world_service.gd")
const BakeService := preload("res://addons/spatial_toolkit/core/scene_bake_service.gd")
const FlightGraphService := preload("res://addons/spatial_toolkit/core/flight_graph_service.gd")
const WorldStyleService := preload("res://addons/spatial_toolkit/core/world_style_service.gd")
const MapExplorer := preload("res://addons/spatial_toolkit/map/map_explorer.gd")
const RegionPanel := preload("res://addons/spatial_toolkit/map/region_panel.gd")
const MaterialCatalog := preload("res://addons/spatial_toolkit/ui/material_catalog.gd")
const WorldChunksPanel := preload("res://addons/spatial_toolkit/ui/world_chunks_panel.gd")
const GeoJSONSource := preload("res://addons/spatial_toolkit/core/spatial_geojson_source.gd")
const Settings := preload("res://addons/spatial_toolkit/core/spatial_project_settings.gd")
const Network := preload("res://addons/spatial_toolkit/core/spatial_network_settings.gd")
const SpatialNetworkInspector := preload("res://addons/spatial_toolkit/ui/spatial_network_inspector.gd")
const SpatialPythonInspector := preload("res://addons/spatial_toolkit/ui/spatial_python_inspector.gd")
const PatrolGraphInspector := preload("res://addons/spatial_toolkit/ui/patrol_graph_inspector.gd")
const Localization := preload("res://addons/spatial_toolkit/ui/editor_localization.gd")
const PatrolZoneTool := preload("res://addons/spatial_toolkit/ui/patrol_zone_tool.gd")
const PatrolZoneGizmo := preload("res://addons/spatial_toolkit/ui/patrol_zone_gizmo.gd")
const DOWNLOAD_RESOURCES := "res://generated/geojson_sources"

var _map_explorer: MapExplorer
var _bake_service: Node
var _flight_graph_service: Node
var _style_service: WorldStyleService
var _dock: Dock
var _chunks_dock: EditorDock
var _world_service: Node
var _python_inspector: SpatialPythonInspector
var _network_inspector: SpatialNetworkInspector
var _patrol_graph_inspector: PatrolGraphInspector
var _patrol_zone_tool: PatrolZoneTool
var _patrol_zone_gizmo: PatrolZoneGizmo

func _enter_tree() -> void:
	Localization.install(EditorInterface.get_editor_language())
	var editor_settings := get_editor_interface().get_editor_settings()
	Settings.register(editor_settings)
	Network.register(editor_settings)
	_patrol_zone_tool = PatrolZoneTool.new()
	_patrol_zone_tool.setup(self)
	_patrol_zone_gizmo = PatrolZoneGizmo.new()
	_patrol_zone_gizmo.undo = get_undo_redo()
	add_node_3d_gizmo_plugin(_patrol_zone_gizmo)
	set_input_event_forwarding_always_enabled()
	set_force_draw_over_forwarding_enabled()
	_network_inspector = SpatialNetworkInspector.new()
	add_inspector_plugin(_network_inspector)
	_python_inspector = SpatialPythonInspector.new()
	add_inspector_plugin(_python_inspector)
	_patrol_graph_inspector = PatrolGraphInspector.new()
	add_inspector_plugin(_patrol_graph_inspector)
	_world_service = ChunkWorldService.new()
	_world_service.name = "ChunkWorldService"
	add_child(_world_service)
	_bake_service = BakeService.new()
	_bake_service.name = "SceneBakeService"
	add_child(_bake_service)
	_flight_graph_service = FlightGraphService.new()
	_flight_graph_service.name = "FlightGraphService"
	add_child(_flight_graph_service)
	_style_service = WorldStyleService.new()
	_style_service.name = "WorldStyleService"
	add_child(_style_service)
	var tabs := _add_chunks_dock()
	_dock = Dock.new()
	_dock.set_translation_domain(Localization.DOMAIN)
	_dock.setup(_world_service, get_editor_interface(), _bake_service, tabs,
		_flight_graph_service, get_undo_redo(), _style_service)
	add_control_to_dock(DOCK_SLOT_RIGHT_UL, _dock)
	scene_changed.connect(_dock.refresh_scene)
	scene_saved.connect(_dock.on_chunk_saved)
	_map_explorer = MapExplorer.new()
	_map_explorer.name = "MapExplorer"
	_map_explorer.hide()
	get_editor_interface().get_editor_main_screen().add_child(_map_explorer)
	_map_explorer.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_map_explorer.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_map_explorer.region_import_requested.connect(_prepare_region_import)
	_map_explorer.preset_scene_requested.connect(_open_preset_scene)
	_dock.map_explorer_requested.connect(_show_map_explorer)
	var areas := RegionPanel.new()
	areas.name = "MapAreas"
	areas.set_translation_domain(Localization.DOMAIN)
	areas.map = _map_explorer.map_view()
	areas.map_requested.connect(_show_map_explorer)
	areas.import_requested.connect(_prepare_region_import)
	areas.download_saved.connect(_register_download)
	tabs.add_child(areas)
	tabs.set_tab_title(tabs.get_tab_idx_from_control(areas), Localization.translate("Map Areas"))
	for path in areas.downloaded_sources():
		_register_download(path)
	var catalog := MaterialCatalog.new()
	catalog.name = "AssetBrowser"
	catalog.setup(get_editor_interface())
	tabs.add_child(catalog)
	tabs.set_tab_title(tabs.get_tab_idx_from_control(catalog), Localization.translate("Textures"))

func _add_chunks_dock() -> WorldChunksPanel:
	_chunks_dock = EditorDock.new()
	_chunks_dock.name = "SpatialBottomDock"
	_chunks_dock.title = "Spatial Toolkit"
	_chunks_dock.layout_key = "spatial_toolkit_bottom"
	_chunks_dock.default_slot = EditorDock.DOCK_SLOT_BOTTOM
	_chunks_dock.available_layouts = EditorDock.DOCK_LAYOUT_HORIZONTAL
	var panel := WorldChunksPanel.new()
	panel.set_translation_domain(Localization.DOMAIN)
	_chunks_dock.add_child(panel)
	add_dock(_chunks_dock)
	return panel

func _register_download(geojson_path: String) -> void:
	var title := geojson_path.get_file().get_basename().capitalize()
	var path := DOWNLOAD_RESOURCES.path_join(title + ".tres")
	if not FileAccess.file_exists(path):
		var error := DirAccess.make_dir_recursive_absolute(DOWNLOAD_RESOURCES)
		if error == OK:
			var source := GeoJSONSource.new()
			source.geojson_path = geojson_path
			source.resource_name = title
			error = ResourceSaver.save(source, path)
		if error != OK:
			push_warning("Spatial could not add %s to Quick Load: %s" % [title, error_string(error)])
			return
	var filesystem := get_editor_interface().get_resource_filesystem()
	while filesystem.is_scanning():
		await get_tree().process_frame
		if not is_inside_tree():
			return
	# The first full scan may have recorded the directory tree before the plugin ran.
	if filesystem.get_filesystem_path(DOWNLOAD_RESOURCES) == null:
		filesystem.scan()
	elif filesystem.get_file_type(path).is_empty():
		filesystem.update_file(path)

func _show_map_explorer() -> void:
	get_editor_interface().set_main_screen_editor("Map Explorer")

func _open_preset_scene(path: String) -> void:
	_map_explorer.open_preset_scene(path)

func _prepare_region_import(paths: PackedStringArray) -> void:
	if not _dock.prepare_sources(paths):
		return
	var container := _dock.get_parent()
	if container.has_method("make_visible"):
		container.call("make_visible")
	elif container is TabContainer:
		container.current_tab = container.get_tab_idx_from_control(_dock)

func _has_main_screen() -> bool:
	return true

func _forward_3d_gui_input(camera: Camera3D, event: InputEvent) -> int:
	return _patrol_zone_tool.forward_input(camera, event)

func _forward_3d_force_draw_over_viewport(overlay: Control) -> void:
	_patrol_zone_tool.draw(overlay)

func _get_plugin_name() -> String:
	return "Map Explorer"

func _make_visible(visible: bool) -> void:
	if is_instance_valid(_map_explorer):
		_map_explorer.visible = visible

func _exit_tree() -> void:
	if _patrol_zone_tool != null:
		_patrol_zone_tool.shutdown()
		_patrol_zone_tool = null
	if _patrol_zone_gizmo != null:
		remove_node_3d_gizmo_plugin(_patrol_zone_gizmo)
		_patrol_zone_gizmo = null
	if _network_inspector != null:
		remove_inspector_plugin(_network_inspector)
		_network_inspector = null
	if _python_inspector != null:
		remove_inspector_plugin(_python_inspector)
		_python_inspector.clear_check()
		_python_inspector = null
	if _patrol_graph_inspector != null:
		remove_inspector_plugin(_patrol_graph_inspector)
		_patrol_graph_inspector = null
	if is_instance_valid(_bake_service):
		_bake_service.shutdown()
		_bake_service.queue_free()
	if is_instance_valid(_flight_graph_service):
		_flight_graph_service.shutdown()
		_flight_graph_service.queue_free()
	if is_instance_valid(_style_service):
		_style_service.shutdown()
		_style_service.queue_free()
	if is_instance_valid(_world_service):
		_world_service.shutdown()
		_world_service.queue_free()
	if is_instance_valid(_dock):
		remove_control_from_docks(_dock)
		_dock.queue_free()
	if is_instance_valid(_chunks_dock):
		remove_dock(_chunks_dock)
		_chunks_dock.queue_free()
	if is_instance_valid(_map_explorer):
		_map_explorer.hide()
		_map_explorer.queue_free()
	Network.register(null)
	Localization.uninstall()
