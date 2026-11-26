@tool
extends "res://addons/spatial_toolkit/core/map_import_service.gd"
## Publishes editable squares and a new world index after the complete revision saves.

const Bank := preload("res://addons/spatial_toolkit/core/spatial_attribute_bank.gd")
const ChunkInfo := preload("res://addons/spatial_toolkit/core/world_chunk_info.gd")
const MANIFEST := "world.json"
const BANK_FILE := "attribute_bank.tres"
const SCHEMA := 1

var _world_path := ""
var _revision := 0
var _previous_index: Dictionary = {}
var _previous_hash := ""

func create_world(sources: PackedStringArray, output_base: String, python_path: String,
		chunk_size_m: float, settings: Dictionary, appearance_profile: Resource = null) -> Dictionary:
	if busy:
		return _error(Localization.translate("An operation is already running."))
	var inputs := _source_inputs(sources)
	if inputs.is_empty():
		return _error(Localization.translate("Select existing GeoJSON files."))
	if not is_finite(chunk_size_m) or chunk_size_m <= 0.0:
		return _error(Localization.translate("The square size must be a positive number."))
	var base := ProjectSettings.localize_path(ProjectSettings.globalize_path(output_base.strip_edges())).simplify_path()
	if not base.begins_with("res://"):
		return _error(Localization.translate("The world folder must be inside the project (res://)."))
	var stem := inputs[0].get_file().get_basename().validate_filename().left(60)
	var index := 1
	_world_path = base.path_join(stem + "_world_%03d" % index)
	while DirAccess.dir_exists_absolute(_world_path) or FileAccess.file_exists(_world_path):
		index += 1
		_world_path = base.path_join(stem + "_world_%03d" % index)
	_previous_index = {}
	_previous_hash = ""
	_scene_options = _build_options(settings)
	var profile := appearance_profile as AppearanceProfile
	if appearance_profile != null and profile == null:
		return _error(Localization.translate("Select a Spatial appearance profile."))
	if profile != null:
		var invalid := profile.validation_error()
		if not invalid.is_empty():
			return _error(invalid)
		if not _scene_options["daylight"] and profile.requires_daylight():
			return _error(Localization.translate("Enable materials, sky, and lighting to use the profile's facades and roofs."))
	var args := PackedStringArray(["--chunk-size", str(chunk_size_m),
		"--world-scale", str(settings.get("world_scale", 1.0)),
		"--default-height", str(settings.get("default_height", 3.0)),
		"--level-height", str(settings.get("level_height", 3.0))])
	var osm_rules: Variant = settings.get("osm_rules", ProjectDefaults.osm_rules())
	args.append_array(PackedStringArray(["--osm-rules", JSON.stringify(osm_rules)]))
	var result := _start_revision(inputs, python_path, args)
	if result.get("ok", false):
		_appearance_profile = profile
	return result

func append_world(sources: PackedStringArray, manifest_path: String, python_path: String) -> Dictionary:
	if busy:
		return _error(Localization.translate("An operation is already running."))
	var inputs := _source_inputs(sources)
	if inputs.is_empty():
		return _error(Localization.translate("Select existing GeoJSON files."))
	var path := ProjectSettings.localize_path(ProjectSettings.globalize_path(manifest_path)).simplify_path()
	if not path.begins_with("res://") or path.get_file() != MANIFEST:
		return _error(Localization.translate("Select a saved world's world.json inside the project."))
	if not FileAccess.file_exists(path):
		return _error(Localization.translate("The saved world index is unavailable."))
	var fingerprint := FileAccess.get_sha256(path)
	var previous := _decode_mesh_payload(path)
	var revision: Variant = previous.get("revision")
	if previous.get("schema", 0) != SCHEMA or not previous.get("chunks") is Dictionary \
			or not previous.get("scene_settings") is Dictionary \
			or not (revision is int or revision is float) or not is_finite(float(revision)) or revision < 1:
		return _error(Localization.translate("The square index is missing or invalid."))
	if fingerprint != FileAccess.get_sha256(path):
		return _error(Localization.translate("The world index changed. Retry the update."))
	_world_path = path.get_base_dir()
	_previous_index = previous
	_previous_hash = fingerprint
	_scene_options = _build_options(previous["scene_settings"])
	return _start_revision(inputs, python_path,
		PackedStringArray(["--previous", ProjectSettings.globalize_path(path)]))

