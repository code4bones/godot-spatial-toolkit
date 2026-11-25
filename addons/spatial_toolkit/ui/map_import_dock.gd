@tool
extends VBoxContainer
## Editor-only UI; deterministic import work lives in the independent service.

signal source_imported(source: String, scene: String)

const DRONE := preload("res://addons/spatial_toolkit/runtime/drone_camera.gd")
const NIGHT_STYLE := preload("res://addons/spatial_toolkit/runtime/night_city_style.gd")
const FLIGHT := preload("res://addons/spatial_toolkit/core/map_flight_module.gd")
const FacadeColorPanel := preload("res://addons/spatial_toolkit/ui/facade_color_panel.gd")
const GroundStylePanel := preload("res://addons/spatial_toolkit/ui/ground_style_panel.gd")
const AppearanceProfile := preload("res://addons/spatial_toolkit/core/map_appearance_profile.gd")

var _service
var _running_source := ""
var _bake_service: Node
var _style_service: Node
var _style_source: LineEdit
var _style_remove: Button
var _style_source_dialog: EditorFileDialog
var _styling := false
var _bake_source: LineEdit
var _bake_chunk_size: SpinBox
var _bake_collisions: CheckBox
var _bake_button: Button
var _bake_source_dialog: EditorFileDialog
var _baking := false
var _editor: EditorInterface
var _undo_redo: EditorUndoRedoManager
var _content: VBoxContainer
var _source_path := ""
var _source_label: Label
var _generate: Button
var _output: LineEdit
var _python: LineEdit
var _height: SpinBox
var _level_height: SpinBox
var _world_scale: SpinBox
var _building_collisions: CheckBox
var _daylight: CheckBox
var _sky_mode: OptionButton
var _facade_colors: FacadeColorPanel
var _ground_style: GroundStylePanel
var _drone: CheckBox
var _flight_controller: OptionButton
var _cancel: Button
var _open: Button
var _status: Label
var _report: RichTextLabel
var _progress: ProgressBar
var _output_dialog: EditorFileDialog
var _last_scene := ""
var _pending_open := ""
var _controls: Array[Control] = []
var _profile_path: LineEdit
var _profile_export: Button
var _profile_clear: Button
var _profile_open_dialog: EditorFileDialog
var _profile_save_dialog: EditorFileDialog
var _pending_profile: AppearanceProfile
var _busy := false

