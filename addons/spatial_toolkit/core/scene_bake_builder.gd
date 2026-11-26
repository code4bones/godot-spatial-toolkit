@tool
extends RefCounted
## Offline static batches. All work happens on a detached saved-scene instance.
signal progress(message: String, fraction: float)
const Localization := preload("res://addons/spatial_toolkit/ui/editor_localization.gd")
const MATERIALS := preload("res://addons/spatial_toolkit/core/scene_bake_materials.gd")
const Layers := preload("res://addons/spatial_toolkit/core/spatial_layers.gd")
const LAYERS := ["Buildings", "Roads", "Paths", "PlannedRoads", "Landuse", "Water"]
const GENERATOR := "spatial_toolkit.scene_bake.v1"
var _host: Node
var _cancelled: Callable
var _materials
var _chunks: Dictionary
var _manifest: Dictionary
var _source_meshes: Array[MeshInstance3D]
var _building_bounds := AABB()
var _has_building_bounds := false

func build(map: Node3D, chunk_size: float, merge_collisions: bool, host: Node, cancelled: Callable,
		window_detail: bool = false) -> Dictionary:
	_host = host
	_cancelled = cancelled
	_chunks = {}
	_source_meshes = []
	_has_building_bounds = false
	_building_bounds = AABB()
	_materials = MATERIALS.new()
	_manifest = {"version": 1, "units": "gameplay_meters", "chunk_size_m": chunk_size,
		"grid_origin_m": [0, 0, 0], "feature_ownership": "whole feature by AABB center; no physical clipping",
		"visual_ranges": [], "collision_ranges": [], "features": {}}
	if map.has_meta("scene_bake") or map.get_node_or_null("BakedChunks") != null:
		return _error(Localization.translate("The scene is already baked. Select the source map."))
	var generated := map.get_node_or_null("Generated") as Node3D
	if generated == null or not generated.has_meta("source"):
		return _error(Localization.translate("The scene does not contain an original Spatial Toolkit Generated map."))
	var validation := _collect(map, generated)
	if not validation.is_empty():
		return _error(validation)
	if _source_meshes.is_empty():
		return _error(Localization.translate("The map has no supported generated meshes."))
	_manifest["source_metadata"] = _metadata(generated)
	var world_features := {"roads": {}, "buildings": {}}
	var window_transforms: Array[Transform3D] = []
	var window_styles: Array[SpatialWindowStyle] = [null]
	var window_style_indices := {}
	var window_style_ids := PackedInt32Array()
	var before := count_scene(map)
	for index: int in _source_meshes.size():
		if _cancelled.call():
			return {"ok": false, "cancelled": true, "error": Localization.translate("Bake cancelled.")}
		var mesh := _source_meshes[index]
		var transform := _relative(mesh, map)
		if absf(transform.basis.determinant()) < 0.00000001:
			return _error(Localization.translate("Degenerate transform on %s") % str(mesh.name))
		if transform.basis.determinant() < 0.0:
			return _error(Localization.translate("A mirrored transform requires a separate save: %s") % str(mesh.name))
		var bounds := transform * mesh.get_aabb()
		var center := bounds.get_center()
		var x := int(floor(center.x / chunk_size))
		var z := int(floor(center.z / chunk_size))
		var chunk_id := "Chunk_%d_%d" % [x, z]
		if not _chunks.has(chunk_id):
			_chunks[chunk_id] = {"origin": Vector3(x * chunk_size, 0, z * chunk_size), "groups": {}, "collision_groups": {}, "bodies": []}
		var chunk: Dictionary = _chunks[chunk_id]
		var identity := str(mesh.get_meta("source_id"))
		var kind := Layers.root_kind(mesh)
		if kind in ["Roads", "Paths", "PlannedRoads"]:
			world_features["roads"][identity] = kind
		elif kind == "Buildings":
			var previous: Array = world_features["buildings"].get(identity, [])
			var combined := bounds
			if previous.size() == 6:
				combined = combined.merge(AABB(Vector3(previous[0], previous[1], previous[2]),
					Vector3(previous[3] - previous[0], previous[4] - previous[1], previous[5] - previous[2])))
			world_features["buildings"][identity] = [combined.position.x, combined.position.y,
				combined.position.z, combined.end.x, combined.end.y, combined.end.z]
		var source_path := str(map.get_path_to(mesh))
		_manifest["features"][source_path] = {"source_id": identity, "chunk_id": chunk_id, "metadata": _metadata(mesh)}
		var window_base := -1
		if window_detail and kind == "Buildings" and _flags(mesh, map)["visible"] and _has_window_atlas(mesh):
			var prepared_windows := _window_transforms(mesh, transform)
			if not prepared_windows.is_empty():
				var style := Layers.effective(mesh).get("window_style") as SpatialWindowStyle
				var style_id := 0
				if style != null:
					if not window_style_indices.has(style):
						var invalid := style.validation_error()
						if not invalid.is_empty():
							return _error(Localization.translate("Invalid window style on %s. %s") % [source_path, invalid])
						window_style_indices[style] = window_styles.size()
						window_styles.append(style)
					style_id = window_style_indices[style]
				window_base = window_transforms.size()
				window_transforms.append_array(prepared_windows)
				if window_styles.size() > 1:
					window_style_ids.resize(window_transforms.size())
					for id in range(window_base, window_transforms.size()):
						window_style_ids[id] = style_id
		if Layers.root_kind(mesh) == "Buildings":
			_building_bounds = _building_bounds.merge(bounds) if _has_building_bounds else bounds
			_has_building_bounds = true
		for surface: int in mesh.mesh.get_surface_count():
			var prepared: Dictionary = _materials.prepare(mesh.get_active_material(surface), window_base)
			var section_coordinates: bool = prepared["section_coordinates"]
			var flags := _flags(mesh, map)
			var key := str(prepared["key"]) + "|" + var_to_str(flags)
			var groups: Dictionary = chunk["groups"]
			if not groups.has(key):
				var tool := SurfaceTool.new()
				tool.begin(Mesh.PRIMITIVE_TRIANGLES)
				tool.set_material(prepared["material"])
				tool.set_custom_format(0, SurfaceTool.CUSTOM_RGBA_FLOAT)
				if section_coordinates:
					tool.set_custom_format(1, SurfaceTool.CUSTOM_RGB_FLOAT)
					tool.set_custom_format(2, SurfaceTool.CUSTOM_RGB_FLOAT)
				groups[key] = {"tool": tool, "triangles": 0, "flags": flags, "ranges": [], "material": prepared["material"]}
			var group: Dictionary = groups[key]
			var arrays := mesh.mesh.surface_get_arrays(surface)
			var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
			var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
			var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
			var uvs: PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV] if arrays[Mesh.ARRAY_TEX_UV] != null else PackedVector2Array()
			var uv2s: PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV2] if arrays[Mesh.ARRAY_TEX_UV2] != null else PackedVector2Array()
			var colors: PackedColorArray = arrays[Mesh.ARRAY_COLOR] if arrays[Mesh.ARRAY_COLOR] != null else PackedColorArray()
			var count := indices.size() if not indices.is_empty() else vertices.size()
			if count % 3 != 0 or normals.size() != vertices.size():
				return _error(Localization.translate("Triangles with normals are required: %s") % source_path)
			for custom_index: int in range(Mesh.ARRAY_CUSTOM0, Mesh.ARRAY_CUSTOM3 + 1):
				if arrays[custom_index] != null and arrays[custom_index].size() > 0:
					return _error(Localization.translate("Custom vertex attributes are already in use: %s") % source_path)
			if arrays[Mesh.ARRAY_BONES] != null and arrays[Mesh.ARRAY_BONES].size() > 0:
				return _error(Localization.translate("Skinned meshes cannot be baked: %s") % source_path)
			var tangents: PackedFloat32Array = arrays[Mesh.ARRAY_TANGENT] if arrays[Mesh.ARRAY_TANGENT] != null else PackedFloat32Array()
			var first_triangle := int(group["triangles"])
			var normal_transform := transform.basis.inverse().transposed()
			var origin: Vector3 = chunk["origin"]
			var tool: SurfaceTool = group["tool"]
			for corner: int in count:
				var vertex_index := indices[corner] if not indices.is_empty() else corner
				var normal := (normal_transform * normals[vertex_index]).normalized()
				tool.set_normal(normal)
				var tangent := normal.cross(Vector3.UP if absf(normal.y) < 0.95 else Vector3.RIGHT).normalized()
				var handedness := 1.0
				if not tangents.is_empty():
					tangent = transform.basis * Vector3(tangents[vertex_index * 4], tangents[vertex_index * 4 + 1], tangents[vertex_index * 4 + 2])
					tangent = (tangent - normal * normal.dot(tangent)).normalized()
					handedness = tangents[vertex_index * 4 + 3] * signf(transform.basis.determinant())
				tool.set_tangent(Plane(tangent, handedness))
				tool.set_uv(prepared["uv"] if prepared["facade"] else uvs[vertex_index] if not uvs.is_empty() else Vector2.ZERO)
				tool.set_uv2(uv2s[vertex_index] if not uv2s.is_empty() else Vector2.ZERO)
				tool.set_color(colors[vertex_index] if not colors.is_empty() else Color.WHITE)
				tool.set_custom(0, prepared["custom"] if prepared["facade"] else Color(0, 0, 0, 0))
				if section_coordinates:
					# The atlas addresses the original mesh, before chunk transforms.
					var local_vertex := vertices[vertex_index]
					var local_normal := normals[vertex_index]
					tool.set_custom(1, Color(local_vertex.x, local_vertex.y, local_vertex.z))
					tool.set_custom(2, Color(local_normal.x, local_normal.y, local_normal.z))
				tool.add_vertex(transform * vertices[vertex_index] - origin)
				if (corner + 1) % 12288 == 0:
					await _host.get_tree().process_frame
					if _cancelled.call():
						return {"ok": false, "cancelled": true, "error": Localization.translate("Bake cancelled.")}
			group["triangles"] = first_triangle + count / 3
			var record := {"source_id": identity, "source_node": source_path, "source_surface": surface,
				"chunk_id": chunk_id, "surface": 0, "triangle_start": first_triangle, "triangle_count": count / 3}
			group["ranges"].append(record)
		for child in mesh.get_children():
			var body := child as StaticBody3D
			if body == null:
				continue
			if not merge_collisions:
				chunk["bodies"].append({"node": body, "transform": _relative(body, map)})
				continue
			for shape_value in body.get_children():
				var shape := shape_value as CollisionShape3D
				var source_shape := shape.shape as ConcavePolygonShape3D
				var collision_key := "%d|%d|%s|%s|%s|%s" % [body.collision_layer, body.collision_mask, source_shape.backface_collision, body.collision_priority, source_shape.margin, source_shape.custom_solver_bias]
				var collision_groups: Dictionary = chunk["collision_groups"]
				if not collision_groups.has(collision_key):
					collision_groups[collision_key] = {"faces": PackedVector3Array(), "layer": body.collision_layer,
						"mask": body.collision_mask, "backface": source_shape.backface_collision,
						"priority": body.collision_priority, "margin": source_shape.margin,
						"solver_bias": source_shape.custom_solver_bias, "ranges": []}
				var collision_group: Dictionary = collision_groups[collision_key]
				var shape_transform := _relative(shape, map)
				if shape_transform.basis.determinant() <= 0.00000001:
					return _error(Localization.translate("Mirrored or degenerate collision transform: %s") % source_path)
				var source_faces := source_shape.get_faces()
				var target_faces: PackedVector3Array = collision_group["faces"]
				var first := target_faces.size() / 3
				for face: Vector3 in source_faces:
					target_faces.append(shape_transform * face - chunk["origin"])
				collision_group["faces"] = target_faces
				collision_group["ranges"].append({"source_id": identity, "source_node": source_path,
					"chunk_id": chunk_id, "triangle_start": first, "triangle_count": source_faces.size() / 3})
		if (index + 1) % 16 == 0:
			progress.emit(Localization.translate("Combining features %d/%d…") % [index + 1, _source_meshes.size()],
				0.08 + 0.62 * float(index + 1) / _source_meshes.size())
			await _host.get_tree().process_frame
	var container := Node3D.new()
	container.name = "BakedChunks"
	container.set_meta("generated_by", GENERATOR)
	map.add_child(container)
	container.owner = map
	var chunk_keys: Array = _chunks.keys()
	chunk_keys.sort()
	for chunk_id: String in chunk_keys:
		if _cancelled.call():
			return {"ok": false, "cancelled": true, "error": Localization.translate("Bake cancelled.")}
		var chunk: Dictionary = _chunks[chunk_id]
		var chunk_node := Node3D.new()
		chunk_node.name = chunk_id
		chunk_node.position = chunk["origin"]
		chunk_node.set_meta("units", "gameplay_meters")
		chunk_node.set_meta("chunk_origin_m", [chunk_node.position.x, 0, chunk_node.position.z])
		container.add_child(chunk_node)
		chunk_node.owner = map
		var group_keys: Array = chunk["groups"].keys()
		group_keys.sort()
		for group_index: int in group_keys.size():
			var group: Dictionary = chunk["groups"][group_keys[group_index]]
			var tool: SurfaceTool = group["tool"]
			tool.index()
			var instance := MeshInstance3D.new()
			instance.name = "Mesh_%03d" % group_index
			instance.mesh = tool.commit()
			if instance.mesh == null:
				return _error(Localization.translate("Could not build mesh %s") % chunk_id)
			for property: String in group["flags"]:
				instance.set(property, group["flags"][property])
			instance.set_meta("generated_by", GENERATOR)
			chunk_node.add_child(instance)
			instance.owner = map
			var path := "BakedChunks/" + chunk_id + "/" + str(instance.name)
			for record: Dictionary in group["ranges"]:
				record["mesh_node"] = path
				_manifest["visual_ranges"].append(record)
		var collision_keys: Array = chunk["collision_groups"].keys()
		collision_keys.sort()
		for collision_index: int in collision_keys.size():
			var group: Dictionary = chunk["collision_groups"][collision_keys[collision_index]]
			var body := StaticBody3D.new()
			body.name = "StaticBody3D" if collision_keys.size() == 1 else "StaticBody3D_%d" % collision_index
			body.collision_layer = group["layer"]
			body.collision_mask = group["mask"]
			body.collision_priority = group["priority"]
			body.set_meta("generated_by", GENERATOR)
			chunk_node.add_child(body)
			body.owner = map
			var collision := CollisionShape3D.new()
			collision.name = "CollisionShape3D"
			var shape := ConcavePolygonShape3D.new()
			shape.set_faces(group["faces"])
			shape.backface_collision = group["backface"]
			shape.margin = group["margin"]
			shape.custom_solver_bias = group["solver_bias"]
			collision.shape = shape
			body.add_child(collision)
			collision.owner = map
			for record: Dictionary in group["ranges"]:
				record["body_node"] = "BakedChunks/" + chunk_id + "/" + str(body.name)
				_manifest["collision_ranges"].append(record)
		for record: Dictionary in chunk["bodies"]:
			var body: StaticBody3D = record["node"]
			_clear_owner(body)
			body.get_parent().remove_child(body)
			chunk_node.add_child(body)
			body.transform = Transform3D(Basis.IDENTITY, -chunk["origin"]) * record["transform"]
			_set_owner(body, map)
		await _host.get_tree().process_frame
	for instance: MeshInstance3D in _source_meshes:
		instance.get_parent().remove_child(instance)
		instance.free()
	if map.has_meta("assembly_source_world"):
		for layer_name: String in LAYERS:
			var layer := generated.get_node_or_null(layer_name)
			if layer is SpatialLayer3D and _contains_only_layer_groups(layer):
				layer.free()
	if _has_building_bounds:
		map.set_meta("baked_building_bounds_m", [_building_bounds.position.x, _building_bounds.position.y, _building_bounds.position.z,
			_building_bounds.size.x, _building_bounds.size.y, _building_bounds.size.z])
	map.set_meta("scene_bake", {"generator": GENERATOR, "chunk_size_m": chunk_size, "merge_collisions": merge_collisions})
	var after := count_scene(map)
	var report := {"version": 1, "before": before, "after": after, "chunks": chunk_keys.size(),
		"chunk_size_m": chunk_size, "units": "gameplay_meters", "merge_collisions": merge_collisions,
		"source_features": _source_meshes.size(), "surface_draws_estimate_before": before["surfaces"],
		"surface_draws_estimate_after": after["surfaces"], "fps_measured": false,
		"limits": ["No HLOD, streaming, lightmap or occlusion bake", "Large features retain one owner chunk and may extend beyond its grid cell", "Global FlatGround retained separately for horizon/overview", "Physics/material/geometry metrics are structural, not measured frame-time claims"]}
	_manifest["metrics"] = report
	return {"ok": true, "report": report, "manifest": _manifest, "world_features": world_features,
		"window_transforms": window_transforms, "window_styles": window_styles, "window_style_ids": window_style_ids}

