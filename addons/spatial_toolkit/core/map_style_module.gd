@tool
extends RefCounted
## Generic map appearance and stable flat-surface rendering.
## Source meshes/materials/metadata and physics remain beneath visual overrides.

const FACADE_SHADER_PATH := "res://addons/spatial_toolkit/materials/building_facade.gdshader"
const FLAT_SHADER_PATH := "res://addons/spatial_toolkit/materials/flat_map_surface.gdshader"
const Layers := preload("res://addons/spatial_toolkit/core/spatial_layers.gd")
const FacadeWindows := preload("res://addons/spatial_toolkit/core/facade_windows.gd")
const WindowPreview := preload("res://addons/spatial_toolkit/runtime/facade_window_preview.gd")
const LAYER_ORIGINAL := &"spatial_layer_original_material"
const PALETTE := [Color("c8bda8"), Color("b6c0c3"), Color("dfd9c9"), Color("b38c75"), Color("afb5a1")]
const STYLE_FRAME_BUDGET_USEC := 12000
const BUILDING_FLOOR_PRIORITY := -70
const BUILDING_FOUNDATION_PRIORITY := -60

static func facade_material(original: Material, albedo: Texture2D, normal: Texture2D,
		roughness: Texture2D, repeat_m: float, metallic: float, metal_map: Texture2D = null) -> ShaderMaterial:
	var facade := original as ShaderMaterial
	if facade == null or facade.shader == null or facade.shader.resource_path != FACADE_SHADER_PATH:
		return null
	var material := facade.duplicate() as ShaderMaterial
	material.set_shader_parameter("finish_albedo", albedo)
	material.set_shader_parameter("finish_normal", normal)
	material.set_shader_parameter("finish_roughness", roughness)
	material.set_shader_parameter("finish_repeat_m", repeat_m)
	material.set_shader_parameter("finish_metallic", metallic)
	material.set_shader_parameter("finish_metal_map", metal_map)
	return material

static func facade_updates(building: MeshInstance3D, selected: Material) -> Array[Dictionary]:
	var results: Array[Dictionary] = []
	if building.mesh == null:
		return results
	if building.material_override != null:
		var material := _selected_facade(building.material_override, selected)
		if material != null:
			results.append({"property": "material_override", "material": material})
		return results
	for index in building.mesh.get_surface_count():
		var material := _selected_facade(building.get_active_material(index), selected)
		if material != null:
			results.append({"property": "surface_material_override/%d" % index, "material": material})
	return results

static func _selected_facade(original: Material, selected: Material) -> ShaderMaterial:
	if selected is StandardMaterial3D and selected.albedo_texture != null:
		return facade_material(original, selected.albedo_texture, selected.normal_texture,
			selected.roughness_texture, float(selected.get_meta("repeat_m", 2.0)), selected.metallic,
			selected.metallic_texture)
	if selected is ShaderMaterial and selected.get_shader_parameter("road_albedo") is Texture2D:
		return facade_material(original, selected.get_shader_parameter("road_albedo"),
			selected.get_shader_parameter("road_normal"), selected.get_shader_parameter("road_roughness"),
			float(selected.get_shader_parameter("repeat_size")), 0.0)
	if selected == null and original is ShaderMaterial and original.shader != null \
			and original.shader.resource_path == FACADE_SHADER_PATH:
		var material := original.duplicate() as ShaderMaterial
		material.set_shader_parameter("finish_albedo", null)
		material.set_shader_parameter("finish_normal", null)
		material.set_shader_parameter("finish_roughness", null)
		material.set_shader_parameter("finish_repeat_m", 0.0)
		material.set_shader_parameter("finish_metallic", 0.0)
		material.set_shader_parameter("finish_metal_map", null)
		return material
	return null

static func apply_to_scene(map: Node3D) -> Dictionary:
	var resources := _prepare_style(map)
	if not resources.get("success", false):
		return resources
	var count := 0
	var tagged_colors := 0
	for building in Layers.buildings(map):
		if _style_building(building, resources["facade_shader"]):
			tagged_colors += 1
		count += 1
	_apply_environment(map)
	var flat := apply_flat_surfaces(map)
	if not flat.get("success", false):
		return flat
	return _finish_style(map, count, int(flat["meshes"]), tagged_colors, int(flat["building_floors"]), int(flat["building_foundations"]))

