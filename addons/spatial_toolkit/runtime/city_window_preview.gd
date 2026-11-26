extends Node3D
## Streams decorative 3D windows near the drone from the saved facade layout.

const Frames := preload("res://addons/spatial_toolkit/runtime/facade_window_preview.gd")
const Layout := preload("res://addons/spatial_toolkit/runtime/facade_window_layout.gd")
const Atlas := preload("res://addons/spatial_toolkit/runtime/facade_window_atlas.gd")
const Layers := preload("res://addons/spatial_toolkit/core/spatial_layers.gd")
const BreakablePane := preload("res://addons/spatial_toolkit/runtime/breakable_window.gd")
const NightStyle := preload("res://addons/spatial_toolkit/runtime/night_city_style.gd")
const FACADE := "res://addons/spatial_toolkit/materials/building_facade.gdshader"
const DETAIL_RADIUS_M := 52.0
const VIEW_RADIUS_M := 112.0
const RANGE_HYSTERESIS_M := 4.0
const MAX_DETAILED_WINDOWS := 1800
const MAX_SIMPLE_WINDOWS := 6500
const LOWRISE_DETAIL_RADIUS_M := 32.0
const MAX_LOWER_FRAMES := 24
const SIMPLE_POOL := 2
const LOWRISE_POOL := 3
const RECESSED_DETAIL_POOL := 0
const RECESSED_SIMPLE_POOL := 1
const RECESSED_DETAIL_RADIUS_M := 30.0
const MAX_RECESSED_DETAIL_FRAMES := 112
const RECESS_DEPTH_M := 0.18
const FRAME_SETBACK_M := 0.055
const FRAME_DEPTH_M := 0.09

@export var apartment_library: PackedScene
@export var factory_library: PackedScene
@export var lowrise_library: PackedScene
@export var lowrise_source_ids := PackedStringArray()
@export var replace_all_frames := false

var _player: Node3D
var _scale := 1.0
var _refresh := 0.0
var _entries: Array[Dictionary] = []
var _pools: Array[MultiMeshInstance3D] = []
var _models: Array[Dictionary] = []
var _lowrise_frame: ArrayMesh
var _recessed_frames := false

func _ready() -> void:
	set_process(false)
	var map := get_parent().get_parent() as Node3D
	_player = map.get_node_or_null("FlyPlayer") as Node3D
	var buildings := Layers.buildings(map)
	var panes := map.get_node_or_null("BreakableWindows")
	if buildings.is_empty():
		return
	var path := map.scene_file_path.get_base_dir().path_join("export_preview.spatial.json")
	if not FileAccess.file_exists(path):
		return
	var spatial: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if not spatial is Dictionary or not spatial.get("features") is Array:
		return
	_scale = float(map.get_meta("world_scale", 1.0))
	if lowrise_library != null and (replace_all_frames or not lowrise_source_ids.is_empty()):
		_lowrise_frame = Frames.extract_frame(lowrise_library)
		if _lowrise_frame == null or _lowrise_frame.get_surface_count() == 0 \
				or _lowrise_frame.get_aabb().size.x <= 0.0 or _lowrise_frame.get_aabb().size.y <= 0.0 \
				or (replace_all_frames and _lowrise_frame.get_aabb().size.z <= 0.0):
			_lowrise_frame = null
			push_warning("Spatial Toolkit: industrial window mesh unavailable")
	_recessed_frames = replace_all_frames and _lowrise_frame != null
	var sources := {}
	for feature: Dictionary in spatial["features"]:
		if feature.get("kind") == "building":
			sources[feature["id"]] = feature
	# Facade masks and legacy openings must be resolved before the first draw.
	var sealed := {}
	for building in buildings:
		if building.mesh == null or not building.is_visible_in_tree():
			continue
		if Layers.effective(building).get("decorative_windows") == SpatialBuildingLayer3D.DecorativeWindows.HIDE:
			continue
		var id := str(building.get_meta("source_id", ""))
		if sources.has(id) and _register_building(building, sources[id]):
			sealed[id] = true
	if is_instance_valid(panes):
		_remove_sealed_panes(panes, sealed)
	if _player == null or _entries.is_empty():
		return
	if _recessed_frames:
		_add_pool(_lowrise_frame, MAX_RECESSED_DETAIL_FRAMES, false)
		_pools[RECESSED_DETAIL_POOL].name = "RecessedIndustrialFrames"
		_add_pool(Frames.simple_industrial_frame(), MAX_SIMPLE_WINDOWS, false)
		_pools[RECESSED_SIMPLE_POOL].name = "RecessedIndustrialFramesLOD"
	elif not _add_legacy_pools(NightStyle.mode_for(map) == NightStyle.NIGHT):
		return
	set_process(true)
	_update_visible_windows()

