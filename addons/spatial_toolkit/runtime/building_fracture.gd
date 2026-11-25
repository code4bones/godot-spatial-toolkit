extends Node
## Prepare a native shell on aim and cut the impact contour directly into it.

const BreakableWindow := preload("res://addons/spatial_toolkit/runtime/breakable_window.gd")
const DEBRIS_BURST := preload("res://addons/spatial_toolkit/runtime/masonry_burst.tscn")
const COLLISION := preload("res://addons/spatial_toolkit/core/building_collision_generator.gd")
const SOLID_SHELL_DEPTH_M := 0.32
const RIM_SIDES := 24
const CLIP_EPSILON := 0.0001
const FRAGMENT_COUNT := 12
const MAX_LIVE_FRAGMENTS := 24

class Surface:
	var original: Array
	var material: Material
	var vertices := PackedVector3Array()
	var normals := PackedVector3Array()
	var fixed := false

var _building: MeshInstance3D
var _collision: CollisionShape3D
var _surfaces: Array[Surface] = []
var _rim := Surface.new()
var _pending: Array[Vector3] = []
var _size := 8.0
var _world_scale := 1.0
var _hollow_depth := 0.0
var _prepared := false
var _damaged := false
var _live_fragments: Array[RigidBody3D] = []

static func for_hit(collider: Object) -> Node:
	var body := collider as StaticBody3D
	if body == null or body.get_meta("generated_by", "") != COLLISION.GENERATOR:
		return null
	var building := body.get_parent() as MeshInstance3D
	var shape := body.get_node_or_null("CollisionShape3D") as CollisionShape3D
	if building == null or not building.mesh is ArrayMesh or shape == null or not shape.shape is ConcavePolygonShape3D:
		return null
	var existing := body.get_node_or_null("RuntimeFracture")
	if existing != null:
		return existing
	var job := (load("res://addons/spatial_toolkit/runtime/building_fracture.gd") as Script).new() as Node
	job.name = "RuntimeFracture"
	job._building = building
	job._collision = shape
	job._world_scale = float(building.get_meta("world_scale", 1.0))
	job._size = float(building.get_meta("fracture_cell_size_m", 8.0 * job._world_scale))
	var openings: Dictionary = building.get_meta("facade_openings", {})
	job._hollow_depth = float(openings.get("wall_thickness_m", 0.0))
	body.add_child(job)
	job.call_deferred("_prepare")
	return job

func hit(point: Vector3, normal: Vector3) -> void:
	if normal.is_zero_approx():
		return
	_pending.append(point)
	_pending.append(normal)
	if _prepared:
		call_deferred("_apply_hits")

func _prepare() -> void:
	var mesh := _building.mesh as ArrayMesh
	var deadline := Time.get_ticks_usec() + 2500
	for index in mesh.get_surface_count():
		if mesh.surface_get_primitive_type(index) != Mesh.PRIMITIVE_TRIANGLES:
			queue_free()
			return
		var surface := Surface.new()
		surface.original = mesh.surface_get_arrays(index)
		surface.material = _building.get_active_material(index)
		surface.fixed = index == _building.get_meta("floor_surface_index", -1) \
			or index == _building.get_meta("foundation_surface_index", -1)
		_surfaces.append(surface)
		if surface.fixed:
			continue
		if not surface.original[Mesh.ARRAY_NORMAL] is PackedVector3Array:
			queue_free()
			return
		var vertices: PackedVector3Array = surface.original[Mesh.ARRAY_VERTEX]
		var normals: PackedVector3Array = surface.original[Mesh.ARRAY_NORMAL]
		var indices: PackedInt32Array = surface.original[Mesh.ARRAY_INDEX] \
			if surface.original[Mesh.ARRAY_INDEX] != null else PackedInt32Array()
		if normals.size() != vertices.size():
			queue_free()
			return
		for offset in (vertices.size() if indices.is_empty() else indices.size()):
			var vertex := offset if indices.is_empty() else indices[offset]
			surface.vertices.append(vertices[vertex])
			surface.normals.append(normals[vertex])
			if offset % 256 == 0 and Time.get_ticks_usec() >= deadline:
				await get_tree().process_frame
				deadline = Time.get_ticks_usec() + 2500
	_rim.material = _masonry_material()
	_prepared = true
	_apply_hits()
	get_tree().create_timer(9.0).timeout.connect(func() -> void:
		if not _damaged and _pending.is_empty():
			queue_free())

