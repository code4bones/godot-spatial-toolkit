@tool
extends VBoxContainer
## Editor-only UI; deterministic import work lives in the independent service.

signal map_explorer_requested

const Settings := preload("res://addons/spatial_toolkit/core/spatial_project_settings.gd")
const ChunkInfo := preload("res://addons/spatial_toolkit/core/world_chunk_info.gd")
const AppearanceProfile := preload("res://addons/spatial_toolkit/core/map_appearance_profile.gd")
const GeoJSONSource := preload("res://addons/spatial_toolkit/core/spatial_geojson_source.gd")
const SourceSelection := preload("res://addons/spatial_toolkit/ui/map_source_selection.gd")
const WorldChunksPanel := preload("res://addons/spatial_toolkit/ui/world_chunks_panel.gd")
const NO_PROFILE_HINT := "Create maps with base colors and no appearance profile or finish textures."
const DEFAULT_WORLD_CHUNK_SIZE_M := 1000.0

var _world_service: Node
var _world_path: LineEdit
var _world_dialog: EditorFileDialog
var _world_manifest: Dictionary = {}
var _world_info: Label
var _world_chunk_label: Label
var _world_chunk_size: SpinBox
var _world_sync: Button
var _world_clear: Button
var _chunks_panel: WorldChunksPanel
var _world_chunk_paths: Dictionary[String, String] = {}
var _world_bake: Button
var _world_bake_drone: CheckBox
var _world_bake_drone_model: EditorResourcePicker
var _world_bake_window_detail: CheckBox
var _opened_chunk_info: Dictionary = {}
var _follow_open_world := true
var _bake_service: Node
var _bake_chunk_size: SpinBox
var _baking := false
var _editor: EditorInterface
var _content: VBoxContainer
var _source_selection := SourceSelection.new()
var _seed_opened_sources := true
var _source_add_opened: Button
var _output: LineEdit
var _cancel: Button
var _open: Button
var _status: Label
var _report: RichTextLabel
var _progress: ProgressBar
var _progress_row: HBoxContainer
var _elapsed: Label
var _operation_started_ms := 0
var _starting_import := false
var _output_dialog: EditorFileDialog
var _last_scene := ""
var _pending_open := ""
var _pending_open_status := ""
var _pending_world_view := ""
var _controls: Array[Control] = []
var _profile_path: LineEdit
var _profile_clear: Button
var _profile_open_dialog: EditorFileDialog
var _busy := false

func setup(world_service: Node, editor: EditorInterface, bake_service: Node,
		chunks_panel: WorldChunksPanel) -> void:
	_bake_service = bake_service
	_world_service = world_service
	_editor = editor
	_chunks_panel = chunks_panel
	_chunks_panel.open_requested.connect(_open_world_chunk)
	name = "Spatial"
	custom_minimum_size.x = 280
	var title := Label.new()
	title.text = atr("Spatial Toolkit · GeoJSON → map")
	add_child(title)
	_setup_operation_status()
	var scroll := ScrollContainer.new()
	scroll.name = "SpatialScroll"
	scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_SHOW_ALWAYS
	scroll.follow_focus = true
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	add_child(scroll)
	_content = VBoxContainer.new()
	_content.mouse_filter = Control.MOUSE_FILTER_PASS
	_content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(_content)
	_setup_source_controls()
	_setup_profile_controls()
	_output = _path_row(atr("Output folder"), "res://generated/maps", _choose_output)
	_output.name = "OutputPath"
	_output.text = "res://generated/maps"
	_setup_world_controls()
	_report = RichTextLabel.new()
	_report.name = "ImportReport"
	_report.custom_minimum_size.y = 160
	_report.selection_enabled = true
	_report.fit_content = true
	_report.scroll_active = false
	_report.bbcode_enabled = false
	_content.add_child(_report)
	_open = _button(atr("Open last scene"), _open_last)
	_controls.erase(_open)
	_open.disabled = true
	_output_dialog = EditorFileDialog.new()
	_output_dialog.file_mode = EditorFileDialog.FILE_MODE_OPEN_DIR
	_output_dialog.access = EditorFileDialog.ACCESS_RESOURCES
	_output_dialog.title = atr("Folder for new maps")
	_output_dialog.dir_selected.connect(func(path: String): _output.text = path)
	_editor.get_base_control().add_child(_output_dialog)
	if _bake_service != null:
		_bake_service.progress.connect(_on_progress)
		_bake_service.completed.connect(_on_bake_completed)
	_world_service.progress.connect(_on_progress)
	_world_service.completed.connect(_on_world_completed)
	refresh_scene(_editor.get_edited_scene_root())

