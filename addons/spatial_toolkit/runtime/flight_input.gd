extends RefCounted
## Default flight actions for projects that use the addon without its sample project settings.

enum Binding { KEY, PHYSICAL_KEY, MOUSE_BUTTON, JOY_BUTTON, JOY_AXIS }

const DEFAULT_BINDINGS := {
	&"flight_move_left": [[Binding.PHYSICAL_KEY, KEY_A], [Binding.JOY_AXIS, JOY_AXIS_LEFT_X, -1.0]],
	&"flight_move_right": [[Binding.PHYSICAL_KEY, KEY_D], [Binding.JOY_AXIS, JOY_AXIS_LEFT_X, 1.0]],
	&"flight_move_forward": [[Binding.PHYSICAL_KEY, KEY_W], [Binding.JOY_AXIS, JOY_AXIS_LEFT_Y, -1.0]],
	&"flight_move_backward": [[Binding.PHYSICAL_KEY, KEY_S], [Binding.JOY_AXIS, JOY_AXIS_LEFT_Y, 1.0]],
	&"flight_look_left": [[Binding.JOY_AXIS, JOY_AXIS_RIGHT_X, -1.0]],
	&"flight_look_right": [[Binding.JOY_AXIS, JOY_AXIS_RIGHT_X, 1.0]],
	&"flight_look_up": [[Binding.JOY_AXIS, JOY_AXIS_RIGHT_Y, -1.0]],
	&"flight_look_down": [[Binding.JOY_AXIS, JOY_AXIS_RIGHT_Y, 1.0]],
	&"flight_lift_up": [[Binding.PHYSICAL_KEY, KEY_E]],
	&"flight_lift_down": [[Binding.PHYSICAL_KEY, KEY_Q]],
	&"flight_bank_lift_up": [[Binding.JOY_BUTTON, JOY_BUTTON_DPAD_UP]],
	&"flight_bank_lift_down": [[Binding.JOY_BUTTON, JOY_BUTTON_DPAD_DOWN]],
	&"flight_speed_step_up": [[Binding.MOUSE_BUTTON, MOUSE_BUTTON_WHEEL_UP]],
	&"flight_speed_step_down": [[Binding.MOUSE_BUTTON, MOUSE_BUTTON_WHEEL_DOWN]],
	&"flight_cruise_increase": [[Binding.JOY_BUTTON, JOY_BUTTON_RIGHT_SHOULDER]],
	&"flight_cruise_decrease": [[Binding.JOY_BUTTON, JOY_BUTTON_LEFT_SHOULDER]],
	&"flight_gamepad_accelerate": [[Binding.JOY_BUTTON, JOY_BUTTON_LEFT_STICK]],
	&"flight_gamepad_brake": [[Binding.JOY_BUTTON, JOY_BUTTON_B]],
	&"flight_gamepad_orbit": [[Binding.JOY_BUTTON, JOY_BUTTON_LEFT_SHOULDER]],
	&"flight_primary_click": [[Binding.MOUSE_BUTTON, MOUSE_BUTTON_LEFT]],
	&"flight_click_modifier": [[Binding.PHYSICAL_KEY, KEY_SPACE]],
	&"flight_fire": [[Binding.JOY_AXIS, JOY_AXIS_TRIGGER_RIGHT, 1.0]],
	&"flight_target_confirm": [[Binding.JOY_BUTTON, JOY_BUTTON_RIGHT_SHOULDER]],
	&"flight_target_left": [[Binding.JOY_BUTTON, JOY_BUTTON_DPAD_LEFT]],
	&"flight_target_right": [[Binding.JOY_BUTTON, JOY_BUTTON_DPAD_RIGHT]],
	&"flight_gamepad_select_target": [[Binding.JOY_BUTTON, JOY_BUTTON_A]],
	&"flight_gamepad_destination": [[Binding.JOY_BUTTON, JOY_BUTTON_Y]],
	&"flight_destination": [[Binding.JOY_BUTTON, JOY_BUTTON_A]],
	&"flight_free_aim": [[Binding.JOY_AXIS, JOY_AXIS_TRIGGER_LEFT, 1.0]],
	&"flight_free_look": [[Binding.MOUSE_BUTTON, MOUSE_BUTTON_RIGHT]],
	&"flight_stop": [[Binding.JOY_BUTTON, JOY_BUTTON_B]],
	&"flight_toggle_controls": [[Binding.JOY_BUTTON, JOY_BUTTON_START]],
	&"flight_release_controls": [[Binding.KEY, KEY_ESCAPE]],
	&"flight_toggle_view": [[Binding.KEY, KEY_V], [Binding.JOY_BUTTON, JOY_BUTTON_Y]],
	&"flight_toggle_overview": [[Binding.KEY, KEY_TAB], [Binding.JOY_BUTTON, JOY_BUTTON_BACK]],
	&"flight_center_aim": [[Binding.JOY_BUTTON, JOY_BUTTON_RIGHT_STICK]],
	&"flight_free_ascend": [[Binding.PHYSICAL_KEY, KEY_SPACE]],
	&"flight_free_descend": [[Binding.PHYSICAL_KEY, KEY_CTRL]],
	&"flight_boost": [[Binding.PHYSICAL_KEY, KEY_SHIFT]],
	&"map_pan_left": [[Binding.PHYSICAL_KEY, KEY_A]],
	&"map_pan_right": [[Binding.PHYSICAL_KEY, KEY_D]],
	&"map_pan_forward": [[Binding.PHYSICAL_KEY, KEY_W]],
	&"map_pan_backward": [[Binding.PHYSICAL_KEY, KEY_S]],
	&"map_zoom_in": [[Binding.MOUSE_BUTTON, MOUSE_BUTTON_WHEEL_UP]],
	&"map_zoom_out": [[Binding.MOUSE_BUTTON, MOUSE_BUTTON_WHEEL_DOWN]],
	&"map_pan_drag": [[Binding.MOUSE_BUTTON, MOUSE_BUTTON_MIDDLE]],
	&"map_orbit_drag": [[Binding.MOUSE_BUTTON, MOUSE_BUTTON_RIGHT]],
	&"map_frame_map": [[Binding.KEY, KEY_HOME]],
	&"map_frame_buildings": [[Binding.KEY, KEY_F]],
	&"map_toggle_legend": [[Binding.KEY, KEY_H]],
	&"map_waypoint": [[Binding.MOUSE_BUTTON, MOUSE_BUTTON_LEFT]],
}

