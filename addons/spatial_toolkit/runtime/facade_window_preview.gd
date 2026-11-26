extends RefCounted
## Extracts window meshes and prepares closed facade surfaces.

const FACADE := "res://addons/spatial_toolkit/materials/building_facade.gdshader"
const GLASS_SHADER := preload("res://addons/spatial_toolkit/materials/modular_window_glass.gdshader")
const GLASS_COLOR := Color(0.28, 0.43, 0.51)
const FRAME_COLOR := Color(0.19, 0.23, 0.25)
const GLASS_ROUGHNESS := 0.35
const GLASS_SPECULAR := 0.32
## Projected bar centers and widths measured on the industrial GLB's front elevation.
const INDUSTRIAL_VERTICAL_BARS := [
	Vector2(0.013, 0.026), Vector2(0.140, 0.009), Vector2(0.2507, 0.018),
	Vector2(0.377, 0.009), Vector2(0.497, 0.017), Vector2(0.626, 0.008),
	Vector2(0.7466, 0.018), Vector2(0.875, 0.014), Vector2(0.987, 0.026),
]
const INDUSTRIAL_HORIZONTAL_BARS := [
	Vector2(0.013, 0.026), Vector2(0.327, 0.026), Vector2(0.659, 0.025), Vector2(0.979, 0.042),
]

static func extract_module(scene: PackedScene, node_name: String, night: bool) -> Dictionary:
	var collection := scene.instantiate()
	var module := collection.find_child(node_name, true, false) as MeshInstance3D
	var visible_window := ArrayMesh.new()
	var glass := AABB()
	if module != null and module.mesh != null:
		for index in module.mesh.get_surface_count():
			var surface := module.get_active_material(index)
			var arrays := module.mesh.surface_get_arrays(index)
			visible_window.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
			if surface != null and surface.resource_name.to_lower().ends_with("glass"):
				var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
				if not vertices.is_empty():
					glass = AABB(vertices[0], Vector3.ZERO)
					for vertex in vertices:
						glass = glass.expand(vertex)
				visible_window.surface_set_material(visible_window.get_surface_count() - 1, _glass_material(night))
				continue
			visible_window.surface_set_material(visible_window.get_surface_count() - 1, surface)
	collection.free()
	return {"glass": glass, "mesh": visible_window}

static func extract_frame(scene: PackedScene) -> ArrayMesh:
	var collection := scene.instantiate()
	if not collection is Node3D:
		collection.free()
		return null
	var modules := collection.find_children("*", "MeshInstance3D", true, false)
	if collection is MeshInstance3D:
		modules.push_front(collection)
	var frame: ArrayMesh
	if modules.size() == 1:
		var module := modules[0] as MeshInstance3D
		if module.mesh != null:
			var transform := Transform3D.IDENTITY
			var node: Node = module
			while node is Node3D:
				transform = node.transform * transform
				node = node.get_parent()
			frame = ArrayMesh.new()
			for index in module.mesh.get_surface_count():
				var surface := SurfaceTool.new()
				surface.begin(Mesh.PRIMITIVE_TRIANGLES)
				surface.append_from(module.mesh, index, transform)
				surface.set_material(module.get_active_material(index))
				surface.commit(frame)
	collection.free()
	return frame

static func simple_window(night: bool) -> ArrayMesh:
	var frame := SurfaceTool.new()
	frame.begin(Mesh.PRIMITIVE_TRIANGLES)
	for side in [-1.0, 1.0]:
		_add_bar(frame, Vector3(0.12, 1.19, 0.22), Vector3(side * 0.56, 0.0, 0.14))
		_add_bar(frame, Vector3(1.24, 0.095, 0.22), Vector3(0.0, side * 0.548, 0.14))
	_add_bar(frame, Vector3(0.045, 1.0, 0.1), Vector3(0.0, 0.0, 0.10))
	_add_bar(frame, Vector3(1.29, 0.045, 0.3), Vector3(0.0, -0.64, 0.17))
	var finish := StandardMaterial3D.new()
	finish.albedo_color = FRAME_COLOR
	finish.roughness = 0.72
	frame.set_material(finish)
	var mesh := frame.commit()

	var glazing := SurfaceTool.new()
	glazing.begin(Mesh.PRIMITIVE_TRIANGLES)
	_add_bar(glazing, Vector3(1.0, 1.0, 0.025), Vector3(0.0, 0.0, 0.045))
	glazing.set_material(_glass_material(night))
	return glazing.commit(mesh)

static func simple_industrial_frame() -> ArrayMesh:
	var surface := SurfaceTool.new()
	surface.begin(Mesh.PRIMITIVE_TRIANGLES)
	for bar: Vector2 in INDUSTRIAL_VERTICAL_BARS:
		_add_bar(surface, Vector3(bar.y, 1.0, 1.0), Vector3(bar.x - 0.5, 0.0, 0.0))
	for bar: Vector2 in INDUSTRIAL_HORIZONTAL_BARS:
		# Recess the front face slightly to avoid coplanar faces at each crossing.
		_add_bar(surface, Vector3(1.0, bar.y, 0.84), Vector3(0.0, bar.x - 0.5, 0.0))
	var finish := StandardMaterial3D.new()
	finish.albedo_color = FRAME_COLOR
	finish.roughness = 0.72
	surface.set_material(finish)
	return surface.commit()

