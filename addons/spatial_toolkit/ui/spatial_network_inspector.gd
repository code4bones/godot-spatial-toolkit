@tool
extends EditorInspectorPlugin

const Network := preload("res://addons/spatial_toolkit/core/spatial_network_settings.gd")
const Localization := preload("res://addons/spatial_toolkit/ui/editor_localization.gd")

class Preferences extends VBoxContainer:
	var _address: LineEdit
	var _switches: Dictionary[String, CheckBox] = {}

	func _ready() -> void:
		set_translation_domain(Localization.DOMAIN)
		var row := HBoxContainer.new()
		add_child(row)
		var label := Label.new()
		label.text = atr("HTTP Proxy")
		row.add_child(label)
		_address = LineEdit.new()
		_address.name = "SpatialHttpProxyAddress"
		_address.placeholder_text = "http://user:password@host:port"
		_address.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(_address)
		_address.text_submitted.connect(func(_text: String) -> void: _save_address())
		_address.focus_exited.connect(_save_address)
		var labels := {
			Network.MAP_EXPLORER: atr("Use Proxy for Map Explorer"),
			Network.OVERPASS: atr("Use Proxy for Overpass"),
			Network.TEXTURES: atr("Use Proxy for Textures"),
		}
		for key: String in labels:
			var toggle := CheckBox.new()
			toggle.text = labels[key]
			toggle.toggled.connect(_save_switch.bind(key))
			_switches[key] = toggle
			add_child(toggle)
		Network.changes().changed.connect(_sync)
		_sync()

	func _save_address() -> void:
		var value := _address.text.strip_edges()
		_address.text = value
		Network.set_preference(Network.PROXY_URL, value)

	func _save_switch(enabled: bool, key: String) -> void:
		Network.set_preference(key, enabled)

	func _sync() -> void:
		if not _address.has_focus():
			_address.text = str(Network.preference(Network.PROXY_URL))
		for key in _switches:
			_switches[key].set_pressed_no_signal(bool(Network.preference(key)))

func _can_handle(_object: Object) -> bool:
	return Network.is_available()

func _parse_property(_object: Object, type: Variant.Type, property: String, hint: PropertyHint,
		hint_text: String, _usage: int, _wide: bool) -> bool:
	if property.get_file() != Network.PROJECT_FIELD.get_file() or type != TYPE_STRING \
			or hint != PROPERTY_HINT_PLACEHOLDER_TEXT or hint_text != Network.PROJECT_HINT:
		return false
	var preferences := Preferences.new()
	preferences.name = "SpatialNetworkPreferences"
	add_custom_control(preferences)
	return true
