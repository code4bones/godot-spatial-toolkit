@tool
extends RefCounted
## Project-wide defaults for Spatial generation and local Python workers.

const Overpass := preload("res://addons/spatial_toolkit/map/overpass_provider.gd")
const Drone := preload("res://addons/spatial_toolkit/runtime/spatial_drone.gd")
const FlightInput := preload("res://addons/spatial_toolkit/runtime/flight_input.gd")
const Localization := preload("res://addons/spatial_toolkit/ui/editor_localization.gd")
const PYTHON_EXECUTABLE := "spatial_toolkit/python/executable"
const PYTHON_PLACEHOLDER := "Python 3.10+ · Spatial Toolkit"
const DEFAULT_HEIGHT := "spatial_toolkit/generation/default_height_m"
const LEVEL_HEIGHT := "spatial_toolkit/generation/level_height_m"
const WORLD_SCALE := "spatial_toolkit/generation/world_scale"
const BUILDING_COLLISIONS := "spatial_toolkit/generation/building_collisions"
const DAYLIGHT := "spatial_toolkit/generation/daylight"
const BAKE_MERGE_COLLISIONS := "spatial_toolkit/bake/merge_collisions"
const FLIGHT_DEFAULT_CONTROLLER := "spatial_toolkit/flight/default_controller"
const FLIGHT_INVERT_WS := "spatial_toolkit/flight/invert_ws"
const FLIGHT_INVERT_GAMEPAD_PITCH := "spatial_toolkit/flight/invert_gamepad_pitch"
const OSM_BUILDINGS := "spatial_toolkit/osm_buildings/"
const OSM_ROADS := "spatial_toolkit/osm_roads/"
const OSM_HEIGHT_LIMITS := {"low_height_limit_m": 10.0, "medium_height_limit_m": 24.0, "high_height_limit_m": 55.0}
const OSM_AREA_LIMITS := {"small_area_limit_m2": 250.0, "medium_area_limit_m2": 900.0, "large_area_limit_m2": 2500.0}
const OSM_ROAD_WIDTHS := {"tertiary": 9.0, "residential": 6.0, "service": 4.0,
	"footway": 2.0, "steps": 2.0, "path": 2.0, "cycleway": 2.5}
const OSM_FALLBACK_ROAD_WIDTH_M := 4.0
const OSM_LANE_WIDTH_M := 3.2
const APERTURES := "spatial_toolkit/apertures/"
const OVERPASS := "spatial_toolkit/overpass/"
const APERTURE_DEFAULTS := {"width_m": 1.08, "height_m": 0.0, "sill_m": -1.0,
	"spacing_m": 2.7, "corner_clearance_m": 0.81}
const APERTURE_RANGES := {"width_m": "0.1,12,0.01,suffix:m", "height_m": "0,6,0.01,suffix:m",
	"sill_m": "-1,6,0.01,suffix:m", "spacing_m": "0.12,100,0.01,suffix:m",
	"corner_clearance_m": "0.01,50,0.01,suffix:m"}
const DEFAULT_HEIGHT_M := 3.0
const DEFAULT_LEVEL_HEIGHT_M := 3.0
const DEFAULT_WORLD_SCALE := 1.0
const METADATA_SECTION := "spatial_toolkit"
const MIGRATION_KEY := "generation_settings_migrated"
const OVERPASS_MIGRATION_KEY := "overpass_settings_migrated"

static var _migration_needs_save := false

