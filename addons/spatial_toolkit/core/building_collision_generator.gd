@tool
extends RefCounted
## Deterministic static building shells from the existing visual mesh triangles.
## Does not replace existing collision objects or modify imported mesh resources.

# Retained for saved Hovrino trial compatibility and repeat-pass identity.
const GENERATOR := "spatial_toolkit.building_collision_trial.v1"
const BODY_NAME := "BuildingCollision"
const SHAPE_KIND := "concave_triangle_surface"
const Layers := preload("res://addons/spatial_toolkit/core/spatial_layers.gd")

static func new_report(enabled: bool = true) -> Dictionary:
	return {"success": true, "enabled": enabled, "created": 0, "existing": 0,
		"triangles": 0, "skipped": [], "collision_layer": 1, "collision_mask": 1,
		"shape_kind": SHAPE_KIND}

static func append_result(report: Dictionary, result: Dictionary) -> void:
	for key: String in ["created", "existing", "triangles"]:
		report[key] = int(report.get(key, 0)) + int(result.get(key, 0))
	var skipped: Array = report["skipped"]
	skipped.append_array(result.get("skipped", []))

static func add_to_building(instance: MeshInstance3D, scene_root: Node) -> Dictionary:
	var report := new_report()
	var identity := str(instance.get_meta("source_id", instance.name))
	if not scene_root.is_ancestor_of(instance):
		return _skip(report, identity, "Building must be a descendant of its saved scene root")
	var previous := instance.get_node_or_null(BODY_NAME)
	if previous != null:
		if previous is StaticBody3D and previous.get_meta("generated_by", "") == GENERATOR:
			report["existing"] = 1
			var collider := previous.get_node_or_null("CollisionShape3D") as CollisionShape3D
			if collider != null and collider.shape is ConcavePolygonShape3D:
				report["triangles"] = collider.shape.get_faces().size() / 3
			return report
		return _skip(report, identity, "Reserved collision name already used; existing node preserved")
	if not instance.find_children("*", "CollisionObject3D", true, false).is_empty():
		return _skip(report, identity, "Existing collision object preserved")
	if instance.mesh == null or instance.mesh.get_surface_count() == 0:
		return _skip(report, identity, "Building has no mesh")
	var shape := instance.mesh.create_trimesh_shape()
	if shape == null or shape.get_faces().is_empty():
		return _skip(report, identity, "No collision triangles available")
	# Imported massings are surface shells. Both faces must block movement.
	shape.backface_collision = true
	var body := StaticBody3D.new()
	body.name = BODY_NAME
	body.collision_layer = 1
	body.collision_mask = 1
	body.set_meta("generated_by", GENERATOR)
	body.set_meta("shape_kind", SHAPE_KIND)
	_copy_provenance(instance, body, identity)
	instance.add_child(body)
	body.owner = scene_root
	var collider := CollisionShape3D.new()
	collider.name = "CollisionShape3D"
	collider.shape = shape
	_copy_provenance(instance, collider, identity)
	body.add_child(collider)
	collider.owner = scene_root
	report["created"] = 1
	report["triangles"] = shape.get_faces().size() / 3
	return report

static func apply_to_scene(scene_root: Node) -> Dictionary:
	var buildings := scene_root.get_node_or_null("Generated/Buildings")
	if buildings == null:
		return {"success": false, "error": "Generated/Buildings layer not found"}
	var report := new_report()
	for building in Layers.meshes(buildings):
		append_result(report, add_to_building(building, scene_root))
	return report

static func _copy_provenance(instance: MeshInstance3D, target: Node, identity: String) -> void:
	target.set_meta("source_id", identity)
	target.set_meta("units", "meters")
	for key: String in ["source", "source_tags", "assumptions"]:
		if instance.has_meta(key):
			target.set_meta(key, instance.get_meta(key))

static func _skip(report: Dictionary, identity: String, reason: String) -> Dictionary:
	report["skipped"].append({"id": identity, "reason": reason})
	return report