func _has_window_atlas(mesh: MeshInstance3D) -> bool:
	for surface in mesh.mesh.get_surface_count():
		var material := mesh.get_active_material(surface) as ShaderMaterial
		if material != null and material.shader != null and material.shader.resource_path == MATERIALS.FACADE \
				and material.get_shader_parameter("section_windows") == true \
				and int(material.get_shader_parameter("section_wall_count")) > 0 \
				and int(material.get_shader_parameter("section_light_offset")) >= 0 \
				and material.get_shader_parameter("hide_decorative_windows") != true:
			return true
	return false

func _window_transforms(mesh: MeshInstance3D, transform: Transform3D) -> Array[Transform3D]:
	var result: Array[Transform3D] = []
	var layout: Dictionary = mesh.get_meta("facade_window_layout", {})
	var width := float(layout.get("width_m", 0.0))
	var height := float(layout.get("height_m", 0.0))
	if width <= 0.0 or height <= 0.0 or not layout.get("walls") is Array:
		return result
	var scale_factor := float(mesh.get_meta("world_scale", 1.0))
	for wall: Dictionary in layout["walls"]:
		var normal_values: Array = wall.get("normal", [])
		if normal_values.size() != 3:
			return []
		var normal := Vector3(normal_values[0], normal_values[1], normal_values[2]).normalized()
		if not normal.is_finite() or absf(normal.dot(Vector3.UP)) > 0.001 or normal.is_zero_approx():
			return []
		var basis := Basis(Vector3.UP.cross(normal) * width, Vector3.UP * height, normal * 0.09 * scale_factor)
		for window: Dictionary in wall.get("windows", []):
			var coordinates: Array = window.get("center", [])
			if coordinates.size() != 3:
				return []
			var center := Vector3(coordinates[0], coordinates[1], coordinates[2])
			if not center.is_finite():
				return []
			result.append(transform * Transform3D(basis, center - normal * 0.10 * scale_factor))
	return result

