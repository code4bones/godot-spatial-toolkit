@tool
extends Node
## Builds and publishes a flight graph from a saved world bake in a local worker.

signal progress(message: String, fraction: float)
signal completed(result: Dictionary)

const Localization := preload("res://addons/spatial_toolkit/ui/editor_localization.gd")
const LAUNCHER := "res://addons/spatial_toolkit/python/run.py"
const MANIFEST_NAME := "manifest.flight_graph.json"
const PROGRESS_PREFIX := "PROGRESS "
const OUTPUT_LIMIT := 256 * 1024

var busy := false
var _process_info: Dictionary = {}
var _stdout := PackedByteArray()
var _stderr := PackedByteArray()
var _diagnostics := ""
var _bake_path := ""
var _manifest_path := ""
var _last_progress := 0.0

func _ready() -> void:
	set_process(busy)

static func published_manifest_path(bake_manifest_path: String) -> String:
	var locations := manifest_locations(bake_manifest_path)
	for path in locations:
		if FileAccess.file_exists(path):
			return path
	return locations[0] if not locations.is_empty() else ""

static func manifest_locations(bake_manifest_path: String) -> PackedStringArray:
	var bake_path := _project_path(bake_manifest_path)
	if bake_path.get_file() != "bake_manifest.json":
		return PackedStringArray()
	var directory := bake_path.get_base_dir()
	var graph_directory := directory.path_join("flight_graph")
	var paths := PackedStringArray([graph_directory.path_join(MANIFEST_NAME),
		graph_directory.path_join("manifest.json")])
	if directory != "res://":
		paths.append(directory + "_flight_graph/manifest.json")
	return paths

static func _project_path(path: String) -> String:
	var clean := path.strip_edges()
	if clean.begins_with("res://"):
		clean = ProjectSettings.globalize_path(clean)
	if not clean.is_absolute_path():
		return ""
	var local := ProjectSettings.localize_path(clean.simplify_path())
	return local if local.begins_with("res://") else ""

func start(bake_manifest_path: String, python_path: String, options: Dictionary) -> Dictionary:
	if busy:
		return _failure("Wait for the current flight graph build to finish, or cancel it.")
	var bake_path := _project_path(bake_manifest_path)
	var manifest_path := published_manifest_path(bake_path)
	if manifest_path.is_empty() or not FileAccess.file_exists(bake_path):
		return _failure("Choose a saved bake_manifest.json inside this project.")
	var executable := python_path.strip_edges()
	if executable.is_empty():
		return _failure("Specify Python 3.10 or later.")
	if not FileAccess.file_exists(LAUNCHER):
		return _failure("The local flight graph worker could not be found.")
	var height_min := float(options.get("min_y_m", 0.0))
	var height_max := float(options.get("max_y_m", 128.0))
	var radius := float(options.get("agent_radius_m", 1.0))
	var margin := float(options.get("safety_margin_m", 0.5))
	if not is_finite(height_min) or not is_finite(height_max) or height_max <= height_min:
		return _failure("The maximum flight height must be higher than the minimum.")
	if not is_finite(radius) or not is_finite(margin) or radius <= 0.0 or margin < 0.0:
		return _failure("Use a positive drone radius and a nonnegative safety margin.")
	var arguments := PackedStringArray([
		"-X", "utf8", "-B", ProjectSettings.globalize_path(LAUNCHER), "flight-graph",
		"--from-bake", ProjectSettings.globalize_path(bake_path),
		"--project-root", ProjectSettings.globalize_path("res://"),
		"--height", str(height_min), str(height_max),
		"--agent-radius", str(radius), "--safety-margin", str(margin),
		"--output", ProjectSettings.globalize_path(manifest_path.get_base_dir()),
		"--manifest-name", manifest_path.get_file(), "--progress",
	])
	_process_info = OS.execute_with_pipe(executable, arguments, false)
	if _process_info.is_empty():
		return _failure("Could not start Python. Check the interpreter path.")
	_bake_path = bake_path
	_manifest_path = manifest_path
	_stdout.clear()
	_stderr.clear()
	_diagnostics = ""
	_last_progress = 0.0
	busy = true
	set_process(true)
	progress.emit(Localization.translate("Preparing flight graph…"), -1.0)
	return {"ok": true}

