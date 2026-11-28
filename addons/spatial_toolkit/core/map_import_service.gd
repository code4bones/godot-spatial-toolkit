@tool
extends Node
## Local subprocess -> normalized payload -> native scene. No network/AI/MCP.

signal progress(message: String, fraction: float)
signal completed(result: Dictionary)

const Localization := preload("res://addons/spatial_toolkit/ui/editor_localization.gd")
const LAUNCHER := "res://addons/spatial_toolkit/python/run.py"
const FLIGHT := preload("res://addons/spatial_toolkit/core/map_flight_module.gd")
const AppearanceProfile := preload("res://addons/spatial_toolkit/core/map_appearance_profile.gd")
const ProjectDefaults := preload("res://addons/spatial_toolkit/core/spatial_project_settings.gd")
const MAP_SCRIPT := "res://addons/spatial_toolkit/core/spatial_map.gd"
const ROAD_PATROLS := preload("res://addons/spatial_toolkit/runtime/road_patrols.gd")
const OUTPUT_LIMIT := 524288
const TIMEOUT_MS := 180000
const PROGRESS_PREFIX := "SPATIAL_PROGRESS "
const PHASE_LABELS := {
	"sources": "Checking world sources",
	"merge": "Merging GeoJSON sources",
	"validate": "Validating GeoJSON data",
	"project": "Projecting features",
	"overlap": "Checking building overlaps",
	"geometry": "Preparing geometry",
	"topology": "Building the road network",
	"write": "Writing prepared data",
	"objects": "Creating scene objects",
	"facades": "Styling buildings",
	"surfaces": "Styling land, roads, and water",
	"floors": "Styling floors",
	"foundations": "Styling foundations",
}
var busy := false
var _process_info: Dictionary = {}
var _stdout := PackedByteArray()
var _stderr := PackedByteArray()
var _stderr_offset := 0
var _mesh_reader: Thread
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

func export_world_data(python_path: String, manifest_path: String, features_path: String,
		output_path: String) -> Dictionary:
	return _launch(python_path, PackedStringArray(["world-data",
		"--world", ProjectSettings.globalize_path(manifest_path),
		"--bake-features", ProjectSettings.globalize_path(features_path),
		"--output", ProjectSettings.globalize_path(output_path)]), "world_data")

func generate_spatial_map(source_path: String, output_base: String, python_path: String,
		default_height: float, level_height: float, building_collisions: bool, daylight: bool,
		drone: bool, world_scale: float, flight_controller: String,
		appearance_profile: AppearanceProfile = null, local_origin: Variant = null,
		additional_sources: PackedStringArray = PackedStringArray()) -> Dictionary:
	return generate_map(source_path, output_base, python_path, default_height, level_height,
		building_collisions, daylight, drone, world_scale, building_collisions, "limited", 6, 5,
		flight_controller, building_collisions, appearance_profile, local_origin, additional_sources)

