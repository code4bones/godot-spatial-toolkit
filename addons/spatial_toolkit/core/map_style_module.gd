@tool
extends RefCounted
## Generic map appearance and stable flat-surface rendering.
## Source meshes/materials/metadata and physics remain beneath visual overrides.

const FACADE_SHADER_PATH := "res://addons/spatial_toolkit/materials/building_facade.gdshader"
const FLAT_SHADER_PATH := "res://addons/spatial_toolkit/materials/flat_map_surface.gdshader"
const Ground := preload("res://addons/spatial_toolkit/core/ground_styles.gd")
const SAMPLE_SURFACES := {
	"Roads": "res://assets/materials/road_rubber_tiles.tres",
	"Landuse": Ground.DEFAULT_PRESET,
	"Paths": "res://assets/materials/path_road_damaged.tres",
}
const BRICK_ROAD := "res://assets/materials/road_broken_brick.tres"
const STONE_ROAD := "res://assets/materials/road_red_stone.tres"
const FacadeGroups := preload("res://addons/spatial_toolkit/core/facade_groups.gd")
const FACADE_FINISHES := {
	"rebar_reinforced_concrete": ["facade", 2.0, 0.0],
	"broken_brick": ["road", 2.0, 0.0],
	"red_stone": ["road", 2.0, 0.0],
	"blue_metal": ["facade", 2.0, 0.35],
	"box_profile_metal": ["facade", 2.0, 0.45],
	"metal_plate": ["facade", 2.0, 0.45],
	"rusty_metal": ["facade", 2.0, 0.22],
}
const METAL_FINISHES := ["blue_metal", "box_profile_metal", "metal_plate", "rusty_metal"]
const MASONRY_FINISHES := ["rebar_reinforced_concrete", "broken_brick", "rebar_reinforced_concrete", "red_stone"]
const PALETTE := [Color("c8bda8"), Color("b6c0c3"), Color("dfd9c9"), Color("b38c75"), Color("afb5a1")]
const BATCH_SIZE := 16
const BUILDING_FLOOR_PRIORITY := -70
const BUILDING_FOUNDATION_PRIORITY := -60

static func apply_sample_surface_materials(map: Node3D) -> void:
	var world_scale := float(map.get_meta("world_scale", 1.0))
	var ground := map.get_node_or_null("FlatGround") as MeshInstance3D
	if ground != null:
		_apply_sample_surface(ground, null, Ground.default_surface(Ground.BACKGROUND), world_scale, {})
	for layer_name: String in SAMPLE_SURFACES:
		var layer := map.get_node_or_null("Generated/" + layer_name)
		var path: String = SAMPLE_SURFACES[layer_name]
		if layer == null or layer.get_child_count() == 0:
			continue
		var preset := load(path) as ShaderMaterial if ResourceLoader.exists(path) else null
		var variants := {}
		if layer_name == "Roads":
			for variant_path in [BRICK_ROAD, STONE_ROAD]:
				if ResourceLoader.exists(variant_path):
					var alternative := load(variant_path) as ShaderMaterial
					if alternative != null:
						variants[variant_path] = alternative
		var materials := {}
		for child in layer.get_children():
			var material := preset
			if not variants.is_empty():
				material = variants.get(_road_preset_path(child), preset)
			_apply_sample_surface(child as MeshInstance3D, ground, material, world_scale, materials)

static func _road_preset_path(road: Node) -> String:
	var tags: Dictionary = road.get_meta("source_tags", {})
	match tags.get("surface", ""):
		"brick", "bricks":
			return BRICK_ROAD
		"sett", "cobblestone", "unhewn_cobblestone", "stone":
			return STONE_ROAD
		"paving_stones", "paving_stones:30", "paving_stones:20":
			var street := str(tags.get("name", "")).strip_edges()
			if street.is_empty():
				street = str(road.get_meta("source_id", road.name))
			return BRICK_ROAD if street.hash() % 2 == 0 else STONE_ROAD
	return SAMPLE_SURFACES["Roads"]

static func _apply_sample_surface(mesh: MeshInstance3D, ground: MeshInstance3D, preset: ShaderMaterial,
		world_scale: float, materials: Dictionary) -> void:
	if mesh == null:
		return
	var original := mesh.material_override as ShaderMaterial
	if original == null or original.shader == null:
		return
	var ground_override := original.has_meta(Ground.ORIGINAL)
	if original.shader.resource_path != FLAT_SHADER_PATH and not ground_override:
		return
	# These layers use an ordered, depth-tested pass without writing depth.
	# They can share the flight ground plane without flickering.
	if ground != null and ground.mesh != null and mesh.mesh != null:
		var bounds := mesh.get_aabb()
		if is_zero_approx(bounds.size.y):
			var on_ground := ground.to_local(mesh.to_global(bounds.position))
			mesh.global_position += ground.global_basis.y * (ground.get_aabb().end.y - on_ground.y)
	if preset == null or ground_override:
		return
	var priority := original.render_priority
	var key := [preset.resource_path, priority]
	if not materials.has(key):
		var material := preset.duplicate() as ShaderMaterial
		var repeat_m := float(preset.get_shader_parameter("repeat_size"))
		material.set_shader_parameter("repeat_size", repeat_m * world_scale)
		material.render_priority = priority
		materials[key] = material
	mesh.material_override = materials[key]

