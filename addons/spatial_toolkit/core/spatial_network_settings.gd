@tool
extends RefCounted
## Local editor proxy preferences. The address can contain credentials.

const PREFIX := "spatial_toolkit/network/"
const PROXY_URL := PREFIX + "http_proxy"
const MAP_EXPLORER := PREFIX + "use_proxy_for_map_explorer"
const OVERPASS := PREFIX + "use_proxy_for_overpass"
const TEXTURES := PREFIX + "use_proxy_for_textures"
const PROJECT_FIELD := PREFIX + "local_proxy_preferences"
const PROJECT_HINT := "Spatial Toolkit local proxy preferences"
const SETTINGS_PATH := "Set an HTTP proxy address in Project Settings → Spatial Toolkit → Network."
const METADATA_SECTION := "spatial_toolkit"
const MIGRATION_KEY := "network_proxy_migrated"

static var _settings: EditorSettings

static func register(settings: EditorSettings) -> void:
	_settings = settings
	if settings == null:
		return
	var defaults := {PROXY_URL: "", MAP_EXPLORER: false, OVERPASS: false, TEXTURES: false}
	for key: String in defaults:
		var value: Variant = defaults[key]
		if not settings.has_setting(key):
			settings.set_setting(key, value)
		settings.set_initial_value(key, value, false)
	settings.add_property_info({
		"name": PROXY_URL,
		"type": TYPE_STRING,
		"hint": PROPERTY_HINT_PLACEHOLDER_TEXT,
		"hint_string": "http://user:password@host:port",
	})
	if Engine.is_editor_hint():
		_register_project_section()
		_migrate_overpass(settings)

static func editor_settings() -> EditorSettings:
	return _settings

## null selects direct transport. An empty string means an enabled proxy without an address.
static func proxy_for(key: String) -> Variant:
	if _settings == null or not bool(_settings.get_setting(key)):
		return null
	return str(_settings.get_setting(PROXY_URL)).strip_edges()

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
	if bool(settings.get_project_metadata(METADATA_SECTION, MIGRATION_KEY, false)):
		return
	var address := str(settings.get_project_metadata(METADATA_SECTION, "overpass_proxy", "")).strip_edges()
	var legacy_enabled: Variant = settings.get_project_metadata(METADATA_SECTION, "overpass_proxy_enabled", -1)
	if address.is_empty() and not legacy_enabled is bool:
		return
	if str(settings.get_setting(PROXY_URL)).strip_edges().is_empty() and not (
			proxy_for(MAP_EXPLORER) != null or proxy_for(OVERPASS) != null or proxy_for(TEXTURES) != null):
		settings.set_setting(PROXY_URL, address)
		settings.set_setting(OVERPASS, legacy_enabled if legacy_enabled is bool else not address.is_empty())
	settings.set_project_metadata(METADATA_SECTION, MIGRATION_KEY, true)