static func ensure_actions() -> void:
	for action: StringName in DEFAULT_BINDINGS:
		_register_action(action, DEFAULT_BINDINGS[action])
	_replace_old_default(&"flight_gamepad_accelerate", [Binding.JOY_BUTTON, JOY_BUTTON_Y], 0.2)
	_replace_old_default(&"flight_free_aim", [Binding.JOY_BUTTON, JOY_BUTTON_Y], 0.55)
	for slot in range(1, 10):
		_register_action(patrol_camera_action(slot), [[Binding.KEY, KEY_0 + slot], [Binding.KEY, KEY_KP_1 + slot - 1]])

static func _replace_old_default(action: StringName, old_binding: Array, deadzone: float) -> void:
	var events := InputMap.action_get_events(action)
	if events.size() != 1 or events[0].device != -1 or not is_equal_approx(InputMap.action_get_deadzone(action), deadzone):
		return
	if not events[0].is_match(_create_event(old_binding), true):
		return
	InputMap.action_erase_event(action, events[0])
	InputMap.action_add_event(action, _create_event(DEFAULT_BINDINGS[action][0]))


static func patrol_camera_action(slot: int) -> StringName:
	return StringName("flight_patrol_camera_%d" % slot)


static func _register_action(action: StringName, bindings: Array) -> void:
	if InputMap.has_action(action):
		return
	var deadzone := 0.2
	if action.begins_with("flight_move_") or action.begins_with("flight_look_"):
		deadzone = 0.18
	elif action == &"flight_fire" or action == &"flight_free_aim":
		deadzone = 0.55
	InputMap.add_action(action, deadzone)
	for binding: Array in bindings:
		InputMap.action_add_event(action, _create_event(binding))