static func apply_to_scene_batched(map: Node3D, facade_layouts: Dictionary = {},
		on_progress: Callable = Callable()) -> Dictionary:
	if not map.is_inside_tree():
		return {"success": false, "error": "Attach map to SceneTree before batched styling"}
	var resources := _prepare_style(map)
	if not resources.get("success", false):
		return resources
	var count := 0
	var tagged_colors := 0
	var buildings := Layers.buildings(map)
	if not _continue_style(on_progress, "facades", 0, buildings.size()):
		return {"success": false, "cancelled": true}
	var yield_after := Time.get_ticks_usec() + STYLE_FRAME_BUDGET_USEC
	for building in buildings:
		if _style_building(building, resources["facade_shader"], facade_layouts.get(building, {})):
			tagged_colors += 1
		count += 1
		if Time.get_ticks_usec() >= yield_after:
			if not _continue_style(on_progress, "facades", count, buildings.size()):
				return {"success": false, "cancelled": true}
			await map.get_tree().process_frame
			yield_after = Time.get_ticks_usec() + STYLE_FRAME_BUDGET_USEC
	if not _continue_style(on_progress, "facades", count, buildings.size()):
		return {"success": false, "cancelled": true}
	_apply_environment(map)
	var flat := await apply_flat_surfaces_batched(map, on_progress)
	if not flat.get("success", false):
		return flat
	return _finish_style(map, count, int(flat["meshes"]), tagged_colors, int(flat["building_floors"]), int(flat["building_foundations"]))

static func _prepare_style(map: Node3D) -> Dictionary:
	if map.get_node_or_null("Generated/Buildings") == null or not map.get_node_or_null("PreviewEnvironment") is WorldEnvironment or not map.get_node_or_null("PreviewSun") is DirectionalLight3D:
		return {"success": false, "error": "Expected building, environment and sun nodes"}
	var facade := load(FACADE_SHADER_PATH) as Shader
	var flat := load(FLAT_SHADER_PATH) as Shader
	if facade == null or flat == null:
		return {"success": false, "error": "Map facade or flat-surface shader unavailable"}
	return {"success": true, "facade_shader": facade}

static func retrofit_citygml_windows(building: MeshInstance3D) -> void:
	if building.mesh == null or not FacadeWindows.is_citygml(building) or building.has_meta(FacadeWindows.METADATA):
		return
	var slots := {}
	if building.material_override != null:
		slots["material_override"] = building.material_override
	else:
		for surface in building.mesh.get_surface_count():
			slots["surface_material_override/%d" % surface] = building.get_active_material(surface)
	var layout := {}
	var copies := {}
	var floor_height := FacadeWindows.floor_height_for(building)
	for slot: String in slots:
		var material := slots[slot] as ShaderMaterial
		if not _is_facade_shader(material) or material.get_shader_parameter("section_windows") == true:
			continue
		if layout.is_empty():
			layout = FacadeWindows.prepare_citygml(building, true)
		if not copies.has(material):
			copies[material] = _retrofit_facade_material(material, layout, floor_height)
		building.set(slot, copies[material])

static func _is_facade_shader(material: ShaderMaterial) -> bool:
	return material != null and material.shader != null and material.shader.resource_path == FACADE_SHADER_PATH

static func _retrofit_facade_material(material: ShaderMaterial, layout: Dictionary, floor_height: float) -> ShaderMaterial:
	var patched := material.duplicate() as ShaderMaterial
	WindowPreview.configure_section_layout(patched, layout, floor_height)
	var original: Array = material.get_meta(LAYER_ORIGINAL, [])
	if original.size() == 2 and _is_facade_shader(original[0] as ShaderMaterial):
		# Later group styles can restore this baseline. Keep the new atlas there too.
		var baseline := (original[0] as ShaderMaterial).duplicate() as ShaderMaterial
		WindowPreview.configure_section_layout(baseline, layout, floor_height)
		patched.set_meta(LAYER_ORIGINAL, [baseline, baseline if original[1] == null or original[1] == original[0] else original[1]])
	return patched