func _remove_sealed_panes(panes: Node, sealed: Dictionary) -> void:
	var remaining := panes.get_child_count()
	for pane in panes.get_children():
		if pane is BreakablePane and sealed.has(str(pane.get_meta("source_id", ""))):
			pane.shatter()
			remaining -= 1
	if remaining == 0:
		panes.queue_free()

func _add_legacy_pools(night: bool) -> bool:
	if apartment_library == null or factory_library == null:
		return false
	_models.append(Frames.extract_module(apartment_library, "window_centered_small_01", night))
	_models.append(Frames.extract_module(factory_library, "window_centered_medium_02", night))
	for model in _models:
		var glass: AABB = model["glass"]
		if model["mesh"].get_surface_count() == 0 or glass.size.x <= 0.0 or glass.size.y <= 0.0:
			push_warning("Spatial Toolkit: modular window library unavailable")
			return false
		_add_pool(model["mesh"], MAX_DETAILED_WINDOWS)
	_add_pool(Frames.simple_window(night), MAX_SIMPLE_WINDOWS)
	if _lowrise_frame != null:
		_add_pool(_lowrise_frame, MAX_LOWER_FRAMES)
		_pools[LOWRISE_POOL].name = "IndustrialGroundFloorFrames"
	return true

func _add_pool(mesh: Mesh, capacity: int, custom_data := true) -> void:
	var pool := MultiMeshInstance3D.new()
	pool.multimesh = MultiMesh.new()
	pool.multimesh.transform_format = MultiMesh.TRANSFORM_3D
	pool.multimesh.use_custom_data = custom_data
	pool.multimesh.mesh = mesh
	pool.multimesh.instance_count = capacity
	pool.multimesh.visible_instance_count = 0
	pool.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(pool)
	_pools.append(pool)

func _register_building(building: MeshInstance3D, source: Dictionary) -> bool:
	var tags: Dictionary = source["source"].get("tags", {})
	var kind := 1 if tags.get("building") in ["industrial", "warehouse", "factory", "service"] else 0
	var material := _facade_material(building)
	if material == null:
		return false
	var height: Variant = material.get_shader_parameter("floor_height")
	var seed := int(material.get_shader_parameter("building_seed"))
	var bounds := building.get_aabb()
	var geometry: Dictionary = source["geometry"]
	var coordinates: Array = geometry["coordinates"]
	if geometry["type"] == "Polygon":
		coordinates = [coordinates]
	var long_axis := Layout.long_facade_axis(coordinates)
	Frames.seal_openings(building, get_parent().get_parent() as Node3D, _scale)
	var floor_height := maxf(2.0, float(height) if height != null else 3.0)
	var wall_height := float(source.get("wall_height_m", source["height_m"]))
	var lowrise := _lowrise_frame != null and kind == 1 and str(tags.get("building:levels", "")) == "1" \
		and lowrise_source_ids.has(str(source["id"]))
	var runs := Layout.build(coordinates, long_axis, kind == 1,
		str(building.get_meta("source_id")).hash(), Atlas.WIDTH_M * 0.5)
	var layout := Atlas.build(building.mesh, runs, _scale, floor_height, wall_height, 0 if lowrise else 1, seed)
	Frames.apply_section_layout(building, layout, floor_height, RECESS_DEPTH_M if _recessed_frames else 0.0)
	_entries.append({
		"building": building, "kind": kind, "walls": layout["walls"], "wall_height": wall_height, "lowrise": lowrise,
		"half_height": layout["vertical"].y,
		"bounds": Rect2(Vector2(bounds.position.x, bounds.position.z) / _scale,
			Vector2(bounds.size.x, bounds.size.z) / _scale),
	})
	return int(building.get_meta("sealed_opening_count", 0)) > 0

