@tool
extends Node3D
## Native scene generation from deterministic, locally projected metre geometry.
## Does not regenerate in _ready; callers must explicitly await build_from_data.

const BREAKABLE_WINDOW := preload("res://addons/spatial_toolkit/runtime/breakable_window.gd")
const ROAD_PATROLS := preload("res://addons/spatial_toolkit/runtime/road_patrols.gd")
const NIGHT_STYLE := preload("res://addons/spatial_toolkit/runtime/night_city_style.gd")
const EDITOR_SKY_PREVIEW := preload("res://addons/spatial_toolkit/core/editor_sky_preview.gd")
const OVERVIEW_PAN_RATE := 0.9
const BUILD_FRAME_BUDGET_USEC := 12000
const LAYERS: Array[String] = ["Landuse", "Water", "Roads", "Paths", "PlannedRoads", "Buildings"]
const COLLISION_BUILDER := preload("res://addons/spatial_toolkit/core/building_collision_generator.gd")
const STYLE_MODULE := preload("res://addons/spatial_toolkit/core/map_style_module.gd")
const FACADE_WINDOWS := preload("res://addons/spatial_toolkit/core/facade_windows.gd")
const LAYER_TREE := preload("res://addons/spatial_toolkit/core/spatial_layers.gd")
const FLIGHT_MODULE := preload("res://addons/spatial_toolkit/core/map_flight_module.gd")
const FlightInput := preload("res://addons/spatial_toolkit/runtime/flight_input.gd")
const CHUNK_INFO := preload("res://addons/spatial_toolkit/core/world_chunk_info.gd")
const Localization := preload("res://addons/spatial_toolkit/ui/editor_localization.gd")
var _target := Vector3.ZERO
var _yaw := 0.0
var _pitch := 0.85
var _distance := 2300.0
var _building := false
var _layer_update_queued := false
var _sky_preview: EDITOR_SKY_PREVIEW
var _editor_saving := false
var _derived_chunk_info: Dictionary = {}

@export_storage var world_manifest_path := ""
@export_storage var world_chunk_id := ""
@export_storage var world_chunk_bounds := Rect2()
@export_storage var world_chunk_info: Dictionary = {}
@export var attribute_bank: SpatialAttributeBank:
	set(value):
		if attribute_bank == value:
			return
		_disconnect_attribute_bank()
		attribute_bank = value
		if is_inside_tree():
			_connect_attribute_bank()
			_queue_attribute_bank_refresh()

@export_group("Lighting and Atmosphere")
@export_enum("day", "night") var sky_mode: String = "day":
	set(value):
		sky_mode = value
		set_meta(NIGHT_STYLE.MODE, StringName(value))
		if is_inside_tree():
			if Engine.is_editor_hint() and attribute_bank != null and get_tree().edited_scene_root == self:
				attribute_bank.set_world_sky_mode(StringName(value))
			_queue_sky_refresh()
@export var sky_settings: SpatialSkySettings:
	set(value):
		if sky_settings == value:
			return
		if sky_settings != null:
			sky_settings.changed.disconnect(_sky_settings_changed)
		sky_settings = value
		if sky_settings != null:
			sky_settings.changed.connect(_sky_settings_changed)
		_sky_settings_changed()

func _sky_settings_changed() -> void:
	if is_inside_tree():
		if Engine.is_editor_hint() and attribute_bank != null and get_tree().edited_scene_root == self:
			attribute_bank.set_world_sky_settings(sky_settings)
		_queue_sky_refresh()

func _queue_sky_refresh() -> void:
	if Engine.is_editor_hint():
		_refresh_editor_sky.call_deferred()
	elif has_node("BakedChunks"):
		_refresh_sky.call_deferred()

func get_world_chunk_info() -> Dictionary:
	if not world_chunk_info.is_empty():
		return world_chunk_info
	if _derived_chunk_info.is_empty():
		_derived_chunk_info = CHUNK_INFO.collect(self)
	return _derived_chunk_info

func _validate_property(property: Dictionary) -> void:
	Localization.localize_inspector_group(property)

func _get_property_list() -> Array[Dictionary]:
	if world_chunk_id.is_empty():
		return []
	return [
		{"name": Localization.translate("World Chunk"), "type": TYPE_NIL, "usage": PROPERTY_USAGE_GROUP,
			"hint_string": "chunk_information/"},
		{"name": "chunk_information/id", "type": TYPE_STRING,
			"usage": PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY},
		{"name": "chunk_information/contents", "type": TYPE_STRING,
			"hint": PROPERTY_HINT_MULTILINE_TEXT,
			"usage": PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY},
	]

func _get(property: StringName) -> Variant:
	if property == &"chunk_information/id":
		return world_chunk_id
	if property == &"chunk_information/contents":
		return CHUNK_INFO.describe(get_world_chunk_info())
	return null

func apply_attribute_bank() -> void:
	if attribute_bank != null and is_inside_tree() and not is_queued_for_deletion():
		attribute_bank.apply_to_map(self)

func _queue_attribute_bank_refresh() -> void:
	apply_attribute_bank.call_deferred()

func _connect_attribute_bank() -> void:
	if attribute_bank != null and not attribute_bank.changed.is_connected(_queue_attribute_bank_refresh):
		attribute_bank.changed.connect(_queue_attribute_bank_refresh)

func _disconnect_attribute_bank() -> void:
	if attribute_bank != null and attribute_bank.changed.is_connected(_queue_attribute_bank_refresh):
		attribute_bank.changed.disconnect(_queue_attribute_bank_refresh)

func apply_layer_styles() -> void:
	_layer_update_queued = false
	if _sky_preview != null:
		_sky_preview.restore_facades()
	LAYER_TREE.apply(self)
	if _sky_preview != null:
		_sky_preview.refresh_facades(self)


func queue_layer_style_update() -> void:
	if not _layer_update_queued and not _building:
		_layer_update_queued = true
		apply_layer_styles.call_deferred()

