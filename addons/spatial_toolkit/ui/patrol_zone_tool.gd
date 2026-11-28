@tool
extends RefCounted
## Editor-only toolbar and drag interaction for patrol zone nodes.

const Edit := preload("patrol_zone_edit.gd")
const Localization := preload("editor_localization.gd")
const FlightGraphLocator := preload("flight_graph_locator.gd")
const Graph := preload("res://addons/spatial_toolkit/runtime/patrol_graph.gd")
var plugin: EditorPlugin
var toolbar: HBoxContainer
var draw_button: Button
var status: Label
var _manager: Node3D
var _dragging := false
var _start := Vector3.ZERO
var _end := Vector3.ZERO
var _camera: Camera3D
var _manifest: Dictionary = {}
var _manifest_path := ""
var _manifest_manager_id := 0
var _manifest_error := ""
var _hover_camera: Camera3D
var _hover_cell := Rect2()
var _hover_id := ""
var _hover_published := false
var _hover_point := Vector3.ZERO

func setup(editor_plugin: EditorPlugin) -> void:
	plugin = editor_plugin
	toolbar = HBoxContainer.new()
	toolbar.set_translation_domain(Localization.DOMAIN)
	var create := Button.new()
	create.text = Localization.translate("Add Patrol Manager")
	create.pressed.connect(_create_manager)
	toolbar.add_child(create)
	draw_button = Button.new()
	draw_button.text = Localization.translate("Draw Patrol Zone")
	draw_button.toggle_mode = true
	draw_button.toggled.connect(_toggle)
	toolbar.add_child(draw_button)
	status = Label.new()
	toolbar.add_child(status)
	plugin.add_control_to_container(EditorPlugin.CONTAINER_SPATIAL_EDITOR_MENU, toolbar)
	EditorInterface.get_selection().selection_changed.connect(_selection_changed)
	plugin.scene_changed.connect(_scene_changed)
	plugin.main_screen_changed.connect(_main_screen_changed)
	_selection_changed()

func shutdown() -> void:
	EditorInterface.get_selection().selection_changed.disconnect(_selection_changed)
	plugin.scene_changed.disconnect(_scene_changed)
	plugin.main_screen_changed.disconnect(_main_screen_changed)
	plugin.remove_control_from_container(EditorPlugin.CONTAINER_SPATIAL_EDITOR_MENU, toolbar)
	toolbar.queue_free()

func _scene_changed(_root: Node) -> void:
	_cancel()
	_manager = null
	_selection_changed()

func _main_screen_changed(screen_name: String) -> void:
	if screen_name != "3D":
		_cancel()

func _selection_changed() -> void:
	_cancel()
	_manifest.clear()
	_manifest_manager_id = 0
	_manager = null
	for selected: Node in EditorInterface.get_selection().get_selected_nodes():
		if Edit.is_manager(selected):
			_manager = selected as Node3D
			break
		if Edit.is_zone(selected) and Edit.is_manager(selected.get_parent()):
			_manager = selected.get_parent() as Node3D
			break
	draw_button.disabled = not is_instance_valid(_manager)
	if draw_button.disabled:
		draw_button.set_pressed_no_signal(false)
	status.text = ""

func _toggle(enabled: bool) -> void:
	_cancel()
	_manifest_manager_id = 0
	if enabled:
		_ensure_manifest()
	status.text = Localization.translate("Top Orthogonal · Drag LMB · Esc cancels") if enabled else ""

func _cancel() -> void:
	_dragging = false
	_camera = null
	_hover_camera = null
	_hover_id = ""
	plugin.update_overlays()

func _ensure_manifest() -> void:
	var path := str(_manager.get("graph_manifest_path"))
	if _manifest_manager_id == _manager.get_instance_id() and path == _manifest_path:
		return
	_manifest_manager_id = _manager.get_instance_id()
	_manifest_path = path
	_manifest.clear()
	_manifest_error = ""
	var opened := Graph.read_manifest(path)
	if not opened["error"].is_empty():
		_manifest_error = Localization.translate("Set a valid navigation manifest on PatrolManager")
		return
	var snapshot: Graph.Snapshot = opened["snapshot"]
	var origin: Variant = Graph._point(snapshot.manifest.get("origin"))
	var step: Variant = snapshot.manifest.get("chunk_size_m")
	if origin == null or not Graph._number(step) or step <= 0.0:
		_manifest_error = Localization.translate("Navigation manifest has an invalid grid")
		return
	_manifest = snapshot.manifest