func _facade_material(building: MeshInstance3D) -> ShaderMaterial:
	for index in building.mesh.get_surface_count():
		var material := building.get_active_material(index) as ShaderMaterial
		if material != null and material.shader != null and material.shader.resource_path == FACADE:
			return material
	return null

func _process(delta: float) -> void:
	_refresh -= delta
	if _refresh <= 0.0:
		_refresh = 0.24
		_update_visible_windows()

func _update_visible_windows() -> void:
	var eye := to_local(_player.global_position) / _scale
	var eye_xz := Vector2(eye.x, eye.z)
	var candidates: Array[Dictionary] = []
	for entry in _entries:
		var bounds: Rect2 = entry["bounds"]
		if not bounds.grow(VIEW_RADIUS_M + RANGE_HYSTERESIS_M).has_point(eye_xz):
			continue
		var building: MeshInstance3D = entry["building"]
		var cuts: Array = building.get_meta("modular_window_cuts", [])
		for wall: Dictionary in entry["walls"]:
			var closest := Geometry2D.get_closest_point_to_segment(eye_xz, wall["a"], wall["b"])
			var height := clampf(eye.y, 0.0, entry["wall_height"])
			var distance := eye.distance_squared_to(Vector3(closest.x, height, closest.y))
			var limit := VIEW_RADIUS_M + (RANGE_HYSTERESIS_M if wall.get("visible", false) else 0.0)
			wall["visible"] = distance <= limit * limit
			if wall["visible"]:
				candidates.append({"wall": wall, "distance": distance, "kind": entry["kind"],
					"half_height": entry["half_height"], "cuts": cuts, "lowrise": entry["lowrise"]})
	if _recessed_frames:
		_update_recessed_windows(eye, candidates)
	else:
		_update_legacy_windows(candidates)

func _update_legacy_windows(candidates: Array[Dictionary]) -> void:
	candidates.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a["distance"] < b["distance"])
	var counts := PackedInt32Array()
	counts.resize(_pools.size())
	var detailed_count := 0
	for item in candidates:
		var wall: Dictionary = item["wall"]
		var windows: Array = wall["windows"]
		var lowrise: bool = item["lowrise"]
		var radius := LOWRISE_DETAIL_RADIUS_M if lowrise else DETAIL_RADIUS_M
		var detail_limit := radius + (RANGE_HYSTERESIS_M if wall.get("detailed", false) else 0.0)
		var detailed: bool = item["distance"] <= detail_limit * detail_limit \
			and detailed_count + windows.size() <= MAX_DETAILED_WINDOWS \
			and (not lowrise or counts[LOWRISE_POOL] + windows.size() <= MAX_LOWER_FRAMES)
		wall["detailed"] = detailed
		if not detailed and counts[SIMPLE_POOL] + windows.size() > MAX_SIMPLE_WINDOWS:
			continue
		var pool := SIMPLE_POOL
		if detailed:
			pool = LOWRISE_POOL if lowrise else item["kind"]
		var bounds := _pools[pool].multimesh.mesh.get_aabb()
		var frame_scale := Vector3(Atlas.WIDTH_M / bounds.size.x, float(item["half_height"]) * 2.0 / bounds.size.y, 0.55) * _scale
		var depth := 0.05
		if pool == LOWRISE_POOL:
			depth = bounds.position.z
		elif detailed:
			var glass: AABB = _models[pool]["glass"]
			depth = glass.end.z
		var anchor := Vector3(bounds.get_center().x, bounds.get_center().y, depth)
		for window: Dictionary in windows:
			var frame: Transform3D = window["frame"]
			if _inside_cut(frame.origin, item["cuts"]):
				continue
			var sized := frame.basis.scaled_local(frame_scale)
			var origin := (frame.origin + frame.basis.z * 0.035) * _scale - sized * anchor
			_pools[pool].multimesh.set_instance_transform(counts[pool], Transform3D(sized, origin))
			_pools[pool].multimesh.set_instance_custom_data(counts[pool], window["light"])
			counts[pool] += 1
			detailed_count += int(detailed)
	for index in _pools.size():
		_pools[index].multimesh.visible_instance_count = counts[index]