static func _style_building(building: MeshInstance3D, shader: Shader, layout: Dictionary = {}) -> bool:
	var tags: Dictionary = building.get_meta("source_tags", {})
	var id := str(building.get_meta("source_id", building.name))
	var seed := id.sha256_text().substr(0, 8).hex_to_int()
	var style: int = seed % PALETTE.size()
	var wall: Color = PALETTE[style]
	var tagged_color := false
	var raw_color := str(tags.get("building:colour", tags.get("building:color", tags.get("colour", ""))))
	if not raw_color.is_empty():
		var parsed := Color.from_string(raw_color, Color(-1, -1, -1, 1))
		if parsed.r >= 0:
			wall = parsed
			tagged_color = true
	var floor_height := FacadeWindows.floor_height_for(building)
	var world_scale := float(building.get_meta("world_scale", 1.0))
	var openings: Dictionary = building.get_meta("facade_openings", {})
	var material := ShaderMaterial.new()
	material.shader = shader
	material.resource_name = "Facade_" + str(style)
	material.set_shader_parameter("wall_color", wall)
	material.set_shader_parameter("roof_color", Color("596167"))
	material.set_shader_parameter("glass_color", Color("56717c"))
	material.set_shader_parameter("floor_height", floor_height)
	material.set_shader_parameter("world_scale", world_scale)
	material.set_shader_parameter("open_windows",
		bool(openings.get("enabled", false)) and not bool(building.get_meta("painted_windows", false)))
	material.set_shader_parameter("building_seed", float(seed % 997))
	if layout.is_empty() and FacadeWindows.is_citygml(building):
		layout = FacadeWindows.prepare_citygml(building, true)
	if not layout.is_empty():
		WindowPreview.configure_section_layout(material, layout, floor_height)
	var floor_index := int(building.get_meta("floor_surface_index", -1))
	var foundation_index := int(building.get_meta("foundation_surface_index", -1))
	var modeled_openings: PackedInt32Array = building.get_meta("measured_opening_surfaces", PackedInt32Array())
	var surfaces := building.mesh.get_surface_count() if building.mesh != null else 0
	var has_floor := floor_index >= 0 and floor_index < surfaces
	var has_foundation := foundation_index >= 0 and foundation_index < surfaces
	if has_floor or has_foundation or not modeled_openings.is_empty():
		# Per-surface materials retain opaque upper walls/roof. The original floor
		# and foundation band join the ordered pass above the flat map layers.
		building.material_override = null
		for surface: int in surfaces:
			if surface != floor_index and surface != foundation_index and surface not in modeled_openings:
				building.set_surface_override_material(surface, material)
	else:
		building.material_override = material
	building.set_meta("appearance_assumption", "Procedural open apertures with reveals and empty hall; no reconstructed real facade or interiors" if openings.get("enabled", false) else "Generic procedural facade/window layout and roof finish; not reconstructed from real facade imagery")
	return tagged_color

static func _apply_environment(map: Node3D) -> void:
	var world_scale := float(map.get_meta("world_scale", 1.0))
	var world := map.get_node("PreviewEnvironment") as WorldEnvironment
	var sun := map.get_node("PreviewSun") as DirectionalLight3D
	var settings := SpatialSkySettings.new()
	var environment := Environment.new()
	settings.configure_day_environment(environment, world_scale)
	world.environment = environment
	settings.configure_sun(sun, world_scale)
	sun.shadow_enabled = true
	sun.shadow_opacity = 0.8
	sun.shadow_bias = 0.08
	sun.shadow_normal_bias = 1.1
	sun.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_4_SPLITS
	sun.directional_shadow_blend_splits = true
	sun.directional_shadow_split_1 = 0.05
	sun.directional_shadow_split_2 = 0.15
	sun.directional_shadow_split_3 = 0.4
	var overview := map.get_node_or_null("OverviewCamera") as Camera3D
	if overview != null:
		overview.environment = _without_fog(environment)
	var ground := map.get_node_or_null("FlatGround") as MeshInstance3D
	if ground != null and ground.mesh is PlaneMesh:
		var plane := ground.mesh.duplicate() as PlaneMesh
		if not ground.has_meta("world_chunk_surface"):
			plane.size = Vector2(maxf(plane.size.x, 30000 * world_scale), maxf(plane.size.y, 30000 * world_scale))
			ground.set_meta("appearance_assumption", "Visual-only flat ground extended to horizon; no measured terrain outside imported source")
		var material := StandardMaterial3D.new()
		material.albedo_color = Color("819077")
		material.roughness = 1.0
		plane.material = material
		ground.mesh = plane

static func clear_overview_fog(map: Node3D) -> void:
	var overview := map.get_node_or_null("OverviewCamera") as Camera3D
	if overview == null or overview.projection != Camera3D.PROJECTION_ORTHOGONAL:
		return
	var environment := overview.environment
	if environment == null:
		var world := map.get_node_or_null("PreviewEnvironment") as WorldEnvironment
		if world != null:
			environment = world.environment
	if environment != null and (environment.fog_enabled or environment.volumetric_fog_enabled):
		overview.environment = _without_fog(environment)

