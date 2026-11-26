@tool
class_name SpatialSkySettings
extends Resource
## Lighting and atmosphere in source metres, shared by the squares of one world.

const Localization := preload("res://addons/spatial_toolkit/ui/editor_localization.gd")
const DEFAULT_MOON_DIRECTION := Vector3(0.32, 0.31, 0.895)
const DEFAULT_NIGHT_FOG_DENSITY := 0.0042

@export_group("Day", "day_")
@export var day_sky_color := Color("4e83b5"):
	set(value):
		day_sky_color = value
		emit_changed()
@export var day_horizon_color := Color("c8dce6"):
	set(value):
		day_horizon_color = value
		emit_changed()
@export var day_ground_color := Color("748376"):
	set(value):
		day_ground_color = value
		emit_changed()
@export var day_ambient_color := Color(0.72, 0.76, 0.82):
	set(value):
		day_ambient_color = value
		emit_changed()
@export_range(0.0, 4.0, 0.01, "or_greater") var day_ambient_energy := 0.3:
	set(value):
		day_ambient_energy = value
		emit_changed()
@export_range(0.01, 4.0, 0.01, "or_greater") var day_exposure := 0.8:
	set(value):
		day_exposure = value
		emit_changed()
@export var day_fog_color := Color("c8dce6"):
	set(value):
		day_fog_color = value
		emit_changed()
@export_range(0.0, 0.02, 0.00001, "or_greater", "suffix:m⁻¹") var day_fog_density := 0.00015:
	set(value):
		day_fog_density = value
		emit_changed()
@export var day_sun_rotation_degrees := Vector3(-38, -145, 0):
	set(value):
		day_sun_rotation_degrees = value
		emit_changed()
@export var day_sun_color := Color("fff1dc"):
	set(value):
		day_sun_color = value
		emit_changed()
@export_range(0.0, 4.0, 0.01, "or_greater") var day_sun_energy := 0.85:
	set(value):
		day_sun_energy = value
		emit_changed()
@export_range(0.0, 16.0, 0.1, "degrees") var day_sun_angular_distance := 0.5:
	set(value):
		day_sun_angular_distance = value
		emit_changed()
@export_range(1.0, 5000.0, 1.0, "or_greater", "suffix:m") var day_shadow_distance_m := 450.0:
	set(value):
		day_shadow_distance_m = value
		emit_changed()

@export_group("Night", "night_")
@export var night_sky_color := Color(0.006, 0.012, 0.031).linear_to_srgb():
	set(value):
		night_sky_color = value
		emit_changed()
@export var night_horizon_color := Color(0.047, 0.065, 0.105).linear_to_srgb():
	set(value):
		night_horizon_color = value
		emit_changed()
@export var night_ambient_color := Color("829acf"):
	set(value):
		night_ambient_color = value
		emit_changed()
@export_range(0.0, 4.0, 0.01, "or_greater") var night_ambient_energy := 0.32:
	set(value):
		night_ambient_energy = value
		emit_changed()
@export_range(0.01, 4.0, 0.01, "or_greater") var night_exposure := 0.86:
	set(value):
		night_exposure = value
		emit_changed()
@export var night_fog_color := Color("0a0b10"):
	set(value):
		night_fog_color = value
		emit_changed()
@export_range(0.0, 0.02, 0.00001, "or_greater", "suffix:m⁻¹") var night_fog_density := DEFAULT_NIGHT_FOG_DENSITY:
	set(value):
		night_fog_density = value
		emit_changed()
## X is azimuth from +Z toward +X. Y is elevation above the horizon.
@export var night_moon_angles_degrees := Vector2(
	rad_to_deg(atan2(DEFAULT_MOON_DIRECTION.x, DEFAULT_MOON_DIRECTION.z)),
	rad_to_deg(asin(DEFAULT_MOON_DIRECTION.normalized().y))):
	set(value):
		night_moon_angles_degrees = value
		emit_changed()
@export var night_moon_color := Color("a9c2f4"):
	set(value):
		night_moon_color = value
		emit_changed()
@export_range(0.0, 4.0, 0.01, "or_greater") var night_moon_energy := 0.35:
	set(value):
		night_moon_energy = value
		emit_changed()
@export_range(0.0, 16.0, 0.1, "degrees") var night_moon_angular_distance := 1.0:
	set(value):
		night_moon_angular_distance = value
		emit_changed()
@export_range(1.0, 5000.0, 1.0, "or_greater", "suffix:m") var night_shadow_distance_m := 200.0:
	set(value):
		night_shadow_distance_m = value
		emit_changed()

func _validate_property(property: Dictionary) -> void:
	Localization.localize_inspector_group(property)


func matches(other: SpatialSkySettings) -> bool:
	if other == null:
		return false
	for property: Dictionary in get_property_list():
		var key: String = property["name"]
		if (key.begins_with("day_") or key.begins_with("night_")) and get(key) != other.get(key):
			return false
	return true

func moon_direction() -> Vector3:
	var azimuth := deg_to_rad(night_moon_angles_degrees.x)
	var elevation := deg_to_rad(clampf(night_moon_angles_degrees.y, -89.9, 89.9))
	return Vector3(cos(elevation) * sin(azimuth), sin(elevation), cos(elevation) * cos(azimuth))

func configure_day_environment(environment: Environment, world_scale: float) -> void:
	var sky_material := ProceduralSkyMaterial.new()
	sky_material.sky_top_color = day_sky_color
	sky_material.sky_horizon_color = day_horizon_color
	sky_material.ground_horizon_color = day_horizon_color
	sky_material.ground_bottom_color = day_ground_color
	sky_material.sky_curve = 0.2
	sky_material.ground_curve = 0.03
	sky_material.sun_angle_max = 12.0
	sky_material.sun_curve = 0.08
	var sky := Sky.new()
	sky.sky_material = sky_material
	environment.background_mode = Environment.BG_SKY
	environment.sky = sky
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.ambient_light_color = day_ambient_color
	environment.ambient_light_energy = day_ambient_energy
	environment.reflected_light_source = Environment.REFLECTION_SOURCE_SKY
	environment.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	environment.tonemap_exposure = day_exposure
	configure_day_fog(environment, world_scale)

func configure_day_fog(environment: Environment, world_scale: float) -> void:
	environment.fog_enabled = day_fog_density > 0.0
	environment.fog_light_color = day_fog_color
	environment.fog_density = day_fog_density / world_scale
	environment.fog_sky_affect = 0.2
	environment.fog_sun_scatter = 0.08

func configure_sun(sun: DirectionalLight3D, world_scale: float) -> void:
	sun.rotation_degrees = day_sun_rotation_degrees
	sun.light_color = day_sun_color
	sun.light_energy = day_sun_energy
	sun.light_angular_distance = day_sun_angular_distance
	sun.directional_shadow_max_distance = day_shadow_distance_m * world_scale