func generate_map(source_path: String, output_base: String, python_path: String,
		default_height: float = 3.0, level_height: float = 3.0, building_collisions: bool = true,
		daylight: bool = true, drone: bool = true, world_scale: float = 1.0, open_windows: bool = false,
		window_density: String = "limited", window_limit: int = 6, window_every_n: int = 5,
		flight_controller: String = FLIGHT.DEFAULT_CONTROLLER, breakable_windows: bool = false,
		appearance_profile: AppearanceProfile = null, local_origin: Variant = null,
		additional_sources: PackedStringArray = PackedStringArray()) -> Dictionary:
	if busy:
		return {"ok": false, "error": Localization.translate("An operation is already running.")}
	if local_origin != null and (not local_origin is Dictionary
			or not _valid_origin_coordinate(local_origin.get("longitude"), 180.0)
			or not _valid_origin_coordinate(local_origin.get("latitude"), 90.0)):
		return {"ok": false, "error": Localization.translate("The reference origin must have valid WGS84 longitude and latitude.")}
	if appearance_profile != null:
		var invalid := appearance_profile.validation_error()
		if not invalid.is_empty():
			return {"ok": false, "error": invalid}
		if not daylight and appearance_profile.requires_daylight():
			return {"ok": false, "error": Localization.translate("Enable materials, sky, and lighting to use the profile's facades and roofs.")}
	if not FLIGHT.CONTROLLERS.has(flight_controller):
		return {"ok": false, "error": Localization.translate("Unknown drone controller.")}
	if not is_finite(default_height) or default_height <= 0 or not is_finite(level_height) or level_height <= 0:
		return {"ok": false, "error": Localization.translate("The height must be a positive number.")}
	if not is_finite(world_scale) or world_scale < 1.0 or world_scale > 100.0:
		return {"ok": false, "error": Localization.translate("The world scale must be a finite number between 1 and 100.")}
	if window_density not in ["limited", "auto", "full"]:
		return {"ok": false, "error": Localization.translate("Window density must be limited, auto, or full.")}
	if window_limit < 1 or window_limit > 1000 or window_every_n < 1 or window_every_n > 1000:
		return {"ok": false, "error": Localization.translate("The aperture limit and building interval must be integers between 1 and 1,000.")}
	if breakable_windows and (not building_collisions or not open_windows or window_density != "limited" or window_limit > 8):
		return {"ok": false, "error": Localization.translate("Breakable windows require collisions and at most eight apertures per building.")}
	var source := ProjectSettings.globalize_path(source_path.strip_edges()).simplify_path()
	if not FileAccess.file_exists(source):
		return {"ok": false, "error": Localization.translate("Select an existing GeoJSON file.")}
	if not source.get_extension().to_lower() in ["geojson", "json"]:
		return {"ok": false, "error": Localization.translate("A .geojson or .json file is required.")}
	var merge_paths := PackedStringArray()
	for path in additional_sources:
		var extra := ProjectSettings.globalize_path(path.strip_edges()).simplify_path()
		if extra == source or extra in merge_paths:
			continue
		if not FileAccess.file_exists(extra) or extra.get_extension().to_lower() not in ["geojson", "json"]:
			return {"ok": false, "error": Localization.translate("Select an existing .geojson or .json file: %s") % extra}
		merge_paths.append(extra)
	var base := ProjectSettings.localize_path(ProjectSettings.globalize_path(output_base.strip_edges())).simplify_path()
	if not base.begins_with("res://"):
		return {"ok": false, "error": Localization.translate("The output folder must be inside the project (res://).")}
	var stem := source.get_file().get_basename().validate_filename().strip_edges().left(60)
	if stem.is_empty():
		stem = "map"
	if not merge_paths.is_empty():
		stem += "_merged"
	var index := 1
	var candidate := base.path_join(stem + "_%03d" % index)
	while DirAccess.dir_exists_absolute(candidate) or FileAccess.file_exists(candidate):
		index += 1
		candidate = base.path_join(stem + "_%03d" % index)
	var error := DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(candidate))
	if error != OK:
		return {"ok": false, "error": Localization.translate("Could not create the output folder: %s") % error_string(error)}
	_job_dir = candidate
	_scene_options = {"building_collisions": building_collisions, "daylight": daylight, "drone": drone, "flight_controller": flight_controller, "world_scale": world_scale, "open_windows": open_windows, "window_density": window_density, "window_limit": window_limit, "window_every_n": window_every_n, "breakable_windows": breakable_windows}
	var args := PackedStringArray(["generate", "--source", source, "--output", ProjectSettings.globalize_path(candidate), "--default-height", str(default_height), "--level-height", str(level_height), "--world-scale", str(world_scale), "--window-density", window_density, "--window-limit", str(window_limit), "--window-every-n", str(window_every_n)])
	args.append_array(PackedStringArray(["--osm-rules", JSON.stringify(ProjectDefaults.osm_rules())]))
	if open_windows:
		var aperture_options := ProjectDefaults.aperture_options()
		args.append_array(PackedStringArray(["--open-windows", "--aperture-options", JSON.stringify(aperture_options)]))
	if breakable_windows:
		args.append("--breakable-windows")
	if local_origin != null:
		args.append_array(PackedStringArray([
			"--origin-longitude=" + JSON.stringify(local_origin["longitude"], "", true, true),
			"--origin-latitude=" + JSON.stringify(local_origin["latitude"], "", true, true),
		]))
	for extra in merge_paths:
		args.append_array(PackedStringArray(["--merge-source", extra]))
	var result := _launch(python_path, args, "generate")
	if not result.get("ok", false):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(candidate))
	else:
		_appearance_profile = appearance_profile
	return result

