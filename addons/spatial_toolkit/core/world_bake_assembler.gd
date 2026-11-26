@tool
extends RefCounted
## Saved editable squares -> one detached scene for the static scene baker.

signal progress(message: String, fraction: float)

const Localization := preload("res://addons/spatial_toolkit/ui/editor_localization.gd")
const Map := preload("res://addons/spatial_toolkit/core/spatial_map.gd")
const Layers := preload("res://addons/spatial_toolkit/core/spatial_layers.gd")
const Flight := preload("res://addons/spatial_toolkit/core/map_flight_module.gd")
const Night := preload("res://addons/spatial_toolkit/runtime/night_city_style.gd")
const SOURCE_CHILDREN := ["Generated", "FlatGround", "PreviewSun", "PreviewEnvironment", "OverviewCamera", "PreviewLegend"]
const VIEW_CHILDREN := ["PreviewSun", "PreviewEnvironment", "OverviewCamera", "PreviewLegend"]

var _world: Node3D
var _source: Node
var _viewport: SubViewport
var _stopped := false

func assemble(manifest_path: String, host: Node, cancelled: Callable, add_drone := true,
		drone_model: PackedScene = null) -> Dictionary:
	if _world != null or _viewport != null:
		return {"ok": false, "error": Localization.translate("A world assembly is already running.")}
	_stopped = false
	var path := ProjectSettings.localize_path(ProjectSettings.globalize_path(manifest_path.strip_edges())).simplify_path()
	if not path.begins_with("res://") or path.get_file() != "world.json" or not FileAccess.file_exists(path):
		return _error(Localization.translate("Select a saved world's world.json inside the project."))
	var fingerprint := FileAccess.get_sha256(path)
	var parser := JSON.new()
	if parser.parse(FileAccess.get_file_as_string(path)) != OK or not parser.data is Dictionary:
		return _error(Localization.translate("Could not read the world index."))
	var index: Dictionary = parser.data
	var invalid := _validate_index(index)
	if not invalid.is_empty():
		return _error(invalid)
	var registry := _world_file(path.get_base_dir(), index["registry"])
	if registry.is_empty():
		return _error(Localization.translate("The world index has an invalid feature registry path."))
	if not is_instance_valid(host) or not host.is_inside_tree():
		return _error(Localization.translate("The assembly service must be in the scene tree."))
	var tree := host.get_tree()
	_world = Node3D.new()
	_world.name = "SpatialWorld"
	_world.set_meta("world_scale", float(index["world_scale"]))
	_world.set_meta("assembly_source_world", path)
	_world.set_meta("assembly_source_revision", int(index["revision"]))
	var generated := Node3D.new()
	generated.name = "Generated"
	_world.add_child(generated)
	generated.owner = _world
	var roots := {}
	for kind: String in Map.LAYERS:
		var layer := Layers.new_root(kind)
		generated.add_child(layer)
		layer.owner = _world
		roots[kind] = layer
	var patches := Node3D.new()
	patches.name = "GroundPatches"
	_world.add_child(patches)
	patches.owner = _world
	var ids: Array = index["chunks"].keys()
	ids.sort()
	var extent := Rect2()
	var scenes: Array[Dictionary] = []
	var mode := ""
	var sky_settings: SpatialSkySettings
	var sky_modes := {}
	progress.emit(Localization.translate("Assembling squares · %d / %d") % [0, ids.size()], 0.0)
	for position: int in ids.size():
		if _cancelled(host, cancelled):
			return _cancel()
		var id: String = ids[position]
		var scene_path := _world_file(path.get_base_dir(), index["chunks"][id])
		if scene_path.is_empty() or scene_path.get_extension().to_lower() not in ["tscn", "scn"] \
				or not FileAccess.file_exists(scene_path):
			return _error(Localization.translate("The square scene is unavailable inside the world folder: %s") % id)
		var scene_hash := FileAccess.get_sha256(scene_path)
		var packed := ResourceLoader.load(scene_path, "PackedScene", ResourceLoader.CACHE_MODE_IGNORE) as PackedScene
		if packed == null:
			return _error(Localization.translate("Could not load scene %s") % scene_path)
		_source = packed.instantiate()
		invalid = _validate_square(_source, id, path, float(index["world_scale"]))
		if not invalid.is_empty():
			return _error(scene_path + "\n" + invalid)
		var square := _source as Node3D
		var sky := str(square.get("sky_mode"))
		var bank := square.get("attribute_bank") as SpatialAttributeBank
		_apply_window_styles(square, bank)
		sky_modes[sky] = int(sky_modes.get(sky, 0)) + 1
		if position == 0:
			mode = str(bank.sky_mode) if bank != null else sky
			var settings := bank.sky_settings if bank != null else square.get("sky_settings") as SpatialSkySettings
			if settings != null:
				sky_settings = settings.duplicate() as SpatialSkySettings
			if mode not in ["day", "night"]:
				return _error(Localization.translate("The attribute bank has an invalid sky mode."))
		var bounds: Rect2 = square.get("world_chunk_bounds")
		var transformed := _transformed_bounds(bounds, square.transform)
		extent = transformed if position == 0 else extent.merge(transformed)
		var source_generated := square.get_node("Generated") as Node3D
		if position == 0:
			for key: StringName in source_generated.get_meta_list():
				generated.set_meta(key, source_generated.get_meta(key))
			for name_: String in VIEW_CHILDREN:
				var view := square.get_node(name_)
				if view is Node3D:
					view.transform = square.transform * view.transform
				_move_branch(view, _world)
		for kind: String in Map.LAYERS:
			var old_layer := source_generated.get_node_or_null(kind) as Node3D
			if old_layer != null:
				old_layer.name = id
				old_layer.transform = square.transform * source_generated.transform * old_layer.transform
				old_layer.visible = square.visible and source_generated.visible and old_layer.visible
				_move_branch(old_layer, roots[kind])
		var patch := square.get_node("FlatGround") as MeshInstance3D
		patch.name = id
		patch.transform = square.transform * patch.transform
		patch.visible = square.visible and patch.visible
		_move_branch(patch, patches)
		if scene_hash != FileAccess.get_sha256(scene_path):
			return _error(Localization.translate("A source scene changed during assembly: %s") % scene_path)
		scenes.append({"id": id, "path": scene_path, "sha256": scene_hash})
		_source.free()
		_source = null
		progress.emit(Localization.translate("Assembling squares · %d / %d") % [position + 1, ids.size()], float(position + 1) / ids.size())
		await tree.process_frame
	if _cancelled(host, cancelled):
		return _cancel()
	if fingerprint != FileAccess.get_sha256(path):
		return _error(Localization.translate("The world index changed during assembly. Retry the bake."))
	var result := _finish_world(index, path, registry, extent, mode, host, add_drone, drone_model, sky_settings)
	if not result.get("ok", false):
		return result
	# Hand ownership to the service only after staging is completely detached.
	var world := _world
	world.set("sky_settings", sky_settings)
	_world = null
	return {"ok": true, "map": world, "source": {
		"source_world": path, "source_world_sha256": fingerprint, "source_revision": int(index["revision"]),
		"source_scene_count": ids.size(), "source_scenes": scenes, "world_scale": float(index["world_scale"]),
		"extent_gameplay_m": [extent.position.x, extent.position.y, extent.size.x, extent.size.y],
		"saved_sky_mode": mode, "source_sky_modes": sky_modes, "add_drone": add_drone,
		"drone_model": drone_model.resource_path if add_drone and drone_model != null else "",
		"limits": ["No streaming or HLOD", "The flight floor spans the assembled world bounds",
			"Street/address labels and dynamic night uplights need a separate baked data overlay"]}}

