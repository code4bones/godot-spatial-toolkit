@tool
class_name SpatialPatrolZone3D
extends Node3D
## A map-aligned patrol rectangle centered at this node's X/Z position.

@export var enabled := true:
	set(value):
		enabled = value
		update_gizmos()
@export var size_xz := Vector2(128.0, 128.0):
	set(value):
		size_xz = value
		update_gizmos()
		update_configuration_warnings()
@export_range(0, 9) var camera_slot := 0
@export var patrol_seed := 1
@export_group("Speed Override")
@export var override_speed := false
## Speed limit during ordinary patrol in this zone.
@export_range(0.1, 100.0, 0.1, "suffix:m/s") var speed_mps := 48.0
## Use this zone's pursuit speed limit in place of the shared profile setting.
@export var override_max_chase_speed := false
## Pursuit speed limit for this zone. Zero uses 1.5 times the effective patrol Speed.
@export_range(0.0, 150.0, 0.1, "or_greater", "suffix:m/s") var max_chase_speed_mps := 0.0
@export_group("Altitude Override")
@export var override_altitude := false
@export var min_height_m := 0.0
@export var max_height_m := 128.0
@export_group("Advanced Flight Override")
## Use this zone's manual acceleration and turn settings.
@export var override_turning := false:
	set(value):
		override_turning = value
		notify_property_list_changed()
@export_range(0.1, 30.0, 0.1, "suffix:m/s²") var cruise_acceleration_mps2 := 18.0
@export_range(0.1, 30.0, 0.1, "suffix:m/s²") var lateral_acceleration_mps2 := 14.0
@export_range(0.1, 30.0, 0.1, "suffix:m") var turn_distance_m := 16.0
@export_range(0.1, 20.0, 0.1) var turn_rate := 5.0
@export_group("Clearance Override")
@export var override_clearance := false
@export_range(0.01, 10.0, 0.01, "suffix:m") var agent_radius_m := 0.35
@export_range(0.0, 10.0, 0.01, "suffix:m") var safety_margin_m := 0.15

var runtime_error := ""

func _validate_property(property: Dictionary) -> void:
	if not override_turning and property["name"] in [&"cruise_acceleration_mps2", &"lateral_acceleration_mps2",
			&"turn_distance_m", &"turn_rate"]:
		property["usage"] &= ~PROPERTY_USAGE_EDITOR

func resolved_profile(base: SpatialPatrolProfile) -> SpatialPatrolProfile:
	var result := base.duplicate() as SpatialPatrolProfile if base != null else SpatialPatrolProfile.new()
	if override_speed:
		result.speed_mps = speed_mps
	if override_max_chase_speed:
		result.max_chase_speed_mps = max_chase_speed_mps
	if override_altitude:
		result.min_height_m = min_height_m
		result.max_height_m = max_height_m
	if override_turning:
		result.manual_acceleration = true
		result.cruise_acceleration_mps2 = cruise_acceleration_mps2
		result.lateral_acceleration_mps2 = lateral_acceleration_mps2
		result.turn_distance_m = turn_distance_m
		result.turn_rate = turn_rate
	if override_clearance:
		result.agent_radius_m = agent_radius_m
		result.safety_margin_m = safety_margin_m
	return result

func map_bounds(map_root: Node3D, profile: SpatialPatrolProfile) -> AABB:
	var center := map_root.to_local(global_position)
	return AABB(Vector3(center.x - size_xz.x * 0.5, profile.min_height_m, center.z - size_xz.y * 0.5),
		Vector3(size_xz.x, profile.max_height_m - profile.min_height_m, size_xz.y))

func validation_error(map_root: Node3D) -> String:
	if not size_xz.is_finite() or size_xz.x <= 0.0 or size_xz.y <= 0.0:
		return "Patrol rectangle must have a finite positive width and depth."
	var relative := map_root.global_transform.affine_inverse() * global_transform
	if not relative.basis.is_equal_approx(Basis.IDENTITY):
		return "Patrol zones must keep map-aligned axes and unit scale."
	if not relative.origin.is_finite():
		return "Patrol zone position must be finite."
	if camera_slot < 0 or camera_slot > 9:
		return "Camera slot must be between 0 and 9."
	return ""

func _get_configuration_warnings() -> PackedStringArray:
	var warnings := PackedStringArray()
	if not get_parent() is SpatialPatrolManager:
		warnings.append("Place this zone directly under a SpatialPatrolManager.")
	if not size_xz.is_finite() or size_xz.x <= 0.0 or size_xz.y <= 0.0:
		warnings.append("Set a positive rectangle size in gameplay metres.")
	return warnings
