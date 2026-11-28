@tool
extends RefCounted
## Keeps generated map paint at the level of the flat ground collider.

const Layers := preload("res://addons/spatial_toolkit/core/spatial_layers.gd")
const SOURCE_Y := -0.03 # Also used by the Python mesh generator and road data.
const FLAT := preload("res://addons/spatial_toolkit/materials/flat_map_surface.gdshader")
const TEXTURED := preload("res://addons/spatial_toolkit/materials/textured_road.gdshader")
const OVERLAYS := ["Landuse", "Water", "Roads", "Paths", "PlannedRoads"]
const LEGACY_HEIGHTS := {-116: 0.01, -114: 0.01, -112: 0.01, -110: 0.025,
	-100: 0.04, -90: 0.08, -85: 0.10, -80: 0.13}
const FLAT_AABB_TOLERANCE := 0.00002 # ArrayMesh pads a flat axis by 0.00001 m.

static func ground_height(map: Node3D) -> float:
	var ground := map.get_node_or_null("FlatGround") as MeshInstance3D
	if ground == null or not ground.mesh is PlaneMesh:
		return NAN
	var bounds := ground.transform * ground.get_aabb()
	return bounds.end.y if is_zero_approx(bounds.size.y) else NAN

static func legacy_offset(mesh: MeshInstance3D, relative: Transform3D, ground_y: float, scale_m: float) -> float:
	if not is_finite(ground_y) or mesh.mesh == null or mesh.mesh.get_surface_count() != 1 or mesh.get_child_count() != 0:
		return 0.0
	var material := mesh.get_active_material(0) as ShaderMaterial
	if material == null or material.shader not in [FLAT, TEXTURED] or not LEGACY_HEIGHTS.has(material.render_priority):
		return 0.0
	var bounds := relative * mesh.get_aabb()
	var old_y := float(LEGACY_HEIGHTS[material.render_priority]) * scale_m
	# Leave terrain, moved surfaces and any authored vertical geometry alone.
	if bounds.size.y <= FLAT_AABB_TOLERANCE and is_equal_approx(bounds.position.y, old_y):
		return ground_y - bounds.position.y
	return 0.0

static func align_for_play(map: Node3D) -> void:
	var ground_y := ground_height(map)
	if not is_finite(ground_y):
		return
	var inverse := map.global_transform.affine_inverse()
	var scale_m := float(map.get_meta("world_scale", 1.0))
	var baked := map.get_node_or_null("BakedChunks")
	if map.has_meta("scene_bake") and baked != null:
		for chunk: Node in baked.get_children():
			for child: Node in chunk.get_children():
				if child is MeshInstance3D and child.get_meta("generated_by", "") == "spatial_toolkit.scene_bake.v1":
					_align_node(child, map, inverse, ground_y, scale_m)
	else:
		for kind: String in OVERLAYS:
			for mesh: MeshInstance3D in Layers.meshes(map.get_node_or_null("Generated/" + kind)):
				if mesh.has_meta("source_id"):
					_align_node(mesh, map, inverse, ground_y, scale_m)

static func _align_node(mesh: MeshInstance3D, map: Node3D, inverse: Transform3D,
		ground_y: float, scale_m: float) -> void:
	var offset := legacy_offset(mesh, inverse * mesh.global_transform, ground_y, scale_m)
	if not is_zero_approx(offset):
		mesh.global_position += map.global_basis.y * offset