## An optional progress callback receives a phase and counts and returns whether to continue.
func build_from_data(data: Dictionary, report: Dictionary = {}, options: Dictionary = {},
		on_progress: Callable = Callable()) -> Dictionary:
	if _building or get_node_or_null("Generated") != null:
		return {"success": false, "error": "Generated already exists or build is active; use a fresh map root"}
	for reserved: String in ["FlatGround", "PreviewSun", "PreviewEnvironment", "OverviewCamera", "PreviewLegend", "FlyPlayer", "BreakableWindows"]:
		if get_node_or_null(reserved) != null:
			return {"success": false, "error": "Reserved map child already exists: " + reserved}
	var error := _validate_header(data)
	if not error.is_empty():
		return {"success": false, "error": error}
	if not is_inside_tree():
		return {"success": false, "error": "Attach the fresh map root to SceneTree before building"}
	for key: String in ["building_collisions", "daylight", "drone", "open_windows", "breakable_windows"]:
		if options.has(key) and not options[key] is bool:
			return {"success": false, "error": key + " must be a boolean"}
	var world_scale := float(data.get("world_scale", 1.0))
	var open_windows: bool = data.get("open_windows", false)
	if options.has("world_scale"):
		if not _finite_number(options["world_scale"]) or not is_equal_approx(float(options["world_scale"]), world_scale):
			return {"success": false, "error": "world_scale must match the prepared gameplay geometry"}
	if options.has("open_windows") and options["open_windows"] != open_windows:
		return {"success": false, "error": "open_windows must match the prepared gameplay geometry"}
	var controller: Variant = options.get("flight_controller", FLIGHT_MODULE.default_controller())
	if not controller is String or not FLIGHT_MODULE.CONTROLLERS.has(controller):
		return {"success": false, "error": "Invalid flight controller"}
	var collisions_enabled: bool = options.get("building_collisions", true)
	var breakable_windows: bool = options.get("breakable_windows", false)
	if breakable_windows and (not collisions_enabled or not open_windows):
		return {"success": false, "error": "Breakable windows require physical facade apertures"}
	var daylight_enabled: bool = options.get("daylight", true)
	var drone_enabled: bool = options.get("drone", true)
	var collisions := COLLISION_BUILDER.new_report(collisions_enabled)
	report["collisions"] = collisions
	var modules := {"daylight": {"enabled": false, "success": true}, "drone": {"enabled": false, "success": true}, "flat_surfaces": {"enabled": true, "success": true, "meshes": 0}}
	report["modules"] = modules
	var settings_value: Variant = report.get("settings", {})
	var settings: Dictionary = settings_value if settings_value is Dictionary else {}
	settings["building_collisions"] = collisions_enabled
	settings["daylight"] = daylight_enabled
	settings["drone"] = drone_enabled
	settings["flight_controller"] = controller
	settings["world_scale"] = world_scale
	settings["open_windows"] = open_windows
	settings["breakable_windows"] = breakable_windows
	if open_windows and data.get("apertures") is Dictionary:
		settings["apertures"] = data["apertures"]
	report["settings"] = settings
	# The CRS/origin and source dimensions remain geographic evidence. Mesh
	# vertices are already transformed; never scale the drone or nodes again.
	set_meta("world_scale", world_scale)
	set_meta("open_windows", open_windows)
	_building = true
	var generated := Node3D.new()
	generated.name = "Generated"
	add_child(generated)
	generated.owner = self
	var osm_rules: Dictionary = data.get("osm_rules", {})
	if not osm_rules.is_empty():
		generated.set_meta("osm_rules", osm_rules)
		report["osm_rules"] = osm_rules
	for key: String in ["source", "projection", "local_origin"]:
		generated.set_meta(key, data[key])
	generated.set_meta("units", "meters")
	generated.set_meta("coordinate_space", "gameplay_meters")
	generated.set_meta("world_scale", world_scale)
	generated.set_meta("open_windows", open_windows)
	generated.set_meta("source_to_game", {"uniform_scale": world_scale, "anchor": "local_origin"})
	generated.set_meta("axes", "X east, Y up, Z south")
	generated.set_meta("generation_report", report)
	var glazing: Node3D
	var glass_assets: Dictionary = {}
	if breakable_windows:
		glazing = Node3D.new()
		glazing.name = "BreakableWindows"
		add_child(glazing)
		glazing.owner = self
		var glass := StandardMaterial3D.new()
		glass.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		glass.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		glass.albedo_color = Color(0.13, 0.40, 0.53, 0.75)
		glass_assets["material"] = glass
	var layers: Dictionary = {}
	var subgroups: Dictionary = {}
	for layer_name: String in LAYERS:
		var layer := LAYER_TREE.new_root(layer_name)
		generated.add_child(layer)
		layer.owner = self
		layers[layer_name] = layer
	var materials: Dictionary = {}
	var counts: Dictionary = {}
	var seen: Dictionary = {}
	var facade_layouts := {}
	var window_count := 0
	var window_buildings := 0
	var items: Array = data["items"]
	if on_progress.is_valid() and not on_progress.call("objects", 0, items.size()):
		return _cancel_build()
	var yield_after := Time.get_ticks_usec() + BUILD_FRAME_BUDGET_USEC
	for item_index: int in items.size():
		var value: Variant = items[item_index]
		error = _validate_item(value)
		if not error.is_empty():
			_building = false
			return {"success": false, "error": "Item %d: %s" % [item_index, error]}
		var entry: Dictionary = value
		var identity: String = str(entry["layer"]) + ":" + str(entry["id"])
		if seen.has(identity):
			_building = false
			return {"success": false, "error": "Duplicate source identity: " + identity.left(180)}
		seen[identity] = true
		var style: String = entry["style"]
		if not materials.has(style):
			materials[style] = _material(style)
		var mesh_result := await _build_item_mesh(entry, materials[style])
		var instance := MeshInstance3D.new()
		instance.name = _feature_name(str(entry["id"]), identity)
		instance.mesh = mesh_result["mesh"]
		if instance.mesh == null:
			instance.free()
			_building = false
			return {"success": false, "error": "Could not create mesh for " + identity.left(180)}
		instance.set_meta("source_id", entry["id"])
		instance.set_meta("source", entry.get("source", data["source"]))
		instance.set_meta("source_tags", entry.get("tags", {}))
		instance.set_meta("assumptions", entry.get("assumptions", []))
		instance.set_meta("units", "meters")
		instance.set_meta("world_scale", world_scale)
		if collisions_enabled and entry["layer"] == "Buildings":
			instance.set_meta("fracture_cell_size_m", 8.0 * world_scale)
		if breakable_windows and entry["layer"] == "Buildings":
			instance.set_meta("painted_windows", true)
		if int(mesh_result["floor_surface_index"]) >= 0:
			instance.set_meta("floor_surface_index", mesh_result["floor_surface_index"])
			instance.set_meta("base_floor_y_m", mesh_result["base_floor_y_m"])
		if int(mesh_result["foundation_surface_index"]) >= 0:
			instance.set_meta("foundation_surface_index", mesh_result["foundation_surface_index"])
		if mesh_result.has("measured_opening_surfaces"):
			instance.set_meta("measured_opening_surfaces", mesh_result["measured_opening_surfaces"])
		for gameplay_key: String in ["source_dimensions_m", "game_dimensions_m", "facade_openings", "coincident_source_ids"]:
			if entry.has(gameplay_key):
				instance.set_meta(gameplay_key, entry[gameplay_key])
		for dimension: String in ["height_m", "width_m", "wall_height_m", "roof_height_m", "foundation_bottom_y_m", "source_foundation_bottom_y_m", "foundation_render_top_y_m", "source_foundation_render_top_y_m"]:
			if entry.get(dimension) != null:
				instance.set_meta(dimension, entry[dimension])
		for provenance_key: String in ["height_source", "roof_source", "width_source"]:
			if entry.get(provenance_key) != null:
				instance.set_meta(provenance_key, entry[provenance_key])
		var layer := LAYER_TREE.layer_for(layers, subgroups, entry["layer"], instance, self, osm_rules)
		layer.add_child(instance)
		instance.owner = self
		if collisions_enabled and str(entry["layer"]) == "Buildings":
			var collision_result := COLLISION_BUILDER.add_to_building(instance, self)
			COLLISION_BUILDER.append_result(collisions, collision_result)
			if int(collision_result.get("created", 0)) + int(collision_result.get("existing", 0)) != 1:
				collisions["success"] = false
				_building = false
				return {"success": false, "error": "Could not create building collision for " + str(entry["id"]).left(180), "collisions": collisions}
		if glazing != null and entry["layer"] == "Buildings":
			var openings: Dictionary = entry.get("facade_openings", {})
			var samples: Variant = openings.get("samples", [])
			var sample_count: Variant = openings.get("count", 0)
			var wall_thickness: Variant = openings.get("wall_thickness_m", 0.0)
			if not samples is Array or not _finite_number(sample_count) or samples.size() != float(sample_count) \
					or not _finite_number(wall_thickness) or float(wall_thickness) < 0.0:
				_building = false
				return {"success": false, "error": "Incomplete glazing coordinates for " + identity.left(180)}
			for sample: Variant in samples:
				if not _valid_glazing_sample(sample):
					_building = false
					return {"success": false, "error": "Invalid glazing coordinates for " + identity.left(180)}
				_add_breakable_window(glazing, sample, str(entry["id"]), float(wall_thickness), glass_assets)
		if entry["layer"] == "Buildings" and entry.has("facade_geometry"):
			var layout := FACADE_WINDOWS.prepare(instance, entry["facade_geometry"], daylight_enabled)
			if daylight_enabled:
				facade_layouts[instance] = layout
			var placements: Dictionary = instance.get_meta(FACADE_WINDOWS.METADATA)
			window_count += int(placements["count"])
			window_buildings += int(placements["count"] > 0)
		var layer_name: String = entry["layer"]
		counts[layer_name] = int(counts.get(layer_name, 0)) + 1
		if Time.get_ticks_usec() >= yield_after:
			if on_progress.is_valid() and not on_progress.call("objects", item_index + 1, items.size()):
				return _cancel_build()
			await get_tree().process_frame
			yield_after = Time.get_ticks_usec() + BUILD_FRAME_BUDGET_USEC
	if on_progress.is_valid() and not on_progress.call("objects", items.size(), items.size()):
		return _cancel_build()
	if glazing != null:
		modules["breakable_windows"] = {"enabled": true, "count": glazing.get_child_count()}
	modules["facade_windows"] = {"count": window_count, "buildings": window_buildings, "painted": daylight_enabled}
	var bounds: Array = data["bounds_xz_m"]
	_setup_view(bounds)
	_setup_legend(counts, data["source"], report)
	if daylight_enabled:
		var styled := await STYLE_MODULE.apply_to_scene_batched(self, facade_layouts, on_progress)
		styled["enabled"] = true
		modules["daylight"] = styled
		if not styled.get("success", false):
			_building = false
			return {"success": false, "error": "Map style module: " + str(styled.get("error", "unknown error")), "modules": modules, "collisions": collisions}
		modules["flat_surfaces"] = {"enabled": true, "success": true, "meshes": int(styled.get("flat_surfaces", 0)), "building_floors": int(styled.get("building_floors", 0)), "building_foundations": int(styled.get("building_foundations", 0))}
	else:
		var flat := await STYLE_MODULE.apply_flat_surfaces_batched(self, on_progress)
		modules["flat_surfaces"] = flat
		if not flat.get("success", false):
			_building = false
			return {"success": false, "error": "Flat surface module: " + str(flat.get("error", "unknown error")), "modules": modules, "collisions": collisions}
	if drone_enabled:
		var flight: Dictionary = FLIGHT_MODULE.apply_to_scene(self, controller)
		flight["enabled"] = true
		modules["drone"] = flight
		if not flight.get("success", false):
			_building = false
			return {"success": false, "error": "Map flight module: " + str(flight.get("error", "unknown error")), "modules": modules, "collisions": collisions}
	generated.set_meta("generation_report", report)
	generated.set_meta("building_collisions", collisions_enabled)
	generated.set_meta("modules", modules)
	_building = false
	return {"success": true, "counts": counts, "source": data["source"].get("path", ""), "bounds_xz_m": bounds, "collisions": collisions, "modules": modules}