func setup(service: Node, editor: EditorInterface, bake_service: Node = null,
		style_service: Node = null, undo_redo: EditorUndoRedoManager = null) -> void:
	_service = service
	_bake_service = bake_service
	_style_service = style_service
	_editor = editor
	_undo_redo = undo_redo
	name = "Spatial"
	custom_minimum_size.x = 280
	var title := Label.new()
	title.text = "Spatial Toolkit · GeoJSON → карта"
	add_child(title)
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
	var source_row := HBoxContainer.new()
	_content.add_child(source_row)
	_source_label = Label.new()
	_source_label.text = "Источник: Map Explorer"
	_source_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_source_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	source_row.add_child(_source_label)
	var explorer := Button.new()
	explorer.text = "[…]"
	explorer.tooltip_text = "Открыть Map Explorer"
	explorer.pressed.connect(func() -> void: _editor.set_main_screen_editor("Map Explorer"))
	source_row.add_child(explorer)
	var sky_row := HBoxContainer.new()
	_content.add_child(sky_row)
	var sky_label := Label.new()
	sky_label.text = "Небо открытой карты"
	sky_row.add_child(sky_label)
	_sky_mode = OptionButton.new()
	_sky_mode.name = "SkyMode"
	_sky_mode.add_item("День")
	_sky_mode.add_item("Ночь")
	_sky_mode.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_sky_mode.item_selected.connect(_set_sky_mode)
	sky_row.add_child(_sky_mode)
	_refresh_sky_mode()
	if _undo_redo != null:
		_undo_redo.version_changed.connect(_refresh_sky_mode, CONNECT_DEFERRED)
	_facade_colors = FacadeColorPanel.new()
	_facade_colors.setup(_undo_redo)
	_content.add_child(_facade_colors)
	_facade_colors.refresh_scene(_editor.get_edited_scene_root())
	_ground_style = GroundStylePanel.new()
	_ground_style.setup(_editor, _undo_redo)
	_content.add_child(_ground_style)
	_setup_profile_controls()
	_output = _path_row("Папка результата", "res://generated/maps", _choose_output)
	_output.name = "OutputPath"
	_output.text = "res://generated/maps"
	_note("Каждая карта сохраняется в новую папку.")
	_note("Исходная высота без данных, м")
	_height = _number(float(_editor.get_editor_settings().get_project_metadata("spatial_toolkit", "default_height", 3.0)))
	_height.name = "DefaultHeight"
	_height.value_changed.connect(func(value: float): _editor.get_editor_settings().set_project_metadata("spatial_toolkit", "default_height", value))
	_note("Исходная высота этажа, м (также для roof:levels)")
	_level_height = _number(float(_editor.get_editor_settings().get_project_metadata("spatial_toolkit", "level_height", 3.0)))
	_level_height.name = "LevelHeight"
	_level_height.value_changed.connect(func(value: float): _editor.get_editor_settings().set_project_metadata("spatial_toolkit", "level_height", value))
	_note("height — полная высота. При расчёте по этажам крыша учитывается отдельно.")
	_note("Игровой масштаб мира, ×")
	_world_scale = _number(float(_editor.get_editor_settings().get_project_metadata("spatial_toolkit", "world_scale", 1.0)))
	_world_scale.name = "WorldScale"
	_world_scale.min_value = 1.0
	_world_scale.step = 1.0
	_world_scale.value_changed.connect(func(value: float): _editor.get_editor_settings().set_project_metadata("spatial_toolkit", "world_scale", value))
	_note("Увеличивает карту, здания и окна. Размер и скорость дрона прежние; исходные размеры OSM сохраняются.")
	_building_collisions = CheckBox.new()
	_building_collisions.name = "BuildingCollisions"
	_building_collisions.text = "Коллизии зданий"
	_building_collisions.button_pressed = bool(_editor.get_editor_settings().get_project_metadata("spatial_toolkit", "building_collisions", true))
	_building_collisions.tooltip_text = "Здания станут препятствиями для физического игрока. Дворы и отверстия сохраняются. Для дрона поверхность земли получает коллизию при запуске."
	_building_collisions.toggled.connect(func(enabled: bool): _editor.get_editor_settings().set_project_metadata("spatial_toolkit", "building_collisions", enabled))
	_content.add_child(_building_collisions)
	_controls.append(_building_collisions)
	_daylight = _module_option("Daylight", "Материалы, небо и освещение", "daylight", "Условные фасады и окна, солнце, небо и атмосферный горизонт.")
	_drone = _module_option("DroneFlight", "Дрон и полёт по точкам", "drone", "Полёт с управлением от мыши и колеса. Для столкновений со зданиями включите их коллизии.")
	_note("Контроллер дрона")
	_flight_controller = OptionButton.new()
	var settings := _editor.get_editor_settings()
	var selected := str(settings.get_project_metadata("spatial_toolkit", "flight_controller", FLIGHT.DEFAULT_CONTROLLER))
	for id: String in FLIGHT.CONTROLLERS:
		_flight_controller.add_item(FLIGHT.CONTROLLER_LABELS[id])
		var index := _flight_controller.item_count - 1
		_flight_controller.set_item_metadata(index, id)
		if id == selected:
			_flight_controller.select(index)
	_flight_controller.item_selected.connect(func(index: int) -> void:
		settings.set_project_metadata("spatial_toolkit", "flight_controller",
			_flight_controller.get_item_metadata(index)))
	_content.add_child(_flight_controller)
	_controls.append(_flight_controller)
	var apply_controller := _button("Применить к открытой сцене", _apply_flight_controller)
	apply_controller.name = "ApplyFlightController"
	apply_controller.tooltip_text = "Меняет скрипт дрона в открытой сцене. Действие можно отменить."

	var invert_ws := CheckBox.new()
	invert_ws.name = "InvertFlightWS"
	invert_ws.text = "Инвертировать W/S · W вниз, S вверх"
	invert_ws.tooltip_text = "Настройка обоих контроллеров дрона для всех карт проекта."
	invert_ws.button_pressed = bool(ProjectSettings.get_setting(DRONE.INVERT_WS_SETTING, false))
	invert_ws.toggled.connect(func(enabled: bool) -> void:
		var previous: Variant = ProjectSettings.get_setting(DRONE.INVERT_WS_SETTING, null)
		ProjectSettings.set_setting(DRONE.INVERT_WS_SETTING, enabled)
		var error := ProjectSettings.save()
		if error != OK:
			ProjectSettings.set_setting(DRONE.INVERT_WS_SETTING, previous)
			invert_ws.set_pressed_no_signal(bool(previous) if previous != null else false)
			_status.text = "Не удалось сохранить настройку W/S: " + error_string(error)
		else:
			_status.text = "Настройка W/S сохранена. Запустите сцену через F6.")
	_content.add_child(invert_ws)
	_controls.append(invert_ws)

	_note("Python 3.10+ (команда или полный путь)")
	_python = LineEdit.new()
	_python.name = "PythonPath"
	_python.text = str(_editor.get_editor_settings().get_project_metadata("spatial_toolkit", "python", "python" if OS.get_name() == "Windows" else "python3"))
	_python.text_changed.connect(func(value: String): _editor.get_editor_settings().set_project_metadata("spatial_toolkit", "python", value))
	_content.add_child(_python)
	_controls.append(_python)
	_button("Проверить зависимости", _check_dependencies)
	_note("Локальный Python + pyproj + GEOS. Плоская карта без рельефа; коллизии — только у зданий.")
	_generate = _button("Создать карту", _generate_map)
	_generate.name = "GenerateMap"
	_generate.disabled = true
	_setup_bake_controls()
	_setup_style_removal_controls()
	_cancel = _button("Отменить", _cancel_operation)
	_controls.erase(_cancel)
	_cancel.disabled = true
	_progress = ProgressBar.new()
	_progress.show_percentage = false
	_progress.max_value = 1
	_progress.visible = false
	_content.add_child(_progress)
	_status = _note("Передайте источник из Map Explorer.")
	_status.name = "Status"
	_report = RichTextLabel.new()
	_report.name = "ImportReport"
	_report.custom_minimum_size.y = 160
	_report.selection_enabled = true
	_report.fit_content = true
	_report.scroll_active = false
	_report.bbcode_enabled = false
	_content.add_child(_report)
	_open = _button("Открыть созданную карту", _open_last)
	_controls.erase(_open)
	_open.disabled = true
	_output_dialog = EditorFileDialog.new()
	_output_dialog.file_mode = EditorFileDialog.FILE_MODE_OPEN_DIR
	_output_dialog.access = EditorFileDialog.ACCESS_RESOURCES
	_output_dialog.title = "Папка для новых карт"
	_output_dialog.dir_selected.connect(func(path: String): _output.text = path)
	_editor.get_base_control().add_child(_output_dialog)
	_service.progress.connect(_on_progress)
	_service.completed.connect(_on_completed)
	if _bake_service != null:
		_bake_service.progress.connect(_on_progress)
		_bake_service.completed.connect(_on_bake_completed)
	if _style_service != null:
		_style_service.progress.connect(_on_progress)
		_style_service.completed.connect(_on_style_completed)

