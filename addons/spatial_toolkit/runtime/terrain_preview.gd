extends Node3D
## One bounded terrain trial using projected metres and a saved source ID.

const GROUND := "res://assets/materials/ground_rocky.tres"
const TERRAIN_SHADER := preload("res://addons/spatial_toolkit/materials/terrain_surface.gdshader")
const RINGS := 12
const SECTORS := 40
const SKIRT_WIDTH_M := 0.35
const SKIRT_DEPTH_M := 0.08
const SURFACE_LIFT_M := 0.01
static var _materials: Dictionary = {}

@export_range(1.0, 100.0) var world_scale := 1.0
@export var radius_m := 6.8
@export var height_m := 1.6
@export var source_id := ""
@export var shape_seed := ""

var _noise := FastNoiseLite.new()

func _ready() -> void:
	_noise.seed = (source_id if shape_seed.is_empty() else shape_seed).hash()
	_noise.frequency = 0.21
	var surface := SurfaceTool.new()
	surface.begin(Mesh.PRIMITIVE_TRIANGLES)
	for ring in range(RINGS + 1):
		for sector in range(SECTORS):
			var inner := _point(ring, sector)
			var outer := _point(ring + 1, sector)
			var next_outer := _point(ring + 1, sector + 1)
			_add_vertex(surface, inner)
			_add_vertex(surface, outer)
			_add_vertex(surface, next_outer)
			if ring > 0:
				_add_vertex(surface, inner)
				_add_vertex(surface, next_outer)
				_add_vertex(surface, _point(ring, sector + 1))
	var overlay := MeshInstance3D.new()
	overlay.name = "HillMesh"
	surface.index()
	overlay.mesh = surface.commit()
	overlay.material_override = _terrain_material(world_scale)
	overlay.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(overlay)
	overlay.set_instance_shader_parameter("terrain_center", Vector2(global_position.x, -global_position.z))
	overlay.set_instance_shader_parameter("terrain_radius", radius_m * world_scale)
	overlay.create_trimesh_collision()
	overlay.get_child(0).add_to_group(&"spatial_terrain")

static func _terrain_material(scale_factor: float) -> ShaderMaterial:
	if _materials.has(scale_factor):
		return _materials[scale_factor]
	if not ResourceLoader.exists(GROUND, "ShaderMaterial"):
		return null
	var preset := load(GROUND) as ShaderMaterial
	if preset == null:
		return null
	var material := ShaderMaterial.new()
	material.shader = TERRAIN_SHADER
	for uniform in TERRAIN_SHADER.get_shader_uniform_list():
		var key: String = uniform["name"]
		var value: Variant = preset.get_shader_parameter(key)
		if value != null:
			material.set_shader_parameter(key, value)
	var repeat_m: float = preset.get_shader_parameter("repeat_size")
	material.set_shader_parameter("repeat_size", repeat_m * scale_factor)
	_materials[scale_factor] = material
	return material

func _point(ring: int, sector: int) -> Vector2:
	var radius := radius_m * ring / RINGS if ring <= RINGS else radius_m + SKIRT_WIDTH_M
	return Vector2.from_angle(TAU * (sector % SECTORS) / SECTORS) * radius

func _height(point: Vector2) -> float:
	var radius_squared := point.length_squared() / (radius_m * radius_m)
	var envelope := maxf(0.0, 1.0 - radius_squared)
	var variation := 0.78 + 0.44 * _noise.get_noise_2dv(point)
	return height_m * variation * envelope * envelope

func _add_vertex(surface: SurfaceTool, point: Vector2) -> void:
	var tangent := Vector2(0.04, 0.0)
	var bitangent := Vector2(0.0, 0.04)
	var dx := (_height(point + tangent) - _height(point - tangent)) / 0.08
	var dz := (_height(point + bitangent) - _height(point - bitangent)) / 0.08
	surface.set_normal(Vector3(-dx, 1.0, -dz).normalized())
	# The outer ring passes under FlatGround, hiding the contact edge.
	var height := -SKIRT_DEPTH_M if point.length() > radius_m + 0.1 else _height(point) + SURFACE_LIFT_M
	surface.add_vertex(Vector3(point.x, height, point.y) * world_scale)