func _cancel_build() -> Dictionary:
	_building = false
	return {"success": false, "cancelled": true}

func _build_item_mesh(entry: Dictionary, material: Material) -> Dictionary:
	if entry.has("measured_openings"):
		return await _build_measured_opening_mesh(entry, material)
	var vertices: Array = entry["vertices"]
	var normals: Array = entry["normals"]
	var openings: Dictionary = entry.get("facade_openings", {})
	var separate_floor: bool = str(entry["layer"]) == "Buildings" and openings.get("enabled", false)
	var separate_foundation: bool = str(entry["layer"]) == "Buildings" and entry.has("foundation_render_top_y_m")
	var foundation_top := float(entry["foundation_render_top_y_m"]) if separate_foundation else 0.0
	var base_y := INF
	if separate_floor:
		if openings.has("base_floor_y_m"):
			# Foundation skirts can extend below the actual interior floor.
			base_y = float(openings["base_floor_y_m"])
		else:
			# Older payloads contained no skirt and placed the floor at min Y.
			for vertex: Array in vertices:
				base_y = minf(base_y, float(vertex[1]))
	var opaque := SurfaceTool.new()
	opaque.begin(Mesh.PRIMITIVE_TRIANGLES)
	opaque.set_material(material)
	var floor_surface := SurfaceTool.new()
	floor_surface.begin(Mesh.PRIMITIVE_TRIANGLES)
	floor_surface.set_material(material)
	var foundation_surface := SurfaceTool.new()
	foundation_surface.begin(Mesh.PRIMITIVE_TRIANGLES)
	foundation_surface.set_material(material)
	var floor_vertices := 0
	var foundation_vertices := 0
	var opaque_vertices := 0
	var yield_after := Time.get_ticks_usec() + BUILD_FRAME_BUDGET_USEC
	for triangle: int in range(0, vertices.size(), 3):
		var is_floor := separate_floor
		if is_floor:
			for offset: int in 3:
				var vertex: Array = vertices[triangle + offset]
				var normal: Array = normals[triangle + offset]
				if absf(float(vertex[1]) - base_y) > 0.00001 or float(normal[1]) < 0.99:
					is_floor = false
					break
		var is_foundation := separate_foundation and not is_floor
		if is_foundation:
			for offset: int in 3:
				var vertex: Array = vertices[triangle + offset]
				var normal: Array = normals[triangle + offset]
				if float(vertex[1]) > foundation_top + 0.00001 or absf(float(normal[1])) > 0.01:
					is_foundation = false
					break
		var target := floor_surface if is_floor else foundation_surface if is_foundation else opaque
		for offset: int in 3:
			var vertex: Array = vertices[triangle + offset]
			var normal: Array = normals[triangle + offset]
			target.set_normal(Vector3(normal[0], normal[1], normal[2]))
			target.add_vertex(Vector3(vertex[0], vertex[1], vertex[2]))
		if is_floor:
			floor_vertices += 3
		elif is_foundation:
			foundation_vertices += 3
		else:
			opaque_vertices += 3
		if (triangle + 3) % 768 == 0 and Time.get_ticks_usec() >= yield_after:
			await get_tree().process_frame
			yield_after = Time.get_ticks_usec() + BUILD_FRAME_BUDGET_USEC
	if opaque_vertices == 0 and foundation_vertices == 0:
		floor_surface.index()
		return {"mesh": floor_surface.commit(), "floor_surface_index": -1, "foundation_surface_index": -1, "base_floor_y_m": base_y}
	var mesh: ArrayMesh
	if opaque_vertices > 0:
		opaque.index()
		mesh = opaque.commit()
	var floor_index := -1
	if floor_vertices > 0:
		floor_surface.index()
		floor_index = mesh.get_surface_count() if mesh != null else 0
		mesh = floor_surface.commit(mesh)
	var foundation_index := -1
	if foundation_vertices > 0:
		foundation_surface.index()
		foundation_index = mesh.get_surface_count() if mesh != null else 0
		mesh = foundation_surface.commit(mesh)
	return {"mesh": mesh, "floor_surface_index": floor_index, "foundation_surface_index": foundation_index, "base_floor_y_m": base_y}

