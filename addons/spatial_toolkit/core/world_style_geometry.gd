@tool
extends RefCounted
## Pure source-relative geometry helpers; never mutate source arrays/resources.

static func relative(node: Node3D, root: Node3D) -> Transform3D:
	var transform := Transform3D.IDENTITY
	var current: Node = node
	while current != root:
		if current is Node3D:
			transform = current.transform * transform
		current = current.get_parent()
	return transform

static func vec3(value: Array) -> Vector3:
	return Vector3(float(value[0]), float(value[1]), float(value[2]))

static func serial_vector(value: Vector3) -> Array:
	return [value.x, value.y, value.z]

static func roll(seed: int, source_id: String, slot: String) -> float:
	return float((str(seed) + "|" + source_id + "|" + slot).sha256_text().substr(0, 12).hex_to_int()) / 281474976710656.0

static func triangle_contains(point: Vector3, triangle: PackedVector3Array, margin: float = 0.00001) -> bool:
	var a := triangle[1] - triangle[0]
	var b := triangle[2] - triangle[0]
	var p := point - triangle[0]
	var denominator := a.dot(a) * b.dot(b) - a.dot(b) * a.dot(b)
	if absf(denominator) < 0.0000001:
		return false
	var u := (b.dot(b) * p.dot(a) - a.dot(b) * p.dot(b)) / denominator
	var v := (a.dot(a) * p.dot(b) - a.dot(b) * p.dot(a)) / denominator
	return u >= margin and v >= margin and u + v <= 1.0 - margin

static func rectangle_supported(center: Vector3, horizontal: Vector3, vertical: Vector3, width: float, height: float, triangle: PackedVector3Array) -> bool:
	for x: float in [-0.5, 0.5]:
		for y: float in [-0.5, 0.5]:
			if not triangle_contains(center + horizontal * width * x + vertical * height * y, triangle):
				return false
	return true

static func box_transform(center: Vector3, horizontal: Vector3, normal: Vector3, dimensions: Vector3) -> Transform3D:
	var vertical := normal.cross(horizontal).normalized()
	return Transform3D(Basis(horizontal * dimensions.x, vertical * dimensions.y, normal * dimensions.z), center)

static func stable_value(value: Variant) -> String:
	if value is PackedByteArray:
		return value.hex_encode().sha256_text()
	if value is PackedVector3Array or value is PackedVector2Array or value is PackedFloat32Array or value is PackedInt32Array or value is PackedColorArray:
		return var_to_bytes(value).hex_encode().sha256_text()
	if value is Dictionary:
		var keys: Array = value.keys()
		keys.sort()
		var output := PackedStringArray()
		for key: Variant in keys:
			output.append(str(key) + "=" + stable_value(value[key]))
		return "{" + ";".join(output) + "}"
	if value is Array:
		var output := PackedStringArray()
		for item: Variant in value:
			output.append(stable_value(item))
		return "[" + ";".join(output) + "]"
	if value is MultiMesh:
		# Only documented public semantics, including CPU-authored matrix data.
		# Native get_instance_transform() returns identity in the dummy renderer;
		# private serialized cache fields also differ between GPU and headless.
		var multimesh := value as MultiMesh
		# Text scene serialization canonicalizes IEEE -0.0 to +0.0. Their
		# numeric/transform meaning is identical; hash only a normalized COPY.
		# Every nonzero float bit and the actual rendering buffer stay intact.
		var canonical_buffer := multimesh.buffer.duplicate()
		for index: int in canonical_buffer.size():
			if canonical_buffer[index] == 0.0:
				canonical_buffer[index] = 0.0
		return stable_value({"class": "MultiMesh", "name": multimesh.resource_name, "mesh": multimesh.mesh,
			"transform_format": multimesh.transform_format, "use_colors": multimesh.use_colors,
			"use_custom_data": multimesh.use_custom_data, "instance_count": multimesh.instance_count,
			"visible_instance_count": multimesh.visible_instance_count, "custom_aabb": multimesh.custom_aabb,
			"buffer": canonical_buffer})
	if value is Resource:
		var resource := value as Resource
		var output := PackedStringArray([resource.get_class()])
		for entry: Dictionary in resource.get_property_list():
			var key := str(entry["name"])
			if int(entry["usage"]) & PROPERTY_USAGE_STORAGE == 0 or key in ["resource_path", "resource_local_to_scene", "resource_scene_unique_id", "script"]:
				continue
			output.append(key + "=" + stable_value(resource.get(key)))
		return "\n".join(output).sha256_text()
	return var_to_str(value)

static func fingerprint(node: Node) -> String:
	var output := PackedStringArray([str(node.name), node.get_class()])
	for property: String in ["transform", "visible", "layers", "cast_shadow", "visibility_range_end", "mesh", "multimesh", "material_override", "material_overlay", "script"]:
		if property in node:
			output.append(property + "=" + stable_value(node.get(property)))
	var metadata := {}
	for key: StringName in node.get_meta_list():
		if key != &"content_fingerprint":
			metadata[str(key)] = node.get_meta(key)
	output.append(stable_value(metadata))
	for child: Node in node.get_children():
		output.append(fingerprint(child))
	return "\n".join(output).sha256_text()
