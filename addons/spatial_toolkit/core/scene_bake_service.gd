@tool
extends Node
## Saved scene -> detached optimized copy -> fresh output; no import/network dependency.
signal progress(message: String, fraction: float)
signal completed(result: Dictionary)
var busy := false
var _cancelled := false
var _closing := false
var _directory := ""
var _working_map: Node3D

func bake_scene(source_scene_path: String, output_base: String, chunk_size_m: float = 5000.0, merge_collisions: bool = true) -> Dictionary:
	if busy:
		return {"ok": false, "error": "Уже выполняется запекание."}
	if not is_finite(chunk_size_m) or chunk_size_m < 10 or chunk_size_m > 100000:
		return {"ok": false, "error": "Размер чанка должен быть от 10 до 100000 игровых метров."}
	var source := ProjectSettings.localize_path(ProjectSettings.globalize_path(source_scene_path.strip_edges())).simplify_path()
	if not source.begins_with("res://") or source.get_extension() not in ["tscn", "scn"] or not FileAccess.file_exists(source):
		return {"ok": false, "error": "Выберите сохранённую сцену карты внутри проекта."}
	var base := ProjectSettings.localize_path(ProjectSettings.globalize_path(output_base.strip_edges())).simplify_path()
	if not base.begins_with("res://"):
		return {"ok": false, "error": "Папка результата должна быть внутри проекта."}
	busy = true
	_cancelled = false
	_closing = false
	_directory = ""
	_run.call_deferred(source, base, chunk_size_m, merge_collisions)
	return {"ok": true}

func _run(source: String, base: String, chunk_size: float, merge_collisions: bool) -> void:
	progress.emit("Чтение сохранённой карты…", 0.02)
	await get_tree().process_frame
	if _cancelled:
		_finish({"ok": false, "cancelled": true, "error": "Запекание отменено."})
		return
	var packed := ResourceLoader.load(source, "PackedScene", ResourceLoader.CACHE_MODE_IGNORE) as PackedScene
	if packed == null:
		_finish({"ok": false, "error": "Не удалось прочитать сцену карты."})
		return
	# Never enter the source instance into SceneTree: drone _ready detaches its rig.
	var instance := packed.instantiate()
	var map := instance as Node3D
	if map == null:
		instance.free()
		_finish({"ok": false, "error": "Корень карты должен быть Node3D."})
		return
	_working_map = map
	var builder_script := load("res://addons/spatial_toolkit/core/scene_bake_builder.gd") as Script
	if builder_script == null or not builder_script.can_instantiate():
		_dispose_map()
		_finish({"ok": false, "error": "Не удалось загрузить сборщик запекания."})
		return
	var builder = builder_script.new()
	builder.progress.connect(func(message: String, fraction: float): progress.emit(message, fraction))
	var built: Dictionary = await builder.build(map, chunk_size, merge_collisions, self, func(): return _cancelled or _closing)
	if not built.get("ok", false) or _cancelled or _closing:
		_dispose_map()
		_finish(built if not built.get("ok", false) else {"ok": false, "cancelled": true, "error": "Запекание отменено."})
		return
	var stem := source.get_base_dir().get_file().validate_filename()
	if stem.is_empty():
		stem = source.get_file().get_basename().validate_filename()
	var index := 1
	_directory = base.path_join(stem + "_baked_%03d" % index)
	while DirAccess.dir_exists_absolute(_directory) or FileAccess.file_exists(_directory):
		index += 1
		_directory = base.path_join(stem + "_baked_%03d" % index)
	var error := DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(_directory))
	if error != OK:
		_dispose_map()
		_finish({"ok": false, "error": "Не удалось создать папку результата: " + error_string(error)})
		return
	var report: Dictionary = built["report"]
	report["source_scene"] = source
	report["source_scene_sha256"] = FileAccess.get_sha256(source)
	var manifest: Dictionary = built["manifest"]
	manifest["source_scene"] = source
	manifest["source_scene_sha256"] = report["source_scene_sha256"]
	map.set_meta("bake_report", report)
	map.set_meta("bake_manifest_path", _directory.path_join("bake_manifest.json"))
	progress.emit("Сохранение игровой сцены…", 0.93)
	var output := PackedScene.new()
	error = output.pack(map)
	if error == OK:
		error = ResourceSaver.save(output, _directory.path_join("map.tscn"))
	_dispose_map()
	if error == OK:
		error = _write_json(_directory.path_join("bake_report.json"), report)
	if error == OK:
		error = _write_json(_directory.path_join("bake_manifest.json"), manifest)
	if error != OK:
		_finish({"ok": false, "error": "Не удалось сохранить запечённую карту: " + error_string(error)})
		return
	_finish({"ok": true, "scene_path": _directory.path_join("map.tscn"), "directory": _directory, "report": report})

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
	result["operation"] = "bake"
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
	# Plugin removal can abort a process_frame await before _run resumes.
	# This detached instance has no SceneTree owner to clean it up for us.
	_dispose_map()