static func _without_fog(environment: Environment) -> Environment:
	var clear := environment.duplicate() as Environment
	clear.fog_enabled = false
	clear.volumetric_fog_enabled = false
	return clear

static func _finish_style(map: Node3D, count: int, flat_count: int, tagged_colors: int, floor_count: int, foundation_count: int) -> Dictionary:
	var world_scale := float(map.get_meta("world_scale", 1.0))
	var legend := map.get_node_or_null("PreviewLegend/Legend/Description") as Label
	if legend != null:
		legend.text = legend.text.replace("Голубой: высота принята · ", "")
		if not "Фасады и окна" in legend.text:
			legend.text += "\nФасады и окна — условное оформление"
	var report := {"success": true, "buildings": count, "flat_surfaces": flat_count, "building_floors": floor_count, "building_foundations": foundation_count, "source_color_tags": tagged_colors, "visual_only": true, "sun_is_georeferenced": false, "horizon_ground_size_m": 30000 * world_scale, "world_scale": world_scale}
	map.set_meta("daylight_style", report)
	return report

static func apply_flat_surfaces(map: Node3D) -> Dictionary:
	var shader := load(FLAT_SHADER_PATH) as Shader
	if shader == null:
		return {"success": false, "error": "Flat-surface shader unavailable"}
	var operations := _flat_operations(map)
	for operation: Dictionary in operations:
		_set_flat_material(operation["mesh"], shader, operation["color"], operation["priority"])
	var floors := _floor_operations(map)
	for operation: Dictionary in floors:
		_set_floor_material(operation["mesh"], shader, operation["surface"], operation["color"])
	var foundations := _foundation_operations(map)
	for operation: Dictionary in foundations:
		_set_foundation_material(operation["mesh"], shader, operation["surface"], operation["color"])
	return {"success": true, "enabled": true, "meshes": operations.size(), "building_floors": floors.size(), "building_foundations": foundations.size()}

static func apply_flat_surfaces_batched(map: Node3D, on_progress: Callable = Callable()) -> Dictionary:
	if not map.is_inside_tree():
		return {"success": false, "error": "Attach map to SceneTree before batched flat styling"}
	var shader := load(FLAT_SHADER_PATH) as Shader
	if shader == null:
		return {"success": false, "error": "Flat-surface shader unavailable"}
	var operations := _flat_operations(map)
	if not _continue_style(on_progress, "surfaces", 0, operations.size()):
		return {"success": false, "cancelled": true}
	var yield_after := Time.get_ticks_usec() + STYLE_FRAME_BUDGET_USEC
	for i: int in operations.size():
		var operation: Dictionary = operations[i]
		_set_flat_material(operation["mesh"], shader, operation["color"], operation["priority"])
		if Time.get_ticks_usec() >= yield_after:
			if not _continue_style(on_progress, "surfaces", i + 1, operations.size()):
				return {"success": false, "cancelled": true}
			await map.get_tree().process_frame
			yield_after = Time.get_ticks_usec() + STYLE_FRAME_BUDGET_USEC
	var floors := _floor_operations(map)
	if not _continue_style(on_progress, "floors", 0, floors.size()):
		return {"success": false, "cancelled": true}
	for i: int in floors.size():
		var operation: Dictionary = floors[i]
		_set_floor_material(operation["mesh"], shader, operation["surface"], operation["color"])
		if Time.get_ticks_usec() >= yield_after:
			if not _continue_style(on_progress, "floors", i + 1, floors.size()):
				return {"success": false, "cancelled": true}
			await map.get_tree().process_frame
			yield_after = Time.get_ticks_usec() + STYLE_FRAME_BUDGET_USEC
	var foundations := _foundation_operations(map)
	if not _continue_style(on_progress, "foundations", 0, foundations.size()):
		return {"success": false, "cancelled": true}
	for i: int in foundations.size():
		var operation: Dictionary = foundations[i]
		_set_foundation_material(operation["mesh"], shader, operation["surface"], operation["color"])
		if Time.get_ticks_usec() >= yield_after:
			if not _continue_style(on_progress, "foundations", i + 1, foundations.size()):
				return {"success": false, "cancelled": true}
			await map.get_tree().process_frame
			yield_after = Time.get_ticks_usec() + STYLE_FRAME_BUDGET_USEC
	return {"success": true, "enabled": true, "meshes": operations.size(), "building_floors": floors.size(), "building_foundations": foundations.size()}

static func _continue_style(on_progress: Callable, phase: String, done: int, total: int) -> bool:
	return not on_progress.is_valid() or bool(on_progress.call(phase, done, total))