func _contains_only_layer_groups(node: Node) -> bool:
	for child in node.get_children():
		if not child is SpatialLayer3D or not _contains_only_layer_groups(child):
			return false
	return true

func _collect(map: Node3D, generated: Node3D) -> String:
	for layer_name: String in LAYERS:
		var layer := generated.get_node_or_null(layer_name)
		if layer == null:
			continue
		for mesh in Layers.meshes(layer):
			if not mesh.has_meta("source_id"):
				continue
			if mesh.mesh == null or mesh.get_script() != null or not mesh.skeleton.is_empty() or mesh.mesh.get_blend_shape_count() != 0:
				return Localization.translate("Unsupported dynamic or empty mesh: %s") % str(mesh.name)
			var ancestor: Node = mesh
			while ancestor != map:
				if ancestor is Node3D and ancestor.top_level:
					return Localization.translate("The source node's top_level setting is unsupported: %s") % str(map.get_path_to(ancestor))
				ancestor = ancestor.get_parent()
			if mesh.material_overlay != null or not mesh.visibility_parent.is_empty() or mesh.custom_aabb != AABB():
				return Localization.translate("Special visual properties require a separate save: %s") % str(mesh.name)
			for surface: int in mesh.mesh.get_surface_count():
				if mesh.mesh.surface_get_primitive_type(surface) != Mesh.PRIMITIVE_TRIANGLES:
					return Localization.translate("The mesh must consist of triangles: %s") % str(mesh.name)
			for child in mesh.get_children():
				if not child is StaticBody3D or child.get_script() != null or not str(child.get_meta("generated_by", "")).begins_with("spatial_toolkit."):
					return Localization.translate("Custom child nodes require a separate save: %s") % str(mesh.name)
				if child.physics_material_override != null or child.constant_linear_velocity != Vector3.ZERO or child.constant_angular_velocity != Vector3.ZERO:
					return Localization.translate("Special physics properties require a separate save: %s") % str(mesh.name)
				for shape in child.get_children():
					if not shape is CollisionShape3D or not shape.shape is ConcavePolygonShape3D or shape.disabled:
						return Localization.translate("Unsupported or disabled collision: %s") % str(mesh.name)
			_source_meshes.append(mesh)
	return ""