static func _create_event(binding: Array) -> InputEvent:
	match binding[0]:
		Binding.KEY, Binding.PHYSICAL_KEY:
			var event := InputEventKey.new()
			event.device = -1
			if binding[0] == Binding.KEY:
				event.keycode = binding[1]
			else:
				event.physical_keycode = binding[1]
			return event
		Binding.MOUSE_BUTTON:
			var event := InputEventMouseButton.new()
			event.device = -1
			event.button_index = binding[1]
			return event
		Binding.JOY_BUTTON:
			var event := InputEventJoypadButton.new()
			event.device = -1
			event.button_index = binding[1]
			return event
		Binding.JOY_AXIS:
			var event := InputEventJoypadMotion.new()
			event.device = -1
			event.axis = binding[1]
			event.axis_value = binding[2]
			return event
	return null


static func keyboard_mouse_strength(action: StringName) -> float:
	if not InputMap.has_action(action):
		return 0.0
	for binding in InputMap.action_get_events(action):
		if binding is InputEventKey and _key_is_down(binding) and _modifiers_are_down(binding):
			return 1.0
		if binding is InputEventMouseButton and Input.is_mouse_button_pressed(binding.button_index) \
				and _modifiers_are_down(binding):
			return 1.0
	return 0.0


static func joy_strength(action: StringName, device: int) -> float:
	if device < 0 or not InputMap.has_action(action):
		return 0.0
	var strength := 0.0
	for binding in InputMap.action_get_events(action):
		if binding.device != -1 and binding.device != device:
			continue
		if binding is InputEventJoypadButton and Input.is_joy_button_pressed(device, binding.button_index):
			return 1.0
		if binding is InputEventJoypadMotion:
			strength = maxf(strength, Input.get_joy_axis(device, binding.axis) * signf(binding.axis_value))
	return strength


static func event_matches(event: InputEvent, action: StringName) -> bool:
	return InputMap.has_action(action) and InputMap.event_is_action(event, action, event is InputEventJoypadMotion)


static func event_pressed(event: InputEvent, action: StringName) -> bool:
	if not InputMap.has_action(action):
		return false
	if event is InputEventJoypadMotion:
		return Input.is_action_just_pressed_by_event(action, event, true)
	return event.is_action_pressed(action)


static func joy_event_is_bound(event: InputEvent, action: StringName) -> bool:
	if not InputMap.has_action(action):
		return false
	for binding in InputMap.action_get_events(action):
		if binding.device != -1 and binding.device != event.device:
			continue
		if event is InputEventJoypadMotion and binding is InputEventJoypadMotion and event.axis == binding.axis:
			return true
		if event is InputEventJoypadButton and binding is InputEventJoypadButton and event.button_index == binding.button_index:
			return true
	return false


static func mouse_drag(event: InputEventMouseMotion, action: StringName) -> bool:
	if not InputMap.has_action(action):
		return false
	for binding in InputMap.action_get_events(action):
		if binding is InputEventMouseButton and binding.button_index > 0 \
				and (event.button_mask & (1 << (binding.button_index - 1))) != 0 and _modifiers_are_down(binding):
			return true
	return keyboard_mouse_strength(action) > 0.0 or Input.is_action_pressed(action)


static func _key_is_down(binding: InputEventKey) -> bool:
	if binding.physical_keycode != KEY_NONE:
		return Input.is_physical_key_pressed(binding.physical_keycode)
	if binding.keycode != KEY_NONE:
		return Input.is_key_pressed(binding.keycode)
	return binding.key_label != KEY_NONE and Input.is_key_label_pressed(binding.key_label)


static func _modifiers_are_down(binding: InputEventWithModifiers) -> bool:
	if binding.command_or_control_autoremap:
		var command_key := KEY_META if OS.has_feature("macos") else KEY_CTRL
		if not Input.is_key_pressed(command_key):
			return false
	return ((not binding.alt_pressed or Input.is_key_pressed(KEY_ALT))
		and (not binding.shift_pressed or Input.is_key_pressed(KEY_SHIFT))
		and (not binding.ctrl_pressed or Input.is_key_pressed(KEY_CTRL))
		and (not binding.meta_pressed or Input.is_key_pressed(KEY_META)))