func _build_measured_opening_mesh(entry: Dictionary, wall_material: Material) -> Dictionary:
	var measured: Dictionary = entry["measured_openings"]
	var vertices: Array = entry["vertices"]
	var normals: Array = entry["normals"]
	var material_by_role: Array[Material] = [wall_material, _material("measured_window"), _material("measured_door")]
	var tools: Array[SurfaceTool] = []
	for surface_material in material_by_role:
		var surface := SurfaceTool.new()
		surface.begin(Mesh.PRIMITIVE_TRIANGLES)
		surface.set_material(surface_material)
		tools.append(surface)
	var triangle_roles := PackedByteArray()
	triangle_roles.resize(vertices.size() / 3)
	for role in range(1, tools.size()):
		for index: Variant in measured.get("windows" if role == 1 else "doors", []):
			triangle_roles[int(index)] = role
	var used := [false, false, false]
	var yield_after := Time.get_ticks_usec() + BUILD_FRAME_BUDGET_USEC
	for triangle in triangle_roles.size():
		var role := int(triangle_roles[triangle])
		var surface := tools[role]
		used[role] = true
		for index in range(triangle * 3, triangle * 3 + 3):
			var point: Array = vertices[index]
			var normal: Array = normals[index]
			surface.set_normal(Vector3(normal[0], normal[1], normal[2]))
			surface.add_vertex(Vector3(point[0], point[1], point[2]))
		if triangle % 256 == 255 and Time.get_ticks_usec() >= yield_after:
			await get_tree().process_frame
			yield_after = Time.get_ticks_usec() + BUILD_FRAME_BUDGET_USEC
	var mesh := ArrayMesh.new()
	var opening_surfaces := PackedInt32Array()
	for role in tools.size():
		if not used[role]:
			continue
		if role > 0:
			opening_surfaces.append(mesh.get_surface_count())
		tools[role].index()
		tools[role].commit(mesh)
	return {"mesh": mesh, "floor_surface_index": -1, "foundation_surface_index": -1,
		"measured_opening_surfaces": opening_surfaces}