func _apply_window_styles(square: Node3D, bank: SpatialAttributeBank) -> void:
	var refresh := false
	for layer in Layers.style_nodes(square):
		var group := layer as SpatialBuildingLayer3D
		if group == null:
			continue
		var style := group.window_style
		var layout := group.window_layout
		if bank != null:
			var rule: Dictionary = bank.layer_styles.get(group.style_key, {})
			style = rule.get("window_style") as SpatialWindowStyle
			layout = rule.get("window_layout") as SpatialWindowLayout
		if style != group.window_style:
			group.window_style = style
			refresh = true
		elif style != null:
			refresh = true
		if layout != group.window_layout:
			group.window_layout = layout
			refresh = true
		elif layout != null:
			refresh = true
	if refresh:
		Layers.apply(square)

func _finish_world(index: Dictionary, path: String, registry: String, extent: Rect2,
		mode: String, host: Node, add_drone: bool, drone_model: PackedScene, sky_settings: SpatialSkySettings) -> Dictionary:
	var support := MeshInstance3D.new()
	support.name = "FlatGround"
	var plane := PlaneMesh.new()
	plane.size = extent.size
	support.mesh = plane
	support.layers = 0
	support.position = Vector3(extent.get_center().x, -0.03 * float(index["world_scale"]), extent.get_center().y)
	_world.add_child(support)
	support.owner = _world
	var camera := _world.get_node("OverviewCamera") as Camera3D
	camera.size = maxf(extent.size.x, extent.size.y) * 1.1
	camera.set_meta("overview_size_m", camera.size)
	camera.far = maxf(20000.0, extent.size.length() * 4.0)
	var generated := _world.get_node("Generated")
	if index.get("osm_rules") is Dictionary:
		generated.set_meta("osm_rules", index["osm_rules"])
	generated.set_meta("source", {"path": registry, "merge_sources": index["sources"],
		"copyright": "© OpenStreetMap contributors · ODbL", "projection": index["projection"],
		"local_origin": index["local_origin"]})
	_viewport = SubViewport.new()
	_viewport.own_world_3d = true
	_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	host.add_child(_viewport)
	_viewport.add_child(_world)
	var center := Vector3(extent.get_center().x, 0.0, extent.get_center().y)
	var distance := maxf(2300.0, camera.far / 4.0)
	camera.look_at_from_position(center + Vector3(0, sin(0.85), cos(0.85)) * distance, center)
	if mode == "night":
		# Keep the saved daylight environment available when Sky Mode changes.
		Night.light_facades(Layers.buildings(_world), false, Night.fog_density(sky_settings))
	if add_drone:
		var flight := Flight.apply_to_scene(_world, Flight.DEFAULT_CONTROLLER, drone_model)
		if not flight.get("success", false):
			return _error(str(flight.get("error", Localization.translate("Could not add the drone."))))
	else:
		camera.current = true
	var patrols := Node3D.new()
	patrols.name = "RoadPatrols"
	_world.add_child(patrols)
	patrols.owner = _world
	var legend := _world.get_node_or_null("PreviewLegend/Legend/Description") as Label
	if legend != null:
		legend.text = "Мир · %d квадратов\n© OpenStreetMap contributors · ODbL" % index["chunks"].size()
	_viewport.remove_child(_world)
	_viewport.free()
	_viewport = null
	# Assign the map script after leaving the tree so its runtime/editor callbacks
	# cannot change the saved appearance or create gameplay overlays during assembly.
	_world.set_script(Map)
	_world.set("sky_mode", mode)
	return {"ok": true}

