@tool
extends RefCounted
## Undoable changes to the active map scene.

const Ground := preload("res://addons/spatial_toolkit/core/ground_styles.gd")

static func commit(undo: EditorUndoRedoManager, map: Node3D, slot: int, material: Resource, color: Variant) -> int:
	if undo == null or (material != null and not Ground.supports_material(material)) or (color != null and not color is Color):
		return 0
	var meshes := Ground.targets(map, slot)
	if meshes.is_empty() or (material == Ground.override_material(map, slot) and color == Ground.override_color(map, slot)):
		return 0
	var previous: Variant = map.get_meta(Ground.RULES) if map.has_meta(Ground.RULES) else null
	var rules: Dictionary = previous.duplicate() if previous is Dictionary else {}
	if material == null and color == null:
		rules.erase(slot)
	else:
		rules[slot] = {"material": material, "color": color}
	var replacements := Ground.surface_overrides(meshes, slot, material, color, float(map.get_meta("world_scale", 1.0)))
	undo.create_action("Изменить оформление земли", UndoRedo.MERGE_DISABLE, map)
	undo.add_do_method(map, "set_meta", Ground.RULES, rules if not rules.is_empty() else null)
	undo.add_undo_method(map, "set_meta", Ground.RULES, previous)
	for mesh in meshes:
		undo.add_do_property(mesh, "material_override", replacements[mesh])
		undo.add_undo_property(mesh, "material_override", mesh.material_override)
	undo.commit_action()
	return meshes.size()
