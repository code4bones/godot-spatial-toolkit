extends Node3D
## Small procedural spider rig for the third-person demo.

const STRIDE_M := 0.52
const LEG_SPREAD := [-0.27, -0.10, 0.10, 0.29]

class Leg:
	var hip: Vector3
	var knee: Vector3
	var foot: Vector3
	var phase: float
	var upper: MeshInstance3D
	var lower: MeshInstance3D

var _legs: Array[Leg] = []
var _phase := 0.0
var _stride_direction := Vector3.FORWARD
var _gait := 0.0

func _ready() -> void:
	var armor := _material(Color("353f47"), 0.65)
	var panel := _material(Color("f0ad41"), 0.32)
	var legs := _material(Color("9ba9b2"), 0.6)
	var optics := _material(Color("91e7e8"), 0.2)
	optics.emission_enabled = true
	optics.emission = optics.albedo_color
	_add_shell(Vector3(0.0, 0.01, 0.06), Vector3(0.47, 0.24, 0.66), armor)
	_add_shell(Vector3(0.0, 0.1, 0.11), Vector3(0.37, 0.14, 0.47), panel)
	_add_shell(Vector3(0.0, -0.01, -0.26), Vector3(0.28, 0.16, 0.22), armor)
	for side: float in [-1.0, 1.0]:
		_add_shell(Vector3(side * 0.075, 0.0, -0.347), Vector3(0.052, 0.051, 0.048), optics)
		for index in LEG_SPREAD.size():
			var spread: float = LEG_SPREAD[index]
			var leg := Leg.new()
			leg.hip = Vector3(side * 0.16, -0.035, spread * 0.72)
			leg.knee = Vector3(side * 0.43, 0.03, spread * 1.45)
			leg.foot = Vector3(side * 0.49, -0.37, spread * 1.85)
			leg.phase = PI * ((index + int(side > 0.0)) % 2)
			leg.upper = _add_segment(0.032, armor)
			leg.lower = _add_segment(0.02, legs)
			_legs.append(leg)
	animate(Vector3.ZERO, 0.0)

func animate(travel: Vector3, delta: float) -> void:
	var planar := Vector3(travel.x, 0.0, travel.z)
	var moving := planar.length_squared() > 0.000001
	if moving:
		_stride_direction = planar.normalized()
		_phase = fposmod(_phase + planar.length() * TAU / STRIDE_M, TAU)
	_gait = move_toward(_gait, 1.0 if moving else 0.0, delta * 9.0)
	for leg: Leg in _legs:
		var phase := _phase + leg.phase
		var lift := maxf(sin(phase), 0.0) * _gait * 0.085
		var step := _stride_direction * (cos(phase) * _gait * 0.1)
		var knee := leg.knee + step * 0.35
		var foot := leg.foot + step + Vector3.UP * lift
		_pose_segment(leg.upper, leg.hip, knee)
		_pose_segment(leg.lower, knee, foot)

func _add_shell(center: Vector3, dimensions: Vector3, material: Material) -> void:
	var shell := SphereMesh.new()
	shell.radial_segments = 16
	shell.rings = 8
	shell.material = material
	var instance := MeshInstance3D.new()
	instance.mesh = shell
	instance.position = center
	instance.scale = dimensions
	add_child(instance)

func _add_segment(radius: float, material: Material) -> MeshInstance3D:
	var segment := CylinderMesh.new()
	segment.height = 1.0
	segment.top_radius = radius * 0.8
	segment.bottom_radius = radius
	segment.radial_segments = 8
	segment.rings = 0
	segment.material = material
	var instance := MeshInstance3D.new()
	instance.mesh = segment
	add_child(instance)
	return instance

func _pose_segment(segment: MeshInstance3D, start: Vector3, end: Vector3) -> void:
	var offset := end - start
	var rotation_basis := Basis(Quaternion(Vector3.UP, offset.normalized()))
	segment.transform = Transform3D(rotation_basis * Basis.from_scale(Vector3(1.0, offset.length(), 1.0)),
		(start + end) * 0.5)

func _material(color: Color, metallic: float) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.metallic = metallic
	material.roughness = 0.6
	return material