func _setup_operation_status() -> void:
	_status = Label.new()
	_status.name = "Status"
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status.max_lines_visible = 3
	_status.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_set_status(atr("Select GeoJSON sources or send them from Map Areas."))
	add_child(_status)
	_progress_row = HBoxContainer.new()
	_progress_row.hide()
	add_child(_progress_row)
	_progress = ProgressBar.new()
	_progress.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_progress.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_progress.show_percentage = false
	_progress.max_value = 1.0
	_progress_row.add_child(_progress)
	_elapsed = Label.new()
	_elapsed.tooltip_text = atr("Elapsed time")
	_progress_row.add_child(_elapsed)
	_cancel = Button.new()
	_cancel.text = atr("Cancel")
	_cancel.disabled = true
	_cancel.pressed.connect(_cancel_operation)
	_progress_row.add_child(_cancel)

func _set_status(message: String) -> void:
	_status.text = message
	_status.tooltip_text = message

func _exit_tree() -> void:
	if is_instance_valid(_world_dialog):
		_world_dialog.queue_free()
	if is_instance_valid(_profile_open_dialog):
		_profile_open_dialog.queue_free()
	if is_instance_valid(_output_dialog):
		_output_dialog.queue_free()

func _note(text: String) -> Label:
	var label := Label.new()
	label.text = text
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_content.add_child(label)
	return label

func _button(text: String, action: Callable) -> Button:
	var button := Button.new()
	button.text = text
	button.pressed.connect(action)
	_content.add_child(button)
	_controls.append(button)
	return button

func _path_row(text: String, placeholder: String, browse: Callable) -> LineEdit:
	_note(text)
	var row := HBoxContainer.new()
	_content.add_child(row)
	var path := LineEdit.new()
	path.placeholder_text = placeholder
	path.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(path)
	_controls.append(path)
	var button := Button.new()
	button.text = "…"
	button.pressed.connect(browse)
	row.add_child(button)
	_controls.append(button)
	return path

func _number(value: float) -> SpinBox:
	var number := SpinBox.new()
	number.min_value = 0.1
	number.max_value = 100
	number.step = 0.1
	number.value = value
	_content.add_child(number)
	_controls.append(number)
	return number

func _choose_output() -> void:
	_output_dialog.popup_centered_ratio(0.6)

func _setup_source_controls() -> void:
	var header := HBoxContainer.new()
	_content.add_child(header)
	_source_add_opened = Button.new()
	_source_add_opened.name = "AddOpenedMapSources"
	_source_add_opened.text = atr("From open map")
	_source_add_opened.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_source_add_opened.tooltip_text = atr("Add the sources from the open map to the array.")
	_source_add_opened.pressed.connect(_add_opened_sources)
	header.add_child(_source_add_opened)
	var explorer := Button.new()
	explorer.name = "OpenMapExplorer"
	explorer.text = "[…]"
	explorer.tooltip_text = atr("Open Map Explorer")
	explorer.pressed.connect(map_explorer_requested.emit)
	header.add_child(explorer)
	var inspector := EditorInspector.new()
	inspector.name = "GeoJSONSourceInspector"
	inspector.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_content.add_child(inspector)
	inspector.resource_selected.connect(func(resource: Resource, _path: String) -> void:
		_editor.edit_resource(resource))
	inspector.edit(_source_selection)
	_source_selection.sources_changed.connect(_on_sources_changed)
	_note(atr("The first source sets the origin of the new world."))

func prepare_source(path: String) -> bool:
	return prepare_sources(PackedStringArray([path]))

func prepare_sources(paths: PackedStringArray) -> bool:
	if _reject_busy():
		return false
	if paths.is_empty():
		return false
	var sources := PackedStringArray()
	for path in paths:
		var source := _canonical_geojson(path)
		if source.is_empty():
			_set_status(atr("A GeoJSON file from Map Areas is unavailable."))
			return false
		sources.append(source)
	_seed_sources(_editor.get_edited_scene_root())
	_seed_opened_sources = false
	if _append_sources(sources):
		_set_status(atr("Source added to the array.") if paths.size() == 1 else atr("Sources added to the array."))
	else:
		_set_status(atr("This source is already in the array.") if paths.size() == 1 \
			else atr("These sources are already in the array."))
	return true

func refresh_scene(root: Node) -> void:
	var manifest_path := _scene_world_manifest(root)
	if _follow_open_world and _world_path.text.is_empty() and not manifest_path.is_empty():
		_select_world(manifest_path)
	if root != null and manifest_path == _world_path.text and "world_chunk_id" in root:
		var chunk_id := str(root.get("world_chunk_id"))
		if _world_chunk_paths.has(chunk_id) and _world_chunk_paths[chunk_id] == root.scene_file_path:
			_remember_chunk_info(root)
			_chunks_panel.update_chunk_info(chunk_id, _chunk_info(chunk_id))
		_chunks_panel.select_chunk(chunk_id)
	_seed_sources(root)
	_refresh_source_controls()