static func apply_sample_facades(map: Node3D) -> void:
	var buildings := map.get_node_or_null("Generated/Buildings")
	if buildings == null:
		return
	var finishes := {}
	for child in buildings.get_children():
		var building := child as MeshInstance3D
		if building == null or building.mesh == null:
			continue
		var selection := FacadeGroups.selected_material(map, building)
		if selection != null:
			for update in facade_updates(building, selection):
				building.set(update["property"], update["material"])
			continue
		var finish := _facade_finish(building)
		if not finishes.has(finish):
			finishes[finish] = _load_facade_finish(finish)
		var textures: Array = finishes[finish]
		if textures.is_empty():
			continue
		if building.material_override != null:
			var material := _textured_facade(building.material_override, finish, textures)
			if material != null:
				building.material_override = material
			continue
		for index in building.mesh.get_surface_count():
			var material := _textured_facade(building.get_active_material(index), finish, textures)
			if material != null:
				building.set_surface_override_material(index, material)

static func _facade_finish(building: MeshInstance3D) -> String:
	var tags: Dictionary = building.get_meta("source_tags", {})
	var source_id := str(building.get_meta("source_id", building.name))
	var seed := source_id.sha256_text().substr(0, 8).hex_to_int()
	var material := str(tags.get("building:material", ""))
	var kind := str(tags.get("building", ""))
	if "brick" in material:
		return "broken_brick"
	if material in ["stone", "sandstone"]:
		return "red_stone"
	if material in ["metal", "steel"] or kind in ["industrial", "warehouse", "garage", "garages"] \
			or tags.get("landuse") == "industrial" or (material.is_empty() and seed % 100 < 18):
		return METAL_FINISHES[seed % METAL_FINISHES.size()]
	if material in ["concrete", "reinforced_concrete"]:
		return "rebar_reinforced_concrete"
	return MASONRY_FINISHES[seed % MASONRY_FINISHES.size()]

static func _load_facade_finish(finish: String) -> Array:
	var prefix := "res://assets/textures/%s_%s_" % [finish, FACADE_FINISHES[finish][0]]
	var textures: Array = []
	for channel: String in ["diff", "nor_gl", "rough"]:
		var path := prefix + channel + "_1k.png"
		if not ResourceLoader.exists(path):
			return []
		var texture := load(path) as Texture2D
		if texture == null:
			return []
		textures.append(texture)
	return textures

static func _textured_facade(original: Material, finish: String, textures: Array) -> ShaderMaterial:
	return facade_material(original, textures[0], textures[1], textures[2],
		FACADE_FINISHES[finish][1], FACADE_FINISHES[finish][2])

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
	for value in map.get_node("Generated/Buildings").get_children():
		var building := value as MeshInstance3D
		if building == null:
			continue
		if _style_building(building, resources["facade_shader"]):
			tagged_colors += 1
		count += 1
	_apply_environment(map)
	var flat := apply_flat_surfaces(map)
	if not flat.get("success", false):
		return flat
	return _finish_style(map, count, int(flat["meshes"]), tagged_colors, int(flat["building_floors"]), int(flat["building_foundations"]))

static func apply_to_scene_batched(map: Node3D) -> Dictionary:
	if not map.is_inside_tree():
		return {"success": false, "error": "Attach map to SceneTree before batched styling"}
	var resources := _prepare_style(map)
	if not resources.get("success", false):
		return resources
	var count := 0
	var tagged_colors := 0
	for value in map.get_node("Generated/Buildings").get_children():
		var building := value as MeshInstance3D
		if building == null:
			continue
		if _style_building(building, resources["facade_shader"]):
			tagged_colors += 1
		count += 1
		if count % BATCH_SIZE == 0:
			await map.get_tree().process_frame
	_apply_environment(map)
	var flat := await apply_flat_surfaces_batched(map)
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

static func _style_building(building: MeshInstance3D, shader: Shader) -> bool:
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
	var floor_height := 3.0
	var world_scale := float(building.get_meta("world_scale", 1.0))
	var source_dimensions: Dictionary = building.get_meta("source_dimensions_m", {})
	var openings: Dictionary = building.get_meta("facade_openings", {})
	var levels := str(tags.get("building:levels", ""))
	if levels.is_valid_float() and float(levels) > 0:
		var source_height := float(source_dimensions.get("wall_height_m", building.get_meta("wall_height_m", building.get_meta("height_m", 3.0))))
		floor_height = clampf(source_height / float(levels), 2.0, 6.0)
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
	var brick: bool = "brick" in str(tags.get("building:material", "")) or style == 3
	material.set_shader_parameter("facade_style", 1 if brick else 0)
	var floor_index := int(building.get_meta("floor_surface_index", -1))
	var foundation_index := int(building.get_meta("foundation_surface_index", -1))
	var surfaces := building.mesh.get_surface_count() if building.mesh != null else 0
	var has_floor := floor_index >= 0 and floor_index < surfaces
	var has_foundation := foundation_index >= 0 and foundation_index < surfaces
	if has_floor or has_foundation:
		# Per-surface materials retain opaque upper walls/roof. The original floor
		# and foundation band join the ordered pass above the flat map layers.
		building.material_override = null
		for surface: int in surfaces:
			if surface != floor_index and surface != foundation_index:
				building.set_surface_override_material(surface, material)
	else:
		building.material_override = material
	building.set_meta("appearance_assumption", "Procedural open apertures with reveals and empty hall; no reconstructed real facade or interiors" if openings.get("enabled", false) else "Generic procedural facade/window layout and roof finish; not reconstructed from real facade imagery")
	return tagged_color