static func _valid_origin_coordinate(value: Variant, limit: float) -> bool:
	return (value is float or value is int) and is_finite(float(value)) and absf(float(value)) <= limit

func _launch(python_path: String, arguments: PackedStringArray, mode: String) -> Dictionary:
	if busy:
		return {"ok": false, "error": Localization.translate("An operation is already running.")}
	var executable := python_path.strip_edges()
	if executable.is_empty():
		return {"ok": false, "error": Localization.translate("Specify Python 3.10 or later.")}
	if not FileAccess.file_exists(LAUNCHER):
		return {"ok": false, "error": Localization.translate("The local GeoJSON worker could not be found.")}
	var args := PackedStringArray(["-X", "utf8", "-B", ProjectSettings.globalize_path(LAUNCHER)])
	args.append_array(arguments)
	_process_info = OS.execute_with_pipe(executable, args, false)
	if _process_info.is_empty():
		return {"ok": false, "error": Localization.translate("Could not start Python. Check the interpreter path.")}
	_mode = mode
	_stdout.clear()
	_stderr.clear()
	_stderr_offset = 0
	_started_ms = Time.get_ticks_msec()
	_cancelled = false
	_closing = false
	busy = true
	var message := "Checking dependencies…" if mode == "check" else "Starting GeoJSON processing…"
	if mode == "citygml_download":
		message = "Preparing 3D archive download…"
	progress.emit(Localization.translate(message), -1.0)
	set_process(true)
	return {"ok": true}

func _process(_delta: float) -> void:
	if _process_info.is_empty() or _building:
		return
	_read_pipes()
	if _stdout.size() > OUTPUT_LIMIT or _stderr.size() > OUTPUT_LIMIT:
		_stop_process()
		_finish({"ok": false, "error": Localization.translate("The worker's diagnostic response is too large.")})
		return
	if Time.get_ticks_msec() - _started_ms > TIMEOUT_MS:
		_stop_process()
		_finish({"ok": false, "error": _timeout_message()})
		return
	if OS.is_process_running(int(_process_info["pid"])):
		return
	_read_pipes()
	var exit_code := OS.get_process_exit_code(int(_process_info["pid"]))
	_close_pipes()
	var parser := JSON.new()
	if parser.parse(_stdout.get_string_from_utf8().strip_edges()) != OK or not parser.data is Dictionary:
		var message := "Invalid Python response (code %d). Python 3.10+, pyproj, and GEOS 3.10+ are required.\n%s"
		if _mode == "citygml_download":
			message = "Invalid CityGML download response (code %d).\n%s"
		_finish({"ok": false, "error": Localization.translate(message) % [exit_code, _diagnostics()]})
		return
	var response: Dictionary = parser.data
	if exit_code != 0 or not response.get("ok", false):
		var failure := {"ok": false, "error": str(response.get("error", Localization.translate("GeoJSON processing failed")))}
		if response.get("merge") is Dictionary:
			failure["merge"] = response["merge"]
			if DirAccess.remove_absolute(_job_dir) == OK:
				_job_dir = ""
		_finish(failure)
		return
	if _mode in ["check", "world_data", "citygml_download"]:
		_finish(response)
		return
	_building = true
	_build_scene(response)