func _seed_sources(root: Node) -> void:
	if _seed_opened_sources and not _busy and _append_sources(_scene_sources(root)):
		_set_status(atr("Added sources from the open map."))

func _add_opened_sources() -> void:
	if _reject_busy():
		return
	var sources := _scene_sources(_editor.get_edited_scene_root())
	if sources.is_empty():
		_set_status(atr("The open map has no available GeoJSON source."))
		return
	_set_status(atr("Added sources from the open map.") if _append_sources(sources)
		else atr("All available sources from the open map are already in the array."))

func _append_sources(paths: PackedStringArray) -> bool:
	var sources := _source_selection.geojson_sources.duplicate()
	var existing := {}
	for source: GeoJSONSource in sources:
		if source != null:
			existing[_canonical_geojson(source.geojson_path)] = true
	for path in paths:
		if not existing.has(path):
			var source := GeoJSONSource.new()
			source.geojson_path = ProjectSettings.localize_path(path)
			sources.append(source)
			existing[path] = true
	if sources.size() == _source_selection.geojson_sources.size():
		return false
	_source_selection.geojson_sources = sources
	return true

func _on_sources_changed() -> void:
	_seed_opened_sources = false
	_refresh_source_controls()

func _refresh_source_controls() -> void:
	_source_add_opened.disabled = _busy or _scene_sources(_editor.get_edited_scene_root()).is_empty()
	_refresh_world_controls()

func _canonical_geojson(path: String) -> String:
	if path.strip_edges().is_empty():
		return ""
	var canonical := ProjectSettings.globalize_path(path.strip_edges()).simplify_path()
	return canonical if canonical.get_extension().to_lower() in ["geojson", "json"] and FileAccess.file_exists(canonical) else ""

func _scene_sources(root: Node) -> PackedStringArray:
	var paths := PackedStringArray()
	if root == null or root.has_meta("scene_bake"):
		return paths
	var manifest_path := _scene_world_manifest(root)
	if not manifest_path.is_empty():
		var manifest := _world_manifest
		if _world_path == null or _world_path.text != manifest_path:
			manifest = _read_world_manifest(manifest_path)
		return _manifest_sources(manifest)
	var generated := root.get_node_or_null("Generated")
	if generated == null:
		return paths
	var source: Variant = generated.get_meta("source", null)
	if not source is Dictionary:
		return paths
	var originals: Variant = source.get("merge_sources", [])
	if not originals is Array:
		originals = []
	for value: Variant in originals:
		var canonical := _canonical_geojson(str(value))
		if canonical.is_empty():
			paths.clear()
			break
		if not paths.has(canonical):
			paths.append(canonical)
	if paths.is_empty():
		var canonical := _canonical_geojson(str(source.get("path", "")))
		if (canonical.is_empty() or not originals.is_empty()) and not root.scene_file_path.is_empty():
			var snapshot := _canonical_geojson(root.scene_file_path.get_base_dir().path_join("source.geojson"))
			if not snapshot.is_empty():
				canonical = snapshot
		if not canonical.is_empty():
			paths.append(canonical)
	return paths

func _setup_world_controls() -> void:
	_content.add_child(HSeparator.new())
	_note(atr("World"))
	_world_path = _path_row(atr("Saved world"), atr("A new world will be created"), _choose_world)
	_world_path.name = "WorldManifestPath"
	_world_path.editable = false
	_world_clear = Button.new()
	_world_clear.name = "ClearWorld"
	_world_clear.text = "×"
	_world_clear.tooltip_text = atr("Clear the selected world and create a new one from the current GeoJSON sources.")
	_world_clear.pressed.connect(_clear_world)
	_world_path.get_parent().add_child(_world_clear)
	_world_info = _note("")
	_world_info.hide()
	_world_chunk_label = _note(atr("New world square size (source m)"))
	_world_chunk_size = _number(1.0)
	_world_chunk_size.name = "WorldChunkSize"
	_world_chunk_size.tooltip_text = atr("Sets the size of separately editable scenes. Adding an area uses the grid from world.json.")
	_world_chunk_size.min_value = 1.0
	_world_chunk_size.max_value = 50000.0
	_world_chunk_size.step = 1.0
	_world_chunk_size.value = DEFAULT_WORLD_CHUNK_SIZE_M
	_world_sync = _button(atr("Create world"), _run_world)
	_world_sync.name = "SyncChunkWorld"
	_setup_world_bake_controls()
	_content.add_child(HSeparator.new())
	_world_dialog = EditorFileDialog.new()
	_world_dialog.file_mode = EditorFileDialog.FILE_MODE_OPEN_FILE
	_world_dialog.access = EditorFileDialog.ACCESS_RESOURCES
	_world_dialog.filters = PackedStringArray(["world.json ; " + atr("Spatial world index")])
	_world_dialog.title = atr("Choose a saved world")
	_world_dialog.file_selected.connect(_pick_world)
	_editor.get_base_control().add_child(_world_dialog)
	var saved: Variant = _editor.get_editor_settings().get_project_metadata("spatial_toolkit", "world_manifest", false)
	if saved is String:
		_follow_open_world = not saved.is_empty()
		if _follow_open_world:
			_select_world(saved)
	_refresh_world_controls()

