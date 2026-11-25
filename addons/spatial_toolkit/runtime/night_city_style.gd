extends Node
## Moonlit lighting for a Spatial map.

const MODE := &"spatial_sky_mode"
const DAY := &"day"
const NIGHT := &"night"

const SKY := preload("res://addons/spatial_toolkit/materials/night_sky.gdshader")
const FACADE := preload("res://addons/spatial_toolkit/materials/building_facade.gdshader")
const Windows := preload("res://addons/spatial_toolkit/runtime/facade_window_preview.gd")
const MOON_DIRECTION := Vector3(0.32, 0.31, 0.895)
const MAX_RENDERED_LIGHTS := 4
const FOG_DENSITY := 0.0042

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
	var environment := world.environment.duplicate() as Environment
	var sky := Sky.new()
	var material := ShaderMaterial.new()
	material.shader = SKY
	material.set_shader_parameter("moon_direction", MOON_DIRECTION)
	sky.sky_material = material
	environment.sky = sky
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.ambient_light_color = Color("829acf")
	environment.ambient_light_energy = 0.32
	environment.tonemap_exposure = 0.86
	environment.fog_enabled = true
	environment.fog_light_color = Color("0a0b10")
	environment.fog_density = FOG_DENSITY / scale_factor
	environment.fog_sky_affect = 0.0
	environment.fog_sun_scatter = 0.0
	world.environment = environment

	moonlight.look_at_from_position(moonlight.global_position, moonlight.global_position - MOON_DIRECTION)
	moonlight.light_color = Color("a9c2f4")
	moonlight.light_energy = 0.35
	moonlight.light_angular_distance = 1.0
	moonlight.directional_shadow_max_distance = 200.0 * scale_factor
	var buildings := map.get_node_or_null("Generated/Buildings")
	if buildings != null:
		for building in buildings.get_children():
			if building is MeshInstance3D:
				var id := str(building.get_meta("source_id", building.name))
				var amount := float(id.hash() % 100) / 100.0
				_light_facade(building, 0.38 + amount * 0.55 if amount >= 0.18 else 0.0)
		_place_street_lights(map, buildings, scale_factor)

func _place_street_lights(map: Node3D, buildings: Node, scale_factor: float) -> void:
	var player := map.get_node_or_null("FlyPlayer") as Node3D
	var ground := map.get_node_or_null("FlatGround") as Node3D
	if player == null or ground == null:
		return
	var origin := Vector2(player.global_position.x, player.global_position.z)
	var candidates: Array[Dictionary] = []
	for building in buildings.get_children():
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

func _light_facade(building: MeshInstance3D, strength: float) -> void:
	if building.material_override != null:
		var material := _lit_material(building.material_override, strength)
		if material != null:
			building.material_override = material
		return
	if building.mesh != null:
		for index in building.mesh.get_surface_count():
			var material := _lit_material(building.get_active_material(index), strength)
			if material != null:
				building.set_surface_override_material(index, material)

func _lit_material(original: Material, strength: float) -> ShaderMaterial:
	var facade := original as ShaderMaterial
	if facade == null or facade.shader != FACADE:
		return null
	var material := facade.duplicate() as ShaderMaterial
	material.set_shader_parameter("night_uplight", strength)
	material.set_shader_parameter("lit_windows", true)
	material.set_shader_parameter("night_fog_density", FOG_DENSITY)
	material.set_shader_parameter("match_window_palette", true)
	material.set_shader_parameter("glass_color", Windows.GLASS_COLOR)
	material.set_shader_parameter("window_frame_color", Windows.FRAME_COLOR)
	material.set_shader_parameter("window_glass_roughness", Windows.GLASS_ROUGHNESS)
	return material