## EditorSettings is available to the plugin, while exported maps also load this script.
static func register(editor_settings: Object) -> void:
	var definitions := {
		PYTHON_EXECUTABLE: {"default": _default_python(), "legacy": "python"},
		DEFAULT_HEIGHT: {"default": DEFAULT_HEIGHT_M, "legacy": "default_height", "range": "0.1,100,0.1,suffix:m"},
		LEVEL_HEIGHT: {"default": DEFAULT_LEVEL_HEIGHT_M, "legacy": "level_height", "range": "0.1,100,0.1,suffix:m"},
		WORLD_SCALE: {"default": DEFAULT_WORLD_SCALE, "legacy": "world_scale", "range": "1,100,1"},
		BUILDING_COLLISIONS: {"default": true, "legacy": "building_collisions"},
		DAYLIGHT: {"default": true, "legacy": "daylight"},
		BAKE_MERGE_COLLISIONS: {"default": true, "legacy": "bake_merge_collisions"},
		FLIGHT_DEFAULT_CONTROLLER: {"default": Drone.CONTROLLER_IDS.find(Drone.DEFAULT_CONTROLLER),
			"enum": "%s:0,%s:1,%s:2,%s:3" % [Localization.translate(&"Classic"),
				Localization.translate(&"Bank and Edge Tracking"), Localization.translate(&"Reticle Flight"),
				Localization.translate(&"Gamepad Flight")]},
		FLIGHT_INVERT_WS: {"default": false},
		FLIGHT_INVERT_GAMEPAD_PITCH: {"default": false},
	}
	for key: String in OSM_HEIGHT_LIMITS:
		definitions[OSM_BUILDINGS + key] = {"default": OSM_HEIGHT_LIMITS[key], "range": "0.1,1000,0.1,or_greater,suffix:m"}
	for key: String in OSM_AREA_LIMITS:
		definitions[OSM_BUILDINGS + key] = {"default": OSM_AREA_LIMITS[key], "range": "1,100000,1,or_greater,suffix:m²"}
	for highway: String in OSM_ROAD_WIDTHS:
		definitions[OSM_ROADS + highway + "_width_m"] = _road_width_definition(OSM_ROAD_WIDTHS[highway])
	definitions[OSM_ROADS + "fallback_width_m"] = _road_width_definition(OSM_FALLBACK_ROAD_WIDTH_M)
	definitions[OSM_ROADS + "lane_width_m"] = _road_width_definition(OSM_LANE_WIDTH_M)
	for key: String in APERTURE_DEFAULTS:
		definitions[APERTURES + key] = {"default": APERTURE_DEFAULTS[key], "range": APERTURE_RANGES[key]}
	var migrate := editor_settings != null and not bool(editor_settings.get_project_metadata(
		METADATA_SECTION, MIGRATION_KEY, false))
	var migrate_overpass := editor_settings != null and not bool(editor_settings.get_project_metadata(
		METADATA_SECTION, OVERPASS_MIGRATION_KEY, false))
	var legacy_layers: Variant = editor_settings.get_project_metadata(METADATA_SECTION, "overpass_layers", Overpass.DEFAULT_LAYERS) \
		if migrate_overpass else null
	for layer: String in Overpass.LAYERS:
		var default := layer in Overpass.DEFAULT_LAYERS
		definitions[OVERPASS + layer] = {"default": default,
			"initial": layer in legacy_layers if legacy_layers is Array else default}
	for key: String in definitions:
		var definition: Dictionary = definitions[key]
		var default: Variant = definition["default"]
		if not ProjectSettings.has_setting(key):
			var value: Variant = definition.get("initial", default)
			if migrate and definition.has("legacy"):
				value = _legacy_value(editor_settings.get_project_metadata(
					METADATA_SECTION, definition["legacy"], default), default)
			ProjectSettings.set_setting(key, value)
			_migration_needs_save = _migration_needs_save or value != default
		ProjectSettings.set_initial_value(key, default)
		var info := {"name": key, "type": typeof(default)}
		if definition.has("range"):
			info["hint"] = PROPERTY_HINT_RANGE
			info["hint_string"] = definition["range"]
		elif definition.has("enum"):
			info["hint"] = PROPERTY_HINT_ENUM
			info["hint_string"] = definition["enum"]
		elif key == PYTHON_EXECUTABLE:
			info["hint"] = PROPERTY_HINT_PLACEHOLDER_TEXT
			info["hint_string"] = PYTHON_PLACEHOLDER
		ProjectSettings.add_property_info(info)
		ProjectSettings.set_as_basic(key, true)
	_migration_needs_save = FlightInput.register_project_actions() or _migration_needs_save
	if _migration_needs_save:
		var error := ProjectSettings.save()
		if error != OK:
			push_warning("Spatial Toolkit: Could not save project settings: " + error_string(error))
			return
		_migration_needs_save = false
		if migrate:
			editor_settings.set_project_metadata(METADATA_SECTION, MIGRATION_KEY, true)
		if migrate_overpass:
			editor_settings.set_project_metadata(METADATA_SECTION, OVERPASS_MIGRATION_KEY, true)