func _valid_glazing_sample(sample: Variant) -> bool:
	if not sample is Dictionary:
		return false
	for key in ["center", "normal"]:
		var vector: Variant = sample.get(key)
		if not vector is Array or vector.size() != 3 or not vector.all(_finite_number):
			return false
	var normal: Array = sample["normal"]
	return Vector2(float(normal[0]), float(normal[2])).length_squared() > 0.0001 \
		and _finite_number(sample.get("width_m")) and float(sample["width_m"]) > 0.0 \
		and _finite_number(sample.get("height_m")) and float(sample["height_m"]) > 0.0

func _add_breakable_window(container: Node3D, sample: Dictionary, source_id: String,
		wall_thickness: float, assets: Dictionary) -> void:
	var center: Array = sample["center"]
	var outward: Array = sample["normal"]
	var normal := Vector3(float(outward[0]), 0.0, float(outward[2])).normalized()
	var dimensions := Vector2(float(sample["width_m"]), float(sample["height_m"]))
	if not assets.has(dimensions):
		var size := Vector3(dimensions.x, dimensions.y, 0.035 * float(get_meta("world_scale")))
		var box := BoxMesh.new()
		box.size = size
		box.material = assets["material"]
		var shape := BoxShape3D.new()
		shape.size = size
		assets[dimensions] = [box, shape]
	var body := StaticBody3D.new()
	body.name = "Pane_%04d" % (container.get_child_count() + 1)
	body.set_script(BREAKABLE_WINDOW)
	body.set_meta("source_id", source_id)
	body.set_meta("units", "meters")
	body.collision_mask = 0
	body.transform = Transform3D(Basis(Vector3.UP.cross(normal), Vector3.UP, normal),
		Vector3(float(center[0]), float(center[1]), float(center[2])) - normal * wall_thickness * 0.5)
	container.add_child(body)
	body.owner = self
	var visual := MeshInstance3D.new()
	visual.name = "Glass"
	visual.mesh = assets[dimensions][0]
	visual.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	body.add_child(visual)
	visual.owner = self
	var collision := CollisionShape3D.new()
	collision.shape = assets[dimensions][1]
	body.add_child(collision)
	collision.owner = self

func _validate_header(data: Dictionary) -> String:
	var scale_value: Variant = data.get("world_scale", 1.0)
	if not _finite_number(scale_value) or float(scale_value) < 1.0 or float(scale_value) > 100.0:
		return "world_scale must be finite and between 1 and 100"
	if not data.get("open_windows", false) is bool:
		return "open_windows must be a boolean"
	if not data.get("osm_rules", {}) is Dictionary:
		return "OSM import settings must be a dictionary"
	if not data.get("source") is Dictionary or not data.get("local_origin") is Dictionary:
		return "Source provenance and local_origin dictionaries are required"
	if not data.get("projection") is String or not "+units=m" in str(data["projection"]):
		return "Explicit local metre projection is required"
	var origin: Dictionary = data["local_origin"]
	if not _finite_number(origin.get("longitude")) or not _finite_number(origin.get("latitude")):
		return "Finite longitude/latitude local origin is required"
	if absf(float(origin["longitude"])) > 180.0 or absf(float(origin["latitude"])) > 90.0:
		return "Local origin is outside WGS84 ranges"
	if not data.get("bounds_xz_m") is Array or data["bounds_xz_m"].size() != 4:
		return "Four metre bounds are required"
	var bounds: Array = data["bounds_xz_m"]
	for value: Variant in bounds:
		if not _finite_number(value):
			return "Bounds must contain finite numbers"
	if bounds[0] > bounds[2] or bounds[1] > bounds[3]:
		return "Bounds are reversed"
	if not data.get("items") is Array:
		return "Mesh items array is required"
	return ""

func _validate_item(value: Variant) -> String:
	if not value is Dictionary:
		return "Mesh item must be a dictionary"
	var entry: Dictionary = value
	if entry.get("id") == null or str(entry["id"]).is_empty():
		return "Source ID is required"
	if not entry.get("layer") in LAYERS or not entry.get("style") is String:
		return "Unsupported layer or invalid style"
	if not entry.get("tags", {}) is Dictionary or not entry.get("assumptions", []) is Array:
		return "Tags and assumptions must be dictionary and array"
	for gameplay_key: String in ["source_dimensions_m", "game_dimensions_m", "facade_openings", "facade_geometry"]:
		if entry.has(gameplay_key) and not entry[gameplay_key] is Dictionary:
			return gameplay_key + " must be a dictionary"
	if entry.has("facade_geometry") and not _valid_facade_geometry(entry["facade_geometry"]):
		return "facade_geometry must contain projected Polygon or MultiPolygon rings"
	var aliases: Variant = entry.get("coincident_source_ids", [])
	if not aliases is Array or not aliases.all(func(id: Variant) -> bool:
		return id is String and not id.is_empty()):
		return "coincident_source_ids must be an array of source IDs"
	var openings: Dictionary = entry.get("facade_openings", {})
	if openings.has("base_floor_y_m") and not _finite_number(openings["base_floor_y_m"]):
		return "base_floor_y_m must be a finite number"
	for foundation_key: String in ["foundation_bottom_y_m", "source_foundation_bottom_y_m", "foundation_render_top_y_m", "source_foundation_render_top_y_m"]:
		if entry.has(foundation_key) and not _finite_number(entry[foundation_key]):
			return foundation_key + " must be a finite number"
	for dimension: String in ["height_m", "width_m", "wall_height_m", "roof_height_m"]:
		if entry.get(dimension) != null and not _finite_number(entry[dimension]):
			return "Non-finite dimension"
	if not entry.get("vertices") is Array or not entry.get("normals") is Array:
		return "Vertex and normal arrays are required"
	var vertices: Array = entry["vertices"]
	var normals: Array = entry["normals"]
	if vertices.is_empty() or vertices.size() % 3 != 0 or vertices.size() != normals.size():
		return "Triangle vertices and normals must have equal nonzero lengths divisible by three"
	if entry.has("measured_openings"):
		var measured: Variant = entry["measured_openings"]
		if entry["layer"] != "Buildings" or openings.get("enabled", false) or not measured is Dictionary:
			return "Modeled openings require a measured building mesh"
		var seen := {}
		for role: Variant in measured:
			if role not in ["windows", "doors"] or not measured[role] is Array:
				return "Modeled openings must list window and door triangles"
			for index: Variant in measured[role]:
				if not _finite_number(index) or index < 0 or index >= vertices.size() / 3 \
						or float(index) != floorf(float(index)) or seen.has(int(index)):
					return "Invalid modeled opening triangle index"
				seen[int(index)] = true
	for vectors: Array in [vertices, normals]:
		for vector: Variant in vectors:
			if not vector is Array or vector.size() != 3:
				return "Each vertex/normal must have three components"
			for component: Variant in vector:
				if not _finite_number(component):
					return "Vertex/normal components must be finite numbers"
	return ""