func _update_hover(camera: Camera3D, screen: Vector2) -> void:
	_ensure_manifest()
	_hover_camera = null
	_hover_id = ""
	var map_root := _manager.get_node_or_null(_manager.get("map_root_path")) as Node3D
	var hit: Variant = Edit.plane_point(camera, screen, _manager)
	if _manifest.is_empty() or map_root == null or not hit is Vector3:
		status.text = _manifest_error
		plugin.update_overlays()
		return
	var point := map_root.to_local(_manager.to_global(hit))
	var origin: Array = _manifest["origin"]
	var step := float(_manifest["chunk_size_m"])
	var cell_x := floori((point.x - float(origin[0])) / step)
	var cell_z := floori((point.z - float(origin[2])) / step)
	_hover_id = "%d_%d" % [cell_x, cell_z]
	_hover_published = _manifest["chunks"].has(_hover_id)
	_hover_cell = Rect2(float(origin[0]) + cell_x * step, float(origin[2]) + cell_z * step, step, step)
	_hover_point = point
	_hover_camera = camera
	status.text = _cell_label()
	plugin.update_overlays()

func _cell_label() -> String:
	var label := Localization.translate("Nav. chunk %s · %.1f × %.1f m") % [_hover_id, _hover_cell.size.x, _hover_cell.size.y]
	return label if _hover_published else label + " · " + Localization.translate("unpublished")

func forward_input(camera: Camera3D, event: InputEvent) -> int:
	if not draw_button.button_pressed or not is_instance_valid(_manager):
		return EditorPlugin.AFTER_GUI_INPUT_PASS
	if event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		_cancel()
		draw_button.button_pressed = false
		return EditorPlugin.AFTER_GUI_INPUT_STOP
	if not Edit.top_view(camera, _manager):
		status.text = Localization.translate("Use Top Orthogonal to draw patrol zones")
		_cancel()
		return EditorPlugin.AFTER_GUI_INPUT_PASS
	if event is InputEventMouseMotion:
		_update_hover(camera, event.position)
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if _dragging and camera != _camera:
			_cancel()
			return EditorPlugin.AFTER_GUI_INPUT_STOP
		var hit: Variant = Edit.plane_point(camera, event.position, _manager)
		if not hit is Vector3:
			return EditorPlugin.AFTER_GUI_INPUT_PASS
		if event.pressed:
			_start = hit
			_end = hit
			_camera = camera
			_dragging = true
		elif _dragging:
			_end = hit
			var extent := Vector2(absf(_end.x - _start.x), absf(_end.z - _start.z))
			if extent.x >= 1.0 and extent.y >= 1.0:
				_commit_zone(extent)
			_cancel()
		plugin.update_overlays()
		return EditorPlugin.AFTER_GUI_INPUT_STOP
	if _dragging and event is InputEventMouseMotion:
		if camera != _camera:
			_cancel()
			return EditorPlugin.AFTER_GUI_INPUT_PASS
		var hit: Variant = Edit.plane_point(camera, event.position, _manager)
		if hit is Vector3:
			_end = hit
			plugin.update_overlays()
		return EditorPlugin.AFTER_GUI_INPUT_STOP
	return EditorPlugin.AFTER_GUI_INPUT_PASS

func draw(overlay: Control) -> void:
	var active_camera := _camera if _dragging else _hover_camera
	if not is_instance_valid(active_camera) or not _overlay_matches(overlay, active_camera):
		return
	if not _hover_id.is_empty() and is_instance_valid(_hover_camera) and is_instance_valid(_manager):
		_draw_hover(overlay)
	if not _dragging or not is_instance_valid(_camera) or not is_instance_valid(_manager):
		return
	var min_x := minf(_start.x, _end.x)
	var max_x := maxf(_start.x, _end.x)
	var min_z := minf(_start.z, _end.z)
	var max_z := maxf(_start.z, _end.z)
	var corners := PackedVector2Array()
	for point in [Vector3(min_x, 0, min_z), Vector3(max_x, 0, min_z),
			Vector3(max_x, 0, max_z), Vector3(min_x, 0, max_z)]:
		corners.append(_camera.unproject_position(_manager.to_global(point)))
	overlay.draw_colored_polygon(corners, Color(1.0, 0.25, 0.65, 0.10))
	corners.append(corners[0])
	overlay.draw_polyline(corners, Color(1.0, 0.25, 0.65), 2.0, true)
	var text := "%.1f × %.1f m" % [max_x - min_x, max_z - min_z]
	var location := _camera.unproject_position(_manager.to_global(_end)) + Vector2(12, -12)
	var font := overlay.get_theme_default_font()
	overlay.draw_string_outline(font, location, text, HORIZONTAL_ALIGNMENT_LEFT, -1, 16, 4, Color.BLACK)
	overlay.draw_string(font, location, text, HORIZONTAL_ALIGNMENT_LEFT, -1, 16, Color.WHITE)

