extends Node
## Moonlit lighting for a Spatial map.

const MODE := &"spatial_sky_mode"
const DAY := &"day"
const NIGHT := &"night"

const SKY := preload("res://addons/spatial_toolkit/materials/night_sky.gdshader")
const FACADE := preload("res://addons/spatial_toolkit/materials/building_facade.gdshader")
const Windows := preload("res://addons/spatial_toolkit/runtime/facade_window_preview.gd")
const Layers := preload("res://addons/spatial_toolkit/core/spatial_layers.gd")
const MAX_RENDERED_LIGHTS := 4

static func mode_for(map: Node) -> StringName:
	if map.has_meta(MODE):
		return StringName(map.get_meta(MODE))
	if map.has_node("StyleLayer/NightLighting"):
		return NIGHT
	if not map.scene_file_path.is_empty():
		var path := map.scene_file_path.get_base_dir().path_join("style_preview.tscn")
		if FileAccess.file_exists(path):
			for dependency in ResourceLoader.get_dependencies(path):
				if dependency.get_slice("::", dependency.get_slice_count("::") - 1) == "res://addons/spatial_toolkit/runtime/night_city_style.gd":
					return NIGHT
	return DAY

func _ready() -> void:
	var map := get_parent().get_parent()
	if map.get_meta(MODE, NIGHT) == DAY:
		return
	var world := map.get_node_or_null("PreviewEnvironment") as WorldEnvironment
	var moonlight := map.get_node_or_null("PreviewSun") as DirectionalLight3D
	if world == null or world.environment == null or moonlight == null:
		return
	var scale_factor := float(map.get_meta("world_scale", 1.0))
	var settings := map.get("sky_settings") as SpatialSkySettings if "sky_settings" in map else null
	configure_lighting(world, moonlight, scale_factor, settings)
	var buildings := Layers.buildings(map)
	light_facades(buildings, false, fog_density(settings))
	_place_street_lights(map, buildings, scale_factor)

static func is_night_environment(environment: Environment) -> bool:
	return environment != null and environment.sky != null \
		and environment.sky.sky_material is ShaderMaterial and environment.sky.sky_material.shader == SKY

static func fog_density(settings: SpatialSkySettings) -> float:
	return settings.night_fog_density if settings != null else SpatialSkySettings.DEFAULT_NIGHT_FOG_DENSITY

static func configure_lighting(world: WorldEnvironment, moonlight: DirectionalLight3D,
		scale_factor: float, settings: SpatialSkySettings = null) -> void:
	if settings == null:
		settings = SpatialSkySettings.new()
	var environment := world.environment.duplicate() as Environment
	var sky := Sky.new()
	var material := ShaderMaterial.new()
	material.shader = SKY
	var direction := settings.moon_direction()
	material.set_shader_parameter("moon_direction", direction)
	var top := settings.night_sky_color.srgb_to_linear()
	var horizon := settings.night_horizon_color.srgb_to_linear()
	material.set_shader_parameter("sky_top", Vector3(top.r, top.g, top.b))
	material.set_shader_parameter("sky_horizon", Vector3(horizon.r, horizon.g, horizon.b))
	sky.sky_material = material
	environment.background_mode = Environment.BG_SKY
	environment.sky = sky
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.ambient_light_color = settings.night_ambient_color
	environment.ambient_light_energy = settings.night_ambient_energy
	environment.tonemap_exposure = settings.night_exposure
	environment.fog_enabled = settings.night_fog_density > 0.0
	environment.fog_light_color = settings.night_fog_color
	environment.fog_density = settings.night_fog_density / scale_factor
	environment.fog_sky_affect = 0.0
	environment.fog_sun_scatter = 0.0
	world.environment = environment

	moonlight.look_at_from_position(moonlight.global_position, moonlight.global_position - direction)
	moonlight.light_color = settings.night_moon_color
	moonlight.light_energy = settings.night_moon_energy
	moonlight.light_angular_distance = settings.night_moon_angular_distance
	moonlight.directional_shadow_max_distance = settings.night_shadow_distance_m * scale_factor

static func light_facades(buildings: Array[MeshInstance3D], remember_materials := false,
		night_fog := SpatialSkySettings.DEFAULT_NIGHT_FOG_DENSITY) -> Array[Dictionary]:
	var originals: Array[Dictionary] = []
	for building in buildings:
		var id := str(building.get_meta("source_id", building.name))
		var amount := float(id.hash() % 100) / 100.0
		var strength := 0.38 + amount * 0.55 if amount >= 0.18 else 0.0
		if building.material_override != null:
			_light_slot(building, "material_override", building.material_override, strength, originals, remember_materials, night_fog)
		elif building.mesh != null:
			for index in building.mesh.get_surface_count():
				_light_slot(building, "surface_material_override/%d" % index,
					building.get_active_material(index), strength, originals, remember_materials, night_fog)
	return originals