func _apply_hits() -> void:
	while _pending.size() >= 2:
		var point := _pending.pop_front() as Vector3
		var normal := _pending.pop_front() as Vector3
		_break_at(point, normal)

func _break_at(world_point: Vector3, world_normal: Vector3) -> void:
	var point := _building.to_local(world_point)
	var normal := (_building.global_basis.transposed() * world_normal).normalized()
	var axis := Vector3.RIGHT if absf(normal.z) > 0.99 else Vector3.BACK
	var right := normal.cross(axis).normalized()
	var up := normal.cross(right)
	var random := RandomNumberGenerator.new()
	random.randomize()
	var radius := _impact_radius(random)
	var depth := maxf(_hollow_depth + 0.06 * _world_scale, 0.42 * _world_scale)
	var planes := _impact_planes(point, normal, right, up, radius, depth, random)
	if not _apply_contour(point, radius * 1.24 + depth, planes):
		return
	_chip_rim(point, normal, right, up, radius, depth, planes, random)
	_commit_mesh()
	_damaged = true
	var window_cuts: Array = _building.get_meta("modular_window_cuts", [])
	window_cuts.append(planes)
	_building.set_meta("modular_window_cuts", window_cuts)
	_remove_glass(planes)
	_spawn_debris(world_point, world_normal.normalized(), right, up, radius, random)
	_emit_masonry(world_point, world_normal.normalized())

func _impact_radius(random: RandomNumberGenerator) -> float:
	return _size * 0.42 * random.randf_range(0.60, 0.95)

func _apply_contour(point: Vector3, extent: float, planes: Array[Plane]) -> bool:
	var span := Vector3.ONE * extent
	var bounds := AABB(point - span, span * 2.0)
	var new_rim := Surface.new()
	var cut := false
	for surface in _surfaces:
		if not surface.fixed:
			cut = _cut_surface(surface, bounds, planes, new_rim) or cut
	if not cut:
		return false
	_cut_surface(_rim, bounds, planes)
	_rim.vertices.append_array(new_rim.vertices)
	_rim.normals.append_array(new_rim.normals)
	return true

func _chip_rim(point: Vector3, normal: Vector3, right: Vector3, up: Vector3, radius: float,
		depth: float, outline: Array[Plane], random: RandomNumberGenerator) -> void:
	var count := random.randi_range(7, 10)
	var phase := random.randf_range(0.0, TAU)
	for index in count:
		var angle := phase + TAU * (float(index) + random.randf_range(-0.35, 0.35)) / count
		var radial := right * cos(angle) + up * sin(angle)
		var reach := INF
		for side in RIM_SIDES:
			var plane := outline[side]
			var projection := plane.normal.dot(radial)
			if projection > 0.001:
				reach = minf(reach, -plane.distance_to(point) / projection)
		var chip_size := radius * random.randf_range(0.10, 0.24)
		var center := point + radial * (reach - chip_size * random.randf_range(0.30, 0.62))
		var chip_planes: Array[Plane] = []
		var sides := random.randi_range(5, 7)
		var twist := random.randf_range(0.0, TAU)
		for side in sides:
			var side_angle := twist + TAU * float(side) / sides
			var outward := right * cos(side_angle) + up * sin(side_angle)
			chip_planes.append(Plane(outward, center + outward * chip_size * random.randf_range(0.78, 1.05)))
		chip_planes.append(outline[-2])
		chip_planes.append(outline[-1])
		_apply_contour(center, chip_size * 1.35 + depth, chip_planes)

func _impact_planes(point: Vector3, normal: Vector3, right: Vector3, up: Vector3,
		radius: float, depth: float, random: RandomNumberGenerator) -> Array[Plane]:
	var rotation := random.randf_range(0.0, TAU)
	var lobe_phase := random.randf_range(0.0, TAU)
	var edge_phase := random.randf_range(0.0, TAU)
	var stretch := random.randf_range(0.12, 0.155)
	var lobe := random.randf_range(0.035, 0.05)
	var edge := random.randf_range(0.004, 0.008)
	var planes: Array[Plane] = []
	for index in RIM_SIDES:
		var angle := TAU * float(index) / RIM_SIDES
		var outward := right * cos(angle + rotation) + up * sin(angle + rotation)
		# Vary the tangent offsets using low harmonics. Their combined
		# curvature stays positive, so the contour has no sharp notches.
		var outline := 1.0 + stretch * cos(2.0 * angle) \
			+ lobe * cos(3.0 * angle + lobe_phase) + edge * cos(4.0 * angle + edge_phase)
		planes.append(Plane(outward, point + outward * radius * outline))
	planes.append(Plane(normal, point + normal * 0.14 * _world_scale))
	planes.append(Plane(-normal, point - normal * depth))
	return planes