func _choose_world() -> void:
	if not _world_path.text.is_empty():
		_world_dialog.current_path = _world_path.text
	_world_dialog.popup_centered_ratio(0.7)

func _pick_world(path: String) -> void:
	if _reject_busy():
		return
	if _select_world(path):
		_set_status(atr("World selected. Add new GeoJSON sources and click “Update world”."))
	else:
		_set_status(atr("Could not read the world index."))

func _clear_world() -> void:
	if _reject_busy():
		return
	_follow_open_world = false
	_world_path.clear()
	_world_path.tooltip_text = ""
	_world_manifest.clear()
	_opened_chunk_info.clear()
	_refresh_world_chunks()
	_editor.get_editor_settings().set_project_metadata("spatial_toolkit", "world_manifest", "")
	_refresh_world_controls()
	_set_status(atr("A new world is ready to create from the current GeoJSON sources."))

func _scene_world_manifest(root: Node) -> String:
	if root != null and "world_manifest_path" in root:
		return str(root.get("world_manifest_path"))
	return ""

func _read_world_manifest(path: String) -> Dictionary:
	if not path.begins_with("res://") or path.get_file() != "world.json":
		return {}
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return {}
	var parser := JSON.new()
	if parser.parse(file.get_as_text()) != OK or not parser.data is Dictionary:
		return {}
	var data: Dictionary = parser.data
	if data.get("schema", 0) != 1 or not data.get("chunks") is Dictionary:
		return {}
	return data

func _manifest_sources(manifest: Dictionary) -> PackedStringArray:
	var paths := PackedStringArray()
	var sources: Variant = manifest.get("sources")
	if sources is Array:
		for path: Variant in sources:
			if path is String:
				var canonical := _canonical_geojson(path)
				if not canonical.is_empty() and not paths.has(canonical):
					paths.append(canonical)
	return paths

func _select_world(path: String, preferred_chunk := "") -> bool:
	path = ProjectSettings.localize_path(path).simplify_path()
	var manifest := _read_world_manifest(path)
	if manifest.is_empty():
		return false
	var switching_world := path != _world_path.text
	if preferred_chunk.is_empty() and not switching_world:
		preferred_chunk = _chunks_panel.selected_chunk_id()
	if switching_world:
		_opened_chunk_info.clear()
	_world_path.text = path
	_world_path.tooltip_text = path
	_world_manifest = manifest
	_refresh_world_chunks(preferred_chunk, switching_world)
	_editor.get_editor_settings().set_project_metadata("spatial_toolkit", "world_manifest", path)
	if _source_selection.geojson_sources.is_empty():
		_append_sources(_manifest_sources(manifest))
	_refresh_world_controls()
	return true

func _refresh_world_chunks(preferred_chunk := "", switching_world := false) -> void:
	_world_chunk_paths.clear()
	var chunks: Dictionary = _world_manifest.get("chunks", {})
	var ids := chunks.keys()
	ids.sort()
	var directory := _world_path.text.get_base_dir()
	var entries: Array[Dictionary] = []
	for id: String in ids:
		var relative: Variant = chunks[id]
		if not relative is String:
			continue
		var chunk_path := _world_scene_path(directory, relative)
		if chunk_path.is_empty():
			continue
		_world_chunk_paths[id] = chunk_path
		entries.append({"id": id, "path": chunk_path, "info": _chunk_info(id)})
	if switching_world and preferred_chunk.is_empty() and not entries.is_empty():
		preferred_chunk = entries[0]["id"]
	_chunks_panel.set_chunks(entries, preferred_chunk)
	_world_info.text = atr("World squares · %d · side %s m") % [
		entries.size(), str(_world_manifest.get("chunk_size_m", DEFAULT_WORLD_CHUNK_SIZE_M))]
	_world_info.visible = not _world_path.text.is_empty()

func _world_scene_path(directory: String, relative: String) -> String:
	if relative.is_empty() or relative.is_absolute_path():
		return ""
	var scene := directory.path_join(relative).simplify_path()
	var prefix := directory if directory.ends_with("/") else directory + "/"
	if not scene.begins_with(prefix) or not scene.get_extension().to_lower() in ["tscn", "scn"]:
		return ""
	return scene

func _remember_chunk_info(root: Node) -> void:
	var path := root.scene_file_path
	if not _opened_chunk_info.has(path):
		_opened_chunk_info[path] = root.call("get_world_chunk_info") if root.has_method("get_world_chunk_info") \
			else ChunkInfo.collect(root)