func _relative(node: Node3D, root: Node3D) -> Transform3D:
	var result := Transform3D.IDENTITY
	var current: Node = node
	while current != root:
		if current is Node3D:
			result = current.transform * result
		current = current.get_parent()
	return result

func _flags(mesh: MeshInstance3D, root: Node3D) -> Dictionary:
	var visible := true
	var current: Node = mesh
	while current != root:
		if current is Node3D:
			visible = visible and current.visible
		current = current.get_parent()
	return {"visible": visible, "layers": mesh.layers, "cast_shadow": mesh.cast_shadow,
		"extra_cull_margin": mesh.extra_cull_margin, "lod_bias": mesh.lod_bias,
		"transparency": mesh.transparency, "sorting_offset": mesh.sorting_offset,
		"sorting_use_aabb_center": mesh.sorting_use_aabb_center, "ignore_occlusion_culling": mesh.ignore_occlusion_culling,
		"gi_mode": mesh.gi_mode, "visibility_range_begin": mesh.visibility_range_begin,
		"visibility_range_end": mesh.visibility_range_end, "visibility_range_begin_margin": mesh.visibility_range_begin_margin,
		"visibility_range_end_margin": mesh.visibility_range_end_margin, "visibility_range_fade_mode": mesh.visibility_range_fade_mode}

