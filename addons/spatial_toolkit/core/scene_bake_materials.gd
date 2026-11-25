@tool
extends RefCounted
## Material identity and optional facade values carried by float vertex attributes.
const FLAT := "res://addons/spatial_toolkit/materials/flat_map_surface.gdshader"
const FACADE := "res://addons/spatial_toolkit/materials/building_facade.gdshader"
var materials: Dictionary = {}

func prepare(material: Material) -> Dictionary:
	var result := {"material": material, "facade": false}
	if material is ShaderMaterial and material.shader != null and material.shader.resource_path == FACADE:
		var original := material as ShaderMaterial
		var wall: Variant = original.get_shader_parameter("wall_color")
		if not wall is Color:
			wall = Color(0.62, 0.59, 0.52, 1)
		# source_color uniforms are converted from sRGB by the renderer. CUSTOM0
		# is a float attribute, so encode that conversion explicitly (no RGBA8 loss).
		var linear: Color = wall.srgb_to_linear()
		result["facade"] = true
		result["custom"] = Color(linear.r, linear.g, linear.b, float(_parameter(original, "facade_style", 0)))
		result["uv"] = Vector2(float(_parameter(original, "building_seed", 0)), float(_parameter(original, "floor_height", 3)))
		var shared := original.duplicate() as ShaderMaterial
		shared.set_shader_parameter("baked_facade_data", true)
		shared.set_shader_parameter("wall_color", Color.WHITE)
		shared.set_shader_parameter("building_seed", 0.0)
		shared.set_shader_parameter("floor_height", 3.0)
		shared.set_shader_parameter("facade_style", 0)
		material = shared
	elif material is ShaderMaterial and material.shader != null and material.shader.resource_path == FLAT:
		var original := material as ShaderMaterial
		var color: Variant = original.get_shader_parameter("surface_color")
		if not color is Color:
			color = Color(0.47, 0.52, 0.40, 1.0)
		var linear: Color = color.srgb_to_linear()
		result["facade"] = true # same float attribute transport, unused UV is zero
		result["custom"] = Color(linear.r, linear.g, linear.b, 1)
		result["uv"] = Vector2.ZERO
		var shared := original.duplicate() as ShaderMaterial
		shared.set_shader_parameter("baked_vertex_color", true)
		shared.set_shader_parameter("surface_color", Color.WHITE)
		material = shared
	var key := _resource_key(material)
	if not materials.has(key):
		materials[key] = material
	result["key"] = key
	result["material"] = materials[key]
	return result

func _parameter(material: ShaderMaterial, name: String, fallback: Variant) -> Variant:
	var value: Variant = material.get_shader_parameter(name)
	return fallback if value == null else value

func _resource_key(value: Variant, depth: int = 0) -> String:
	if value == null:
		return "null"
	if not value is Resource:
		return var_to_str(value)
	var resource := value as Resource
	if depth > 8:
		return resource.get_class() + ":" + resource.resource_path
	if resource is Shader:
		return "Shader:" + resource.code.sha256_text()
	if resource is Texture2D or resource is Texture3D or resource is TextureLayered:
		return resource.get_class() + ":" + resource.resource_path
	var properties: Array[String] = []
	for entry: Dictionary in resource.get_property_list():
		var name := str(entry["name"])
		if int(entry["usage"]) & PROPERTY_USAGE_STORAGE == 0 or name.begins_with("resource_"):
			continue
		properties.append(name)
	properties.sort()
	var parts := PackedStringArray([resource.get_class()])
	for name: String in properties:
		parts.append(name + "=" + _resource_key(resource.get(name), depth + 1))
	return "\n".join(parts).sha256_text()