func _source_inputs(sources: PackedStringArray) -> PackedStringArray:
	var paths := PackedStringArray()
	for input in sources:
		if input.strip_edges().is_empty():
			return PackedStringArray()
		var path := ProjectSettings.globalize_path(input.strip_edges()).simplify_path()
		if not FileAccess.file_exists(path) or path.get_extension().to_lower() not in ["geojson", "json"]:
			return PackedStringArray()
		if not paths.has(path):
			paths.append(path)
	return paths

func _build_options(settings: Dictionary) -> Dictionary:
	return {"building_collisions": bool(settings.get("building_collisions", true)),
		"daylight": bool(settings.get("daylight", true)), "drone": false}

func _start_revision(inputs: PackedStringArray, python_path: String, options: PackedStringArray) -> Dictionary:
	var revisions := _world_path.path_join("revisions")
	var error := DirAccess.make_dir_recursive_absolute(revisions)
	if error != OK:
		return _error(Localization.translate("Could not create the world folder: %s") % error_string(error))
	_revision = int(_previous_index.get("revision", 0)) + 1
	_job_dir = revisions.path_join("%06d" % _revision)
	while DirAccess.dir_exists_absolute(_job_dir) or FileAccess.file_exists(_job_dir):
		_revision += 1
		_job_dir = revisions.path_join("%06d" % _revision)
	error = DirAccess.make_dir_absolute(_job_dir)
	if error != OK:
		return _error(Localization.translate("Could not create the world revision: %s") % error_string(error))
	var args := PackedStringArray(["world-chunks", "--output", ProjectSettings.globalize_path(_job_dir)])
	args.append_array(options)
	for path in inputs:
		args.append_array(PackedStringArray(["--source", path]))
	var result := _launch(python_path, args, "generate")
	if not result.get("ok", false):
		DirAccess.remove_absolute(_job_dir)
	return result

func _build_scene(response: Dictionary) -> void:
	var path := _revision_file(response.get("plan", ""))
	var plan := _decode_mesh_payload(path) if not path.is_empty() else {}
	var index: Variant = plan.get("manifest")
	var cells: Variant = plan.get("cells")
	var summary: Variant = plan.get("summary")
	if not index is Dictionary or not cells is Array or not summary is Dictionary \
			or int(index.get("schema", 0)) != SCHEMA:
		_finish(_error(Localization.translate("The import worker returned an invalid world plan.")))
		return
	var manifest_path := _world_path.path_join(MANIFEST)
	if not _previous_index.is_empty() and cells.is_empty() and int(summary.get("new_sources", 0)) == 0:
		_remove_plan_files(path)
		DirAccess.remove_absolute(_job_dir)
		_finish({"ok": true, "manifest_path": manifest_path, "report": summary, "changed_chunks": PackedStringArray()})
		return
	var bank := _load_bank()
	if bank == null:
		_finish(_error(Localization.translate("Could not open the world's attribute bank.")))
		return
	var registry := _job_dir.path_join("source.geojson")
	if not FileAccess.file_exists(registry):
		_finish(_error(Localization.translate("The import worker did not save the GeoJSON registry.")))
		return
	var chunks: Dictionary = _previous_index.get("chunks", {}).duplicate()
	var previous_info: Variant = _previous_index.get("chunk_info", {})
	var chunk_info: Dictionary = previous_info.duplicate(true) if previous_info is Dictionary else {}
	var changed := PackedStringArray()
	if not cells.is_empty():
		_show_scene_progress(0, cells.size())
	for cell: Variant in cells:
		if not cell is Dictionary or not _valid_cell(cell):
			_finish(_error(Localization.translate("The plan contains an invalid square.")))
			return
		var chunk_id: String = cell["id"]
		if changed.has(chunk_id):
			_finish(_error(Localization.translate("The plan contains a duplicate square: %s.") % chunk_id))
			return
		var result: Dictionary = await _save_chunk(cell, str(chunks.get(chunk_id, "")), manifest_path, bank)
		if _native_interrupted():
			return
		if not result.get("ok", false):
			_finish(result)
			return
		chunks[chunk_id] = _world_relative(result["scene"])
		chunk_info[chunk_id] = result["info"]
		changed.append(chunk_id)
		_show_scene_progress(changed.size(), cells.size())
		await get_tree().process_frame
		if _native_interrupted():
			return
	index["chunks"] = chunks
	index["chunk_info"] = chunk_info
	index["registry"] = _world_relative(registry)
	index["revision"] = _revision
	index["scene_settings"] = _scene_options
	if not _publish_manifest(manifest_path, index):
		_finish(_error(Localization.translate("The world index changed or could not be written. Retry the update.")))
		return
	DirAccess.remove_absolute(path)
	DirAccess.remove_absolute(_job_dir.path_join("payloads"))
	_finish({"ok": true, "manifest_path": manifest_path, "report": summary, "changed_chunks": changed})

