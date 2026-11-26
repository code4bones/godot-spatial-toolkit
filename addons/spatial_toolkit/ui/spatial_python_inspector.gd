@tool
extends EditorInspectorPlugin

const Settings := preload("res://addons/spatial_toolkit/core/spatial_project_settings.gd")
const DependencyCheck := preload("res://addons/spatial_toolkit/ui/dependency_check.gd")

var _has_python_setting := false
var _check: DependencyCheck

func _can_handle(_object: Object) -> bool:
	return true

func _parse_begin(_object: Object) -> void:
	_has_python_setting = false

func _parse_property(_object: Object, type: Variant.Type, property: String, hint: PropertyHint,
		hint_text: String, _usage: int, _wide: bool) -> bool:
	# The settings inspector passes the property name relative to the selected section.
	if type == TYPE_STRING and property.get_file() == "executable" \
			and hint == PROPERTY_HINT_PLACEHOLDER_TEXT and hint_text == Settings.PYTHON_PLACEHOLDER:
		_has_python_setting = true
	return false

func _parse_end(_object: Object) -> void:
	if _has_python_setting:
		_check = DependencyCheck.new()
		add_custom_control(_check)

func clear_check() -> void:
	if is_instance_valid(_check):
		_check.queue_free()
