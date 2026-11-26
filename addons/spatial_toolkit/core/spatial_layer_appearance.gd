@tool
class_name SpatialLayerAppearance
extends Resource
## Reusable material, tint and texture repeat settings.

@export var material: Material:
	set(value):
		material = value
		emit_changed()
@export var override_tint := false:
	set(value):
		override_tint = value
		emit_changed()
@export var tint := Color.WHITE:
	set(value):
		tint = value
		emit_changed()
## Texture repeat size in source metres. Zero uses the material's size.
@export_range(0.0, 100.0, 0.05, "or_greater", "suffix:m") var texture_repeat_m := 0.0:
	set(value):
		texture_repeat_m = value
		emit_changed()


func style_values() -> Dictionary:
	return appearance_values(material, override_tint, tint, texture_repeat_m)


static func appearance_values(selected: Material, use_tint: bool, tint_color: Color, repeat_m: float) -> Dictionary:
	var values := {}
	if selected != null:
		values["material"] = selected
	if use_tint:
		values["tint"] = tint_color
	if repeat_m > 0.0:
		values["texture_repeat_m"] = repeat_m
	return values
