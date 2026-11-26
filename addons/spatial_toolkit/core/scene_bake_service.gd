@tool
extends Node
## Saved scene or world index -> detached optimized copy -> fresh output.
signal progress(message: String, fraction: float)
signal completed(result: Dictionary)

const Localization := preload("res://addons/spatial_toolkit/ui/editor_localization.gd")
const ImportService := preload("res://addons/spatial_toolkit/core/map_import_service.gd")
const Settings := preload("res://addons/spatial_toolkit/core/spatial_project_settings.gd")

var busy := false
var _cancelled := false
var _closing := false
var _directory := ""
var _staging_directory := ""
var _working_map: Node3D
var _assembler: RefCounted
var _operation := "bake"
var _python_path := ""
var _data_worker: ImportService
var _data_result: Dictionary = {}
var _window_detail := false

func bake_scene(source_scene_path: String, output_base: String, chunk_size_m: float = 5000.0,
		merge_collisions: bool = true) -> Dictionary:
	var error := _validate_start(output_base, chunk_size_m)
	if not error.is_empty():
		return {"ok": false, "error": error}
	var source := _project_path(source_scene_path)
	if not source.begins_with("res://") or source.get_extension() not in ["tscn", "scn"] or not FileAccess.file_exists(source):
		return {"ok": false, "error": Localization.translate("Select a saved map scene inside the project.")}
	_begin("bake")
	_run_scene.call_deferred(source, _project_path(output_base), chunk_size_m, merge_collisions)
	return {"ok": true}

func bake_world(manifest_path: String, output_base: String, chunk_size_m: float = 5000.0,
		merge_collisions: bool = true, add_drone: bool = true, python_path: String = "",
		window_detail: bool = false, drone_model: PackedScene = null) -> Dictionary:
	var error := _validate_start(output_base, chunk_size_m)
	if not error.is_empty():
		return {"ok": false, "error": error}
	var source := _project_path(manifest_path)
	if not source.begins_with("res://") or source.get_file() != "world.json" or not FileAccess.file_exists(source):
		return {"ok": false, "error": Localization.translate("Select a saved world's world.json inside the project.")}
	_begin("bake_world")
	_python_path = python_path if not python_path.is_empty() else Settings.python_executable()
	_window_detail = window_detail
	_run_world.call_deferred(source, _project_path(output_base), chunk_size_m, merge_collisions, add_drone, drone_model)
	return {"ok": true}

func _project_path(path: String) -> String:
	return ProjectSettings.localize_path(ProjectSettings.globalize_path(path.strip_edges())).simplify_path()

func _validate_start(output_base: String, chunk_size_m: float) -> String:
	if busy:
		return Localization.translate("A bake is already running.")
	if not is_finite(chunk_size_m) or chunk_size_m < 10 or chunk_size_m > 100000:
		return Localization.translate("The chunk size must be between 10 and 100,000 game metres.")
	if output_base.strip_edges().is_empty() or not _project_path(output_base).begins_with("res://"):
		return Localization.translate("The output folder must be inside the project.")
	return ""

func _begin(operation: String) -> void:
	busy = true
	_cancelled = false
	_closing = false
	_directory = ""
	_staging_directory = ""
	_operation = operation
	_window_detail = false

func _run_scene(source: String, base: String, chunk_size: float, merge_collisions: bool) -> void:
	progress.emit(Localization.translate("Reading the saved map…"), 0.02)
	await get_tree().process_frame
	if _interrupted():
		_finish(_cancel_result())
		return
	var fingerprint := FileAccess.get_sha256(source)
	var packed := ResourceLoader.load(source, "PackedScene", ResourceLoader.CACHE_MODE_IGNORE) as PackedScene
	if packed == null:
		_finish({"ok": false, "error": Localization.translate("Could not read the map scene.")})
		return
	# Detached instances keep the authored chase-camera rig intact.
	var instance := packed.instantiate()
	_working_map = instance as Node3D
	if _working_map == null:
		instance.free()
		_finish({"ok": false, "error": Localization.translate("The map root must be a Node3D.")})
		return
	if fingerprint != FileAccess.get_sha256(source):
		_finish({"ok": false, "error": Localization.translate("The source scene changed while being loaded. Retry the bake.")})
		return
	var stem := source.get_base_dir().get_file().validate_filename()
	if stem.is_empty():
		stem = source.get_file().get_basename().validate_filename()
	await _build_and_save(base, stem, chunk_size, merge_collisions,
		{"source_scene": source, "source_scene_sha256": fingerprint}, false)