func _cut_surface(surface: Surface, bounds: AABB, planes: Array[Plane], rim: Surface = null) -> bool:
	var kept := Surface.new()
	var cut := false
	for index in range(0, surface.vertices.size(), 3):
		var a := surface.vertices[index]
		var b := surface.vertices[index + 1]
		var c := surface.vertices[index + 2]
		var triangle_bounds := AABB(a, Vector3.ZERO).expand(b).expand(c).grow(CLIP_EPSILON)
		if triangle_bounds.intersects(bounds):
			var original := PackedVector3Array([a, b, c])
			var inside := original
			var outside: Array[PackedVector3Array] = []
			for plane in planes:
				var clipped := _split_polygon(inside, plane)
				inside = clipped[0]
				if inside.size() < 3:
					break
				if clipped[1].size() >= 3:
					outside.append(clipped[1])
			if inside.size() >= 3 and _polygon_area_squared(inside) > 0.000001:
				cut = true
				var face_normal := surface.normals[index]
				for polygon in outside:
					_append_polygon(kept, polygon, face_normal)
				if rim != null:
					_append_reveals(rim, inside, face_normal, planes)
				continue
		for corner in range(index, index + 3):
			kept.vertices.append(surface.vertices[corner])
			kept.normals.append(surface.normals[corner])
	if cut:
		surface.vertices = kept.vertices
		surface.normals = kept.normals
	return cut

func _split_polygon(polygon: PackedVector3Array, plane: Plane) -> Array[PackedVector3Array]:
	var inside := PackedVector3Array()
	var outside := PackedVector3Array()
	for index in polygon.size():
		var a := polygon[index]
		var b := polygon[(index + 1) % polygon.size()]
		var da := plane.distance_to(a)
		var db := plane.distance_to(b)
		if da <= CLIP_EPSILON:
			inside.append(a)
		else:
			outside.append(a)
		if (da > CLIP_EPSILON) != (db > CLIP_EPSILON):
			var edge := a.lerp(b, clampf(da / (da - db), 0.0, 1.0))
			inside.append(edge)
			outside.append(edge)
	return [inside, outside]

func _polygon_area_squared(polygon: PackedVector3Array) -> float:
	var normal := Vector3.ZERO
	for index in range(1, polygon.size() - 1):
		normal += (polygon[index] - polygon[0]).cross(polygon[index + 1] - polygon[0])
	return normal.length_squared()

func _append_polygon(surface: Surface, polygon: PackedVector3Array, normal: Vector3) -> void:
	for index in range(1, polygon.size() - 1):
		var a := polygon[0]
		var b := polygon[index]
		var c := polygon[index + 1]
		if (b - a).cross(c - a).length_squared() < 0.00000001:
			continue
		surface.vertices.append_array(PackedVector3Array([a, b, c]))
		surface.normals.append_array(PackedVector3Array([normal, normal, normal]))

func _append_reveals(rim: Surface, polygon: PackedVector3Array, face_normal: Vector3, planes: Array[Plane]) -> void:
	var depth := SOLID_SHELL_DEPTH_M * _world_scale
	if _hollow_depth > 0.0 and absf(face_normal.y) <= 0.55:
		depth = _hollow_depth * 0.5
	var back := -face_normal * depth
	for index in polygon.size():
		var a := polygon[index]
		var b := polygon[(index + 1) % polygon.size()]
		for side in range(planes.size() - 2):
			var plane := planes[side]
			if absf(plane.distance_to(a)) < 0.001 and absf(plane.distance_to(b)) < 0.001:
				_append_polygon(rim, PackedVector3Array([a, b, b + back, a + back]), -plane.normal)
				break