func _exit_tree() -> void:
	if is_instance_valid(_profile_open_dialog):
		_profile_open_dialog.queue_free()
	if is_instance_valid(_profile_save_dialog):
		_profile_save_dialog.queue_free()
	if is_instance_valid(_style_source_dialog):
		_style_source_dialog.queue_free()
	if is_instance_valid(_bake_source_dialog):
		_bake_source_dialog.queue_free()
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

func _module_option(node_name: String, title: String, setting: String, tooltip: String, default_enabled: bool = true) -> CheckBox:
	var checkbox := CheckBox.new()
	checkbox.name = node_name
	checkbox.text = title
	checkbox.tooltip_text = tooltip
	checkbox.button_pressed = bool(_editor.get_editor_settings().get_project_metadata("spatial_toolkit", setting, default_enabled))
	checkbox.toggled.connect(func(enabled: bool): _editor.get_editor_settings().set_project_metadata("spatial_toolkit", setting, enabled))
	_content.add_child(checkbox)
	_controls.append(checkbox)
	return checkbox

func _choose_output() -> void:
	_output_dialog.popup_centered_ratio(0.6)

func _check_dependencies() -> void:
	if _reject_busy():
		return
	_baking = false
	_start_result(_service.check_dependencies(_python.text))

func prepare_source(path: String) -> bool:
	if _reject_busy():
		return false
	if not FileAccess.file_exists(path):
		_status.text = "Файл из Map Explorer недоступен."
		return false
	_source_path = path
	_source_label.text = path.get_file()
	_source_label.tooltip_text = path
	_generate.disabled = false
	_status.text = "Источник выбран. Нажмите «Создать карту»."
	return true

func refresh_scene(root: Node) -> void:
	_refresh_sky_mode()
	_facade_colors.refresh_scene(root)
	_ground_style.refresh_scene(root)
	_refresh_profile_controls()

