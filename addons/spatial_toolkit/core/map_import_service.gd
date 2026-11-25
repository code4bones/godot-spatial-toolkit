@tool
extends Node
## Local subprocess -> normalized payload -> native scene. No network/AI/MCP.

signal progress(message: String, fraction: float)
signal completed(result: Dictionary)

const LAUNCHER := "res://addons/spatial_toolkit/python/run.py"
const FLIGHT := preload("res://addons/spatial_toolkit/core/map_flight_module.gd")
const AppearanceProfile := preload("res://addons/spatial_toolkit/core/map_appearance_profile.gd")
const MAP_SCRIPT := "res://addons/spatial_toolkit/core/spatial_map.gd"
const ROAD_PATROLS := preload("res://addons/spatial_toolkit/runtime/road_patrols.gd")
const OUTPUT_LIMIT := 524288
const TIMEOUT_MS := 180000
var busy := false
var _process_info: Dictionary = {}
var _stdout := PackedByteArray()
var _stderr := PackedByteArray()
var _started_ms := 0
var _mode := ""
var _job_dir := ""
var _cancelled := false
var _closing := false
var _building := false
var _scene_options: Dictionary = {}
var _appearance_profile: AppearanceProfile

func check_dependencies(python_path: String) -> Dictionary:
	return _launch(python_path, PackedStringArray(["check"]), "check")

func generate_spatial_map(source_path: String, output_base: String, python_path: String,
		default_height: float, level_height: float, building_collisions: bool, daylight: bool,
		drone: bool, world_scale: float, flight_controller: String,
		appearance_profile: AppearanceProfile = null) -> Dictionary:
	return generate_map(source_path, output_base, python_path, default_height, level_height,
		building_collisions, daylight, drone, world_scale, building_collisions, "limited", 6, 5,
		flight_controller, building_collisions, appearance_profile)

func generate_map(source_path: String, output_base: String, python_path: String, default_height: float = 3.0, level_height: float = 3.0, building_collisions: bool = true, daylight: bool = true, drone: bool = true, world_scale: float = 1.0, open_windows: bool = false, window_density: String = "limited", window_limit: int = 6, window_every_n: int = 5, flight_controller: String = FLIGHT.DEFAULT_CONTROLLER, breakable_windows: bool = false, appearance_profile: AppearanceProfile = null) -> Dictionary:
	if busy:
		return {"ok": false, "error": "Уже выполняется операция."}
	if appearance_profile != null:
		var invalid := appearance_profile.validation_error()
		if not invalid.is_empty():
			return {"ok": false, "error": invalid}
		if not daylight and appearance_profile.requires_daylight():
			return {"ok": false, "error": "Включите «Материалы, небо и освещение» для фасадов и крыш из профиля."}
	if not FLIGHT.CONTROLLERS.has(flight_controller):
		return {"ok": false, "error": "Неизвестный контроллер дрона."}
	if not is_finite(default_height) or default_height <= 0 or not is_finite(level_height) or level_height <= 0:
		return {"ok": false, "error": "Высота должна быть положительным числом."}
	if not is_finite(world_scale) or world_scale < 1.0 or world_scale > 100.0:
		return {"ok": false, "error": "Масштаб мира должен быть конечным числом от 1 до 100."}
	if window_density not in ["limited", "auto", "full"]:
		return {"ok": false, "error": "Плотность окон должна быть limited, auto или full."}
	if window_limit < 1 or window_limit > 1000 or window_every_n < 1 or window_every_n > 1000:
		return {"ok": false, "error": "Лимит проёмов и шаг выбора зданий должны быть целыми числами от 1 до 1000."}
	if breakable_windows and (not building_collisions or not open_windows or window_density != "limited" or window_limit > 8):
		return {"ok": false, "error": "Разбиваемые окна требуют коллизий и до восьми проёмов на здание."}
	var source := ProjectSettings.globalize_path(source_path.strip_edges())
	if not FileAccess.file_exists(source):
		return {"ok": false, "error": "Выберите существующий файл GeoJSON."}
	if not source.get_extension().to_lower() in ["geojson", "json"]:
		return {"ok": false, "error": "Ожидается файл .geojson или .json."}
	var base := ProjectSettings.localize_path(ProjectSettings.globalize_path(output_base.strip_edges())).simplify_path()
	if not base.begins_with("res://"):
		return {"ok": false, "error": "Папка результата должна находиться внутри проекта (res://)."}
	var stem := source.get_file().get_basename().validate_filename().strip_edges().left(60)
	if stem.is_empty():
		stem = "map"
	var index := 1
	var candidate := base.path_join(stem + "_%03d" % index)
	while DirAccess.dir_exists_absolute(candidate) or FileAccess.file_exists(candidate):
		index += 1
		candidate = base.path_join(stem + "_%03d" % index)
	var error := DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(candidate))
	if error != OK:
		return {"ok": false, "error": "Не удалось создать папку результата: " + error_string(error)}
	_job_dir = candidate
	_scene_options = {"building_collisions": building_collisions, "daylight": daylight, "drone": drone, "flight_controller": flight_controller, "world_scale": world_scale, "open_windows": open_windows, "window_density": window_density, "window_limit": window_limit, "window_every_n": window_every_n, "breakable_windows": breakable_windows}
	var args := PackedStringArray(["generate", "--source", source, "--output", ProjectSettings.globalize_path(candidate), "--default-height", str(default_height), "--level-height", str(level_height), "--world-scale", str(world_scale), "--window-density", window_density, "--window-limit", str(window_limit), "--window-every-n", str(window_every_n)])
	if open_windows:
		args.append("--open-windows")
	if breakable_windows:
		args.append("--breakable-windows")
	var result := _launch(python_path, args, "generate")
	if not result.get("ok", false):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(candidate))
	else:
		_appearance_profile = appearance_profile
	return result