func _commit_mesh() -> void:
	var mesh := ArrayMesh.new()
	for surface in _surfaces:
		if surface.fixed:
			_add_arrays(mesh, surface.original, surface.material)
		else:
			_add_surface(mesh, surface)
	_add_surface(mesh, _rim)
	for index in _building.mesh.get_surface_count():
		_building.set_surface_override_material(index, null)
	_building.material_override = null
	_building.mesh = mesh
	var shape := mesh.create_trimesh_shape() if mesh.get_surface_count() > 0 else null
	if shape != null:
		shape.backface_collision = true
	_collision.shape = shape

func _add_surface(mesh: ArrayMesh, surface: Surface) -> void:
	if surface.vertices.is_empty():
		return
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = surface.vertices
	arrays[Mesh.ARRAY_NORMAL] = surface.normals
	_add_arrays(mesh, arrays, surface.material)

func _add_arrays(mesh: ArrayMesh, arrays: Array, material: Material) -> void:
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	mesh.surface_set_material(mesh.get_surface_count() - 1, material)

func _masonry_material() -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.resource_name = "Exposed masonry"
	material.albedo_color = Color(0.45, 0.38, 0.32)
	material.roughness = 0.94
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	return material

func _remove_glass(planes: Array[Plane]) -> void:
	var ancestor := _building.get_parent()
	while ancestor != null:
		var glazing := ancestor.get_node_or_null("BreakableWindows")
		if glazing != null:
			var source_id: Variant = _building.get_meta("source_id", "")
			for child in glazing.get_children():
				var pane := child as BreakableWindow
				if pane == null or pane.get_meta("source_id", "") != source_id:
					continue
				var center := _building.to_local(pane.global_position)
				if planes.all(func(plane: Plane) -> bool: return plane.distance_to(center) <= 0.0):
					pane.shatter()
			return
		ancestor = ancestor.get_parent()

func _spawn_debris(point: Vector3, normal: Vector3, local_right: Vector3, local_up: Vector3,
		radius: float, random: RandomNumberGenerator) -> void:
	_live_fragments = _live_fragments.filter(is_instance_valid)
	var right := (_building.global_basis * local_right).normalized()
	var up := (_building.global_basis * local_up).normalized()
	var mesh := PrismMesh.new()
	mesh.material = _rim.material
	for index in FRAGMENT_COUNT:
		if _live_fragments.size() >= MAX_LIVE_FRAGMENTS:
			_live_fragments.pop_front().queue_free()
		var angle := TAU * (float(index) + random.randf()) / FRAGMENT_COUNT
		var outward := right * cos(angle) + up * sin(angle)
		var scale_factor := clampf(_world_scale, 1.0, 2.0)
		var size := Vector3(random.randf_range(0.19, 0.41), random.randf_range(0.13, 0.30),
			random.randf_range(0.12, 0.29)) * scale_factor
		var chunk := RigidBody3D.new()
		chunk.name = "BuildingFragment"
		chunk.top_level = true
		chunk.collision_layer = 0
		chunk.collision_mask = 1
		chunk.angular_damp = 1.4
		var visual := MeshInstance3D.new()
		visual.mesh = mesh
		visual.scale = size
		chunk.add_child(visual)
		var shape := BoxShape3D.new()
		shape.size = size
		var collider := CollisionShape3D.new()
		collider.shape = shape
		chunk.add_child(collider)
		add_child(chunk, true)
		chunk.global_position = point + normal * 0.5 + outward * radius * random.randf_range(0.35, 0.75)
		chunk.linear_velocity = normal * random.randf_range(10.0, 18.0) + outward * random.randf_range(8.0, 16.0)
		chunk.angular_velocity = Vector3(random.randf_range(-6.0, 6.0), random.randf_range(-6.0, 6.0),
			random.randf_range(-6.0, 6.0))
		_live_fragments.append(chunk)
		get_tree().create_timer(2.2).timeout.connect(chunk.queue_free)

func _emit_masonry(point: Vector3, normal: Vector3) -> void:
	var axis := Vector3.RIGHT if absf(normal.z) > 0.99 else Vector3.FORWARD
	var right := normal.cross(axis).normalized()
	var chips := DEBRIS_BURST.instantiate() as CPUParticles3D
	add_child(chips, true)
	chips.global_transform = Transform3D(Basis(right, normal, right.cross(normal)), point + normal * 0.15)
	var dust := chips.get_node("Dust") as CPUParticles3D
	dust.finished.connect(chips.queue_free)
	chips.restart()
	dust.restart()