func _load_bank() -> Bank:
	var path := _world_path.path_join(BANK_FILE)
	if not _previous_index.is_empty():
		return load(path) as Bank if FileAccess.file_exists(path) else null
	var bank := Bank.new()
	if _appearance_profile != null:
		var invalid := bank.seed_from_profile(_appearance_profile)
		if not invalid.is_empty():
			push_warning(invalid)
			return null
	if ResourceSaver.save(bank, path) != OK:
		return null
	bank.take_over_path(path)
	return bank

func _save_chunk(cell: Dictionary, previous_scene: String, manifest_path: String, bank: Bank) -> Dictionary:
	var payload := _revision_file(cell["payload"])
	var chunk_id: String = cell["id"]
	var bounds: Array = cell["bounds"]
	var data := await _read_mesh_payload(payload)
	if _cancelled or _closing:
		return {}
	if data.is_empty():
		return _error(Localization.translate("Could not read geometry for %s.") % chunk_id)
	var staging := SubViewport.new()
	staging.own_world_3d = true
	staging.render_target_update_mode = SubViewport.UPDATE_DISABLED
	add_child(staging)
	var world := Node3D.new()
	world.set_script(load(MAP_SCRIPT))
	world.name = "SpatialChunk"
	world.set("world_manifest_path", manifest_path)
	world.set("world_chunk_id", chunk_id)
	world.set("world_chunk_bounds", Rect2(Vector2(bounds[0], bounds[1]),
		Vector2(bounds[2] - bounds[0], bounds[3] - bounds[1])))
	staging.add_child(world)
	var built: Dictionary = await world.build_from_data(data, {}, _scene_options, _on_phase_progress)
	if _cancelled or _closing or not built.get("success", false):
		staging.queue_free()
		return _error(str(built.get("error", Localization.translate("Could not build %s.") % chunk_id)))
	if not previous_scene.is_empty():
		var restored := _load_previous_chunk(previous_scene, manifest_path, chunk_id)
		if restored == null:
			staging.queue_free()
			return _error(Localization.translate("Could not open the saved scene for %s.") % chunk_id)
		staging.remove_child(world)
		staging.add_child(restored, true)
		var incoming := world.get_node("Generated")
		var existing := restored.get_node("Generated")
		_append_layers(incoming, existing, world, restored)
		existing.set_meta("source", incoming.get_meta("source"))
		world.free()
		world = restored
	world.set("attribute_bank", bank)
	world.apply_attribute_bank()
	world.apply_layer_styles()
	var info := ChunkInfo.collect(world)
	world.set("world_chunk_info", info)
	var scene_path := _job_dir.path_join(chunk_id + ".tscn")
	await get_tree().process_frame
	if _cancelled or _closing:
		staging.queue_free()
		return {}
	var packed := PackedScene.new()
	var error := packed.pack(world)
	if error == OK:
		error = ResourceSaver.save(packed, scene_path)
	staging.queue_free()
	if error != OK:
		return _error(Localization.translate("Could not save %s: %s") % [chunk_id, error_string(error)])
	DirAccess.remove_absolute(payload)
	return {"ok": true, "scene": scene_path, "info": info}