func _chunk_info(id: String) -> Dictionary:
	var path: String = _world_chunk_paths.get(id, "")
	var indexed: Variant = _world_manifest.get("chunk_info", {})
	var saved: Variant = indexed.get(id) if indexed is Dictionary else null
	var info: Variant = _opened_chunk_info.get(path, saved)
	return info if info is Dictionary else {}

func _refresh_world_controls() -> void:
	var has_world := not _world_path.text.is_empty()
	var no_chunks := _world_chunk_paths.is_empty()
	_world_path.editable = false
	_world_clear.disabled = _busy or not has_world
	_world_chunk_label.visible = not has_world
	_world_chunk_size.visible = not has_world
	_world_sync.text = atr("Update world") if has_world else atr("Create world")
	_world_sync.tooltip_text = atr("Processes new and changed GeoJSON sources and saves the affected squares.") if has_world \
		else atr("Merges the source files and saves a separate scene for each square.")
	_world_sync.disabled = _busy or _source_selection.geojson_sources.is_empty()
	_chunks_panel.set_busy(_busy)
	_world_bake.disabled = _busy or _bake_service == null or not has_world or no_chunks
	_world_bake.tooltip_text = atr("Assembles the saved squares of the selected world into a new gameplay scene.") if has_world \
		else atr("Select world.json in “Saved world”.")
	_world_bake_drone.disabled = _world_bake.disabled
	_refresh_drone_model_picker()
	if is_instance_valid(_world_bake_window_detail):
		_world_bake_window_detail.disabled = _world_bake.disabled

func _run_world() -> void:
	var manifest_path := _world_path.text
	var append := not manifest_path.is_empty()
	if not await _prepare_import(atr("Preparing world update…") if append else atr("Preparing world…")):
		return
	var sources := _selected_source_paths()
	if sources.is_empty():
		_set_busy(false)
		return
	_report.clear()
	var result: Dictionary
	if append:
		result = _world_service.append_world(sources, manifest_path, Settings.python_executable())
	else:
		var profile := _load_generation_profile()
		if profile == null and not _profile_path.text.is_empty():
			_set_busy(false)
			return
		result = _world_service.create_world(sources, _output.text, Settings.python_executable(),
			_world_chunk_size.value, Settings.generation_options(), profile)
	_start_result(result)

func _on_world_completed(result: Dictionary) -> void:
	_set_busy(false)
	if not result.get("ok", false):
		_set_status(str(result.get("error", atr("Could not save the world."))))
		var merge: Dictionary = result.get("merge", {})
		if not merge.is_empty():
			_report.text = _merge_summary(merge)
			var directory := str(result.get("directory", ""))
			if not directory.is_empty() and FileAccess.file_exists(directory.path_join("merge_conflicts.json")):
				_report.text += "\n" + directory.path_join("merge_conflicts.json")
		return
	var path := str(result.get("manifest_path", ""))
	var changed := PackedStringArray(result.get("changed_chunks", []))
	var preferred := ""
	if ProjectSettings.localize_path(path).simplify_path() != _world_path.text and not changed.is_empty():
		preferred = changed[0]
	if not _select_world(path, preferred):
		_set_status(atr("Could not open the saved world index."))
		return
	var report: Dictionary = result.get("report", {})
	var lines := PackedStringArray([path, "", atr("Squares updated · %d") % changed.size()])
	if report.has("processed_sources"):
		lines.append(atr("Sources processed · %d") % int(report["processed_sources"]))
	if int(report.get("unchanged_sources", 0)) > 0:
		lines.append(atr("Unchanged sources · %d") % int(report["unchanged_sources"]))
	if report.has("new_ids"):
		lines.append(atr("New OSM objects · %d") % int(report["new_ids"]))
	if report.has("unique_osm_ids"):
		lines.append(atr("Total OSM objects · %d") % int(report["unique_osm_ids"]))
	if int(report.get("skipped_count", 0)) > 0:
		lines.append(atr("Skipped objects · %d") % int(report["skipped_count"]))
	_report.text = "\n".join(lines)
	_set_status(atr("Squares saved. Open Chunks in the bottom dock to browse them.") if not changed.is_empty()
		else atr("Sources processed. Squares updated · 0."))
	_editor.get_resource_filesystem().scan()

func _open_world_chunk(id: String) -> void:
	if _reject_busy() or not _world_chunk_paths.has(id):
		return
	var path: String = _world_chunk_paths[id]
	if not FileAccess.file_exists(path):
		var message := atr("The selected square's scene is unavailable.")
		_chunks_panel.set_status(message)
		_set_status(message)
		return
	_set_busy(true)
	_cancel.disabled = true
	var preparing := atr("Preparing to open square…")
	_chunks_panel.set_status(preparing)
	_on_progress(preparing, -1.0)
	_pending_open_status = atr("Opened square %s") % id
	_pending_world_view = path
	_pending_open = path