static func _apply_environment(map: Node3D) -> void:
	var world_scale := float(map.get_meta("world_scale", 1.0))
	var world := map.get_node("PreviewEnvironment") as WorldEnvironment
	var sun := map.get_node("PreviewSun") as DirectionalLight3D
	var sky_material := ProceduralSkyMaterial.new()
	sky_material.sky_top_color = Color("4e83b5")
	sky_material.sky_horizon_color = Color("c8dce6")
	sky_material.ground_horizon_color = Color("c8dce6")
	sky_material.ground_bottom_color = Color("748376")
	sky_material.sky_curve = 0.2
	sky_material.ground_curve = 0.03
	sky_material.sun_angle_max = 12.0
	sky_material.sun_curve = 0.08
	var sky := Sky.new()
	sky.sky_material = sky_material
	var environment := Environment.new()
	environment.background_mode = Environment.BG_SKY
	environment.sky = sky
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.ambient_light_color = Color(0.72, 0.76, 0.82, 1)
	environment.ambient_light_energy = 0.3
	environment.reflected_light_source = Environment.REFLECTION_SOURCE_SKY
	environment.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	environment.tonemap_exposure = 0.8
	environment.fog_enabled = true
	environment.fog_light_color = Color("c8dce6")
	environment.fog_density = 0.00015 / world_scale
	environment.fog_sky_affect = 0.2
	environment.fog_sun_scatter = 0.08
	world.environment = environment
	sun.rotation_degrees = Vector3(-38, -145, 0)
	sun.light_color = Color("fff1dc")
	sun.light_energy = 0.85
	sun.light_angular_distance = 0.5
	sun.shadow_enabled = true
	sun.shadow_opacity = 0.8
	sun.shadow_bias = 0.08
	sun.shadow_normal_bias = 1.1
	sun.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_4_SPLITS
	sun.directional_shadow_max_distance = 450.0 * world_scale
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
		plane.size = Vector2(maxf(plane.size.x, 30000 * world_scale), maxf(plane.size.y, 30000 * world_scale))
		var material := StandardMaterial3D.new()
		material.albedo_color = Color("819077")
		material.roughness = 1.0
		plane.material = material
		ground.mesh = plane
		ground.set_meta("appearance_assumption", "Visual-only flat ground extended to horizon; no measured terrain outside imported source")

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

static func apply_flat_surfaces_batched(map: Node3D) -> Dictionary:
	if not map.is_inside_tree():
		return {"success": false, "error": "Attach map to SceneTree before batched flat styling"}
	var shader := load(FLAT_SHADER_PATH) as Shader
	if shader == null:
		return {"success": false, "error": "Flat-surface shader unavailable"}
	var operations := _flat_operations(map)
	for i: int in operations.size():
		var operation: Dictionary = operations[i]
		_set_flat_material(operation["mesh"], shader, operation["color"], operation["priority"])
		if (i + 1) % BATCH_SIZE == 0:
			await map.get_tree().process_frame
	var floors := _floor_operations(map)
	for i: int in floors.size():
		var operation: Dictionary = floors[i]
		_set_floor_material(operation["mesh"], shader, operation["surface"], operation["color"])
		if (i + 1) % BATCH_SIZE == 0:
			await map.get_tree().process_frame
	var foundations := _foundation_operations(map)
	for i: int in foundations.size():
		var operation: Dictionary = foundations[i]
		_set_foundation_material(operation["mesh"], shader, operation["surface"], operation["color"])
		if (i + 1) % BATCH_SIZE == 0:
			await map.get_tree().process_frame
	return {"success": true, "enabled": true, "meshes": operations.size(), "building_floors": floors.size(), "building_foundations": foundations.size()}

static func _foundation_operations(map: Node3D) -> Array[Dictionary]:
	var operations: Array[Dictionary] = []
	var buildings := map.get_node_or_null("Generated/Buildings")
	if buildings == null:
		return operations
	for child in buildings.get_children():
		var mesh := child as MeshInstance3D
		if mesh == null or mesh.mesh == null:
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
	var buildings := map.get_node_or_null("Generated/Buildings")
	if buildings == null:
		return operations
	for child in buildings.get_children():
		var mesh := child as MeshInstance3D
		if mesh == null or mesh.mesh == null:
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
		var layer := map.get_node_or_null("Generated/" + layer_name)
		if layer == null:
			continue
		for child in layer.get_children():
			var mesh := child as MeshInstance3D
			if mesh == null:
				continue
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