func _overlay_matches(overlay: Control, camera: Camera3D) -> bool:
	var ancestor: Node = camera.get_viewport()
	while ancestor != null:
		if ancestor.is_class("Node3DEditorViewport"):
			return ancestor.is_ancestor_of(overlay) and (ancestor as Control).is_visible_in_tree()
		ancestor = ancestor.get_parent()
	return true

func _draw_hover(overlay: Control) -> void:
	var map_root := _manager.get_node_or_null(_manager.get("map_root_path")) as Node3D
	if map_root == null:
		return
	var color := Color(0.25, 1.0, 0.55) if _hover_published else Color(1.0, 0.65, 0.2)
	var points := PackedVector2Array()
	for corner in [_hover_cell.position, Vector2(_hover_cell.end.x, _hover_cell.position.y),
			_hover_cell.end, Vector2(_hover_cell.position.x, _hover_cell.end.y)]:
		points.append(_hover_camera.unproject_position(map_root.to_global(Vector3(corner.x, 0, corner.y))))
	points.append(points[0])
	overlay.draw_polyline(points, color, 2.0, true)
	if not _dragging:
		var location := _hover_camera.unproject_position(map_root.to_global(_hover_point)) + Vector2(12, -12)
		var font := overlay.get_theme_default_font()
		overlay.draw_string_outline(font, location, _cell_label(), HORIZONTAL_ALIGNMENT_LEFT, -1, 16, 4, Color.BLACK)
		overlay.draw_string(font, location, _cell_label(), HORIZONTAL_ALIGNMENT_LEFT, -1, 16, color)

func _commit_zone(extent: Vector2) -> void:
	var zone := Node3D.new()
	zone.set_script(load(Edit.ZONE_SCRIPT))
	zone.name = "PatrolZone"
	zone.position = Vector3((_start.x + _end.x) * 0.5, 0, (_start.z + _end.z) * 0.5)
	zone.set("size_xz", extent)
	var used := {}
	for child: Node in _manager.get_children():
		if Edit.is_zone(child):
			used[int(child.get("camera_slot"))] = true
	for slot in range(1, 10):
		if not used.has(slot):
			zone.set("camera_slot", slot)
			break
	var root := EditorInterface.get_edited_scene_root()
	var undo := plugin.get_undo_redo()
	undo.create_action(Localization.translate("Add patrol zone"), UndoRedo.MERGE_DISABLE, root)
	undo.add_do_method(_manager, "add_child", zone, true)
	undo.add_do_method(zone, "set_owner", root)
	undo.add_do_reference(zone)
	undo.add_undo_method(_manager, "remove_child", zone)
	undo.commit_action()
	status.text = Localization.translate("Patrol zone added")

func _create_manager() -> void:
	var root := EditorInterface.get_edited_scene_root()
	if not root is Node3D:
		return
	var existing := _find_manager(root)
	if existing != null:
		EditorInterface.get_selection().clear()
		EditorInterface.get_selection().add_node(existing)
		EditorInterface.edit_node(existing)
		return
	if not root.has_meta("bake_manifest_path"):
		status.text = Localization.translate("Open a baked map scene first")
		return
	var manager := Node3D.new()
	manager.set_script(load(Edit.MANAGER_SCRIPT))
	manager.name = "PatrolManager"
	manager.set("defaults", load("res://addons/spatial_toolkit/runtime/patrol_profile.gd").new())
	manager.set("graph_manifest_path", FlightGraphLocator.find_for_map(root))
	var undo := plugin.get_undo_redo()
	undo.create_action(Localization.translate("Add Patrol Manager"), UndoRedo.MERGE_DISABLE, root)
	undo.add_do_method(root, "add_child", manager, true)
	undo.add_do_method(manager, "set_owner", root)
	undo.add_do_reference(manager)
	undo.add_undo_method(root, "remove_child", manager)
	undo.commit_action()
	EditorInterface.get_selection().clear()
	EditorInterface.get_selection().add_node(manager)
	EditorInterface.edit_node(manager)

func _find_manager(root: Node) -> Node3D:
	if Edit.is_manager(root):
		return root as Node3D
	for child: Node in root.get_children():
		var found := _find_manager(child)
		if found != null:
			return found
	return null