static func _glass_material(night: bool) -> ShaderMaterial:
	var material := ShaderMaterial.new()
	material.shader = GLASS_SHADER
	material.set_shader_parameter("glass_color", GLASS_COLOR)
	material.set_shader_parameter("glass_roughness", GLASS_ROUGHNESS)
	material.set_shader_parameter("glass_specular", GLASS_SPECULAR)
	material.set_shader_parameter("lit_windows", night)
	return material

static func _add_bar(surface: SurfaceTool, size: Vector3, position: Vector3) -> void:
	var bar := BoxMesh.new()
	bar.size = size
	surface.append_from(bar, 0, Transform3D(Basis.IDENTITY, position))

static func apply_section_layout(building: MeshInstance3D, layout: Dictionary, floor_height: float,
		recess_depth_m: float = 0.0) -> void:
	if building.material_override != null:
		var changed := _layout_material(building.material_override, layout, floor_height, recess_depth_m)
		if changed != null:
			building.material_override = changed
		return
	for index in building.mesh.get_surface_count():
		var changed := _layout_material(building.get_active_material(index), layout, floor_height, recess_depth_m)
		if changed != null:
			building.set_surface_override_material(index, changed)

static func _layout_material(original: Material, layout: Dictionary, floor_height: float,
		recess_depth_m: float) -> ShaderMaterial:
	var facade := original as ShaderMaterial
	if facade == null or facade.shader == null or facade.shader.resource_path != FACADE:
		return null
	var material := facade.duplicate() as ShaderMaterial
	material.set_shader_parameter("open_windows", false)
	configure_section_layout(material, layout, floor_height, recess_depth_m)
	return material

static func configure_section_layout(material: ShaderMaterial, layout: Dictionary, floor_height: float,
		recess_depth_m := 0.0) -> void:
	material.set_shader_parameter("floor_height", floor_height)
	material.set_shader_parameter("section_windows", true)
	material.set_shader_parameter("section_first_level", layout.get("first_level", 1))
	material.set_shader_parameter("section_wall_count", layout["wall_count"] if layout.has("wall_count") else layout["walls"].size())
	material.set_shader_parameter("section_window_vertical", layout["vertical"])
	material.set_shader_parameter("section_window_half_width_m", float(layout.get("width_m", SpatialWindowLayout.DEFAULT_WIDTH_M)) * 0.5)
	material.set_shader_parameter("section_window_atlas", layout["texture"])
	material.set_shader_parameter("section_light_offset", layout.get("light_offset", -1))
	if recess_depth_m > 0.0:
		material.set_shader_parameter("section_window_depth_m", recess_depth_m)

static func seal_openings(building: MeshInstance3D, map: Node3D, world_scale: float) -> void:
	var openings: Dictionary = building.get_meta("facade_openings", {})
	var samples: Array = openings.get("samples", [])
	if samples.is_empty() or not building.mesh is ArrayMesh:
		return
	var facade: ShaderMaterial
	for index in building.mesh.get_surface_count():
		var active := building.get_active_material(index) as ShaderMaterial
		if active != null and active.shader != null and active.shader.resource_path == FACADE:
			facade = active
			break
	if facade == null:
		return
	var panels := SurfaceTool.new()
	panels.begin(Mesh.PRIMITIVE_TRIANGLES)
	panels.set_material(facade)
	var depth := maxf(0.0, float(openings.get("wall_thickness_m", 0.0)))
	var overlap := 0.004 * world_scale
	for sample: Dictionary in samples:
		var position: Array = sample["center"]
		var outward: Array = sample["normal"]
		var center := building.to_local(map.to_global(Vector3(position[0], position[1], position[2])))
		var normal := (building.global_basis.transposed()
			* (map.global_basis * Vector3(outward[0], 0.0, outward[2]))).normalized()
		var half_width := float(sample["width_m"]) * 0.5 + overlap
		var half_height := float(sample["height_m"]) * 0.5 + overlap
		_add_panel(panels, center + normal * overlap, normal, half_width, half_height)
		if depth > 0.0:
			_add_panel(panels, center - normal * (depth + overlap), -normal, half_width, half_height)
	var closed := building.mesh.duplicate() as ArrayMesh
	panels.index()
	building.mesh = panels.commit(closed)
	var body := building.get_node_or_null("BuildingCollision/CollisionShape3D") as CollisionShape3D
	if body != null:
		var shape := building.mesh.create_trimesh_shape()
		shape.backface_collision = true
		body.shape = shape
	building.set_meta("sealed_opening_count", samples.size())

static func _add_panel(surface: SurfaceTool, center: Vector3, normal: Vector3,
		half_width: float, half_height: float) -> void:
	var side := Vector3.UP.cross(normal).normalized() * half_width
	var up := Vector3.UP * half_height
	for corner in [center - side - up, center - side + up, center + side + up,
		center - side - up, center + side + up, center + side - up]:
		surface.set_normal(normal)
		surface.add_vertex(corner)
