@tool
extends Node
## Saved native map -> detached style overlay -> separate numbered scene copy.
signal progress(message: String, fraction: float)
signal completed(result: Dictionary)
const ENGINE_PATH := "res://addons/spatial_toolkit/core/world_style_engine.gd"
const DEFAULT_PRESET := "res://addons/spatial_toolkit/styles/alien-tech-v1.style.json"
var busy := false
var _cancelled := false
var _closing := false
var _directory := ""
var _working_map: Node3D

func style_scene(source_path: String, output_base: String, preset_path: String = DEFAULT_PRESET, seed_override: int = 42042, remove_style: bool = false) -> Dictionary:
	if busy:
		return {"ok": false, "error": "Уже выполняется стилизация."}
	var source := _project_path(source_path)
	if not source.begins_with("res://") or source.get_extension() not in ["tscn", "scn"] or not FileAccess.file_exists(source):
		return {"ok": false, "error": "Выберите сохранённую сцену карты внутри проекта."}
	var base := _project_path(output_base)
	if not base.begins_with("res://"):
		return {"ok": false, "error": "Папка результата должна быть внутри проекта."}
	var spec: Dictionary = {}
	if not remove_style:
		var preset := _project_path(preset_path)
		if not preset.begins_with("res://") or not FileAccess.file_exists(preset):
			return {"ok": false, "error": "Не найден локальный пресет стиля."}
		var parser := JSON.new()
		if parser.parse(FileAccess.get_file_as_string(preset)) != OK or not parser.data is Dictionary:
			return {"ok": false, "error": "Пресет должен содержать JSON object."}
		spec = parser.data.duplicate(true)
		spec["seed"] = seed_override
	busy = true
	_cancelled = false
	_closing = false
	_directory = ""
	_run.call_deferred(source, base, spec, remove_style)
	return {"ok": true}

func _run(source: String, base: String, spec: Dictionary, remove_style: bool) -> void:
	progress.emit("Чтение сохранённой карты…", 0.02)
	await get_tree().process_frame
	if _cancelled:
		_finish({"ok": false, "cancelled": true, "error": "Стилизация отменена."})
		return
	var engine_script := load(ENGINE_PATH) as Script
	if engine_script == null or not engine_script.can_instantiate():
		_finish({"ok": false, "error": "Не удалось загрузить World Style Engine."})
		return
	var engine = engine_script.new()
	if not remove_style:
		var errors: Array = engine.validate_spec(spec)
		if not errors.is_empty():
			_finish({"ok": false, "error": "Некорректный пресет: " + "; ".join(errors)})
			return
	var packed := ResourceLoader.load(source, "PackedScene", ResourceLoader.CACHE_MODE_IGNORE) as PackedScene
	if packed == null:
		_finish({"ok": false, "error": "Не удалось прочитать сцену карты."})
		return
	var instance := packed.instantiate()
	_working_map = instance as Node3D
	if _working_map == null:
		instance.free()
		_finish({"ok": false, "error": "Корень карты должен быть Node3D."})
		return
	# Do not enter the source into SceneTree: drone _ready changes rig topology.
	engine.progress.connect(func(message: String, fraction: float): progress.emit(message, fraction))
	var built: Dictionary
	if remove_style:
		built = engine.remove(_working_map)
	else:
		built = await engine.apply(_working_map, spec, self, func(): return _cancelled or _closing)
	if not built.get("ok", false) or _cancelled or _closing:
		_dispose_map()
		_finish(built if not built.get("ok", false) else {"ok": false, "cancelled": true, "error": "Стилизация отменена."})
		return
	var report: Dictionary = built.get("report", {})
	var manifest: Dictionary = built.get("manifest", {})
	var provenance := {"source_scene": source, "source_scene_sha256": FileAccess.get_sha256(source),
		"operation": "remove_style" if remove_style else "apply_style", "generator_version": "0.7.0"}
	report.merge(provenance, true)
	manifest.merge(provenance, true)
	manifest["style_spec"] = spec
	var stem := source.get_base_dir().get_file().validate_filename()
	if stem.is_empty():
		stem = source.get_file().get_basename().validate_filename()
	var suffix := "_unstyled_" if remove_style else "_styled_"
	var index := 1
	_directory = base.path_join(stem + suffix + "%03d" % index)
	while DirAccess.dir_exists_absolute(_directory) or FileAccess.file_exists(_directory):
		index += 1
		_directory = base.path_join(stem + suffix + "%03d" % index)
	var error := DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(_directory))
	if error != OK:
		_dispose_map()
		_finish({"ok": false, "error": "Не удалось создать папку результата: " + error_string(error)})
		return
	var layer := _working_map.get_node_or_null("StyleLayer")
	if layer != null and not remove_style:
		layer.set_meta("style_manifest_path", _directory.path_join("style_manifest.json"))
	progress.emit("Сохранение стилизованной карты…", 0.95)
	var output := PackedScene.new()
	error = output.pack(_working_map)
	if error == OK:
		error = ResourceSaver.save(output, _directory.path_join("map.tscn"))
	_dispose_map()
	if error == OK:
		error = _write_json(_directory.path_join("style_report.json"), report)
	if error == OK:
		error = _write_json(_directory.path_join("style_manifest.json"), manifest)
	if error == OK and not remove_style:
		error = _write_json(_directory.path_join("style_spec.json"), spec)
	if error != OK:
		_finish({"ok": false, "error": "Не удалось сохранить стиль: " + error_string(error)})
		return
	_finish({"ok": true, "scene_path": _directory.path_join("map.tscn"), "directory": _directory, "report": report})

func _project_path(path: String) -> String:
	return ProjectSettings.localize_path(ProjectSettings.globalize_path(path.strip_edges())).simplify_path()

func _write_json(path: String, value: Dictionary) -> Error:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return FileAccess.get_open_error()
	file.store_string(JSON.stringify(value, "  ") + "\n")
	file.flush()
	return file.get_error()

func cancel() -> void:
	_cancelled = true

func shutdown() -> void:
	_closing = true
	_cancelled = true

func _finish(result: Dictionary) -> void:
	busy = false
	result["operation"] = "style"
	if not result.get("ok", false) and not _directory.is_empty():
		result["directory"] = _directory
	if not _closing:
		completed.emit(result)

func _dispose_map() -> void:
	if is_instance_valid(_working_map):
		_working_map.free()
	_working_map = null

func _exit_tree() -> void:
	_closing = true
	_cancelled = true
	_dispose_map()
