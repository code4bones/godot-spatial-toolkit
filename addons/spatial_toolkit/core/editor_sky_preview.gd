@tool
extends RefCounted
## Apply a reversible sky mode to a map and its facade materials.

const Night := preload("res://addons/spatial_toolkit/runtime/night_city_style.gd")
const Layers := preload("res://addons/spatial_toolkit/core/spatial_layers.gd")
const LIGHT_PROPERTIES := [&"transform", &"light_color", &"light_energy",
	&"light_angular_distance", &"directional_shadow_max_distance"]

var _world: WorldEnvironment
var _sun: DirectionalLight3D
var _environment: Environment
var _overview: Camera3D
var _overview_environment: Environment
var _light := {}
var _materials: Array[Dictionary] = []
var _night := false
var _night_fog := 0.0


func start(map: Node3D, mode: StringName, settings: SpatialSkySettings) -> bool:
	_world = map.get_node_or_null("PreviewEnvironment") as WorldEnvironment
	_sun = map.get_node_or_null("PreviewSun") as DirectionalLight3D
	if _world == null or _world.environment == null or _sun == null:
		return false
	_night = mode == Night.NIGHT
	_night_fog = Night.fog_density(settings)
	var world_scale := float(map.get_meta("world_scale", 1.0))
	var legacy_night := Night.is_night_environment(_world.environment)
	if _night or settings != null or legacy_night:
		_environment = _world.environment
		for property: StringName in LIGHT_PROPERTIES:
			_light[property] = _sun.get(property)
		if _night:
			Night.configure_lighting(_world, _sun, world_scale, settings)
		else:
			var day := settings if settings != null else SpatialSkySettings.new()
			var environment := _day_environment(map, day, world_scale, legacy_night and settings == null)
			_world.environment = environment
			day.configure_sun(_sun, world_scale)
	if settings != null:
		_overview = map.get_node_or_null("OverviewCamera") as Camera3D
		if _overview != null:
			_overview_environment = _overview.environment
			var clear := (_overview_environment if _overview_environment != null else _world.environment).duplicate() as Environment
			settings.configure_day_environment(clear, world_scale)
			clear.fog_enabled = false
			clear.volumetric_fog_enabled = false
			_overview.environment = clear
	refresh_facades(map)
	return true

func _day_environment(map: Node3D, settings: SpatialSkySettings, world_scale: float,
		recover_overview: bool) -> Environment:
	if recover_overview:
		var camera := map.get_node_or_null("OverviewCamera") as Camera3D
		if camera != null and camera.environment != null and not Night.is_night_environment(camera.environment):
			# Older bakes often retain the original day palette on the fog-free overview.
			var recovered := camera.environment.duplicate() as Environment
			settings.configure_day_fog(recovered, world_scale)
			return recovered
	var environment := _environment.duplicate() as Environment
	settings.configure_day_environment(environment, world_scale)
	return environment


func refresh_facades(map: Node3D) -> void:
	var chunks := map.get_node_or_null("BakedChunks")
	if chunks != null:
		_materials = Night.preview_baked_facades(chunks, _night, _night_fog)
	elif _night:
		_materials = Night.light_facades(Layers.buildings(map), true, _night_fog)


func restore_facades() -> void:
	for entry in _materials:
		var building: Variant = entry["building"]
		if is_instance_valid(building) and building.get(entry["slot"]) == entry["preview"]:
			building.set(entry["slot"], entry["material"])
	_materials.clear()


func stop() -> void:
	restore_facades()
	if _environment != null and is_instance_valid(_world):
		_world.environment = _environment
	if is_instance_valid(_overview):
		_overview.environment = _overview_environment
	if is_instance_valid(_sun):
		for property: StringName in _light:
			_sun.set(property, _light[property])