func _valid_facade_geometry(geometry: Dictionary) -> bool:
	var coordinates: Variant = geometry.get("coordinates")
	if not coordinates is Array or coordinates.is_empty() or geometry.get("type") not in ["Polygon", "MultiPolygon"]:
		return false
	var polygons: Array = [coordinates] if geometry["type"] == "Polygon" else coordinates
	for polygon: Variant in polygons:
		if not polygon is Array or polygon.is_empty():
			return false
		for ring: Variant in polygon:
			if not ring is Array or ring.size() < 4 or ring[0] != ring[-1]:
				return false
			for point: Variant in ring:
				if not point is Array or point.size() != 2 or not point.all(_finite_number):
					return false
	return true

func _finite_number(value: Variant) -> bool:
	return (value is float or value is int) and is_finite(float(value))

func _feature_name(source_id: String, identity: String) -> String:
	var safe := source_id.validate_node_name().replace(" ", "_").left(64)
	return "Feature_%s_%s" % [safe, identity.sha256_text().left(24)]

func _material(style: String) -> StandardMaterial3D:
	var palette := {
		"building_height_tag": Color("e9cf9c"),
		"building_levels_estimate": Color("e0dbcf"),
		"building_default_estimate": Color("83a9bd"),
		"measured_window": Color("53717d"),
		"measured_door": Color("58544f"),
		"road_existing": Color("46505a"),
		"road_path": Color("d5c19c"),
		"road_proposed": Color("df8a4b"),
		"road_construction": Color("e2ba56"),
		"land_grass": Color("789279"),
		"land_residential": Color("9da695"),
		"land_industrial": Color("929998"),
		"land_construction": Color("aea18a"),
		"ground": Color("7f897f"),
		"water": Color("477f9d"),
	}
	var material := StandardMaterial3D.new()
	material.albedo_color = palette.get(style, Color("9da695"))
	material.roughness = 0.95
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	return material

func _setup_view(bounds: Array) -> void:
	var world_scale := float(get_meta("world_scale", 1.0))
	var width: float = bounds[2] - bounds[0]
	var depth: float = bounds[3] - bounds[1]
	var center := Vector3((bounds[0] + bounds[2]) / 2.0, 0, (bounds[1] + bounds[3]) / 2.0)
	var ground := MeshInstance3D.new()
	ground.name = "FlatGround"
	ground.set_script(LAYER_TREE.Layer)
	ground.set("style_key", "FlatGround")
	ground.set("style_kind", "FlatGround")
	var plane := PlaneMesh.new()
	var ground_center := center
	if world_chunk_bounds.has_area():
		plane.size = world_chunk_bounds.size
		var square_center := world_chunk_bounds.get_center()
		ground_center = Vector3(square_center.x, 0, square_center.y)
		ground.set_meta("world_chunk_surface", true)
	else:
		plane.size = Vector2(width + 160 * world_scale, depth + 160 * world_scale)
	plane.material = _material("ground")
	ground.mesh = plane
	ground.position = ground_center + Vector3(0, -0.03 * world_scale, 0)
	add_child(ground)
	ground.owner = self
	ground.set_meta("assumptions", "Flat reference plane; no terrain elevation data")
	var sun := DirectionalLight3D.new()
	sun.name = "PreviewSun"
	sun.rotation_degrees = Vector3(-55, -35, 0)
	sun.light_color = Color("fff0da")
	sun.light_energy = 1.1
	sun.shadow_enabled = true
	sun.directional_shadow_max_distance = 3500 * world_scale
	add_child(sun)
	sun.owner = self
	var world := WorldEnvironment.new()
	world.name = "PreviewEnvironment"
	var environment := Environment.new()
	environment.background_mode = Environment.BG_COLOR
	environment.background_color = Color("202a33")
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.ambient_light_color = Color("e6efff")
	environment.ambient_light_energy = 0.7
	world.environment = environment
	add_child(world)
	world.owner = self
	var camera := Camera3D.new()
	camera.name = "OverviewCamera"
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.size = maxf(10.0, maxf(width, depth) * 1.02)
	camera.near = 1.0
	_distance = maxf(2300.0, maxf(width, depth) * 2.0)
	camera.far = _distance * 4.0
	camera.current = true
	camera.set_meta("overview_size_m", camera.size)
	add_child(camera)
	camera.owner = self
	_target = center
	reset_view()

