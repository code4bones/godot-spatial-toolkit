@tool
extends Node
## Runs a batch against one local OSM snapshot and stages the per-area GeoJSON.

signal completed(result: Dictionary, directory: String)

const SCRIPT := "res://addons/spatial_toolkit/python/spatial_backend/pbf_source.py"
const RESULT_FILE := "result.json"
const Settings := preload("res://addons/spatial_toolkit/core/spatial_project_settings.gd")

var _pid := -1
var _directory := ""

static func read_header(path: String) -> Dictionary:
	var output: Array = []
	var code := OS.execute(Settings.python_executable(), PackedStringArray([
		ProjectSettings.globalize_path(SCRIPT), "header", path]), output, true)
	if not output.is_empty():
		var text := str(output[0]).strip_edges()
		if text.begins_with("{"):
			var header: Variant = JSON.parse_string(text)
			if header is Dictionary and (code == 0 or header.has("error")):
				return header
	return {"error": "Could not run the PBF reader with the configured Python executable."}

func _ready() -> void:
	set_process(false)

func start(request: Dictionary) -> Error:
	if _pid != -1:
		return ERR_BUSY
	_directory = "user://spatial_toolkit/regions/.pbf_%d_%d" % [OS.get_process_id(), Time.get_ticks_usec()]
	var error := DirAccess.make_dir_recursive_absolute(_directory)
	if error != OK:
		_directory = ""
		return error
	var request_path := _directory.path_join("request.json")
	var file := FileAccess.open(request_path, FileAccess.WRITE)
	if file == null:
		error = FileAccess.get_open_error()
	else:
		file.store_string(JSON.stringify(request))
		error = file.get_error()
		file.close()
	if error != OK:
		_cleanup(_directory)
		_directory = ""
		return error
	_pid = OS.create_process(Settings.python_executable(), PackedStringArray([
		ProjectSettings.globalize_path(SCRIPT), "extract", ProjectSettings.globalize_path(request_path),
		ProjectSettings.globalize_path(_directory)]))
	if _pid == -1:
		_cleanup(_directory)
		_directory = ""
		return ERR_CANT_FORK
	set_process(true)
	return OK

func _process(_delta: float) -> void:
	if OS.is_process_running(_pid):
		return
	var code := OS.get_process_exit_code(_pid)
	var directory := _directory
	_pid = -1
	_directory = ""
	set_process(false)
	var path := directory.path_join(RESULT_FILE)
	var result: Variant
	if FileAccess.file_exists(path):
		result = JSON.parse_string(FileAccess.get_file_as_string(path))
	if not result is Dictionary:
		result = {"error": "The PBF extractor exited with code %d." % code}
	elif code != 0 and not result.has("error"):
		result["error"] = "The PBF extractor exited with code %d." % code
	completed.emit(result, directory)
	_cleanup(directory)

func cancel() -> void:
	if _pid != -1 and OS.is_process_running(_pid):
		OS.kill(_pid)
	_pid = -1
	set_process(false)
	if not _directory.is_empty():
		_cleanup(_directory)
		_directory = ""

func _exit_tree() -> void:
	cancel()

func _cleanup(directory: String) -> void:
	for filename: String in DirAccess.get_files_at(directory):
		DirAccess.remove_absolute(directory.path_join(filename))
	DirAccess.remove_absolute(directory)
