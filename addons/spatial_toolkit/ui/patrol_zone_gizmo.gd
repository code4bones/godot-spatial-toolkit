@tool
extends EditorNode3DGizmoPlugin

const Edit := preload("patrol_zone_edit.gd")
const Localization := preload("editor_localization.gd")
var undo: EditorUndoRedoManager
var _opposite := Vector3.ZERO
var _fill := PlaneMesh.new()

func _init() -> void:
	_fill.size = Vector2.ONE
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	material.no_depth_test = true
	material.render_priority = 20
	material.albedo_color = Color(1.0, 0.25, 0.65, 0.24)
	add_material("coverage_fill", material)
	create_material("footprint", Color(1.0, 0.25, 0.65), false, true)
	create_handle_material("corners")

func _get_gizmo_name() -> String:
	return Localization.translate("Patrol Zone")

func _has_gizmo(node: Node3D) -> bool:
	return Edit.is_zone(node)

func _redraw(gizmo: EditorNode3DGizmo) -> void:
	gizmo.clear()
	var zone := gizmo.get_node_3d()
	var size_xz: Vector2 = zone.get("size_xz")
	var points := Edit.corners(size_xz)
	if zone.get("enabled") and size_xz.is_finite() and size_xz.x > 0.0 and size_xz.y > 0.0:
		var basis := Basis.from_scale(Vector3(size_xz.x, 1.0, size_xz.y))
		gizmo.add_mesh(_fill, get_material("coverage_fill"), Transform3D(basis, Vector3.ZERO))
	var lines := PackedVector3Array()
	for index in 4:
		lines.append(points[index])
		lines.append(points[(index + 1) % 4])
	gizmo.add_lines(lines, get_material("footprint", gizmo))
	gizmo.add_collision_segments(lines)
	gizmo.add_handles(points, get_material("corners", gizmo), PackedInt32Array([0, 1, 2, 3]))

func _get_handle_name(_gizmo: EditorNode3DGizmo, _id: int, _secondary: bool) -> String:
	return Localization.translate("Patrol zone corner")

func _get_handle_value(gizmo: EditorNode3DGizmo, _id: int, _secondary: bool) -> Variant:
	var zone := gizmo.get_node_3d()
	return {"position": zone.position, "size_xz": zone.get("size_xz")}

func _begin_handle_action(gizmo: EditorNode3DGizmo, id: int, _secondary: bool) -> void:
	var zone := gizmo.get_node_3d()
	_opposite = zone.position + Edit.corners(zone.get("size_xz"))[(id + 2) % 4]

func _set_handle(gizmo: EditorNode3DGizmo, _id: int, _secondary: bool, camera: Camera3D, screen: Vector2) -> void:
	var zone := gizmo.get_node_3d()
	var manager := zone.get_parent() as Node3D
	if not Edit.top_view(camera, manager):
		return
	var hit: Variant = Edit.plane_point(camera, screen, manager)
	if not hit is Vector3:
		return
	var opposite := _opposite
	var minimum := Vector2(minf(hit.x, opposite.x), minf(hit.z, opposite.z))
	var maximum := Vector2(maxf(hit.x, opposite.x), maxf(hit.z, opposite.z))
	var extent := maximum - minimum
	if extent.x < 1.0 or extent.y < 1.0:
		return
	Edit.set_bounds(zone, Vector3((minimum.x + maximum.x) * 0.5, zone.position.y,
		(minimum.y + maximum.y) * 0.5), extent)

func _commit_handle(gizmo: EditorNode3DGizmo, _id: int, _secondary: bool, restore: Variant, cancel: bool) -> void:
	var zone := gizmo.get_node_3d()
	if cancel:
		Edit.set_bounds(zone, restore["position"], restore["size_xz"])
		return
	undo.create_action(Localization.translate("Resize patrol zone"), UndoRedo.MERGE_DISABLE, zone)
	undo.add_do_method(Edit, "set_bounds", zone, zone.position, zone.get("size_xz"))
	undo.add_undo_method(Edit, "set_bounds", zone, restore["position"], restore["size_xz"])
	undo.commit_action()