func _frame_world_chunk(path: String) -> void:
	var chunk := _editor.get_edited_scene_root() as Node3D
	if chunk == null or chunk.scene_file_path != path:
		return
	var square: Variant = chunk.get("world_chunk_bounds")
	if not square is Rect2 or not square.has_area():
		return
	_editor.set_main_screen_editor("3D")
	await get_tree().process_frame
	if not is_instance_valid(chunk) or _editor.get_edited_scene_root() != chunk:
		return
	var camera := _editor.get_editor_viewport_3d(0).get_camera_3d()
	if camera == null:
		return
	var midpoint: Vector2 = square.get_center()
	var center := chunk.to_global(Vector3(midpoint.x, 0.0, midpoint.y))
	var scale_factor := float(chunk.get_meta("world_scale", 1.0))
	var height := clampf(minf(square.size.x, square.size.y) * 0.1, 2.0, 150.0 * scale_factor)
	height = minf(height, camera.far * 0.25)
	var horizontal := Vector3(0.62, 0.0, 0.85).normalized() * (2.0 * height)
	var eye := center + horizontal + Vector3.UP * height
	if camera.projection == Camera3D.PROJECTION_ORTHOGONAL:
		camera.size = height * 3.0
	camera.look_at_from_position(eye, center)

func _setup_profile_controls() -> void:
	_profile_path = _path_row(atr("New map appearance"), atr("No profile selected"), _choose_profile)
	_profile_path.name = "AppearanceProfilePath"
	_profile_path.editable = false
	_profile_path.tooltip_text = atr("Layer and group settings, sky, and individual assignments by OSM ID.")
	var saved := str(_editor.get_editor_settings().get_project_metadata("spatial_toolkit", "appearance_profile", ""))
	if FileAccess.file_exists(saved):
		_profile_path.text = saved
	_profile_clear = Button.new()
	_profile_clear.name = "ClearAppearanceProfile"
	_profile_clear.text = "×"
	_profile_clear.tooltip_text = atr(NO_PROFILE_HINT)
	_profile_clear.pressed.connect(func() -> void: _select_profile(""))
	_profile_path.get_parent().add_child(_profile_clear)
	_controls.append(_profile_clear)
	_profile_open_dialog = EditorFileDialog.new()
	_profile_open_dialog.file_mode = EditorFileDialog.FILE_MODE_OPEN_FILE
	_profile_open_dialog.access = EditorFileDialog.ACCESS_RESOURCES
	_profile_open_dialog.filters = PackedStringArray(["*.tres ; " + atr("Spatial appearance profile")])
	_profile_open_dialog.title = atr("Choose an appearance profile")
	_profile_open_dialog.file_selected.connect(_load_profile_selection)
	_editor.get_base_control().add_child(_profile_open_dialog)
	_refresh_profile_controls()

func _refresh_profile_controls() -> void:
	_profile_clear.disabled = _busy or _profile_path.text.is_empty()

func _select_profile(path: String) -> void:
	_profile_path.text = path
	_profile_path.tooltip_text = path if not path.is_empty() else atr(NO_PROFILE_HINT)
	_editor.get_editor_settings().set_project_metadata("spatial_toolkit", "appearance_profile", path)
	_refresh_profile_controls()

func _choose_profile() -> void:
	if not _reject_busy():
		_profile_open_dialog.popup_centered_ratio(0.65)

func _load_profile_selection(path: String) -> void:
	if _reject_busy():
		return
	var profile := ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_IGNORE) as AppearanceProfile
	if profile == null:
		_set_status(atr("Select a Spatial appearance profile."))
		return
	var error := profile.validation_error()
	if not error.is_empty():
		_set_status(error)
		return
	_select_profile(path)
	_set_status(atr("Profile selected for the next import."))

func _prepare_import(message: String) -> bool:
	if _reject_busy():
		return false
	_starting_import = true
	_set_busy(true)
	_on_progress(message, -1.0)
	# Let the dock draw before loading the profile or launching Python.
	await get_tree().process_frame
	await get_tree().process_frame
	if not _starting_import:
		_set_busy(false)
		return false
	_starting_import = false
	return true

func _load_generation_profile() -> AppearanceProfile:
	if _profile_path.text.is_empty():
		return null
	var profile := ResourceLoader.load(_profile_path.text, "", ResourceLoader.CACHE_MODE_IGNORE) as AppearanceProfile
	if profile == null:
		_set_status(atr("The appearance profile is unavailable. Select the file again."))
		return null
	var error := profile.validation_error()
	if not error.is_empty():
		_set_status(error)
		return null
	return profile