func _setup_legend(counts: Dictionary, source: Dictionary, report: Dictionary) -> void:
	var overlay := CanvasLayer.new()
	overlay.name = "PreviewLegend"
	add_child(overlay)
	overlay.owner = self
	var panel := PanelContainer.new()
	panel.name = "Legend"
	panel.position = Vector2(22, 22)
	var background := StyleBoxFlat.new()
	background.bg_color = Color(0.07, 0.1, 0.13, 0.93)
	background.content_margin_left = 18
	background.content_margin_right = 18
	background.content_margin_top = 14
	background.content_margin_bottom = 14
	background.set_corner_radius_all(8)
	panel.add_theme_stylebox_override("panel", background)
	overlay.add_child(panel)
	panel.owner = self
	var text := Label.new()
	text.name = "Description"
	text.add_theme_font_size_override("font_size", 14)
	text.text = legend_text(counts, source, report)
	text.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	text.custom_minimum_size.x = 420.0
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	text.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.add_child(text)
	text.owner = self

func _enter_tree() -> void:
	_connect_attribute_bank()
	if attribute_bank != null:
		_queue_attribute_bank_refresh()
	if Engine.is_editor_hint():
		_refresh_editor_sky.call_deferred()

func _ready() -> void:
	if Engine.is_editor_hint():
		return
	FlightInput.ensure_actions()
	_setup_scene_style.call_deferred()
	if not scene_file_path.is_empty() and not has_node("RoadPatrols"):
		_start_legacy_patrols.call_deferred()
	reset_view()
	var description := get_node_or_null("PreviewLegend/Legend/Description") as Label
	if description != null:
		var lines := description.text.split("\n")
		var kept := PackedStringArray()
		for line in lines:
			if not line.begins_with("Колесо: масштаб") and not line.begins_with("Home: весь участок"):
				kept.append(line)
		description.text = "\n".join(kept)

func _refresh_editor_sky() -> void:
	if not is_inside_tree() or is_queued_for_deletion() or _editor_saving or get_tree().edited_scene_root != self:
		return
	_refresh_sky()

func _refresh_sky() -> void:
	if not is_inside_tree() or is_queued_for_deletion():
		return
	_clear_editor_sky()
	var mode := NIGHT_STYLE.mode_for(self)
	if mode == NIGHT_STYLE.NIGHT or sky_settings != null or has_node("BakedChunks"):
		var preview := EDITOR_SKY_PREVIEW.new()
		if preview.start(self, mode, sky_settings):
			_sky_preview = preview

func _clear_editor_sky() -> void:
	if _sky_preview != null:
		_sky_preview.stop()
		_sky_preview = null

func _exit_tree() -> void:
	_disconnect_attribute_bank()
	_clear_editor_sky()

func _notification(what: int) -> void:
	if not Engine.is_editor_hint():
		return
	if what == NOTIFICATION_EDITOR_PRE_SAVE:
		_editor_saving = true
		_clear_editor_sky()
		if _layer_update_queued:
			apply_layer_styles()
	elif what == NOTIFICATION_EDITOR_POST_SAVE:
		_editor_saving = false
		_refresh_editor_sky.call_deferred()

func _setup_scene_style() -> void:
	if is_queued_for_deletion():
		return
	if not scene_file_path.is_empty():
		_load_style_layer()
	STYLE_MODULE.clear_overview_fog(self)
	if has_node("BakedChunks") or NIGHT_STYLE.mode_for(self) == NIGHT_STYLE.DAY:
		_refresh_sky()
	elif not has_node("StyleLayer/NightLighting"):
		var layer := get_node_or_null("StyleLayer")
		if layer == null:
			layer = Node3D.new()
			layer.name = "StyleLayer"
			add_child(layer)
		var lighting := NIGHT_STYLE.new()
		lighting.name = "NightLighting"
		layer.add_child(lighting)

func _load_style_layer() -> void:
	if is_queued_for_deletion() or has_node("StyleLayer"):
		return
	var path := scene_file_path.get_base_dir().path_join("style_preview.tscn")
	if ResourceLoader.exists(path, "PackedScene"):
		var preview := load(path) as PackedScene
		if preview != null:
			var layer := preview.instantiate()
			add_child(layer)
			var points := layer.get_node_or_null("PreviewWaypoints")
			var player := get_node_or_null("FlyPlayer")
			if points == null or player == null:
				return
			var overlay := player.find_child("FlightMap", true, false)
			if overlay == null or not overlay.has_method("add_waypoint"):
				return
			for point in points.get_children():
				if point is Marker3D:
					overlay.add_waypoint(point.global_position)

func _start_legacy_patrols() -> void:
	if not is_queued_for_deletion():
		await ROAD_PATROLS.add_from_file(self,
			scene_file_path.get_base_dir().path_join(ROAD_PATROLS.MODEL_FILE), false)