static func python_executable() -> String:
	return str(ProjectSettings.get_setting(PYTHON_EXECUTABLE, _default_python())).strip_edges()

static func generation_options() -> Dictionary:
	return {
		"default_height": float(ProjectSettings.get_setting(DEFAULT_HEIGHT, DEFAULT_HEIGHT_M)),
		"level_height": float(ProjectSettings.get_setting(LEVEL_HEIGHT, DEFAULT_LEVEL_HEIGHT_M)),
		"world_scale": float(ProjectSettings.get_setting(WORLD_SCALE, DEFAULT_WORLD_SCALE)),
		"building_collisions": bool(ProjectSettings.get_setting(BUILDING_COLLISIONS, true)),
		"daylight": bool(ProjectSettings.get_setting(DAYLIGHT, true)),
		"osm_rules": osm_rules(),
	}

static func osm_rules() -> Dictionary:
	var heights: Array = []
	var areas: Array = []
	var widths := {}
	for key: String in OSM_HEIGHT_LIMITS:
		heights.append(ProjectSettings.get_setting(OSM_BUILDINGS + key, OSM_HEIGHT_LIMITS[key]))
	for key: String in OSM_AREA_LIMITS:
		areas.append(ProjectSettings.get_setting(OSM_BUILDINGS + key, OSM_AREA_LIMITS[key]))
	for highway: String in OSM_ROAD_WIDTHS:
		widths[highway] = ProjectSettings.get_setting(OSM_ROADS + highway + "_width_m", OSM_ROAD_WIDTHS[highway])
	return {"building_height_limits_m": heights, "building_area_limits_m2": areas,
		"road_widths_m": widths,
		"fallback_road_width_m": ProjectSettings.get_setting(OSM_ROADS + "fallback_width_m", OSM_FALLBACK_ROAD_WIDTH_M),
		"lane_width_m": ProjectSettings.get_setting(OSM_ROADS + "lane_width_m", OSM_LANE_WIDTH_M)}

static func merge_bake_collisions() -> bool:
	return bool(ProjectSettings.get_setting(BAKE_MERGE_COLLISIONS, true))

static func default_flight_controller() -> String:
	var selected: Variant = ProjectSettings.get_setting(FLIGHT_DEFAULT_CONTROLLER, null)
	if selected is int and selected >= 0 and selected < Drone.CONTROLLER_IDS.size():
		return Drone.CONTROLLER_IDS[selected]
	return Drone.DEFAULT_CONTROLLER

static func aperture_options() -> Dictionary:
	var options := {}
	for key: String in APERTURE_DEFAULTS:
		options[key] = ProjectSettings.get_setting(APERTURES + key, APERTURE_DEFAULTS[key])
	return options

static func overpass_layers() -> Array[String]:
	var layers: Array[String] = []
	for layer: String in Overpass.LAYERS:
		if ProjectSettings.get_setting(OVERPASS + layer, layer in Overpass.DEFAULT_LAYERS):
			layers.append(layer)
	return layers

static func set_overpass_layer(layer: String, enabled: bool) -> Error:
	if not Overpass.LAYERS.has(layer):
		return ERR_INVALID_PARAMETER
	var key := OVERPASS + layer
	var previous := bool(ProjectSettings.get_setting(key, layer in Overpass.DEFAULT_LAYERS))
	ProjectSettings.set_setting(key, enabled)
	var error := ProjectSettings.save() if Engine.is_editor_hint() else OK
	if error != OK:
		ProjectSettings.set_setting(key, previous)
	return error

static func _default_python() -> String:
	return "python" if OS.get_name() == "Windows" else "python3"

static func _road_width_definition(default: float) -> Dictionary:
	return {"default": default, "range": "0.1,100,0.1,or_greater,suffix:m"}

static func _legacy_value(value: Variant, default: Variant) -> Variant:
	if default is float and (value is float or value is int):
		return float(value) if is_finite(float(value)) and float(value) > 0.0 else default
	if default is String and value is String:
		return value.strip_edges() if not value.strip_edges().is_empty() else default
	return value if typeof(value) == typeof(default) else default