func _timeout_message() -> String:
	return Localization.translate("Processing exceeded 180 seconds. Try a smaller area.")

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
	if _mode in ["generate", "citygml_download"] and _stderr.size() <= OUTPUT_LIMIT:
		_read_backend_progress()

func _read_backend_progress() -> void:
	while _stderr_offset < _stderr.size():
		var line_end := _stderr.find(10, _stderr_offset)
		if line_end < 0:
			return
		var line := _stderr.slice(_stderr_offset, line_end).get_string_from_utf8()
		_stderr_offset = line_end + 1
		if not line.begins_with(PROGRESS_PREFIX):
			continue
		var event: Variant = JSON.parse_string(line.trim_prefix(PROGRESS_PREFIX))
		if event is Array and event.size() == 3 and event[0] is String \
				and (event[1] is float or event[1] is int) and (event[2] is float or event[2] is int):
			_on_phase_progress(event[0], int(event[1]), int(event[2]))

func _diagnostics() -> String:
	var lines := PackedStringArray()
	for line in _stderr.get_string_from_utf8().split("\n"):
		if not line.begins_with(PROGRESS_PREFIX):
			lines.append(line)
	return "\n".join(lines).strip_edges().left(2000)

func _on_phase_progress(phase: String, done: int, total: int) -> bool:
	if _cancelled or _closing:
		return false
	if not PHASE_LABELS.has(phase):
		return true
	var label := Localization.translate(PHASE_LABELS[phase])
	if total > 0 and done >= 0 and done <= total:
		progress.emit("%s · %d / %d" % [label, done, total], float(done) / total)
	else:
		progress.emit(label + "…", -1.0)
	return true

func _build_scene(response: Dictionary) -> void:
	var files: Dictionary = response.get("files", {})
	var mesh_path := str(files.get("meshes", ""))
	var expected := ProjectSettings.globalize_path(_job_dir).simplify_path().trim_suffix("/") + "/"
	if mesh_path.is_empty() or not mesh_path.simplify_path().begins_with(expected):
		_finish({"ok": false, "error": Localization.translate("The worker returned a path outside the output folder.")})
		return
	progress.emit(Localization.translate("Reading prepared geometry…"), -1.0)
	var data: Dictionary = await _read_mesh_payload(mesh_path)
	if _native_interrupted():
		return
	if data.is_empty():
		_finish({"ok": false, "error": Localization.translate("Could not read the prepared geometry.")})
		return
	var script := load(MAP_SCRIPT) as Script
	if script == null or not script.can_instantiate():
		_finish({"ok": false, "error": Localization.translate("Could not load the scene generator.")})
		return
	var world := Node3D.new()
	world.set_script(script)
	world.name = "SpatialMap"
	# Keep the temporary map's geometry, camera and lighting out of the editor viewport.
	var staging := SubViewport.new()
	staging.own_world_3d = true
	staging.render_target_update_mode = SubViewport.UPDATE_DISABLED
	add_child(staging)
	staging.add_child(world)
	var report: Dictionary = response.get("report", {})
	var built: Dictionary = await world.build_from_data(data, report, _scene_options, _on_phase_progress)
	data = {}
	if _native_interrupted(staging):
		return
	if not built.get("success", false):
		staging.queue_free()
		_finish({"ok": false, "error": str(built.get("error", Localization.translate("Could not create the scene")))})
		return
	progress.emit(Localization.translate("Preparing patrol routes…"), -1.0)
	await get_tree().process_frame
	if _native_interrupted(staging):
		return
	var patrol_count := await ROAD_PATROLS.add_from_file(world, _job_dir.path_join(ROAD_PATROLS.MODEL_FILE), true)
	if _native_interrupted(staging):
		return
	report.get("modules", {})["road_patrols"] = {"robots": patrol_count}
	if _appearance_profile != null:
		progress.emit(Localization.translate("Applying the appearance profile…"), -1.0)
		await get_tree().process_frame
		if _native_interrupted(staging):
			return
		report.get("modules", {})["appearance_profile"] = _appearance_profile.apply_to_new_map(world)
	var report_saved := _save_native_report(files, report, expected)
	if not report_saved.get("ok", false):
		staging.queue_free()
		_finish(report_saved)
		return
	world.get_node("Generated").set_meta("generation_report", report)
	progress.emit(Localization.translate("Packing the scene…"), -1.0)
	await get_tree().process_frame
	if _native_interrupted(staging):
		return
	var scene_path := _job_dir.path_join("map.tscn")
	if FileAccess.file_exists(scene_path):
		staging.queue_free()
		_finish({"ok": false, "error": Localization.translate("The scene file already exists.")})
		return
	var packed := PackedScene.new()
	var error := packed.pack(world)
	if error == OK:
		progress.emit(Localization.translate("Saving map.tscn…"), -1.0)
		await get_tree().process_frame
		if _native_interrupted(staging):
			return
		error = ResourceSaver.save(packed, scene_path)
	staging.queue_free()
	if error != OK:
		_finish({"ok": false, "error": Localization.translate("Could not save the scene: %s") % error_string(error)})
		return
	_finish({"ok": true, "scene_path": scene_path, "directory": _job_dir, "report": report, "files": files})