func _setup_profile_controls() -> void:
	_profile_path = _path_row("Оформление новой карты", "Профиль не выбран", _choose_profile)
	_profile_path.name = "AppearanceProfilePath"
	_profile_path.editable = false
	_profile_path.tooltip_text = "Материалы фасадов, крыш и земли, цвета и индивидуальные назначения по ID OSM."
	var saved := str(_editor.get_editor_settings().get_project_metadata("spatial_toolkit", "appearance_profile", ""))
	if FileAccess.file_exists(saved):
		_profile_path.text = saved
	_profile_clear = Button.new()
	_profile_clear.name = "ClearAppearanceProfile"
	_profile_clear.text = "×"
	_profile_clear.tooltip_text = "Создавать карту со стандартным оформлением"
	_profile_clear.pressed.connect(func() -> void: _select_profile(""))
	_profile_path.get_parent().add_child(_profile_clear)
	_controls.append(_profile_clear)
	_profile_export = _button("Сохранить оформление…", _choose_profile_export)
	_profile_export.name = "SaveAppearanceProfile"
	_profile_export.tooltip_text = "Сохранить текущие назначения открытой карты в отдельный профиль."
	_profile_open_dialog = EditorFileDialog.new()
	_profile_open_dialog.file_mode = EditorFileDialog.FILE_MODE_OPEN_FILE
	_profile_open_dialog.access = EditorFileDialog.ACCESS_RESOURCES
	_profile_open_dialog.filters = PackedStringArray(["*.tres ; Профиль оформления Spatial"])
	_profile_open_dialog.title = "Выбрать профиль оформления"
	_profile_open_dialog.file_selected.connect(_load_profile_selection)
	_editor.get_base_control().add_child(_profile_open_dialog)
	_profile_save_dialog = EditorFileDialog.new()
	_profile_save_dialog.file_mode = EditorFileDialog.FILE_MODE_SAVE_FILE
	_profile_save_dialog.access = EditorFileDialog.ACCESS_RESOURCES
	_profile_save_dialog.filters = PackedStringArray(["*.tres ; Профиль оформления Spatial"])
	_profile_save_dialog.title = "Сохранить оформление карты"
	_profile_save_dialog.file_selected.connect(_save_profile)
	_profile_save_dialog.canceled.connect(func() -> void: _pending_profile = null)
	_editor.get_base_control().add_child(_profile_save_dialog)
	_refresh_profile_controls()

func _profile_map() -> Node3D:
	var map := _editor.get_edited_scene_root() as Node3D
	return map if map != null and map.has_node("Generated/Buildings") else null

func _refresh_profile_controls() -> void:
	if _profile_export == null:
		return
	_profile_export.disabled = _busy or _profile_map() == null
	_profile_clear.disabled = _busy or _profile_path.text.is_empty()

func _select_profile(path: String) -> void:
	_profile_path.text = path
	_profile_path.tooltip_text = path if not path.is_empty() else "Создать карту со стандартным оформлением."
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
		_status.text = "Выберите профиль оформления Spatial."
		return
	var error := profile.validation_error()
	if not error.is_empty():
		_status.text = error
		return
	_select_profile(path)
	_status.text = "Профиль выбран для следующего импорта."

func _choose_profile_export() -> void:
	if _reject_busy():
		return
	var map := _profile_map()
	if map == null:
		_status.text = "Откройте карту Spatial, чтобы сохранить её оформление."
		return
	_pending_profile = AppearanceProfile.new()
	_pending_profile.capture(map)
	var error := _pending_profile.validation_error()
	if not error.is_empty():
		_pending_profile = null
		_status.text = error
		return
	_profile_save_dialog.current_file = "map_appearance.tres"
	_profile_save_dialog.popup_centered_ratio(0.65)

func _save_profile(path: String) -> void:
	if _reject_busy() or _pending_profile == null:
		return
	if not path.begins_with("res://") or path.get_extension().to_lower() != "tres":
		_status.text = "Сохраните профиль в проекте как файл .tres."
		return
	var error := ResourceSaver.save(_pending_profile, path)
	if error != OK:
		_status.text = "Не удалось сохранить оформление. " + error_string(error)
		return
	_pending_profile = null
	_select_profile(path)
	_editor.get_resource_filesystem().scan()
	_status.text = "Оформление сохранено и выбрано для следующего импорта."

func _map_with_sky() -> Node:
	var scene := _editor.get_edited_scene_root()
	if scene != null and scene.get_node_or_null("PreviewEnvironment") is WorldEnvironment \
			and scene.get_node_or_null("PreviewSun") is DirectionalLight3D:
		return scene
	return null

func _refresh_sky_mode() -> void:
	var map := _map_with_sky()
	_sky_mode.disabled = map == null or _undo_redo == null
	_sky_mode.select(int(NIGHT_STYLE.mode_for(map) == NIGHT_STYLE.NIGHT) if map != null else -1)
	_sky_mode.tooltip_text = "Сохраните сцену и запустите через F6." if map != null else "Откройте карту Spatial с освещением."