func _process(_delta: float) -> void:
	if not busy:
		return
	var pid := int(_process_info["pid"])
	_read_pipes()
	if int(_process_info.get("pid", -1)) != pid:
		return
	if _response_too_large():
		OS.kill(pid)
		_finish(_failure("The flight graph worker response is too large."))
		return
	if OS.is_process_running(pid):
		return
	while _read_pipes():
		if int(_process_info.get("pid", -1)) != pid:
			return
		if _response_too_large():
			_finish(_failure("The flight graph worker response is too large."))
			return
	var exit_code := OS.get_process_exit_code(pid)
	var parser := JSON.new()
	var response: Dictionary = {}
	if parser.parse(_stdout.get_string_from_utf8().strip_edges()) == OK and parser.data is Dictionary:
		response = parser.data
	if exit_code != 0 or not response.get("ok", false):
		var detail := str(response.get("error", ""))
		if detail.is_empty():
			detail = (_diagnostics + _stderr.get_string_from_utf8()).strip_edges()
		if detail.is_empty():
			detail = Localization.translate("Flight graph worker exited with code %d.") % exit_code
		_finish({"ok": false, "error": detail})
		return
	if _project_path(str(response.get("manifest", ""))) != _manifest_path or not FileAccess.file_exists(_manifest_path):
		_finish(_failure("The flight graph worker did not publish the expected manifest."))
		return
	_finish({"ok": true, "bake_manifest_path": _bake_path, "manifest_path": _manifest_path,
		"directory": _manifest_path.get_base_dir(), "summary": response})

func _read_pipes() -> bool:
	var received := false
	for key in ["stdio", "stderr"]:
		var pipe := _process_info.get(key) as FileAccess
		if pipe == null or not pipe.is_open():
			continue
		for read in 8:
			var chunk := pipe.get_buffer(4096)
			if chunk.is_empty():
				break
			received = true
			if key == "stdio":
				_stdout.append_array(chunk)
			else:
				_stderr.append_array(chunk)
	_read_progress()
	return received

func _read_progress() -> void:
	var offset := 0
	var done := 0
	var total := 0
	while offset < _stderr.size():
		var ending := _stderr.find(10, offset)
		if ending < 0:
			break
		var line := _stderr.slice(offset, ending).get_string_from_utf8()
		offset = ending + 1
		if not line.begins_with(PROGRESS_PREFIX):
			_diagnostics += line + "\n"
			continue
		var event: Variant = JSON.parse_string(line.trim_prefix(PROGRESS_PREFIX))
		if not event is Dictionary:
			continue
		done = int(event.get("done", 0))
		total = int(event.get("total", 0))
	if offset > 0:
		_stderr = _stderr.slice(offset)
	if total > 0:
		_last_progress = maxf(_last_progress, clampf(float(done) / total, 0.0, 1.0))
		progress.emit(Localization.translate("Building flight graph · %d/%d cells checked") % [done, total],
			_last_progress)

func _response_too_large() -> bool:
	return _stdout.size() > OUTPUT_LIMIT or _stderr.size() + _diagnostics.length() > OUTPUT_LIMIT

func cancel() -> void:
	if not busy:
		return
	var pid := int(_process_info["pid"])
	if not OS.is_process_running(pid):
		return  # A completed worker will be collected during the normal editor tick.
	if OS.kill(pid) != OK:
		if OS.is_process_running(pid):
			progress.emit(Localization.translate("Could not stop the flight graph worker."), _last_progress)
		return
	_finish({"ok": false, "cancelled": true, "error": Localization.translate("Flight graph build cancelled.")})

func shutdown() -> void:
	if not busy:
		return
	var pid := int(_process_info["pid"])
	if OS.is_process_running(pid):
		OS.kill(pid)
	_close_pipes()

func _exit_tree() -> void:
	shutdown()

func _finish(result: Dictionary) -> void:
	_close_pipes()
	completed.emit(result)

func _close_pipes() -> void:
	for key in ["stdio", "stderr"]:
		var pipe := _process_info.get(key) as FileAccess
		if pipe != null and pipe.is_open():
			pipe.close()
	_process_info.clear()
	busy = false
	set_process(false)

static func _failure(message: String) -> Dictionary:
	return {"ok": false, "error": Localization.translate(message)}