func _run_world(source: String, base: String, chunk_size: float, merge_collisions: bool,
		add_drone: bool, drone_model: PackedScene) -> void:
	var assembler_script := load("res://addons/spatial_toolkit/core/world_bake_assembler.gd") as Script
	if assembler_script == null or not assembler_script.can_instantiate():
		_finish({"ok": false, "error": Localization.translate("Could not load the world assembler.")})
		return
	_assembler = assembler_script.new()
	_assembler.connect("progress", func(message: String, fraction: float) -> void:
		progress.emit(message, 0.3 * clampf(fraction, 0.0, 1.0)))
	var assembled: Dictionary = await _assembler.call("assemble", source, self, _interrupted, add_drone, drone_model)
	if assembled.get("ok", false):
		_working_map = assembled["map"]
	if not assembled.get("ok", false) or _interrupted():
		_finish(assembled if not assembled.get("ok", false) else _cancel_result())
		return
	_assembler = null
	await _build_and_save(base, source.get_base_dir().get_file().validate_filename(), chunk_size,
		merge_collisions, assembled["source"], true)

func _build_and_save(base: String, stem: String, chunk_size: float, merge_collisions: bool,
		source_info: Dictionary, binary: bool) -> void:
	var builder_script := load("res://addons/spatial_toolkit/core/scene_bake_builder.gd") as Script
	if builder_script == null or not builder_script.can_instantiate():
		_finish({"ok": false, "error": Localization.translate("Could not load the scene bake builder.")})
		return
	var builder = builder_script.new()
	builder.progress.connect(func(message: String, fraction: float) -> void:
		progress.emit(message, 0.3 + fraction * 0.6 if binary else fraction))
	var built: Dictionary = await builder.build(_working_map, chunk_size, merge_collisions, self,
		_interrupted, _window_detail)
	if not built.get("ok", false) or _interrupted():
		_finish(built if not built.get("ok", false) else _cancel_result())
		return
	var error := DirAccess.make_dir_recursive_absolute(base)
	if error != OK:
		_finish({"ok": false, "error": Localization.translate("Could not create the output folder: %s") % error_string(error)})
		return
	var index := 1
	_directory = base.path_join(stem + "_baked_%03d" % index)
	while DirAccess.dir_exists_absolute(_directory) or FileAccess.file_exists(_directory):
		index += 1
		_directory = base.path_join(stem + "_baked_%03d" % index)
	_staging_directory = base.path_join(".spatial_bake_%d_%d" % [OS.get_process_id(), Time.get_ticks_usec()])
	error = DirAccess.make_dir_absolute(_staging_directory)
	if error != OK:
		_finish({"ok": false, "error": Localization.translate("Could not create the temporary output folder: %s") % error_string(error)})
		return
	var report: Dictionary = built["report"]
	report.merge(source_info, true)
	var manifest: Dictionary = built["manifest"]
	manifest.merge(source_info, true)
	if _window_detail:
		error = _save_window_detail(built, report, manifest)
		if error != OK:
			_finish({"ok": false, "error": Localization.translate("Could not save near-window details: %s") % error_string(error)})
			return
	if binary:
		var data := await _export_world_data(source_info["source_world"], built["world_features"])
		if _interrupted():
			_finish(_cancel_result())
			return
		if data.get("ok", false):
			var data_path := _directory.path_join("world_data.json")
			report["world_data_path"] = data_path
			manifest["world_data_path"] = data_path
			report["world_data_counts"] = {"roads": int(data.get("road_count", 0)),
				"buildings": int(data.get("building_count", 0))}
			_working_map.set_meta("world_data_path", data_path)
		else:
			report["world_data_error"] = str(data.get("error", "Could not save world data."))
	_working_map.set_meta("bake_report", report)
	_working_map.set_meta("bake_manifest_path", _directory.path_join("bake_manifest.json"))
	var filename := "map.scn" if binary else "map.tscn"
	progress.emit(Localization.translate("Saving the game scene…"), 0.93)
	await get_tree().process_frame
	if _interrupted():
		_finish(_cancel_result())
		return
	var output := PackedScene.new()
	error = output.pack(_working_map)
	if error == OK:
		error = ResourceSaver.save(output, _staging_directory.path_join(filename))
	_dispose_map()
	if error == OK and not _interrupted():
		progress.emit(Localization.translate("Saving the report and OSM references…"), 0.97)
		error = _write_json(_staging_directory.path_join("bake_report.json"), report)
	if error == OK and not _interrupted():
		error = _write_json(_staging_directory.path_join("bake_manifest.json"), manifest, binary)
	if _interrupted():
		_finish(_cancel_result())
		return
	if not _sources_unchanged(source_info):
		_finish({"ok": false, "error": Localization.translate("The source scenes or world index changed. Retry the bake.")})
		return
	if error == OK:
		if DirAccess.dir_exists_absolute(_directory) or FileAccess.file_exists(_directory):
			error = ERR_ALREADY_EXISTS
		else:
			error = DirAccess.rename_absolute(_staging_directory, _directory)
	if error != OK:
		_finish({"ok": false, "error": Localization.translate("Could not save the baked map: %s") % error_string(error)})
		return
	_staging_directory = ""
	progress.emit(Localization.translate("The game scene was saved."), 1.0)
	_finish({"ok": true, "scene_path": _directory.path_join(filename), "directory": _directory, "report": report})