func _set_sky_mode(index: int) -> void:
	var map := _map_with_sky()
	if map == null or _undo_redo == null:
		return
	var mode := NIGHT_STYLE.NIGHT if index == 1 else NIGHT_STYLE.DAY
	if NIGHT_STYLE.mode_for(map) == mode:
		return
	_undo_redo.create_action("Сменить небо карты", UndoRedo.MERGE_DISABLE, map)
	_undo_redo.add_do_method(map, "set_meta", NIGHT_STYLE.MODE, mode)
	_undo_redo.add_undo_method(map, "set_meta", NIGHT_STYLE.MODE, map.get_meta(NIGHT_STYLE.MODE, null) if map.has_meta(NIGHT_STYLE.MODE) else null)
	_undo_redo.commit_action()
	_status.text = "Небо выбрано. Сохраните сцену и запустите её через F6."

func _apply_flight_controller() -> void:
	if _reject_busy():
		return
	var scene := _editor.get_edited_scene_root()
	var player := scene.get_node_or_null(FLIGHT.PLAYER_NAME) as CharacterBody3D if scene != null else null
	var camera := player.get_node_or_null("CameraPivot/CameraBoom/FlyCamera") as Camera3D if player != null else null
	if camera == null or camera.owner != scene or player.get_meta("generated_by", "") != FLIGHT.GENERATOR:
		_status.text = "Откройте карту Spatial с дроном."
		return
	var selected := str(_flight_controller.get_selected_metadata())
	var previous := camera.get_script() as Script
	var next := FLIGHT.CONTROLLERS.get(selected) as Script
	if next == null or not previous in FLIGHT.CONTROLLERS.values():
		_status.text = "Контроллер открытой карты не распознан."
		return
	if next == previous:
		_status.text = "Этот контроллер уже установлен."
		return
	if _undo_redo == null:
		_status.text = "История действий Godot недоступна."
		return
	var next_properties := {}
	for property in next.get_script_property_list():
		next_properties[property["name"]] = true
	_undo_redo.create_action("Сменить контроллер дрона", UndoRedo.MERGE_DISABLE, scene)
	_undo_redo.add_do_property(camera, "script", next)
	_undo_redo.add_undo_property(camera, "script", previous)
	for property in previous.get_script_property_list():
		var usage: int = property["usage"]
		if (usage & PROPERTY_USAGE_EDITOR) == 0 or (usage & PROPERTY_USAGE_STORAGE) == 0:
			continue
		var key: StringName = property["name"]
		var value: Variant = camera.get(key)
		_undo_redo.add_undo_property(camera, key, value)
		if next_properties.has(key):
			_undo_redo.add_do_property(camera, key, value)
	_undo_redo.add_do_method(player, "set_meta", &"flight_controller", selected)
	if player.has_meta("flight_controller"):
		_undo_redo.add_undo_method(player, "set_meta", &"flight_controller", player.get_meta("flight_controller"))
	else:
		_undo_redo.add_undo_method(player, "remove_meta", &"flight_controller")
	_undo_redo.commit_action()
	_status.text = "Контроллер сменён. Сохраните сцену и запустите её через F6."

func _generate_map() -> void:
	if _reject_busy():
		return
	if _source_path.is_empty():
		_status.text = "Передайте источник из Map Explorer."
		return
	var profile: AppearanceProfile
	if not _profile_path.text.is_empty():
		profile = ResourceLoader.load(_profile_path.text, "", ResourceLoader.CACHE_MODE_IGNORE) as AppearanceProfile
		if profile == null:
			_status.text = "Профиль оформления недоступен. Выберите файл заново."
			return
		var error := profile.validation_error()
		if not error.is_empty():
			_status.text = error
			return
	_baking = false
	_report.clear()
	_running_source = _source_path
	_start_result(_service.generate_spatial_map(_source_path, _output.text, _python.text, _height.value, _level_height.value, _building_collisions.button_pressed, _daylight.button_pressed, _drone.button_pressed, _world_scale.value, str(_flight_controller.get_selected_metadata()), profile))

func _start_result(result: Dictionary) -> void:
	if result.get("ok", false):
		_set_busy(true)
	else:
		_status.text = str(result.get("error", "Не удалось начать обработку."))

func _set_busy(value: bool) -> void:
	_busy = value
	_facade_colors.set_busy(value)
	_ground_style.set_busy(value)
	for control in _controls:
		if control is Button:
			control.disabled = value
		elif control is LineEdit:
			control.editable = not value
		elif control is SpinBox:
			control.editable = not value
	_generate.disabled = value or _source_path.is_empty()
	_cancel.disabled = not value
	_open.disabled = value or _last_scene.is_empty()
	_progress.visible = value
	if _bake_service == null:
		_bake_button.disabled = true
	if _style_service == null:
		_style_remove.disabled = true
	_profile_path.editable = false
	_refresh_profile_controls()