func _metadata(node: Node) -> Dictionary:
	var value := {}
	for key: StringName in node.get_meta_list():
		value[str(key)] = node.get_meta(key)
	return value

func _clear_owner(node: Node) -> void:
	for child in node.get_children():
		_clear_owner(child)
	node.owner = null

func _set_owner(node: Node, owner: Node) -> void:
	node.owner = owner
	for child in node.get_children():
		_set_owner(child, owner)

func _error(message: String) -> Dictionary:
	return {"ok": false, "error": message}

static func count_scene(root: Node) -> Dictionary:
	var result := {"nodes": 0, "mesh_instances": 0, "materials": 0, "surfaces": 0,
		"static_bodies": 0, "collision_shapes": 0, "visual_triangles": 0, "collision_triangles": 0}
	var material_ids := {}
	var pending: Array[Node] = [root]
	while not pending.is_empty():
		var node: Node = pending.pop_back()
		result["nodes"] += 1
		pending.append_array(node.get_children())
		if node is MeshInstance3D and node.mesh != null:
			result["mesh_instances"] += 1
			result["surfaces"] += node.mesh.get_surface_count()
			result["visual_triangles"] += node.mesh.get_faces().size() / 3
			for surface: int in node.mesh.get_surface_count():
				var material: Material = node.get_active_material(surface)
				if material != null:
					material_ids[material.get_instance_id()] = true
		if node is StaticBody3D:
			result["static_bodies"] += 1
		if node is CollisionShape3D:
			result["collision_shapes"] += 1
			if node.shape is ConcavePolygonShape3D:
				result["collision_triangles"] += node.shape.get_faces().size() / 3
	result["materials"] = material_ids.size()
	return result