func _save_window_detail(built: Dictionary, report: Dictionary, manifest: Dictionary) -> Error:
	var transforms: Array[Transform3D] = built["window_transforms"]
	report["window_detail_count"] = transforms.size()
	if transforms.is_empty():
		return OK
	var script := load("res://addons/spatial_toolkit/runtime/baked_window_detail.gd") as Script
	# The editor packs the runtime script without executing it.
	if script == null or script.get_instance_base_type() != &"Node3D":
		return ERR_INVALID_DATA
	var final_path := _directory.path_join("window_detail.bin")
	var file := FileAccess.open(_staging_directory.path_join("window_detail.bin"), FileAccess.WRITE)
	if file == null:
		return FileAccess.get_open_error()
	var payload := {"version": 1, "transforms": transforms}
	var styles: Array[SpatialWindowStyle] = built["window_styles"]
	if styles.size() > 1:
		payload["version"] = 2
		payload["style_ids"] = built["window_style_ids"]
	file.store_var(payload, false)
	file.flush()
	var error := file.get_error()
	file.close()
	if error != OK:
		return error
	var detail := Node3D.new()
	detail.set_script(script)
	detail.name = "BakedWindowDetail"
	detail.set("data_path", final_path)
	if styles.size() > 1:
		detail.set("window_styles", styles)
		report["window_style_count"] = styles.size() - 1
	_working_map.add_child(detail)
	detail.owner = _working_map
	report["window_detail_path"] = final_path
	manifest["window_detail_path"] = final_path
	report["after"]["nodes"] = int(report["after"]["nodes"]) + 1
	return OK

func _export_world_data(source: String, features: Dictionary) -> Dictionary:
	progress.emit(Localization.translate("Saving roads and building footprints…"), 0.91)
	if _interrupted():
		return _cancel_result()
	var selector_path := _staging_directory.path_join("bake_features.json")
	var error := _write_json(selector_path, features, true)
	if error != OK:
		return {"ok": false, "error": Localization.translate("Could not prepare the list of world features: %s") % error_string(error)}
	_data_result = {}
	_data_worker = ImportService.new()
	add_child(_data_worker)
	_data_worker.completed.connect(func(result: Dictionary): _data_result = result)
	var started := _data_worker.export_world_data(_python_path, source, selector_path,
		_staging_directory.path_join("world_data.json"))
	if started.get("ok", false):
		while _data_result.is_empty() and not _interrupted():
			await get_tree().process_frame
	else:
		_data_result = started
	_dispose_data_worker()
	DirAccess.remove_absolute(selector_path)
	if not _data_result.get("ok", false):
		DirAccess.remove_absolute(_staging_directory.path_join("world_data.json"))
	return _data_result

func _dispose_data_worker() -> void:
	if is_instance_valid(_data_worker):
		_data_worker.shutdown()
		_data_worker.queue_free()
	_data_worker = null

func _sources_unchanged(info: Dictionary) -> bool:
	if info.has("source_world"):
		if FileAccess.get_sha256(info["source_world"]) != info.get("source_world_sha256", ""):
			return false
		for source: Dictionary in info.get("source_scenes", []):
			if FileAccess.get_sha256(source["path"]) != source.get("sha256", ""):
				return false
		return true
	return FileAccess.get_sha256(info["source_scene"]) == info.get("source_scene_sha256", "")

func _write_json(path: String, value: Dictionary, compact: bool = false) -> Error:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return FileAccess.get_open_error()
	file.store_string(JSON.stringify(value, "" if compact else "  ") + "\n")
	file.flush()
	return file.get_error()

func _interrupted() -> bool:
	return _cancelled or _closing

func _cancel_result() -> Dictionary:
	return {"ok": false, "cancelled": true, "error": Localization.translate("Bake cancelled.")}

func cancel() -> void:
	_cancelled = true
	if is_instance_valid(_data_worker):
		_data_worker.cancel()

func shutdown() -> void:
	_closing = true
	_cancelled = true

func _finish(result: Dictionary) -> void:
	_dispose_data_worker()
	_dispose_map()
	if _assembler != null:
		_assembler.call("dispose")
		_assembler = null
	busy = false
	result["operation"] = _operation
	if not result.get("ok", false) and not _staging_directory.is_empty():
		result["directory"] = _staging_directory
	if not _closing:
		completed.emit(result)

func _dispose_map() -> void:
	if is_instance_valid(_working_map):
		_working_map.free()
	_working_map = null

func _exit_tree() -> void:
	shutdown()
	_dispose_data_worker()
	_dispose_map()
	if _assembler != null:
		_assembler.call("dispose")
		_assembler = null