func _on_progress(message: String, fraction: float) -> void:
	_status.text = message
	_progress.value = fraction

func _on_completed(result: Dictionary) -> void:
	_set_busy(false)
	if not result.get("ok", false):
		_status.text = str(result.get("error", "Ошибка создания карты."))
		if result.has("directory"):
			_report.text = "Незавершённый результат: " + str(result["directory"])
		return
	if result.get("operation") == "check":
		_status.text = "Зависимости доступны. Можно создавать карту."
		_report.text = JSON.stringify(result.get("dependencies", {}), "  ")
		return
	_last_scene = result["scene_path"]
	source_imported.emit(_running_source, _last_scene)
	_bake_source.text = _last_scene
	_style_source.text = _last_scene
	_open.disabled = false
	_status.text = "Карта создана."
	_report.text = _format_report(result.get("report", {}), _last_scene)
	_pending_open = _last_scene
	_editor.get_resource_filesystem().scan()

func _format_report(report: Dictionary, scene_path: String) -> String:
	var generated: Dictionary = report.get("generated", {})
	var skipped: Array = report.get("skipped", [])
	var lines := PackedStringArray([scene_path, ""])
	var settings: Dictionary = report.get("settings", {})
	lines.append("Игровой масштаб: ×%s · дрон обычного размера" % str(float(settings.get("world_scale", 1.0))))
	if settings.get("breakable_windows", false):
		lines.append("Разбиваемых стёкол: %d" % int(report.get("modules", {}).get("breakable_windows", {}).get("count", 0)))
	elif settings.get("open_windows", false):
		var openings: Dictionary = report.get("facade_openings", {})
		lines.append("Сквозных окон: %d · внутри пустые залы без этажей" % int(openings.get("count", 0)))
		if settings.get("window_density", "limited") == "limited":
			lines.append("До %d проёмов на всё здание · каждое %d-е · выбрано зданий: %d" % [int(settings.get("window_limit", 6)), int(settings.get("window_every_n", 5)), int(openings.get("selected_buildings", 0))])
		elif openings.get("adjusted", false):
			lines.append("Разрежение окон: %d → %d · шаг сетки ×%d" % [int(openings.get("estimated_full_count", 0)), int(openings.get("count", 0)), int(openings.get("grid_stride", 1))])
	var names := {"Buildings": "Здания", "Roads": "Дороги", "Paths": "Пешеходные пути / лестницы", "PlannedRoads": "Проект / стройка", "Landuse": "Территории", "Water": "Водоёмы"}
	for key in names:
		lines.append("%s: %d" % [names[key], generated.get(key, 0)])
	lines.append("Пропущено: %d · отверстий сохранено: %d" % [report.get("skipped_count", skipped.size()), report.get("polygon_holes", 0)])
	var coincident := int(report.get("coincident_building_count", 0))
	if coincident > 0:
		lines.append("Совпадающие оболочки: %d · исходные ID в полном отчёте" % coincident)
	var heights: Dictionary = report.get("height_sources", {})
	lines.append("Высота по умолчанию: %d зданий" % heights.get("default_estimate", 0))
	lines.append("Высота по этажности: %d зданий" % heights.get("levels_estimate", 0))
	var collisions: Dictionary = report.get("collisions", {})
	if collisions.get("enabled", false):
		lines.append("Препятствия: %d зданий · %d треугольников" % [collisions.get("created", 0), collisions.get("triangles", 0)])
		var collision_skips: Array = collisions.get("skipped", [])
		if not collision_skips.is_empty():
			lines.append("Без коллизий: %d (причины в полном отчёте)" % collision_skips.size())
	else:
		lines.append("Коллизии зданий: выключены")
	var modules: Dictionary = report.get("modules", {})
	lines.append("Оформление: " + ("включено" if modules.get("daylight", {}).get("enabled", false) else "выключено"))
	var profile: Dictionary = modules.get("appearance_profile", {})
	if not profile.is_empty():
		lines.append("Профиль оформления · " + str(profile.get("path", "")))
		lines.append("Индивидуальных материалов перенесено · %d" % int(profile.get("matched_building_materials", 0)))
		var unmatched: Array = profile.get("unmatched_building_ids", [])
		if not unmatched.is_empty():
			lines.append("Назначения без совпавших зданий · %d" % unmatched.size())
	lines.append("Дрон: " + ("включён" if modules.get("drone", {}).get("enabled", false) else "выключен"))
	var widths: Dictionary = report.get("width_sources", {})
	lines.append("Оценочная ширина: %d линий" % (int(widths.get("type_estimate", 0)) + int(widths.get("lanes_estimate", 0))))
	for item: Dictionary in skipped.slice(0, 5):
		lines.append("%s: %s" % [item.get("id", "?"), item.get("reason", "?")])
	lines.append("\nПолный отчёт: export_preview.report.json рядом со сценой.")
	return "\n".join(lines)