func _launch(python_path: String, arguments: PackedStringArray, mode: String) -> Dictionary:
	if busy:
		return {"ok": false, "error": "Уже выполняется операция."}
	var executable := python_path.strip_edges()
	if executable.is_empty():
		return {"ok": false, "error": "Укажите Python 3.10 или новее."}
	if not FileAccess.file_exists(LAUNCHER):
		return {"ok": false, "error": "Не найден локальный обработчик GeoJSON."}
	var args := PackedStringArray(["-X", "utf8", "-B", ProjectSettings.globalize_path(LAUNCHER)])
	args.append_array(arguments)
	_process_info = OS.execute_with_pipe(executable, args, false)
	if _process_info.is_empty():
		return {"ok": false, "error": "Не удалось запустить Python. Проверьте путь к интерпретатору."}
	_mode = mode
	_stdout.clear()
	_stderr.clear()
	_started_ms = Time.get_ticks_msec()
	_cancelled = false
	_closing = false
	busy = true
	progress.emit("Проверка зависимостей…" if mode == "check" else "Обработка GeoJSON…", 0.05)
	set_process(true)
	return {"ok": true}

func _process(_delta: float) -> void:
	if _process_info.is_empty() or _building:
		return
	_read_pipes()
	if _stdout.size() > OUTPUT_LIMIT or _stderr.size() > OUTPUT_LIMIT:
		_stop_process()
		_finish({"ok": false, "error": "Слишком большой диагностический ответ обработчика."})
		return
	if Time.get_ticks_msec() - _started_ms > TIMEOUT_MS:
		_stop_process()
		_finish({"ok": false, "error": "Обработка превысила 180 секунд. Попробуйте меньший участок."})
		return
	if OS.is_process_running(int(_process_info["pid"])):
		return
	_read_pipes()
	var exit_code := OS.get_process_exit_code(int(_process_info["pid"]))
	_close_pipes()
	var parser := JSON.new()
	if parser.parse(_stdout.get_string_from_utf8().strip_edges()) != OK or not parser.data is Dictionary:
		_finish({"ok": false, "error": "Некорректный ответ Python (код %d). Нужны Python 3.10+, pyproj и GEOS 3.10+.\n%s" % [exit_code, _stderr.get_string_from_utf8().strip_edges().left(2000)]})
		return
	var response: Dictionary = parser.data
	if exit_code != 0 or not response.get("ok", false):
		_finish({"ok": false, "error": str(response.get("error", "Ошибка обработки GeoJSON"))})
		return
	if _mode == "check":
		_finish(response)
		return
	_building = true
	_build_scene(response)

func _read_pipes() -> void:
	for key in ["stdio", "stderr"]:
		var pipe: FileAccess = _process_info.get(key)
		if pipe == null or not pipe.is_open():
			continue
		for i in 8:
			var chunk := pipe.get_buffer(4096)
			if chunk.is_empty():
				break
			if key == "stdio":
				_stdout.append_array(chunk)
			else:
				_stderr.append_array(chunk)

