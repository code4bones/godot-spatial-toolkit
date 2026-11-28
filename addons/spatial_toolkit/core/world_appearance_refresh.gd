@tool
extends RefCounted
## Refreshes the appearance stored in closed editable squares from the shared bank.

signal progress(count: int, total: int)

const Layers := preload("res://addons/spatial_toolkit/core/spatial_layers.gd")
const Localization := preload("res://addons/spatial_toolkit/ui/editor_localization.gd")
const APPLIED_HASH := &"world_attribute_bank_sha256"

func run(manifest_path: String, host: Node, is_open: Callable, cancelled: Callable) -> Dictionary:
	var directory := manifest_path.get_base_dir()
	var bank_path := directory.path_join(SpatialAttributeBank.FILE_NAME)
	var bank_hash := FileAccess.get_sha256(bank_path)
	var manifest_hash := FileAccess.get_sha256(manifest_path)
	var manifest: Variant = JSON.parse_string(FileAccess.get_file_as_string(manifest_path))
	if not manifest is Dictionary or manifest.get("schema") != 1 or not manifest.get("chunks") is Dictionary:
		return _error(Localization.translate("The square index is missing or invalid."))
	var bank := ResourceLoader.load(bank_path, "Resource", ResourceLoader.CACHE_MODE_IGNORE) as SpatialAttributeBank
	if bank == null or bank_hash.is_empty():
		return _error(Localization.translate("Could not open the world's attribute bank."))
	var tree := host.get_tree()
	var ids: Array = manifest["chunks"].keys()
	ids.sort()
	var updated := 0
	progress.emit(0, ids.size())
	for position in ids.size():
		await tree.process_frame
		if not is_instance_valid(host) or not host.is_inside_tree() or cancelled.call():
			return {"ok": false, "cancelled": true}
		if FileAccess.get_sha256(bank_path) != bank_hash or FileAccess.get_sha256(manifest_path) != manifest_hash:
			return _error(Localization.translate("The world index or attribute bank changed. Save the square again."))
		var id: String = ids[position]
		var relative: Variant = manifest["chunks"][id]
		if not relative is String:
			return _error(Localization.translate("The world index has an invalid square scene reference."))
		var path := directory.path_join(relative).simplify_path()
		if relative.is_absolute_path() or not path.begins_with(directory.trim_suffix("/") + "/") \
				or not path.get_extension() in ["tscn", "scn"] or not FileAccess.file_exists(path):
			return _error(Localization.translate("The square scene is unavailable inside the world folder: %s") % id)
		# Open scenes already follow the bank in memory and may have unsaved edits.
		if not is_open.call(path):
			var written := _refresh_square(path, manifest_path, id, bank, bank_hash)
			if written < 0:
				return _error(Localization.translate("Could not refresh the appearance of square %s.") % id)
			updated += written
		progress.emit(position + 1, ids.size())
	return {"ok": true, "updated": updated, "total": ids.size(), "bank_hash": bank_hash}

func _refresh_square(path: String, manifest_path: String, id: String,
		bank: SpatialAttributeBank, bank_hash: String) -> int:
	var source_hash := FileAccess.get_sha256(path)
	var packed := ResourceLoader.load(path, "PackedScene", ResourceLoader.CACHE_MODE_IGNORE) as PackedScene
	if packed == null:
		return -1
	var square := packed.instantiate()
	if not square is Node3D or square.get("world_chunk_id") != id \
			or square.get("world_manifest_path") != manifest_path or square.has_meta("scene_bake"):
		square.free()
		return -1
	if square.get_meta(APPLIED_HASH, "") == bank_hash:
		square.free()
		return 0
	var linked_bank := square.get("attribute_bank") as SpatialAttributeBank
	square.set("attribute_bank", bank)
	bank.apply_to_map(square)
	Layers.apply(square)
	square.set("attribute_bank", linked_bank)
	square.set_meta(APPLIED_HASH, bank_hash)
	var refreshed := PackedScene.new()
	var error := refreshed.pack(square)
	square.free()
	if error != OK:
		return -1
	var temporary := path.get_base_dir().path_join(".appearance_%d_%d.%s" % [
		OS.get_process_id(), Time.get_ticks_usec(), path.get_extension()])
	error = ResourceSaver.save(refreshed, temporary)
	var uid := ResourceLoader.get_resource_uid(path)
	if error == OK and uid != ResourceUID.INVALID_ID:
		error = ResourceSaver.set_uid(temporary, uid)
	if error == OK and FileAccess.get_sha256(path) == source_hash:
		error = DirAccess.rename_absolute(temporary, path)
		if error == OK:
			return 1
	DirAccess.remove_absolute(temporary)
	return -1

func _error(message: String) -> Dictionary:
	return {"ok": false, "error": message}
