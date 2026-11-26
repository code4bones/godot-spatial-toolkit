@tool
class_name SpatialDrone
extends CharacterBody3D
## Inspector configuration for the Spatial Toolkit flight rig.

const Localization := preload("res://addons/spatial_toolkit/ui/editor_localization.gd")
const DEFAULT_CONTROLLER := "signed_wheel_drone"
const CONTROLLERS := {
	DEFAULT_CONTROLLER: preload("res://addons/spatial_toolkit/runtime/drone_camera.gd"),
	"viewport_bank": preload("res://addons/spatial_toolkit/runtime/viewport_bank_camera.gd"),
	"reticle_flight": preload("res://addons/spatial_toolkit/runtime/reticle_flight_camera.gd"),
}
const CONTROLLER_IDS: Array[String] = [DEFAULT_CONTROLLER, "viewport_bank", "reticle_flight"]
const CAMERA_PATH := ^"CameraPivot/CameraBoom/FlyCamera"

@export_group("Drone Controls")
@export_enum("Classic:0", "Bank and Edge Tracking:1", "Reticle Flight:2") var flight_controller := 0:
	get:
		var camera := get_node_or_null(CAMERA_PATH) as Camera3D
		if camera != null:
			var controller: Variant = CONTROLLERS.find_key(camera.get_script())
			if controller != null:
				return CONTROLLER_IDS.find(controller)
		return flight_controller
	set(value):
		if value < 0 or value >= CONTROLLER_IDS.size():
			return
		if not Engine.is_editor_hint() and is_inside_tree() and is_node_ready():
			return
		flight_controller = value
		var controller := CONTROLLER_IDS[value]
		set_meta("flight_controller", controller)
		_apply_controller(controller)
## Reverse the direction of W/S pitch input for this drone.
@export var invert_ws := false
@export_group("")

@export_storage var _inactive_camera_parameters: Dictionary = {}

func _validate_property(property: Dictionary) -> void:
	Localization.localize_inspector_group(property)
	if Engine.is_editor_hint() and property.name == &"flight_controller":
		property.hint_string = "%s:0,%s:1,%s:2" % [
			Localization.translate(&"Classic"), Localization.translate(&"Bank and Edge Tracking"),
			Localization.translate(&"Reticle Flight"),
		]

func is_pitch_input_inverted() -> bool:
	return invert_ws

func _apply_controller(controller: String) -> void:
	var camera := get_node_or_null(CAMERA_PATH) as Camera3D
	if camera == null:
		return
	var previous := camera.get_script() as Script
	var selected: Script = CONTROLLERS[controller]
	if previous == selected or previous not in CONTROLLERS.values():
		return
	var parameters := _inactive_camera_parameters.duplicate()
	for key: StringName in _camera_exports(previous):
		parameters[key] = camera.get(key)
	if is_equal_approx(float(camera.get(&"vertical_screen_offset")), float(camera.call(&"default_vertical_screen_offset"))):
		parameters.erase(&"vertical_screen_offset")
	camera.set_script(selected)
	for key: StringName in _camera_exports(selected):
		if parameters.has(key):
			camera.set(key, parameters[key])
			parameters.erase(key)
	_inactive_camera_parameters = parameters

static func _camera_exports(script: Script) -> Array[StringName]:
	var keys: Array[StringName] = []
	while script != null:
		for property in script.get_script_property_list():
			var usage: int = property["usage"]
			var key: StringName = property["name"]
			if (usage & PROPERTY_USAGE_EDITOR) != 0 and (usage & PROPERTY_USAGE_STORAGE) != 0 and not keys.has(key):
				keys.append(key)
		script = script.get_base_script()
	return keys
