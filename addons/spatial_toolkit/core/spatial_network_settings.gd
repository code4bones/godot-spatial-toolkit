@tool
extends RefCounted
## Project-local editor proxy preferences. The address can contain credentials.

const PREFIX := "spatial_toolkit/network/"
const PROXY_URL := "http_proxy"
const MAP_EXPLORER := "use_proxy_for_map_explorer"
const OVERPASS := "use_proxy_for_overpass"
const TEXTURES := "use_proxy_for_textures"
const PROJECT_FIELD := PREFIX + "local_proxy_preferences"
const PROJECT_HINT := "Spatial Toolkit local proxy preferences"
const SETTINGS_PATH := "Set an HTTP proxy address in Project Settings → Spatial Toolkit → Network."
const METADATA_SECTION := "spatial_toolkit"
const PREFERENCES_KEY := "network_proxy_preferences"

class Changes extends RefCounted:
	signal changed

static var _settings: EditorSettings
static var _changes: Changes

static func register(settings: EditorSettings) -> void:
	_settings = settings
	if settings == null:
		_changes = null
		return
	if Engine.is_editor_hint():
		_register_project_section()
		_migrate_overpass(settings)

static func is_available() -> bool:
	return _settings != null

static func changes() -> Changes:
	if _changes == null:
		_changes = Changes.new()
	return _changes

static func preference(key: String) -> Variant:
	return _preferences().get(key, "" if key == PROXY_URL else false)

static func set_preference(key: String, value: Variant) -> void:
	if _settings == null or preference(key) == value:
		return
	var preferences := _preferences().duplicate()
	preferences[key] = value
	_settings.set_project_metadata(METADATA_SECTION, PREFERENCES_KEY, preferences)
	changes().changed.emit()

## null selects direct transport. An empty string means an enabled proxy without an address.
static func proxy_for(key: String) -> Variant:
	if not bool(preference(key)):
		return null
	return str(preference(PROXY_URL)).strip_edges()

static func _preferences() -> Dictionary:
	if _settings == null:
		return {}
	var value: Variant = _settings.get_project_metadata(METADATA_SECTION, PREFERENCES_KEY, {})
	return value if value is Dictionary else {}

static func _register_project_section() -> void:
	# A default-valued marker exposes the form without storing editor preferences in the project.
	if not ProjectSettings.has_setting(PROJECT_FIELD):
		ProjectSettings.set_setting(PROJECT_FIELD, "")
	ProjectSettings.set_initial_value(PROJECT_FIELD, "")
	ProjectSettings.add_property_info({
		"name": PROJECT_FIELD,
		"type": TYPE_STRING,
		"hint": PROPERTY_HINT_PLACEHOLDER_TEXT,
		"hint_string": PROJECT_HINT,
	})
	ProjectSettings.set_as_basic(PROJECT_FIELD, true)

static func _migrate_overpass(settings: EditorSettings) -> void:
	if settings.get_project_metadata(METADATA_SECTION, PREFERENCES_KEY, false) is Dictionary:
		return
	var address := str(settings.get_project_metadata(METADATA_SECTION, "overpass_proxy", "")).strip_edges()
	var legacy_enabled: Variant = settings.get_project_metadata(METADATA_SECTION, "overpass_proxy_enabled", -1)
	var preferences := {}
	if not address.is_empty() or legacy_enabled is bool:
		preferences[PROXY_URL] = address
		preferences[OVERPASS] = legacy_enabled if legacy_enabled is bool else not address.is_empty()
	settings.set_project_metadata(METADATA_SECTION, PREFERENCES_KEY, preferences)
