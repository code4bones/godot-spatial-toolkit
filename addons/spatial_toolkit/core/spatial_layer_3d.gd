@tool
class_name SpatialLayer3D
extends Node3D
## Shared appearance of generated features and their subgroups.

const Appearance := preload("res://addons/spatial_toolkit/core/spatial_layer_appearance.gd")
const Localization := preload("res://addons/spatial_toolkit/ui/editor_localization.gd")

@export_storage var style_key := ""
@export_storage var style_kind := ""

@export_group("Group Appearance")
## Leave empty to inherit the material.
@export var material: Material:
	set(value):
		material = value
		request_style_update(&"material")
@export var override_tint := false:
	set(value):
		override_tint = value
		request_style_update(&"override_tint")
@export var tint := Color.WHITE:
	set(value):
		tint = value
		request_style_update(&"tint")
## Texture repeat size in source metres. Zero inherits.
@export_range(0.0, 100.0, 0.05, "or_greater", "suffix:m") var texture_repeat_m := 0.0:
	set(value):
		texture_repeat_m = value
		request_style_update(&"texture_repeat_m")


func _validate_property(property: Dictionary) -> void:
	Localization.localize_inspector_group(property)


func style_values() -> Dictionary:
	return Appearance.appearance_values(material, override_tint, tint, texture_repeat_m)


func request_style_update(field: StringName = &"") -> void:
	if not Engine.is_editor_hint() or not is_inside_tree():
		return
	var node: Node = self
	while node != null:
		if node.has_method("queue_layer_style_update"):
			if not field.is_empty() and node == get_tree().edited_scene_root and "attribute_bank" in node:
				var bank: Resource = node.get("attribute_bank")
				if bank != null:
					bank.set_layer_field(self, field)
			node.call("queue_layer_style_update")
			return
		node = node.get_parent()
