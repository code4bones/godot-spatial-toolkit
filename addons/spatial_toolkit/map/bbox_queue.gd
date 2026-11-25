@tool
extends RefCounted

const DIRECTORY := "user://spatial_toolkit/regions"
const FILE := DIRECTORY + "/queue.json"

var entries: Array[Dictionary] = []
var next_id := 1

func load_queue() -> Error:
	if not FileAccess.file_exists(FILE):
		return OK
	var file := FileAccess.open(FILE, FileAccess.READ)
	if file == null:
		return FileAccess.get_open_error()
	var data: Variant = JSON.parse_string(file.get_as_text())
	if not data is Dictionary or not data.get("entries") is Array:
		return ERR_FILE_CORRUPT
	var loaded: Array[Dictionary] = []
	var newest := 0
	for entry: Variant in data["entries"]:
		if not entry is Dictionary or not entry.get("bbox") is Dictionary:
			return ERR_FILE_CORRUPT
		var id := int(entry.get("id", 0))
		if id <= newest:
			return ERR_FILE_CORRUPT
		for key in ["south", "west", "north", "east"]:
			if not (entry["bbox"].get(key) is float or entry["bbox"].get(key) is int):
				return ERR_FILE_CORRUPT
		entry["id"] = id
		newest = id
		loaded.append(entry)
	entries = loaded
	next_id = maxi(newest + 1, int(data.get("next_id", 1)))
	return OK

func save_queue() -> Error:
	var result := DirAccess.make_dir_recursive_absolute(DIRECTORY)
	if result != OK:
		return result
	var file := FileAccess.open(FILE + ".tmp", FileAccess.WRITE)
	if file == null:
		return FileAccess.get_open_error()
	file.store_string(JSON.stringify({"next_id": next_id, "entries": entries}, "\t"))
	result = file.get_error()
	file.close()
	if result != OK:
		return result
	return DirAccess.rename_absolute(FILE + ".tmp", FILE)

static func data_path(id: int, revision := 0) -> String:
	var stem := "area_%d" % id
	if revision > 0:
		stem += "_r%d" % revision
	return DIRECTORY.path_join(stem + ".geojson")