func _update_recessed_windows(eye: Vector3, walls: Array[Dictionary]) -> void:
	var candidates: Array[Dictionary] = []
	var view_distance := VIEW_RADIUS_M + RANGE_HYSTERESIS_M
	for item in walls:
		for window: Dictionary in item["wall"]["windows"]:
			var frame: Transform3D = window["frame"]
			var distance := eye.distance_squared_to(frame.origin)
			if distance <= view_distance * view_distance and not _inside_cut(frame.origin, item["cuts"]):
				candidates.append({"window": window, "distance": distance, "order": candidates.size(),
					"half_height": item["half_height"]})
	candidates.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return a["order"] < b["order"] if a["distance"] == b["distance"] else a["distance"] < b["distance"])
	var detail_mesh := _pools[RECESSED_DETAIL_POOL].multimesh
	var simple_mesh := _pools[RECESSED_SIMPLE_POOL].multimesh
	var meshes: Array[MultiMesh] = [detail_mesh, simple_mesh]
	var bounds: Array[AABB] = [detail_mesh.mesh.get_aabb(), simple_mesh.mesh.get_aabb()]
	var counts := PackedInt32Array([0, 0])
	for item in candidates:
		var window: Dictionary = item["window"]
		var detail_radius := RECESSED_DETAIL_RADIUS_M
		if window.get("detailed", false):
			detail_radius += RANGE_HYSTERESIS_M
		var detailed: bool = item["distance"] <= detail_radius * detail_radius \
			and counts[RECESSED_DETAIL_POOL] < MAX_RECESSED_DETAIL_FRAMES
		window["detailed"] = detailed
		var pool := RECESSED_DETAIL_POOL if detailed else RECESSED_SIMPLE_POOL
		if pool == RECESSED_SIMPLE_POOL and counts[pool] >= MAX_SIMPLE_WINDOWS:
			continue
		var frame: Transform3D = window["frame"]
		var pose := recessed_frame_pose(frame, bounds[pool], item["half_height"], _scale)
		meshes[pool].set_instance_transform(counts[pool], pose)
		counts[pool] += 1
	for index in _pools.size():
		_pools[index].multimesh.visible_instance_count = counts[index]

static func recessed_frame_pose(frame: Transform3D, bounds: AABB, half_height: float,
		world_scale: float) -> Transform3D:
	# Frame bases point outward along +Z. Anchor the front of both meshes behind the wall.
	var scale_factor := Vector3(Atlas.WIDTH_M / bounds.size.x, half_height * 2.0 / bounds.size.y,
		FRAME_DEPTH_M / bounds.size.z) * world_scale
	var basis := frame.basis.scaled_local(scale_factor)
	var anchor := Vector3(bounds.get_center().x, bounds.get_center().y, bounds.end.z)
	var front := (frame.origin - frame.basis.z * FRAME_SETBACK_M) * world_scale
	return Transform3D(basis, front - basis * anchor)

func _inside_cut(point: Vector3, cuts: Array) -> bool:
	for contour: Array in cuts:
		if contour.all(func(plane: Plane) -> bool: return plane.distance_to(point * _scale) <= 0.0):
			return true
	return false