func _validate_index(index: Dictionary) -> String:
	if index.get("schema", 0) != 1 or not index.get("chunks") is Dictionary or index["chunks"].is_empty():
		return Localization.translate("The world index has no saved squares.")
	if not _number(index.get("revision"), 1.0) or float(index["revision"]) != floorf(float(index["revision"])):
		return Localization.translate("The world index has an invalid revision.")
	if not _number(index.get("world_scale"), 1.0) or float(index["world_scale"]) > 100.0:
		return Localization.translate("The world index has an invalid scale.")
	if not _number(index.get("chunk_size_m"), 0.001):
		return Localization.translate("The world index has an invalid square size.")
	if not index.get("sources") is Array or not index.get("registry") is String \
			or not index.get("projection") is String or not index.get("local_origin") is Dictionary:
		return Localization.translate("The world index is missing source or projection information.")
	var origin: Dictionary = index["local_origin"]
	if not _number(origin.get("longitude"), -180.0) or float(origin["longitude"]) > 180.0 \
			or not _number(origin.get("latitude"), -90.0) or float(origin["latitude"]) > 90.0:
		return Localization.translate("The world index has an invalid geographic origin.")
	for source: Variant in index["sources"]:
		if not source is String:
			return Localization.translate("The world index has an invalid source path.")
	for key in index["chunks"]:
		if not key is String or not index["chunks"][key] is String:
			return Localization.translate("The world index has an invalid square scene reference.")
		var parts := str(key).split("_")
		if parts.size() != 3 or parts[0] != "chunk" or not parts[1].is_valid_int() or not parts[2].is_valid_int():
			return Localization.translate("The world index has an invalid square ID.")
	return ""