func legend_text(counts: Dictionary, source: Dictionary = {}, report: Dictionary = {}) -> String:
	var title := str(source.get("title", "")).strip_edges()
	if title.is_empty():
		title = str(source.get("path", "")).get_file()
	if title.is_empty():
		title = "Карта местности"
	var lines := PackedStringArray([title.left(90)])
	var roads: int = int(counts.get("Roads", 0)) + int(counts.get("Paths", 0)) + int(counts.get("PlannedRoads", 0))
	lines.append("Здания: %d · Дороги и пути: %d" % [int(counts.get("Buildings", 0)), roads])
	lines.append("Территории: %d · Водоёмы: %d · Поверхность плоская" % [int(counts.get("Landuse", 0)), int(counts.get("Water", 0))])
	var settings_value: Variant = report.get("settings", {})
	var settings: Dictionary = settings_value if settings_value is Dictionary else {}
	var world_scale := float(settings.get("world_scale", 1.0))
	lines.append("Игровой масштаб ×%s · исходные размеры OSM сохранены" % str(world_scale))
	if settings.get("open_windows", false):
		var openings: Dictionary = report.get("facade_openings", {})
		var window_label := "Разбиваемые стёкла" if settings.get("breakable_windows", false) else "Сквозные окна"
		lines.append("%s: %d · пустые залы без этажей" % [window_label, int(openings.get("count", 0))])
	var default_height: Variant = settings.get("default_height_m")
	var level_height: Variant = settings.get("level_height_m")
	var estimates := PackedStringArray()
	if _finite_number(default_height) and float(default_height) > 0.0:
		estimates.append("Без высоты: %s м" % str(float(default_height)))
	else:
		estimates.append("Без высоты: см. допущения объекта")
	if _finite_number(level_height) and float(level_height) > 0.0:
		estimates.append("этаж: %s м" % str(float(level_height)))
	lines.append(" · ".join(estimates))
	lines.append("Крыши пока плоские; общая высота включает крышу")
	var collisions_value: Variant = report.get("collisions", {})
	var collisions: Dictionary = collisions_value if collisions_value is Dictionary else {}
	if collisions.get("enabled", false):
		lines.append("Препятствия зданий: %d · треугольников: %d" % [int(collisions.get("created", 0)) + int(collisions.get("existing", 0)), int(collisions.get("triangles", 0))])
	elif collisions.has("enabled"):
		lines.append("Препятствия зданий отключены")
	lines.append("Голубой: высота принята · Оранжевый: проект · Жёлтый: стройка")
	var attribution := str(source.get("copyright", report.get("copyright", "")))
	if not attribution.is_empty():
		if "openstreetmap" in attribution.to_lower() or "odbl" in attribution.to_lower():
			lines.append("© OpenStreetMap contributors · ODbL")
		else:
			lines.append(attribution.left(250))
	return "\n".join(lines)

func focus_buildings() -> Dictionary:
	var camera := get_node_or_null("OverviewCamera") as Camera3D
	if camera == null:
		return {"success": false}
	var bounds := AABB()
	var baked: Variant = get_meta("baked_building_bounds_m", [])
	if baked is Array and baked.size() == 6:
		bounds = AABB(Vector3(baked[0], baked[1], baked[2]), Vector3(baked[3], baked[4], baked[5]))
	else:
		var buildings := LAYER_TREE.buildings(self)
		if buildings.is_empty():
			return {"success": false}
		var to_map := global_transform.affine_inverse()
		for index in buildings.size():
			var building := buildings[index]
			var local_bounds := (to_map * building.global_transform) * building.get_aabb()
			bounds = local_bounds if index == 0 else bounds.merge(local_bounds)
	_target = bounds.get_center()
	_target.y = 0
	_yaw = -0.3
	_pitch = 0.85
	camera.size = maxf(10.0, maxf(bounds.size.x, bounds.size.z) * 1.12)
	_update_camera()
	return {"success": true}

func reset_view() -> Dictionary:
	var camera := get_node_or_null("OverviewCamera") as Camera3D
	if camera == null:
		return {"success": false}
	var ground := get_node_or_null("FlatGround") as Node3D
	if ground == null:
		return {"success": false}
	_distance = maxf(2300.0, camera.far / 4.0)
	_target = ground.position
	_target.y = 0
	_yaw = 0
	_pitch = 0.85
	camera.size = float(camera.get_meta("overview_size_m", 1770.0))
	_update_camera()
	return {"success": true}

func preview_info() -> Dictionary:
	return {"engine": Engine.get_version_info(), "scene": scene_file_path, "executable_path": OS.get_executable_path()}

func _update_camera() -> void:
	var camera := get_node_or_null("OverviewCamera") as Camera3D
	if camera == null:
		return
	camera.position = _target + Vector3(sin(_yaw) * cos(_pitch), sin(_pitch), cos(_yaw) * cos(_pitch)) * _distance
	camera.look_at(_target, Vector3.UP)

func _process(delta: float) -> void:
	if Engine.is_editor_hint():
		return
	var camera := get_node_or_null("OverviewCamera") as Camera3D
	if camera == null or not camera.current:
		return
	var axes := Vector2(
		Input.get_axis(&"map_pan_left", &"map_pan_right"),
		Input.get_axis(&"map_pan_backward", &"map_pan_forward"))
	if axes != Vector2.ZERO:
		_pan_overview(camera, axes, delta)

func _pan_overview(camera: Camera3D, axes: Vector2, delta: float) -> void:
	var lateral := Vector3(cos(_yaw), 0.0, -sin(_yaw))
	var forward := Vector3(-sin(_yaw), 0.0, -cos(_yaw))
	var direction := axes.limit_length()
	_target += (lateral * direction.x + forward * direction.y) * camera.size * OVERVIEW_PAN_RATE * delta
	_update_camera()

func _unhandled_input(event: InputEvent) -> void:
	if Engine.is_editor_hint():
		return
	var camera := get_node_or_null("OverviewCamera") as Camera3D
	if camera == null:
		return
	# A scene may supply a first-person camera; only the active overview owns orbit input.
	if FlightInput.event_pressed(event, &"map_toggle_legend"):
		var legend := get_node_or_null("PreviewLegend/Legend") as Control
		if legend != null:
			legend.visible = not legend.visible
		return
	if not camera.current:
		return
	if FlightInput.event_pressed(event, &"map_frame_map"):
		reset_view()
	elif FlightInput.event_pressed(event, &"map_frame_buildings"):
		focus_buildings()
	elif FlightInput.event_pressed(event, &"map_zoom_in"):
		camera.size = maxf(1.0, camera.size * 0.88)
	elif FlightInput.event_pressed(event, &"map_zoom_out"):
		camera.size = minf(camera.far, camera.size / 0.88)
	elif event is InputEventMouseMotion:
		if FlightInput.mouse_drag(event, &"map_orbit_drag"):
			_yaw -= event.relative.x * 0.006
			_pitch = clampf(_pitch + event.relative.y * 0.006, 0.18, 1.5)
			_update_camera()
		elif FlightInput.mouse_drag(event, &"map_pan_drag"):
			var scale_m: float = camera.size / maxf(1, get_viewport().get_visible_rect().size.y)
			_target += (-camera.global_basis.x * event.relative.x + camera.global_basis.y * event.relative.y) * scale_m
			_target.y = 0
			_update_camera()