static func preview_baked_facades(chunks: Node, night: bool, night_fog: float) -> Array[Dictionary]:
	var originals: Array[Dictionary] = []
	var previews := {}
	for mesh: MeshInstance3D in chunks.find_children("*", "MeshInstance3D", true, false):
		if mesh.mesh == null:
			continue
		for index in mesh.mesh.get_surface_count():
			var facade := mesh.get_active_material(index) as ShaderMaterial
			if facade == null or facade.shader != FACADE:
				continue
			if not previews.has(facade):
				previews[facade] = _baked_facade_preview(facade, night, night_fog)
			var preview := previews[facade] as ShaderMaterial
			if preview == null:
				continue
			var slot := "surface_material_override/%d" % index
			originals.append({"building": mesh, "slot": slot, "material": mesh.get(slot), "preview": preview})
			mesh.set(slot, preview)
	return originals

static func _baked_facade_preview(facade: ShaderMaterial, night: bool, night_fog: float) -> ShaderMaterial:
	var lit: bool = facade.get_shader_parameter("lit_windows") == true
	var saved_strength: Variant = facade.get_shader_parameter("night_uplight")
	var strength := float(saved_strength) if saved_strength != null else 0.0
	if night:
		if not lit:
			return _lit_material(facade, strength, night_fog)
		var saved_fog: Variant = facade.get_shader_parameter("night_fog_density")
		if saved_fog != null and is_equal_approx(float(saved_fog), night_fog):
			return null
		var lit_preview := facade.duplicate() as ShaderMaterial
		lit_preview.set_shader_parameter("night_fog_density", night_fog)
		return lit_preview
	if not lit and is_zero_approx(strength):
		return null
	var daylight := facade.duplicate() as ShaderMaterial
	daylight.set_shader_parameter("lit_windows", false)
	daylight.set_shader_parameter("night_uplight", 0.0)
	return daylight

func _place_street_lights(map: Node3D, buildings: Array[MeshInstance3D], scale_factor: float) -> void:
	var player := map.get_node_or_null("FlyPlayer") as Node3D
	var ground := map.get_node_or_null("FlatGround") as Node3D
	if player == null or ground == null:
		return
	var origin := Vector2(player.global_position.x, player.global_position.z)
	var candidates: Array[Dictionary] = []
	for building in buildings:
		if not building.is_visible_in_tree():
			continue
		var layout: Dictionary = building.get_meta("facade_openings", {})
		for sample: Dictionary in layout.get("samples", []):
			var center: Array = sample["center"]
			var normal: Array = sample["normal"]
			var edge := map.to_global(Vector3(float(center[0]), 0.0, float(center[2])))
			var distance := origin.distance_squared_to(Vector2(edge.x, edge.z))
			if distance < pow(100.0 * scale_factor, 2):
				var direction := (map.global_basis * Vector3(float(normal[0]), 0.0, float(normal[2]))).normalized()
				candidates.append({"edge": edge, "normal": direction, "distance": distance})
	candidates.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a["distance"] < b["distance"])
	var placed: Array[Vector3] = []
	for candidate in candidates:
		var edge: Vector3 = candidate["edge"]
		if placed.any(func(other: Vector3) -> bool: return edge.distance_to(other) < 11.0 * scale_factor):
			continue
		placed.append(edge)
		var spot := SpotLight3D.new()
		spot.name = "StreetUplight%02d" % placed.size()
		spot.light_color = Color("ffb978") if placed.size() % 2 == 1 else Color("75bfff")
		spot.light_energy = 2.5
		spot.spot_range = 8.0 * scale_factor
		spot.spot_angle = 32.0
		spot.distance_fade_enabled = true
		spot.distance_fade_begin = 65.0 * scale_factor
		spot.distance_fade_length = 45.0 * scale_factor
		add_child(spot)
		edge.y = ground.global_position.y
		spot.global_position = edge + candidate["normal"] * (1.8 * scale_factor) + Vector3.UP * (0.25 * scale_factor)
		spot.look_at(edge + Vector3.UP * (2.4 * scale_factor))
		if placed.size() == MAX_RENDERED_LIGHTS:
			return

static func _light_slot(building: MeshInstance3D, slot: String, source: Material, strength: float,
		originals: Array[Dictionary], remember_materials: bool, night_fog: float) -> void:
	var material := _lit_material(source, strength, night_fog)
	if material == null:
		return
	if remember_materials:
		originals.append({"building": building, "slot": slot, "material": building.get(slot), "preview": material})
	building.set(slot, material)

static func _lit_material(original: Material, strength: float, night_fog: float) -> ShaderMaterial:
	var facade := original as ShaderMaterial
	if facade == null or facade.shader != FACADE:
		return null
	var material := facade.duplicate() as ShaderMaterial
	material.set_shader_parameter("night_uplight", strength)
	material.set_shader_parameter("lit_windows", true)
	material.set_shader_parameter("night_fog_density", night_fog)
	material.set_shader_parameter("match_window_palette", true)
	var grille: Variant = facade.get_shader_parameter("window_grille_style")
	if grille == null or grille < 0:
		material.set_shader_parameter("glass_color", Windows.GLASS_COLOR)
		material.set_shader_parameter("window_frame_color", Windows.FRAME_COLOR)
	material.set_shader_parameter("window_glass_roughness", Windows.GLASS_ROUGHNESS)
	return material