func _validate_square(source: Node, id: String, path: String, world_scale: float) -> String:
	var square := source as Node3D
	if square == null or square.get_script() != Map or square.has_meta("scene_bake"):
		return Localization.translate("Select the original editable Spatial Toolkit scenes.")
	if str(square.get("world_chunk_id")) != id or str(square.get("world_manifest_path")).simplify_path() != path:
		return Localization.translate("The square scene belongs to a different world index.")
	var bounds: Rect2 = square.get("world_chunk_bounds")
	if not bounds.has_area() or not bounds.position.is_finite() or not bounds.size.is_finite():
		return Localization.translate("The square is missing valid bounds.")
	if not is_equal_approx(float(square.get_meta("world_scale", 0.0)), world_scale):
		return Localization.translate("The square scene's scale differs from the world index.")
	if square.top_level or square.transform.basis.determinant() <= 0.00000001:
		return Localization.translate("The square root has an unsupported transform.")
	for child in square.get_children():
		if not str(child.name) in SOURCE_CHILDREN:
			return Localization.translate("An extra node requires a separate game scene: %s") % str(child.name)
	var generated := square.get_node_or_null("Generated") as Node3D
	if generated == null or generated.top_level or not generated.has_meta("source"):
		return Localization.translate("The square is missing its original Generated map.")
	for child in generated.get_children():
		if not str(child.name) in Map.LAYERS or not child is SpatialLayer3D:
			return Localization.translate("An extra Generated node requires a separate game scene: %s") % str(child.name)
	if not square.get_node_or_null("FlatGround") is MeshInstance3D \
			or not square.get_node_or_null("PreviewSun") is DirectionalLight3D \
			or not square.get_node_or_null("PreviewEnvironment") is WorldEnvironment \
			or not square.get_node_or_null("OverviewCamera") is Camera3D \
			or square.get_node_or_null("PreviewLegend") == null:
		return Localization.translate("The square is missing a required ground, lighting, or camera node.")
	if str(square.get("sky_mode")) not in ["day", "night"]:
		return Localization.translate("The source scene has an invalid sky mode.")
	return ""

func _world_file(directory: String, relative: String) -> String:
	if relative.is_empty() or relative.is_absolute_path():
		return ""
	var path := directory.path_join(relative).simplify_path()
	return path if path.begins_with(directory.trim_suffix("/") + "/") else ""

func _transformed_bounds(bounds: Rect2, transform: Transform3D) -> Rect2:
	var first := transform * Vector3(bounds.position.x, 0, bounds.position.y)
	var result := Rect2(Vector2(first.x, first.z), Vector2.ZERO)
	for corner in [bounds.position, Vector2(bounds.end.x, bounds.position.y), bounds.end,
			Vector2(bounds.position.x, bounds.end.y)]:
		var point := transform * Vector3(corner.x, 0, corner.y)
		result = result.expand(Vector2(point.x, point.z))
	return result

func _number(value: Variant, minimum: float) -> bool:
	return (value is float or value is int) and is_finite(float(value)) and float(value) >= minimum

func _cancelled(host: Node, cancelled: Callable) -> bool:
	return _stopped or not is_instance_valid(host) or not host.is_inside_tree() \
		or (cancelled.is_valid() and bool(cancelled.call()))

func _cancel() -> Dictionary:
	dispose()
	return {"ok": false, "cancelled": true, "error": Localization.translate("World assembly cancelled.")}

func _error(message: String) -> Dictionary:
	dispose()
	return {"ok": false, "error": message}

func _move_branch(node: Node, parent: Node) -> void:
	_clear_owner(node)
	node.get_parent().remove_child(node)
	parent.add_child(node, true)
	_own_branch(node)

func _clear_owner(node: Node) -> void:
	for child in node.get_children():
		_clear_owner(child)
	node.owner = null

func _own_branch(node: Node) -> void:
	node.owner = _world
	for child in node.get_children():
		_own_branch(child)

func dispose() -> void:
	_stopped = true
	if is_instance_valid(_source):
		_source.free()
	_source = null
	if is_instance_valid(_world):
		_world.free()
	_world = null
	if is_instance_valid(_viewport):
		_viewport.free()
	_viewport = null