func _open_last() -> void:
	if not _last_scene.is_empty():
		_pending_open = _last_scene

func _process(_delta: float) -> void:
	if _pending_open.is_empty() or _editor.get_resource_filesystem().is_scanning():
		return
	var path := _pending_open
	_pending_open = ""
	_editor.open_scene_from_path(path)

func _setup_bake_controls() -> void:
	var separator := HSeparator.new()
	_content.add_child(separator)
	_note("Финальная игровая сцена")
	_bake_source = _path_row("Сохранённая карта для запекания", "res://…/map.tscn", _choose_bake_source)
	_bake_source.name = "BakeSourcePath"
	var edited := _editor.get_edited_scene_root()
	if edited != null:
		_bake_source.text = edited.scene_file_path
	_note("Используется сохранённая версия сцены с диска. Исходная карта сохраняется; результат — в новой папке.")
	_note("Размер чанка, игровых метров")
	_bake_chunk_size = _number(float(_editor.get_editor_settings().get_project_metadata("spatial_toolkit", "bake_chunk_size_m", 5000.0)))
	_bake_chunk_size.name = "BakeChunkSize"
	_bake_chunk_size.min_value = 100.0
	_bake_chunk_size.max_value = 50000.0
	_bake_chunk_size.step = 100.0
	# _number initially clamps to the import height range; apply the saved value
	# again after assigning this control's independent chunk range.
	_bake_chunk_size.value = float(_editor.get_editor_settings().get_project_metadata("spatial_toolkit", "bake_chunk_size_m", 5000.0))
	_bake_chunk_size.value_changed.connect(func(value: float): _editor.get_editor_settings().set_project_metadata("spatial_toolkit", "bake_chunk_size_m", value))
	_bake_collisions = _module_option("BakeMergeCollisions", "Объединять коллизии внутри чанков", "bake_merge_collisions", "Проёмы и формы препятствий сохраняются; объединяются статические тела зданий.")
	_bake_button = _button("Запечь игровую сцену", _bake_scene)
	_bake_button.name = "BakeScene"
	_bake_button.disabled = _bake_service == null
	if _bake_service == null:
		_note("Сервис запекания недоступен. Перезапустите плагин Spatial Toolkit.")
	_bake_source_dialog = EditorFileDialog.new()
	_bake_source_dialog.file_mode = EditorFileDialog.FILE_MODE_OPEN_FILE
	_bake_source_dialog.access = EditorFileDialog.ACCESS_RESOURCES
	_bake_source_dialog.filters = PackedStringArray(["*.tscn,*.scn ; Godot Scene"])
	_bake_source_dialog.title = "Выбрать сохранённую карту"
	_bake_source_dialog.file_selected.connect(func(path: String): _bake_source.text = path)
	_editor.get_base_control().add_child(_bake_source_dialog)

func _choose_bake_source() -> void:
	_bake_source_dialog.popup_centered_ratio(0.7)

func _reject_busy() -> bool:
	if bool(_service.get("busy")) or (_bake_service != null and bool(_bake_service.get("busy"))) or (_style_service != null and bool(_style_service.get("busy"))):
		_status.text = "Дождитесь завершения текущей операции или отмените её."
		return true
	return false

func _cancel_operation() -> void:
	if _styling and _style_service != null:
		_style_service.cancel()
	elif _baking and _bake_service != null:
		_bake_service.cancel()
	else:
		_service.cancel()

func _bake_scene() -> void:
	if _reject_busy():
		return
	if _bake_service == null:
		_status.text = "Сервис запекания недоступен."
		return
	if _bake_source.text.strip_edges().is_empty():
		var edited := _editor.get_edited_scene_root()
		if edited != null:
			_bake_source.text = edited.scene_file_path
	_report.clear()
	_baking = true
	var result: Dictionary = _bake_service.bake_scene(_bake_source.text, _output.text, _bake_chunk_size.value, _bake_collisions.button_pressed)
	_start_result(result)
	if not result.get("ok", false):
		_baking = false

func _on_bake_completed(result: Dictionary) -> void:
	_baking = false
	_set_busy(false)
	if not result.get("ok", false):
		_status.text = str(result.get("error", "Не удалось запечь сцену."))
		if result.has("directory"):
			_report.text = "Незавершённый результат: " + str(result["directory"])
		return
	_last_scene = str(result["scene_path"])
	_status.text = "Игровая сцена запечена. Исходная карта сохранена."
	_report.text = _format_bake_report(result.get("report", {}), _last_scene)
	_open.disabled = false
	_pending_open = _last_scene
	_editor.get_resource_filesystem().scan()