func _load_previous_chunk(relative_path: String, manifest_path: String, chunk_id: String) -> Node3D:
	var path := _world_path.path_join(relative_path).simplify_path()
	if not path.begins_with(_world_path.trim_suffix("/") + "/revisions/") or not FileAccess.file_exists(path):
		return null
	var packed := ResourceLoader.load(path, "PackedScene", ResourceLoader.CACHE_MODE_IGNORE) as PackedScene
	if packed == null:
		return null
	var instance := packed.instantiate()
	if instance is Node3D and instance.has_node("Generated") \
			and instance.get("world_manifest_path") == manifest_path and instance.get("world_chunk_id") == chunk_id:
		return instance
	if instance != null:
		instance.free()
	return null

func _append_layers(source: Node, target: Node, from_owner: Node, to_owner: Node) -> void:
	var groups := {}
	for child in target.get_children():
		if child is SpatialLayer3D and not child.style_key.is_empty():
			groups[child.style_key] = child
	for child in source.get_children():
		if child is SpatialLayer3D and groups.has(child.style_key):
			_append_layers(child, groups[child.style_key], from_owner, to_owner)
		else:
			var owned: Array[Node] = []
			_find_owned(child, from_owner, owned)
			# Remove/add retains an incoming layer's relative transform and resolves name collisions.
			for node in owned:
				node.owner = null
			source.remove_child(child)
			target.add_child(child, true)
			for node in owned:
				node.owner = to_owner

func _find_owned(root: Node, scene: Node, owned: Array[Node]) -> void:
	if root.owner == scene:
		owned.append(root)
	for child in root.get_children():
		_find_owned(child, scene, owned)

func _on_phase_progress(phase: String, done: int, total: int) -> bool:
	if _cancelled or _closing:
		return false
	if _building:
		return true
	if phase == "partition":
		if total > 0:
			progress.emit(Localization.translate("Dividing into squares · %d / %d") % [done, total], float(done) / total)
		return true
	return super._on_phase_progress(phase, done, total)

func _show_scene_progress(done: int, total: int) -> void:
	progress.emit(Localization.translate("Creating scenes · %d / %d") % [done, total], float(done) / total)

func _valid_cell(cell: Dictionary) -> bool:
	if not cell.get("id") is String or not cell.get("bounds") is Array or cell["bounds"].size() != 4 \
			or _revision_file(cell.get("payload", "")).is_empty():
		return false
	var parts: PackedStringArray = cell["id"].split("_")
	if parts.size() != 3 or parts[0] != "chunk" or not parts[1].is_valid_int() or not parts[2].is_valid_int():
		return false
	for v: Variant in cell["bounds"]:
		if not (v is int or v is float) or not is_finite(float(v)):
			return false
	return cell["bounds"][0] < cell["bounds"][2] and cell["bounds"][1] < cell["bounds"][3]

func _revision_file(value: Variant) -> String:
	if not value is String or value.is_empty():
		return ""
	var path := ProjectSettings.localize_path(value).simplify_path()
	return path if path.begins_with(_job_dir.trim_suffix("/") + "/") and FileAccess.file_exists(path) else ""

func _world_relative(path: String) -> String:
	return path.trim_prefix(_world_path.trim_suffix("/") + "/")

func _publish_manifest(path: String, index: Dictionary) -> bool:
	var temp := _job_dir.path_join(MANIFEST + ".tmp")
	var file := FileAccess.open(temp, FileAccess.WRITE)
	if file == null:
		return false
	file.store_string(JSON.stringify(index, "\t", true, true) + "\n")
	file.flush()
	var error := file.get_error()
	file.close()
	if error != OK:
		return false
	# The previous index remains valid until every new file exists and the replacement is ready.
	var lock := _world_path.path_join(".publish")
	if DirAccess.make_dir_absolute(lock) != OK:
		return false
	var valid := (not FileAccess.file_exists(path) if _previous_hash.is_empty()
		else FileAccess.get_sha256(path) == _previous_hash)
	var published := valid and DirAccess.rename_absolute(temp, path) == OK
	DirAccess.remove_absolute(lock)
	return published

func _remove_plan_files(path: String) -> void:
	DirAccess.remove_absolute(path)
	DirAccess.remove_absolute(_job_dir.path_join("source.geojson"))

func _error(message: String) -> Dictionary:
	return {"ok": false, "error": message}