func _selected_source_paths() -> PackedStringArray:
	var paths := PackedStringArray()
	var sources := _source_selection.geojson_sources
	if sources.is_empty():
		_set_status(atr("Add a GeoJSON source."))
	for index in sources.size():
		var source := sources[index]
		if source == null or source.geojson_path.strip_edges().is_empty():
			_set_status(atr("Item %d: select a GeoJSON file.") % index)
			return PackedStringArray()
		var canonical := _canonical_geojson(source.geojson_path)
		if canonical.is_empty():
			_set_status(atr("Item %d: the GeoJSON file is unavailable.") % index)
			return PackedStringArray()
		if paths.has(canonical):
			_set_status(atr("Item %d: this GeoJSON file has already been added.") % index)
			return PackedStringArray()
		paths.append(canonical)
	return paths

func _start_result(result: Dictionary) -> void:
	if result.get("ok", false):
		_set_busy(true)
	else:
		_set_busy(false)
		_set_status(str(result.get("error", atr("Could not start processing."))))

func _set_busy(value: bool) -> void:
	if value and not _busy:
		_operation_started_ms = Time.get_ticks_msec()
		_elapsed.text = "00:00"
	_busy = value
	for control in _controls:
		if control is Button:
			control.disabled = value
		elif control is LineEdit:
			control.editable = not value
		elif control is SpinBox:
			control.editable = not value
	_refresh_source_controls()
	_cancel.disabled = not value
	_open.disabled = value or _last_scene.is_empty()
	_progress_row.visible = value
	_profile_path.editable = false
	_refresh_profile_controls()

func _on_progress(message: String, fraction: float) -> void:
	_set_status(message)
	_progress.indeterminate = fraction < 0.0
	_progress.value = clampf(fraction, 0.0, 1.0)

func _merge_summary(merge: Dictionary) -> String:
	return atr("Sources %d · OSM objects %d · duplicates %d · conflicts %d") % [
		merge.get("source_count", 0), merge.get("unique_osm_ids", 0),
		merge.get("identical_duplicates", 0), merge.get("conflict_count", 0)]

func _open_last() -> void:
	if not _last_scene.is_empty():
		_pending_open = _last_scene

func _process(_delta: float) -> void:
	if _busy:
		var seconds := floori((Time.get_ticks_msec() - _operation_started_ms) / 1000.0)
		_elapsed.text = "%02d:%02d" % [floori(seconds / 60.0), seconds % 60]
	if _pending_open.is_empty() or _editor.get_resource_filesystem().is_scanning():
		return
	var path := _pending_open
	var frame_chunk := path == _pending_world_view
	_pending_open = ""
	_pending_world_view = ""
	if not _pending_open_status.is_empty():
		_on_progress(atr("Opening saved map…"), -1.0)
		await get_tree().process_frame
	_editor.open_scene_from_path(path)
	if frame_chunk:
		await _frame_world_chunk(path)
	if not _pending_open_status.is_empty():
		var opened := _editor.get_edited_scene_root()
		var message := _pending_open_status if opened != null and opened.scene_file_path == path \
			else atr("Could not open the selected square.")
		_chunks_panel.set_status(message)
		_set_status(message)
		_pending_open_status = ""
		_set_busy(false)

func _setup_world_bake_controls() -> void:
	var editor_settings := _editor.get_editor_settings()
	_note(atr("Bake chunk size (gameplay m)"))
	_bake_chunk_size = _number(100.0)
	_bake_chunk_size.name = "BakeChunkSize"
	_bake_chunk_size.tooltip_text = atr("Sets the size of mesh and collision batches in the baked world.")
	_bake_chunk_size.min_value = 100.0
	_bake_chunk_size.max_value = 50000.0
	_bake_chunk_size.step = 100.0
	_bake_chunk_size.value = float(editor_settings.get_project_metadata("spatial_toolkit", "bake_chunk_size_m", 5000.0))
	_bake_chunk_size.value_changed.connect(func(value: float): editor_settings.set_project_metadata("spatial_toolkit", "bake_chunk_size_m", value))
	_world_bake_drone = CheckBox.new()
	_world_bake_drone.name = "WorldBakeDrone"
	_world_bake_drone.text = atr("Add drone")
	_world_bake_drone.tooltip_text = atr("Adds one controllable drone to the assembled world. Configure controls on FlyPlayer.")
	_world_bake_drone.button_pressed = bool(editor_settings.get_project_metadata("spatial_toolkit", "drone", true))
	_world_bake_drone.toggled.connect(func(enabled: bool):
		editor_settings.set_project_metadata("spatial_toolkit", "drone", enabled)
		_refresh_drone_model_picker())
	_content.add_child(_world_bake_drone)
	_note(atr("Drone model"))
	_world_bake_drone_model = EditorResourcePicker.new()
	_world_bake_drone_model.name = "WorldBakeDroneModel"
	_world_bake_drone_model.base_type = "PackedScene"
	_world_bake_drone_model.tooltip_text = atr("Model scene with a Node3D root and no physics bodies. Leave empty to use the default model.")
	var model_path := str(editor_settings.get_project_metadata("spatial_toolkit", "bake_drone_model", ""))
	if not model_path.is_empty() and ResourceLoader.exists(model_path, "PackedScene"):
		_world_bake_drone_model.edited_resource = load(model_path) as PackedScene
	_world_bake_drone_model.resource_changed.connect(func(resource: Resource):
		editor_settings.set_project_metadata("spatial_toolkit", "bake_drone_model",
			resource.resource_path if resource != null else ""))
	_content.add_child(_world_bake_drone_model)
	_world_bake_window_detail = CheckBox.new()
	_world_bake_window_detail.name = "WorldBakeWindowDetail"
	_world_bake_window_detail.text = atr("Nearby 3D window frames")
	_world_bake_window_detail.tooltip_text = atr("Saves the window layout and enables 3D frames near the gameplay camera.")
	_world_bake_window_detail.button_pressed = bool(editor_settings.get_project_metadata("spatial_toolkit", "bake_window_detail", false))
	_world_bake_window_detail.toggled.connect(func(enabled: bool): editor_settings.set_project_metadata("spatial_toolkit", "bake_window_detail", enabled))
	_content.add_child(_world_bake_window_detail)
	_world_bake = _button(atr("Assemble and bake world"), _bake_world)
	_world_bake.name = "BakeWorld"

