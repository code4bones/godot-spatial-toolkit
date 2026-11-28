@tool
extends RefCounted
## Geometry shared by the patrol drawing tool and its corner handles.

const MANAGER_SCRIPT := "res://addons/spatial_toolkit/runtime/patrol_manager.gd"
const ZONE_SCRIPT := "res://addons/spatial_toolkit/runtime/patrol_zone_3d.gd"

static func is_manager(node: Object) -> bool:
	return node is Node3D and node.get_script() != null and node.get_script().resource_path == MANAGER_SCRIPT

static func is_zone(node: Object) -> bool:
	return node is Node3D and node.get_script() != null and node.get_script().resource_path == ZONE_SCRIPT

static func top_view(camera: Camera3D, frame: Node3D) -> bool:
	if camera == null or frame == null or camera.projection != Camera3D.PROJECTION_ORTHOGONAL:
		return false
	var down := -camera.global_basis.z.normalized()
	var up := frame.global_basis.y.normalized()
	return down.dot(up) < -0.9999

static func plane_point(camera: Camera3D, screen: Vector2, frame: Node3D) -> Variant:
	var normal := frame.global_basis.y.normalized()
	var plane := Plane(normal, frame.global_position)
	var hit := plane.intersects_ray(camera.project_ray_origin(screen), camera.project_ray_normal(screen))
	return frame.to_local(hit) if hit is Vector3 else null

static func corners(size_xz: Vector2) -> PackedVector3Array:
	var half := size_xz * 0.5
	return PackedVector3Array([Vector3(-half.x, 0, -half.y), Vector3(half.x, 0, -half.y),
		Vector3(half.x, 0, half.y), Vector3(-half.x, 0, half.y)])

static func set_bounds(zone: Node3D, center: Vector3, size_xz: Vector2) -> void:
	zone.position = center
	zone.set("size_xz", size_xz)
	zone.update_gizmos()
