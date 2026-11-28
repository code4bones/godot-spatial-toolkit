@tool
extends "res://addons/spatial_toolkit/core/map_import_service.gd"
## Runs one confirmed download and owns its private staging directory.

const CACHE_FOLDER := "user://spatial_toolkit/citygml"
const DOWNLOAD_LABELS := {
	"download": "Downloading 3D data…",
	"verify": "Verifying the CityGML archive…",
	"package": "Preparing the CityGML archive…",
}

var _staging := ""

func start(dataset_id: String, destination: String, python_path: String) -> Dictionary:
	if busy:
		return {"ok": false, "error": Localization.translate("An operation is already running.")}
	if destination.get_base_dir() != CACHE_FOLDER:
		return {"ok": false, "error": Localization.translate("Invalid CityGML cache path.")}
	var directory := CACHE_FOLDER.path_join(".download_%d_%d" % [OS.get_process_id(), Time.get_ticks_usec()])
	var error := DirAccess.make_dir_recursive_absolute(directory)
	if error != OK:
		return {"ok": false, "error": Localization.translate("Could not create the CityGML cache (%s).") % error_string(error)}
	_staging = directory
	var result := _launch(python_path, PackedStringArray(["citygml-download", dataset_id,
		ProjectSettings.globalize_path(destination), ProjectSettings.globalize_path(_staging)]), "citygml_download")
	if not result.get("ok", false):
		_clean_staging()
	return result

func _on_phase_progress(phase: String, done: int, total: int) -> bool:
	if _cancelled or _closing:
		return false
	if DOWNLOAD_LABELS.has(phase):
		_started_ms = Time.get_ticks_msec()
		var fraction := clampf(float(done) / total, 0.0, 1.0) if total > 0 else -1.0
		progress.emit(Localization.translate(DOWNLOAD_LABELS[phase]), fraction)
	return true

func _timeout_message() -> String:
	return Localization.translate("The 3D archive download stopped reporting progress.")

func _finish(result: Dictionary) -> void:
	_clean_staging()
	super._finish(result)

func _exit_tree() -> void:
	shutdown()
	_clean_staging()

func _clean_staging() -> void:
	if not _staging.is_empty():
		_remove_staging_tree(_staging)
		_staging = ""

func _remove_staging_tree(path: String) -> void:
	for filename: String in DirAccess.get_files_at(path):
		DirAccess.remove_absolute(path.path_join(filename))
	for directory: String in DirAccess.get_directories_at(path):
		_remove_staging_tree(path.path_join(directory))
	DirAccess.remove_absolute(path)