func _read_mesh_payload(path: String) -> Dictionary:
	_mesh_reader = Thread.new()
	if _mesh_reader.start(_decode_mesh_payload.bind(path)) != OK:
		_mesh_reader = null
		await get_tree().process_frame
		return {} if _cancelled or _closing else _decode_mesh_payload(path)
	while _mesh_reader.is_alive():
		await get_tree().process_frame
		if _closing:
			return {}
	var data: Dictionary = _mesh_reader.wait_to_finish()
	_mesh_reader = null
	return data

static func _decode_mesh_payload(path: String) -> Dictionary:
	var file := FileAccess.open(path, FileAccess.READ)
	var parser := JSON.new()
	if file == null or parser.parse(file.get_as_text()) != OK or not parser.data is Dictionary:
		return {}
	return parser.data

func _native_interrupted(staging: SubViewport = null) -> bool:
	if not _cancelled and not _closing:
		return false
	if staging != null:
		staging.queue_free()
	if not _closing:
		_finish({"ok": false, "cancelled": true, "error": Localization.translate("Map creation cancelled.")})
	return true

func _save_native_report(files: Dictionary, report: Dictionary, expected_directory: String) -> Dictionary:
	var path := str(files.get("report", "")).simplify_path()
	if path.is_empty() or not path.begins_with(expected_directory):
		return {"ok": false, "error": Localization.translate("The report path is outside the output folder.")}
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return {"ok": false, "error": Localization.translate("Could not read the full import report.")}
	var parser := JSON.new()
	var parsed := parser.parse(file.get_as_text())
	file.close()
	if parsed != OK or not parser.data is Dictionary:
		return {"ok": false, "error": Localization.translate("The full import report contains invalid JSON.")}
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
		return {"ok": false, "error": Localization.translate("Could not save the collision report.")}
	file.store_string(JSON.stringify(full, "  ", true, true) + "\n")
	file.flush()
	var error := file.get_error()
	file.close()
	if error != OK:
		return {"ok": false, "error": Localization.translate("Could not write the collision report: %s") % error_string(error)}
	return {"ok": true}

func cancel() -> void:
	if not busy:
		return
	_cancelled = true
	if _building:
		progress.emit(Localization.translate("Cancelling map creation…"), -1.0)
	else:
		_stop_process()
		_finish({"ok": false, "cancelled": true, "error": Localization.translate("Processing cancelled.")})

func shutdown() -> void:
	_closing = true
	_cancelled = true
	_stop_process()
	if _mesh_reader != null:
		_mesh_reader.wait_to_finish()
		_mesh_reader = null
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