static func _foundation_operations(map: Node3D) -> Array[Dictionary]:
	var operations: Array[Dictionary] = []
	for mesh in Layers.buildings(map):
		if mesh.mesh == null:
			continue
		var surface := int(mesh.get_meta("foundation_surface_index", -1))
		if surface < 0 or surface >= mesh.mesh.get_surface_count():
			continue
		var wall_material := mesh.get_active_material(0)
		var color := Color("c8bda8")
		if wall_material is StandardMaterial3D:
			color = wall_material.albedo_color
		elif wall_material is ShaderMaterial:
			var wall_color: Variant = wall_material.get_shader_parameter("wall_color")
			if wall_color is Color:
				color = wall_color
		operations.append({"mesh": mesh, "surface": surface, "color": color})
	return operations

static func _set_foundation_material(mesh: MeshInstance3D, shader: Shader, surface: int, color: Color) -> void:
	var material := ShaderMaterial.new()
	material.shader = shader
	material.set_shader_parameter("surface_color", color)
	material.render_priority = BUILDING_FOUNDATION_PRIORITY
	mesh.set_surface_override_material(surface, material)
	# Only this existing vertical band is ordered. Preserve opaque wall/roof
	# occlusion, the shared building mesh/collision and building shadow settings.
	mesh.set_meta("foundation_render_order", BUILDING_FOUNDATION_PRIORITY)

static func _floor_operations(map: Node3D) -> Array[Dictionary]:
	var operations: Array[Dictionary] = []
	for mesh in Layers.buildings(map):
		if mesh.mesh == null:
			continue
		var surface := int(mesh.get_meta("floor_surface_index", -1))
		if surface < 0 or surface >= mesh.mesh.get_surface_count():
			continue
		var openings: Dictionary = mesh.get_meta("facade_openings", {})
		if not openings.get("enabled", false):
			continue
		var wall_material := mesh.get_active_material(0)
		var color := Color("596167")
		if wall_material is StandardMaterial3D:
			color = wall_material.albedo_color
		operations.append({"mesh": mesh, "surface": surface, "color": color})
	return operations

static func _set_floor_material(mesh: MeshInstance3D, shader: Shader, surface: int, color: Color) -> void:
	var material := ShaderMaterial.new()
	material.shader = shader
	material.set_shader_parameter("surface_color", color)
	material.render_priority = BUILDING_FLOOR_PRIORITY
	mesh.set_surface_override_material(surface, material)
	# Leave building shadow casting and the opaque facade materials untouched.
	mesh.set_meta("floor_render_order", BUILDING_FLOOR_PRIORITY)

static func _flat_operations(map: Node3D) -> Array[Dictionary]:
	# ALPHA=1 selects the ordered transparent pass without writing depth.
	# Depth testing remains on so opaque buildings and the ship occlude ground.
	var operations: Array[Dictionary] = []
	var base := map.get_node_or_null("FlatGround") as MeshInstance3D
	if base != null:
		operations.append({"mesh": base, "color": Color("819077"), "priority": -120})
	var land_colors := {"industrial": Color("929998"), "residential": Color("9da695"), "construction": Color("aea18a"), "grass": Color("789279")}
	var land_order := {"industrial": -116, "residential": -114, "construction": -112, "grass": -110}
	for layer_name: String in ["Landuse", "Water", "Roads", "Paths", "PlannedRoads"]:
		for mesh in Layers.meshes(map.get_node_or_null("Generated/" + layer_name)):
			var tags: Dictionary = mesh.get_meta("source_tags", {})
			var color := Color("46505a")
			var priority := -90
			match layer_name:
				"Landuse":
					var kind := str(tags.get("landuse", "grass" if tags.get("leisure") == "park" else ""))
					color = land_colors.get(kind, Color("9da695"))
					priority = int(land_order.get(kind, -114))
				"Water":
					color = Color("477f9d")
					priority = -100
				"Paths":
					color = Color("d5c19c")
					priority = -85
				"PlannedRoads":
					color = Color("df8a4b") if tags.get("highway") == "proposed" else Color("e2ba56")
					priority = -80
			operations.append({"mesh": mesh, "color": color, "priority": priority})
	return operations

static func _set_flat_material(mesh: MeshInstance3D, shader: Shader, color: Color, priority: int) -> void:
	var material := ShaderMaterial.new()
	material.shader = shader
	material.set_shader_parameter("surface_color", color)
	material.render_priority = priority
	mesh.material_override = material
	mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mesh.set_meta("flat_render_order", priority)