func _format_bake_report(report: Dictionary, scene_path: String) -> String:
	var before: Dictionary = report.get("before", {})
	var after: Dictionary = report.get("after", {})
	var lines := PackedStringArray([scene_path, "", "До → после"])
	var metrics := {"nodes": "Узлы", "mesh_instances": "Меши", "materials": "Материалы", "surfaces": "Поверхности", "static_bodies": "Статические тела", "collision_shapes": "Формы коллизий", "visual_triangles": "Визуальные треугольники", "collision_triangles": "Физические треугольники"}
	for key: String in metrics:
		if before.has(key) and after.has(key):
			lines.append("%s: %d → %d" % [metrics[key], int(before[key]), int(after[key])])
	if report.has("chunks"):
		lines.append("Чанков: %s" % str(report["chunks"]))
	lines.append("Поверхности — оценка числа отправок на отрисовку, не измерение FPS.")
	lines.append("Подробности: bake_report.json рядом со сценой.")
	return "\n".join(lines)


func _setup_style_removal_controls() -> void:
	_content.add_child(HSeparator.new())
	_note("Удаление оформления")
	_style_source = _path_row("Сохранённая карта со стилем", "res://…/map.tscn", _choose_style_source)
	_style_source.name = "StyleSourcePath"
	var edited := _editor.get_edited_scene_root()
	if edited != null:
		_style_source.text = edited.scene_file_path
	_style_remove = _button("Создать копию без стиля", _remove_style)
	_style_remove.name = "RemoveWorldStyle"
	_style_remove.disabled = _style_service == null
	_style_source_dialog = EditorFileDialog.new()
	_style_source_dialog.file_mode = EditorFileDialog.FILE_MODE_OPEN_FILE
	_style_source_dialog.access = EditorFileDialog.ACCESS_RESOURCES
	_style_source_dialog.filters = PackedStringArray(["*.tscn,*.scn ; Godot Scene"])
	_style_source_dialog.title = "Выбрать карту со стилем"
	_style_source_dialog.file_selected.connect(func(path: String): _style_source.text = path)
	_editor.get_base_control().add_child(_style_source_dialog)

func _choose_style_source() -> void:
	_style_source_dialog.popup_centered_ratio(0.7)

func _remove_style() -> void:
	if _reject_busy():
		return
	if _style_service == null:
		_status.text = "Сервис оформления недоступен."
		return
	if _style_source.text.strip_edges().is_empty():
		var edited := _editor.get_edited_scene_root()
		if edited != null:
			_style_source.text = edited.scene_file_path
	_report.clear()
	_styling = true
	_baking = false
	var result: Dictionary = _style_service.style_scene(_style_source.text, _output.text, "", 0, true)
	_start_result(result)
	if not result.get("ok", false):
		_styling = false

func _on_style_completed(result: Dictionary) -> void:
	_styling = false
	_set_busy(false)
	if not result.get("ok", false):
		_status.text = str(result.get("error", "Не удалось создать оформление."))
		if result.has("directory"):
			_report.text = "Незавершённый результат: " + str(result["directory"])
		return
	_last_scene = str(result["scene_path"])
	_style_source.text = _last_scene
	_bake_source.text = _last_scene
	_status.text = "Копия карты без оформления создана."
	_report.text = _format_style_report(result.get("report", {}), _last_scene)
	_open.disabled = false
	_pending_open = _last_scene
	_editor.get_resource_filesystem().scan()

func _format_style_report(report: Dictionary, scene_path: String) -> String:
	var lines := PackedStringArray([scene_path, ""])
	var labels := {"buildings": "Объекты", "styled_buildings": "Оформлено объектов", "chunks": "Чанки оформления", "mesh_instances": "Меши оформления", "multimesh_instances": "Группы повторяемого декора", "decor_instances": "Элементы декора", "dynamic_lights": "Динамические источники света", "materials": "Общие материалы", "wall_triangles_styled": "Треугольники оформленных стен"}
	var counts: Dictionary = report.get("counts", report)
	for key: String in labels:
		if counts.has(key):
			lines.append("%s: %s" % [labels[key], str(counts[key])])
	lines.append("Исходная геометрия и коллизии сохранены.")
	for limitation: String in report.get("limitations", []):
		lines.append(limitation)
	lines.append("Подробности: style_report.json рядом со сценой.")
	return "\n".join(lines)
