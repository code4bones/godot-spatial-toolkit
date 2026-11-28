@tool
class_name SpatialDrone
extends CharacterBody3D
## Inspector configuration for the Spatial Toolkit flight rig.

const Localization := preload("res://addons/spatial_toolkit/ui/editor_localization.gd")
const CLASSIC_CONTROLLER := "signed_wheel_drone"
const GAMEPAD_CONTROLLER := "gamepad_flight"
const DEFAULT_CONTROLLER := GAMEPAD_CONTROLLER
const CONTROLLERS := {
	CLASSIC_CONTROLLER: preload("res://addons/spatial_toolkit/runtime/drone_camera.gd"),
	"viewport_bank": preload("res://addons/spatial_toolkit/runtime/viewport_bank_camera.gd"),
	"reticle_flight": preload("res://addons/spatial_toolkit/runtime/reticle_flight_camera.gd"),
	GAMEPAD_CONTROLLER: preload("res://addons/spatial_toolkit/runtime/gamepad_flight_camera.gd"),
}
const CONTROLLER_IDS: Array[String] = [CLASSIC_CONTROLLER, "viewport_bank", "reticle_flight", GAMEPAD_CONTROLLER]
const CAMERA_PATH := ^"CameraPivot/CameraBoom/FlyCamera"

@export_group("Drone Controls")
@export_enum("Classic:0", "Bank and Edge Tracking:1", "Reticle Flight:2", "Gamepad Flight:3") var flight_controller := 0:
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
		if Engine.is_editor_hint():
			notify_property_list_changed()
## Reverse W/S pitch in Classic and Bank and Edge Tracking.
@export var invert_ws := false
## Reverse the vertical steering axis of the gamepad. The camera stores this setting.
@export var invert_gamepad_pitch := false:
	get:
		var camera := _gamepad_camera()
		return bool(camera.get(&"gamepad_invert_pitch")) if camera != null else false
	set(value):
		var camera := _gamepad_camera()
		if camera != null:
			camera.set(&"gamepad_invert_pitch", value)
@export_group("")

@export_storage var _inactive_camera_parameters: Dictionary = {}

func _validate_property(property: Dictionary) -> void:
	Localization.localize_inspector_group(property)
	if property.name == &"invert_ws" and CONTROLLER_IDS[flight_controller] in ["reticle_flight", GAMEPAD_CONTROLLER]:
		property.usage = int(property.usage) & ~PROPERTY_USAGE_EDITOR
	if property.name == &"invert_gamepad_pitch":
		property.usage = int(property.usage) & ~PROPERTY_USAGE_STORAGE
		if _gamepad_camera() == null:
			property.usage = int(property.usage) & ~PROPERTY_USAGE_EDITOR
	if Engine.is_editor_hint() and property.name == &"flight_controller":
		property.hint_string = "%s:0,%s:1,%s:2,%s:3" % [
			Localization.translate(&"Classic"), Localization.translate(&"Bank and Edge Tracking"),
			Localization.translate(&"Reticle Flight"), Localization.translate(&"Gamepad Flight"),
		]

func is_pitch_input_inverted() -> bool:
	return invert_ws

func _gamepad_camera() -> Camera3D:
	var camera := get_node_or_null(CAMERA_PATH) as Camera3D
	return camera if camera != null and CONTROLLERS.find_key(camera.get_script()) != null else null

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
	if camera.has_method(&"default_strafe_speed_mps") \
			and is_equal_approx(float(camera.get(&"strafe_speed_mps")), float(camera.call(&"default_strafe_speed_mps"))):
		parameters.erase(&"strafe_speed_mps")
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