func _build_scene(response: Dictionary) -> void:
	progress.emit("Создание сцены…", 0.55)
	var files: Dictionary = response.get("files", {})
	var mesh_path := str(files.get("meshes", ""))
	var expected := ProjectSettings.globalize_path(_job_dir).simplify_path().trim_suffix("/") + "/"
	if mesh_path.is_empty() or not mesh_path.simplify_path().begins_with(expected):
		_finish({"ok": false, "error": "Обработчик вернул путь вне папки результата."})
		return
	var parser := JSON.new()
	var file := FileAccess.open(mesh_path, FileAccess.READ)
	if file == null or parser.parse(file.get_as_text()) != OK or not parser.data is Dictionary:
		_finish({"ok": false, "error": "Не удалось прочитать подготовленную геометрию."})
		return
	var script := load(MAP_SCRIPT) as Script
	if script == null or not script.can_instantiate():
		_finish({"ok": false, "error": "Не удалось загрузить генератор сцены."})
		return
	var world := Node3D.new()
	world.set_script(script)
	world.name = "SpatialMap"
	add_child(world)
	var report: Dictionary = response.get("report", {})
	var built: Dictionary = await world.build_from_data(parser.data, report, _scene_options)
	if _cancelled or _closing:
		world.queue_free()
		if not _closing:
			_finish({"ok": false, "cancelled": true, "error": "Создание карты отменено."})
		return
	if not built.get("success", false):
		world.queue_free()
		_finish({"ok": false, "error": str(built.get("error", "Не удалось создать сцену"))})
		return
	var patrol_count := await ROAD_PATROLS.add_from_file(world, _job_dir.path_join(ROAD_PATROLS.MODEL_FILE), true)
	if _cancelled or _closing:
		world.queue_free()
		if not _closing:
			_finish({"ok": false, "cancelled": true, "error": "Создание карты отменено."})
		return
	report.get("modules", {})["road_patrols"] = {"robots": patrol_count}
	if _appearance_profile != null:
		progress.emit("Применение профиля оформления…", 0.86)
		report.get("modules", {})["appearance_profile"] = _appearance_profile.apply_to_new_map(world)
	var report_saved := _save_native_report(files, report, expected)
	if not report_saved.get("ok", false):
		world.queue_free()
		_finish(report_saved)
		return
	world.get_node("Generated").set_meta("generation_report", report)
	progress.emit("Сохранение карты…", 0.9)
	var scene_path := _job_dir.path_join("map.tscn")
	if FileAccess.file_exists(scene_path):
		world.queue_free()
		_finish({"ok": false, "error": "Файл сцены уже существует."})
		return
	var packed := PackedScene.new()
	var error := packed.pack(world)
	if error == OK:
		error = ResourceSaver.save(packed, scene_path)
	world.queue_free()
	if error != OK:
		_finish({"ok": false, "error": "Не удалось сохранить сцену: " + error_string(error)})
		return
	_finish({"ok": true, "scene_path": scene_path, "directory": _job_dir, "report": report, "files": files})

func _save_native_report(files: Dictionary, report: Dictionary, expected_directory: String) -> Dictionary:
	var path := str(files.get("report", "")).simplify_path()
	if path.is_empty() or not path.begins_with(expected_directory):
		return {"ok": false, "error": "Путь отчёта находится вне папки результата."}
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return {"ok": false, "error": "Не удалось прочитать полный отчёт импорта."}
	var parser := JSON.new()
	var parsed := parser.parse(file.get_as_text())
	file.close()
	if parsed != OK or not parser.data is Dictionary:
		return {"ok": false, "error": "Полный отчёт импорта содержит некорректный JSON."}
	var full: Dictionary = parser.data
	var collisions: Dictionary = report.get("collisions", {})
	full["collisions"] = collisions
	full["modules"] = report.get("modules", {})
	var settings: Dictionary = full.get("settings", {})
	for key in ["building_collisions", "daylight", "drone", "open_windows"]:
		settings[key] = bool(_scene_options.get(key, key != "open_windows"))
	settings["world_scale"] = float(_scene_options.get("world_scale", 1.0))
	settings["flight_controller"] = _scene_options.get("flight_controller", FLIGHT.DEFAULT_CONTROLLER)
	settings["window_density"] = str(_scene_options.get("window_density", "limited"))
	settings["window_limit"] = int(_scene_options.get("window_limit", 6))
	settings["window_every_n"] = int(_scene_options.get("window_every_n", 5))
	full["settings"] = settings
	report["settings"] = settings
	var limitations: Array = full.get("limitations", [])
	if collisions.get("enabled", false):
		limitations.erase("No collision, navigation or road lane markings")
		limitations.append("Static building surface collisions only; no ground/road collisions, navigation or road lane markings")
	full["limitations"] = limitations
	report["limitations"] = limitations
	file = FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return {"ok": false, "error": "Не удалось сохранить отчёт коллизий."}
	file.store_string(JSON.stringify(full, "  ") + "\n")
	file.flush()
	var error := file.get_error()
	file.close()
	if error != OK:
		return {"ok": false, "error": "Ошибка записи отчёта коллизий: " + error_string(error)}
	return {"ok": true}

func cancel() -> void:
	if not busy:
		return
	_cancelled = true
	if not _building:
		_stop_process()
		_finish({"ok": false, "cancelled": true, "error": "Обработка отменена."})

func shutdown() -> void:
	_closing = true
	_cancelled = true
	_stop_process()
	set_process(false)

func _stop_process() -> void:
	if not _process_info.is_empty() and OS.is_process_running(int(_process_info["pid"])):
		OS.kill(int(_process_info["pid"]))
	_close_pipes()

func _close_pipes() -> void:
	for key in ["stdio", "stderr"]:
		var pipe: FileAccess = _process_info.get(key)
		if pipe != null and pipe.is_open():
			pipe.close()
	_process_info.clear()

func _finish(result: Dictionary) -> void:
	busy = false
	_building = false
	_appearance_profile = null
	set_process(false)
	result["operation"] = _mode
	if not result.get("ok", false) and not _job_dir.is_empty() and _mode == "generate":
		result["directory"] = _job_dir
	if not _closing:
		completed.emit(result)
