extends CPUParticles3D
## Keep the plume attached to the nozzle and pulse on throttle increases.

const BOOST_HOLD := 0.08
const BOOST_FADE := 0.16
const BOOST_STRETCH := 2.6
const PLUME_SHADER := preload("res://addons/spatial_toolkit/materials/elastic_plume.gdshader")
const BOOST_COLORS := [
	Color(1.0, 0.74, 0.49, 0.9),
	Color(1.0, 0.23, 0.11, 0.64),
	Color(0.88, 0.07, 0.025, 0.25),
	Color(0.72, 0.025, 0.01, 0.0),
]

var _boost_age := 0.0
var _pulse := 0.0
var _turn_thrust := 0.0
var _maneuver_thrust := 0.0
var _normal_colors := PackedColorArray()
var _normal_scale := Vector3.ONE
var _plume_material: ShaderMaterial
var _nozzle_position := Vector3.ZERO
var _middle_axis := Vector3.BACK
var _tail_axis := Vector3.BACK
var _near_velocity := Vector3.ZERO
var _far_velocity := Vector3.ZERO

func _ready() -> void:
	_normal_scale = scale
	color_ramp = color_ramp.duplicate() as Gradient
	_normal_colors = color_ramp.colors
	_plume_material = ShaderMaterial.new()
	_plume_material.shader = PLUME_SHADER
	material_override = _plume_material
	extra_cull_margin = 4.0 * global_basis.get_scale().length()
	_reset_bend()

func boost() -> void:
	_boost_age = 0.0
	_apply_pulse(1.0)

func set_turn_thrust(thrust: float) -> void:
	_turn_thrust = clampf(thrust, -1.0, 1.0)
	_apply_scale()

func set_maneuver_thrust(thrust: float) -> void:
	if is_equal_approx(_maneuver_thrust, thrust):
		return
	_maneuver_thrust = thrust
	_apply_scale()

func _process(delta: float) -> void:
	if _pulse > 0.0:
		_boost_age += delta
		var pulse := 1.0 - smoothstep(BOOST_HOLD, BOOST_HOLD + BOOST_FADE, _boost_age)
		_apply_pulse(pulse)
	_update_bend(delta)

func _reset_bend() -> void:
	_nozzle_position = global_position
	_middle_axis = global_basis.z.normalized()
	_tail_axis = _middle_axis
	_near_velocity = Vector3.ZERO
	_far_velocity = Vector3.ZERO
	_plume_material.set_shader_parameter("bend_middle", Vector3.ZERO)
	_plume_material.set_shader_parameter("bend_tail", Vector3.ZERO)

func _update_bend(delta: float) -> void:
	if delta <= 0.0:
		return
	var axis := global_basis.z.normalized()
	var displacement := global_position - _nozzle_position
	if not is_visible_in_tree() or displacement.length() > maxf(12.0, delta * 180.0):
		_reset_bend()
		return
	_nozzle_position = global_position
	var velocity := displacement / delta
	var near_weight := 1.0 - exp(-16.0 * delta)
	var far_weight := 1.0 - exp(-4.0 * delta)
	_middle_axis = _middle_axis.lerp(axis, near_weight)
	_tail_axis = _tail_axis.lerp(axis, far_weight)
	_near_velocity = _near_velocity.lerp(velocity, near_weight)
	_far_velocity = _far_velocity.lerp(velocity, far_weight)
	var reference_speed := maxf(4.0, maxf(_near_velocity.length(), _far_velocity.length()))
	var drift := (_far_velocity - _near_velocity).slide(axis) / reference_speed
	var length_m := lifetime * (initial_velocity_min + initial_velocity_max) * 0.5 * global_basis.z.length()
	var middle := ((_middle_axis - axis).slide(axis) * 2.0 + drift * 0.32).limit_length(0.65)
	var tail := ((_tail_axis - axis).slide(axis) * 2.8 + drift * 0.52).limit_length(0.93)
	_plume_material.set_shader_parameter("bend_middle", middle * length_m)
	_plume_material.set_shader_parameter("bend_tail", tail * length_m)
	_plume_material.set_shader_parameter("nozzle_axis", axis)
	_plume_material.set_shader_parameter("plume_length", length_m)

func _apply_pulse(pulse: float) -> void:
	_pulse = pulse
	_apply_scale()
	var colors := _normal_colors.duplicate()
	for index in colors.size():
		colors[index] = colors[index].lerp(BOOST_COLORS[index], pulse)
	color_ramp.colors = colors


func _apply_scale() -> void:
	var width := 1.0 + _turn_thrust * 0.13 + _maneuver_thrust * 0.04
	var length := (1.0 + _turn_thrust * 0.4) * (1.0 + _maneuver_thrust * 0.22)
	scale = _normal_scale * Vector3(width, width, length * lerpf(1.0, BOOST_STRETCH, _pulse))
