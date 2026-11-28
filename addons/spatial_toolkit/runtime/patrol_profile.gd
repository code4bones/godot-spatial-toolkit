@tool
class_name SpatialPatrolProfile
extends Resource
## Shared patrol settings, expressed in the baked map's gameplay metres.

const REFERENCE_SPEED_MPS := 13.0
const REFERENCE_CRUISE_ACCELERATION_MPS2 := 8.0
const REFERENCE_LATERAL_ACCELERATION_MPS2 := 4.0
const MIN_AUTO_ACCELERATION_MPS2 := 0.1
const MAX_AUTO_CRUISE_ACCELERATION_MPS2 := 18.0
const MAX_AUTO_LATERAL_ACCELERATION_MPS2 := 14.0

@export_group("Flight")
## Speed limit during ordinary patrol.
@export_range(0.1, 100.0, 0.1, "suffix:m/s") var speed_mps := 48.0
## Speed limit during pursuit. Zero uses 1.5 times Speed. A positive limit is at least Speed.
@export_range(0.0, 150.0, 0.1, "or_greater", "suffix:m/s") var max_chase_speed_mps := 0.0
@export_group("Advanced Flight")
## Use the stored acceleration values for both patrol and pursuit.
@export var manual_acceleration := false:
	set(value):
		manual_acceleration = value
		notify_property_list_changed()
@export_range(0.1, 30.0, 0.1, "suffix:m/s²") var cruise_acceleration_mps2 := 18.0
@export_range(0.1, 30.0, 0.1, "suffix:m/s²") var lateral_acceleration_mps2 := 14.0
@export_range(0.1, 30.0, 0.1, "suffix:m") var turn_distance_m := 16.0
@export_range(0.1, 20.0, 0.1) var turn_rate := 5.0
@export_group("Altitude")
@export var min_height_m := 0.0
@export var max_height_m := 128.0
@export_group("Clearance")
@export_range(0.01, 10.0, 0.01, "suffix:m") var agent_radius_m := 0.35
@export_range(0.0, 10.0, 0.01, "suffix:m") var safety_margin_m := 0.15

func _validate_property(property: Dictionary) -> void:
	if not manual_acceleration and property["name"] in [&"cruise_acceleration_mps2", &"lateral_acceleration_mps2"]:
		property["usage"] &= ~PROPERTY_USAGE_EDITOR

func effective_max_chase_speed_mps() -> float:
	if max_chase_speed_mps == 0.0:
		return speed_mps * SpatialFlyingPatrol.AUTO_CHASE_SPEED_MULTIPLIER
	return maxf(speed_mps, max_chase_speed_mps)

func effective_accelerations() -> Vector2:
	## X is longitudinal acceleration and braking; Y is lateral acceleration on curves.
	if manual_acceleration:
		return Vector2(cruise_acceleration_mps2, lateral_acceleration_mps2)
	var ratio := speed_mps / REFERENCE_SPEED_MPS
	# Preserve time to cruise and the preferred turn radius until the tested caps apply.
	return Vector2(
		clampf(REFERENCE_CRUISE_ACCELERATION_MPS2 * ratio, MIN_AUTO_ACCELERATION_MPS2,
			MAX_AUTO_CRUISE_ACCELERATION_MPS2),
		clampf(REFERENCE_LATERAL_ACCELERATION_MPS2 * ratio * ratio, MIN_AUTO_ACCELERATION_MPS2,
			MAX_AUTO_LATERAL_ACCELERATION_MPS2))

func validation_error() -> String:
	for value in [speed_mps, turn_distance_m, turn_rate, agent_radius_m]:
		if not is_finite(value) or value <= 0.0:
			return "Flight speed, acceleration, turn settings and agent radius must be positive and finite."
	if not is_finite(max_chase_speed_mps) or max_chase_speed_mps < 0.0 or not is_finite(effective_max_chase_speed_mps()):
		return "Maximum chase speed must be finite and nonnegative."
	var acceleration := effective_accelerations()
	if not acceleration.is_finite() or acceleration.x <= 0.0 or acceleration.y <= 0.0:
		return "Patrol acceleration values must be positive and finite."
	if not is_finite(safety_margin_m) or safety_margin_m < 0.0:
		return "Safety margin must be finite and nonnegative."
	if not is_finite(min_height_m) or not is_finite(max_height_m) or max_height_m <= min_height_m:
		return "Altitude bounds must be finite and ordered."
	return ""

func apply_to(patrol: SpatialFlyingPatrol) -> void:
	var acceleration := effective_accelerations()
	patrol.speed_mps = speed_mps
	patrol.max_chase_speed_mps = effective_max_chase_speed_mps()
	patrol.automatic_chase_acceleration = not manual_acceleration
	patrol.cruise_acceleration_mps2 = acceleration.x
	patrol.lateral_acceleration_mps2 = acceleration.y
	patrol.turn_distance_m = turn_distance_m
	patrol.turn_rate = turn_rate
	patrol.agent_radius_m = agent_radius_m
	patrol.safety_margin_m = safety_margin_m