func _refresh_drone_model_picker() -> void:
	_world_bake_drone_model.editable = not _world_bake_drone.disabled and _world_bake_drone.button_pressed

func _reject_busy() -> bool:
	if _busy:
		return true
	for service: Node in [_world_service, _bake_service]:
		if service != null and bool(service.get("busy")):
			_set_status(atr("Wait for the current operation to finish, or cancel it."))
			return true
	return false

func _cancel_operation() -> void:
	if _starting_import:
		_starting_import = false
		_cancel.disabled = true
		_set_status(atr("Import preparation cancelled."))
	elif _baking and _bake_service != null:
		_bake_service.cancel()
	else:
		_world_service.cancel()

func _bake_world() -> void:
	if _reject_busy() or _world_bake.disabled:
		return
	_report.clear()
	_baking = true
	var window_detail := is_instance_valid(_world_bake_window_detail) and _world_bake_window_detail.button_pressed
	var result: Dictionary = _bake_service.bake_world(_world_path.text, _output.text,
		_bake_chunk_size.value, Settings.merge_bake_collisions(), _world_bake_drone.button_pressed,
		Settings.python_executable(), window_detail, _world_bake_drone_model.edited_resource as PackedScene)
	_start_result(result)
	if not result.get("ok", false):
		_baking = false

func _on_bake_completed(result: Dictionary) -> void:
	_baking = false
	_set_busy(false)
	if not result.get("ok", false):
		_set_status(str(result.get("error", atr("Could not bake the scene."))))
		if result.has("directory"):
			_report.text = atr("Incomplete output: %s") % str(result["directory"])
		return
	_last_scene = str(result["scene_path"])
	var report: Dictionary = result.get("report", {})
	_set_status(atr("World baked. You can open the last scene."))
	_report.text = _format_bake_report(report, _last_scene)
	_open.disabled = false
	_editor.get_resource_filesystem().scan()

func _format_bake_report(report: Dictionary, scene_path: String) -> String:
	var before: Dictionary = report.get("before", {})
	var after: Dictionary = report.get("after", {})
	var lines := PackedStringArray([scene_path, ""])
	if report.has("source_scene_count"):
		lines.append(atr("Source squares · %d") % int(report["source_scene_count"]))
	if report.has("world_data_path"):
		lines.append(atr("Coordinate data · %s") % str(report["world_data_path"]))
	if report.has("world_data_error"):
		lines.append(atr("Coordinate data export · %s") % str(report["world_data_error"]))
	if report.has("window_detail_count"):
		lines.append(atr("3D frame layout · %d windows") % int(report["window_detail_count"]))
	lines.append(atr("Before → after"))
	var metrics := {
		"nodes": atr("Nodes"),
		"mesh_instances": atr("Meshes"),
		"materials": atr("Materials"),
		"surfaces": atr("Surfaces"),
		"static_bodies": atr("Static bodies"),
		"collision_shapes": atr("Collision shapes"),
		"visual_triangles": atr("Visual triangles"),
		"collision_triangles": atr("Collision triangles"),
	}
	for key: String in metrics:
		if before.has(key) and after.has(key):
			lines.append("%s: %d → %d" % [metrics[key], int(before[key]), int(after[key])])
	if report.has("chunks"):
		lines.append(atr("Chunks: %s") % str(report["chunks"]))
	lines.append(atr("Surfaces estimate draw submissions. FPS requires a separate measurement."))
	lines.append(atr("See bake_report.json next to the scene."))
	return "\n".join(lines)
