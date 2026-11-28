@tool
extends VBoxContainer

signal region_import_requested(paths: PackedStringArray)
signal preset_scene_requested(path: String)

enum GeoJSONAction { OPEN, FIT, CLEAR, SEND }
enum DatasetAction { CATALOG, SCENE, DOWNLOAD }

const DEFAULT_ATTRIBUTION := "© OpenStreetMap contributors"
const REGION_PRESETS := [
	{"name": "Helsinki · CityGML archive", "latitude": 60.18473, "longitude": 24.97702,
		"zoom": 12, "source": "City of Helsinki · Kalasatama CityGML LoD2 (2019) · CC BY 4.0",
		"catalog": "https://3d.hel.ninja/data/citygml/",
		"scene": "res://generated/maps/helsinki_kalasatama_001/preview.tscn",
		"citygml_id": "helsinki_kalasatama_archive", "archive_path": "user://spatial_toolkit/citygml/kalasatama_2019.zip",
		"archive_mb": 24,
		"archive_bounds": {"west": 24.948799, "south": 60.164890, "east": 25.005249, "north": 60.204566}},
	{"name": "Montréal · Ville-Marie", "latitude": 45.5128, "longitude": -73.5623,
		"zoom": 13, "source": "Ville de Montréal · CityGML LoD2 (2016) · CC BY 4.0",
		"catalog": "https://www.donneesquebec.ca/recherche/dataset/vmtl-batiment-3d-2016-maquette-citygml-lod2-avec-textures2",
		"citygml_id": "montreal_ville_marie", "archive_path": "user://spatial_toolkit/citygml/montreal_ville_marie.zip",
		"archive_mb": 226,
		"archive_bounds": {"west": -73.603776, "south": 45.485841, "east": -73.520741, "north": 45.539745}},
	{"name": "Munich · TUM Campus (full LoD3)", "latitude": 48.14910, "longitude": 11.56733,
		"zoom": 16, "source": "TUM2TWIN · CityGML LoD3 · CC BY 4.0",
		"catalog": "https://tum2t.win/datasets/cm-buildings",
		"citygml_id": "tum2twin_lod3_full", "archive_path": "user://spatial_toolkit/citygml/tum2twin_lod3_full.zip",
		"archive_mb": 119, "transfer_mb": 812,
		"archive_bounds": {"west": 11.565435, "south": 48.147417, "east": 11.569222, "north": 48.150791}},
	{"name": "Zürich", "latitude": 47.3766, "longitude": 8.5417,
		"zoom": 12, "source": "Stadt Zürich · Bauten – Dachmodell CityGML LoD2 · CC0 1.0",
		"catalog": "https://data.stadt-zuerich.ch/dataset/geo_bauten___dachmodell",
		"citygml_id": "zurich_citygml", "archive_path": "user://spatial_toolkit/citygml/zurich_citygml.zip",
		"archive_mb": 304,
		"archive_bounds": {"west": 8.458729, "south": 47.321364, "east": 8.623421, "north": 47.433646}},
	{"name": "Lyon · Presqu’île", "latitude": 45.7531, "longitude": 4.8255,
		"zoom": 13, "source": "Métropole de Lyon · CityGML (2018) · Etalab 2.0",
		"catalog": "https://www.data.gouv.fr/datasets/maquettes-3d-texturees-2018-des-communes-de-la-metropole-de-lyon",
		"citygml_id": "lyon_presquile", "archive_path": "user://spatial_toolkit/citygml/lyon_presquile.zip",
		"archive_mb": 44,
		"archive_bounds": {"west": 4.812664, "south": 45.731080, "east": 4.838421, "north": 45.775071}},
]
const MapView := preload("map_view.gd")
const GeoJSONOverlay := preload("geojson_overlay.gd")
const Mercator := preload("map_projection.gd")
const TileProvider := preload("tile_provider.gd")
const Localization := preload("res://addons/spatial_toolkit/ui/editor_localization.gd")
const Settings := preload("res://addons/spatial_toolkit/core/spatial_project_settings.gd")
const DownloadService := preload("res://addons/spatial_toolkit/core/citygml_download_service.gd")

var _map: MapView
var _url: LineEdit
var _coordinates: LineEdit
var _region_preset: OptionButton
var _dataset_button: MenuButton
var _default_longitude := 37.6176
var _default_latitude := 55.7558
var _default_zoom := 11
var _active_preset := 0
var _position: Label
var _status: Label
var _credit: LinkButton
var _overlay_status: Label
var _file_dialog: FileDialog
var _download_service: DownloadService
var _download_confirmation: ConfirmationDialog
var _download_dialog: AcceptDialog
var _download_bar: ProgressBar
var _download_preset := 0
var _offered_downloads: Variant = null
var _overlay_job: Thread
var _loading_overlay: GeoJSONOverlay
var _overlay_path := ""
var _loaded_overlay_path := ""
var _geojson_menu: PopupMenu

func map_view() -> MapView:
	return _map

func _notification(what: int) -> void:
	if what == NOTIFICATION_THEME_CHANGED and is_instance_valid(_dataset_button):
		_style_dataset_button()
	elif what == NOTIFICATION_VISIBILITY_CHANGED and is_visible_in_tree() and is_instance_valid(_map):
		_refresh_region_presets()

func _ready() -> void:
	set_translation_domain(Localization.DOMAIN)
	var source_bar := HBoxContainer.new()
	add_child(source_bar)
	_url = _add_input(source_bar, atr("XYZ URL"), "https://host/{z}/{x}/{y}.png")
	_url.text = TileProvider.OSM_URL
	_add_button(source_bar, atr("Connect"), _connect_provider)
	_url.text_submitted.connect(func(_value: String) -> void: _connect_provider())
	var geojson := MenuButton.new()
	geojson.name = "GeoJSONMenu"
	geojson.text = "GeoJSON"
	source_bar.add_child(geojson)
	_geojson_menu = geojson.get_popup()
	_geojson_menu.add_item(atr("Open GeoJSON…"), GeoJSONAction.OPEN)
	_geojson_menu.add_item(atr("Fit GeoJSON"), GeoJSONAction.FIT)
	_geojson_menu.add_item(atr("Clear GeoJSON"), GeoJSONAction.CLEAR)
	_geojson_menu.add_item(atr("Send GeoJSON to Spatial"), GeoJSONAction.SEND)
	_geojson_menu.id_pressed.connect(_on_geojson_action)
	_set_overlay_actions_enabled(false)

	var navigation := HBoxContainer.new()
	add_child(navigation)
	_coordinates = _add_input(navigation, atr("Coordinates"), atr("Latitude, longitude"))
	_coordinates.text_submitted.connect(func(_value: String) -> void: _go_to())
	_add_button(navigation, atr("Go to"), _go_to)
	_region_preset = OptionButton.new()
	_region_preset.name = "RegionPreset"
	_region_preset.add_item(atr("Default map"))
	_sync_region_presets()
	_region_preset.item_selected.connect(_select_region_preset)
	navigation.add_child(_region_preset)
	_add_button(navigation, "−", func() -> void: _map.change_zoom(-1, _map.size * 0.5))
	_add_button(navigation, "+", func() -> void: _map.change_zoom(1, _map.size * 0.5))
	_update_dataset_actions()

	_file_dialog = FileDialog.new()
	_file_dialog.title = atr("Open GeoJSON")
	_file_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	_file_dialog.access = FileDialog.ACCESS_FILESYSTEM
	_file_dialog.filters = PackedStringArray(["*.geojson, *.geo.json, *.json ; GeoJSON"])
	var samples := ProjectSettings.globalize_path("res://samples")
	_file_dialog.current_dir = samples if DirAccess.dir_exists_absolute(samples) else ProjectSettings.globalize_path("res://")
	_file_dialog.file_selected.connect(_load_geojson)
	add_child(_file_dialog)
	set_process(false)

	_map = MapView.new()
	_map.name = "MapView"
	_map.set_translation_domain(Localization.DOMAIN)
	_map.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_map.size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_child(_map)
	var footer := HBoxContainer.new()
	add_child(footer)
	_position = Label.new()
	footer.add_child(_position)
	_status = Label.new()
	_status.text = atr("Connect an XYZ source to display tiles.")
	_status.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_status.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_status.mouse_filter = Control.MOUSE_FILTER_STOP
	_status.mouse_entered.connect(func() -> void: _status.tooltip_text = _status.text)
	footer.add_child(_status)
	_overlay_status = Label.new()
	_overlay_status.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_overlay_status.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_overlay_status.mouse_filter = Control.MOUSE_FILTER_STOP
	_overlay_status.hide()
	footer.add_child(_overlay_status)
	_credit = LinkButton.new()
	_credit.hide()
	_credit.pressed.connect(func() -> void:
		OS.shell_open("https://www.openstreetmap.org/copyright"))
	footer.add_child(_credit)
	_map.view_changed.connect(_update_position)
	_map.tile_status.connect(func(message: String) -> void: _status.text = message)
	_map.selection_feedback.connect(_show_selection_feedback)
	_map.go_to(_default_longitude, _default_latitude, _default_zoom)
	# MapView only requests tiles while the main screen is visible.
	if Engine.is_editor_hint() and DisplayServer.get_name() != "headless":
		_connect_provider()
	else:
		_update_position()

func _add_input(parent: Control, caption: String, hint: String) -> LineEdit:
	var label := Label.new()
	label.text = caption
	parent.add_child(label)
	var field := LineEdit.new()
	field.placeholder_text = hint
	field.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	parent.add_child(field)
	return field

func _add_button(parent: Control, caption: String, action: Callable) -> Button:
	var button := Button.new()
	button.text = caption
	button.pressed.connect(action)
	parent.add_child(button)
	return button

func _connect_provider() -> void:
	var provider := TileProvider.new(_url.text.strip_edges())
	if not provider.is_valid():
		_status.text = atr("Enter an HTTP(S) URL containing {z}, {x} and {y}.")
		return
	_credit.text = DEFAULT_ATTRIBUTION
	_credit.visible = provider.template == TileProvider.OSM_URL
	_status.text = ""
	_map.set_provider(provider)

func _go_to() -> void:
	var parts := _coordinates.text.split(",")
	if parts.size() == 2:
		var latitude := parts[0].strip_edges()
		var longitude := parts[1].strip_edges()
		if latitude.is_valid_float() and longitude.is_valid_float():
			var lat := latitude.to_float()
			var lon := longitude.to_float()
			if absf(lat) <= 90.0 and absf(lon) <= 180.0:
				_status.text = ""
				_active_preset = 0
				_region_preset.select(0)
				_region_preset.tooltip_text = ""
				_update_dataset_actions()
				_map.set_citygml_dataset({})
				_map.go_to(lon, lat)
				return
	_status.text = atr("Enter latitude (−90 to 90), longitude (−180 to 180).")

func _sync_region_presets() -> void:
	# Open editor tabs can still contain entries from the old list.
	while _region_preset.item_count > REGION_PRESETS.size() + 1:
		_region_preset.remove_item(_region_preset.item_count - 1)
	for index in REGION_PRESETS.size():
		var preset: Dictionary = REGION_PRESETS[index]
		var menu_index := index + 1
		var label := atr(preset["name"])
		if menu_index == _region_preset.item_count:
			_region_preset.add_item(label)
		elif _region_preset.get_item_text(menu_index) != label:
			_region_preset.set_item_text(menu_index, label)
		if _region_preset.get_item_tooltip(menu_index) != preset["source"]:
			_region_preset.set_item_tooltip(menu_index, preset["source"])

func _refresh_region_presets() -> void:
	if _region_preset.item_count == REGION_PRESETS.size() + 1:
		return
	var dataset_id: String = _map.citygml_dataset.get("id", "")
	_sync_region_presets()
	for index in REGION_PRESETS.size():
		if REGION_PRESETS[index]["citygml_id"] == dataset_id:
			_active_preset = index + 1
			_region_preset.select(_active_preset)
			_region_preset.tooltip_text = REGION_PRESETS[index]["source"]
			_update_dataset_actions()
			return
	_region_preset.select(0)
	if _active_preset != 0:
		_select_region_preset(0)
	else:
		_update_dataset_actions()

func _select_region_preset(index: int) -> void:
	if _region_preset.item_count > REGION_PRESETS.size() + 1 and index > 0:
		# An open selector can still contain the previous list after script reload.
		var selected_label := _region_preset.get_item_text(index)
		index = 0
		for candidate in REGION_PRESETS.size():
			if selected_label == atr(REGION_PRESETS[candidate]["name"]):
				index = candidate + 1
				break
	_sync_region_presets()
	_region_preset.select(index)
	if not _map.selection_feedback.is_connected(_show_selection_feedback):
		_map.selection_feedback.connect(_show_selection_feedback)
	if index > 0 and _active_preset == 0:
		_default_longitude = Mercator.x_to_longitude(_map.center_x)
		_default_latitude = Mercator.y_to_latitude(_map.center_y)
		_default_zoom = _map.zoom
	_active_preset = index
	var longitude := _default_longitude
	var latitude := _default_latitude
	var zoom := _default_zoom
	var preset := {}
	if index > 0:
		preset = REGION_PRESETS[index - 1]
		longitude = preset["longitude"]
		latitude = preset["latitude"]
		zoom = preset["zoom"]
	_coordinates.text = "%.6f, %.6f" % [latitude, longitude]
	_region_preset.tooltip_text = _region_preset.get_item_tooltip(index)
	_update_dataset_actions()
	_status.text = ""
	_map.go_to(longitude, latitude, zoom)
	_apply_preset_citygml(preset)
	if Engine.is_editor_hint() and index > 0:
		_maybe_offer_dataset_download.call_deferred(index)

func _show_selection_feedback(message: String) -> void:
	_status.text = message

func _ensure_dataset_button() -> void:
	if is_instance_valid(_dataset_button):
		return
	# An existing editor workspace may have reloaded the script without running _ready again.
	var navigation := _region_preset.get_parent()
	_dataset_button = navigation.get_node_or_null("RegionDataset") as MenuButton
	if _dataset_button != null:
		return
	_dataset_button = MenuButton.new()
	_dataset_button.name = "RegionDataset"
	_dataset_button.text = atr("3D data")
	navigation.add_child(_dataset_button)
	navigation.move_child(_dataset_button, _region_preset.get_index() + 1)
	_dataset_button.get_popup().id_pressed.connect(_on_dataset_action)
	_dataset_button.about_to_popup.connect(_update_dataset_actions)

func _style_dataset_button() -> void:
	_dataset_button.flat = false
	_dataset_button.icon = get_theme_icon("arrow", "OptionButton")
	_dataset_button.icon_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	# The editor's MenuButton theme is designed for menu bars.
	for state: StringName in [&"normal", &"hover", &"pressed", &"disabled", &"focus"]:
		var style := get_theme_stylebox(state, &"Button")
		if _dataset_button.get_theme_stylebox(state) != style:
			_dataset_button.add_theme_stylebox_override(state, style)

func _update_dataset_actions() -> void:
	if _region_preset.item_count > REGION_PRESETS.size() + 1:
		_refresh_region_presets()
		return
	_ensure_dataset_button()
	_style_dataset_button()
	_dataset_button.visible = _active_preset > 0
	if _active_preset == 0:
		return
	var preset: Dictionary = REGION_PRESETS[_active_preset - 1]
	var popup := _dataset_button.get_popup()
	popup.clear()
	popup.add_item(atr("Open dataset catalog"), DatasetAction.CATALOG)
	var scene_path: String = preset.get("scene", "")
	if not scene_path.is_empty() and ResourceLoader.exists(scene_path, "PackedScene"):
		popup.add_item(atr("Open prepared 3D scene"), DatasetAction.SCENE)
	if not FileAccess.file_exists(preset["archive_path"]):
		popup.add_item(atr("Download 3D archive"), DatasetAction.DOWNLOAD)
		popup.set_item_disabled(popup.get_item_index(DatasetAction.DOWNLOAD), _dataset_download_busy())

func _on_dataset_action(id: int) -> void:
	if _active_preset == 0:
		return
	var popup := _dataset_button.get_popup()
	var item := popup.get_item_index(id)
	if item == -1 or popup.is_item_disabled(item):
		return
	var preset: Dictionary = REGION_PRESETS[_active_preset - 1]
	var error := OK
	match id:
		DatasetAction.CATALOG:
			error = OS.shell_open(preset["catalog"])
		DatasetAction.SCENE:
			if preset_scene_requested.has_connections():
				preset_scene_requested.emit(preset["scene"])
			elif Engine.is_editor_hint():
				open_preset_scene(preset["scene"])
		DatasetAction.DOWNLOAD:
			_offer_dataset_download(_active_preset)
	if error != OK:
		_status.text = atr("Could not open the 3D dataset link (%s).") % error_string(error)

func _preset_citygml(preset: Dictionary) -> Dictionary:
	if preset.is_empty():
		return {}
	return {"id": preset["citygml_id"], "path": preset["archive_path"], "requires_osm_buildings": true}

func _apply_preset_citygml(preset: Dictionary) -> void:
	var dataset := _preset_citygml(preset)
	_map.set_citygml_dataset(dataset, preset.get("archive_bounds", {}))
	if dataset.is_empty():
		return
	var path: String = dataset["path"]
	if not FileAccess.file_exists(path):
		_status.text = atr("Download the archive in the 3D data menu.")
	else:
		_status.text = atr("CityGML archive %s. Fetch the OSM Buildings layer with this preset.") % path.get_file()

func _dataset_download_busy() -> bool:
	return is_instance_valid(_download_service) and _download_service.busy

func _maybe_offer_dataset_download(index: int) -> void:
	if index <= 0 or index > REGION_PRESETS.size() or index != _active_preset:
		return
	var dataset_id: String = REGION_PRESETS[index - 1]["citygml_id"]
	if _offered_downloads != null and _offered_downloads.has(dataset_id):
		return
	_offer_dataset_download(index)

func _offer_dataset_download(index: int) -> void:
	var preset: Dictionary = REGION_PRESETS[index - 1]
	if _dataset_download_busy() or FileAccess.file_exists(preset["archive_path"]):
		return
	if _offered_downloads == null:
		_offered_downloads = {}
	_offered_downloads[preset["citygml_id"]] = true
	_download_preset = index
	if not is_instance_valid(_download_confirmation):
		_download_confirmation = ConfirmationDialog.new()
		_download_confirmation.title = atr("Download 3D archive")
		_download_confirmation.ok_button_text = atr("Download")
		_download_confirmation.cancel_button_text = atr("Later")
		_download_confirmation.dialog_autowrap = true
		_download_confirmation.confirmed.connect(_start_dataset_download)
		_download_confirmation.canceled.connect(func() -> void: _download_preset = 0)
		add_child(_download_confirmation)
	var description := atr("Download 3D models for %s?\n%s") % [atr(preset["name"]), preset["source"]]
	if preset.has("archive_mb"):
		description += "\n" + atr("Local archive size: about %d MB.") % int(preset["archive_mb"])
	if preset.has("transfer_mb"):
		description += "\n" + atr("Download size: about %d MB.") % int(preset["transfer_mb"])
	_download_confirmation.dialog_text = description
	_download_confirmation.popup_centered(Vector2i(430, 0))

func _start_dataset_download() -> void:
	if _download_preset == 0 or _dataset_download_busy():
		return
	_download_confirmation.hide()
	var preset: Dictionary = REGION_PRESETS[_download_preset - 1]
	if not is_instance_valid(_download_service):
		_download_service = DownloadService.new()
		_download_service.progress.connect(_on_dataset_download_progress)
		_download_service.completed.connect(_on_dataset_download_completed)
		add_child(_download_service)
	_ensure_download_dialog()
	_download_dialog.ok_button_text = atr("Cancel")
	_download_bar.show()
	var result := _download_service.start(preset["citygml_id"], preset["archive_path"], Settings.python_executable())
	if not result.get("ok", false):
		_on_dataset_download_completed(result)
	else:
		_download_dialog.popup_centered(Vector2i(430, 0))
		_update_dataset_actions()

func _ensure_download_dialog() -> void:
	if is_instance_valid(_download_dialog):
		return
	_download_dialog = AcceptDialog.new()
	_download_dialog.title = atr("Download 3D archive")
	_download_dialog.dialog_autowrap = true
	_download_dialog.confirmed.connect(_cancel_dataset_download)
	_download_dialog.canceled.connect(_cancel_dataset_download)
	_download_bar = ProgressBar.new()
	_download_bar.custom_minimum_size.x = 410.0
	_download_dialog.add_child(_download_bar)
	add_child(_download_dialog)

func _on_dataset_download_progress(message: String, fraction: float) -> void:
	_download_dialog.dialog_text = "%s\n%s" % [atr(REGION_PRESETS[_download_preset - 1]["name"]), message]
	_download_bar.indeterminate = fraction < 0.0
	_download_bar.value = maxf(0.0, fraction) * 100.0

func _on_dataset_download_completed(result: Dictionary) -> void:
	var preset := _download_preset
	_download_preset = 0
	_update_dataset_actions()
	_download_dialog.hide()
	if result.get("ok", false):
		if _active_preset == preset:
			_apply_preset_citygml(REGION_PRESETS[preset - 1])
	elif not result.get("cancelled", false):
		_download_dialog.dialog_text = atr("Could not download the 3D archive.\n%s") % result.get("error", "")
		_download_dialog.ok_button_text = atr("Close")
		_download_bar.hide()
		_download_dialog.popup_centered(Vector2i(430, 0))

func _cancel_dataset_download() -> void:
	if _dataset_download_busy():
		_download_service.cancel()

func open_preset_scene(path: String) -> void:
	EditorInterface.open_scene_from_path(path)
	var scene := EditorInterface.get_edited_scene_root()
	if scene != null and scene.scene_file_path == path:
		EditorInterface.set_main_screen_editor("3D")

func _update_position() -> void:
	_position.text = "%.6f, %.6f  ·  z%d" % [
		Mercator.y_to_latitude(_map.center_y), Mercator.x_to_longitude(_map.center_x), _map.zoom]

func _on_geojson_action(id: int) -> void:
	match id:
		GeoJSONAction.OPEN: _choose_geojson()
		GeoJSONAction.FIT: _map.fit_overlay()
		GeoJSONAction.CLEAR: _clear_geojson()
		GeoJSONAction.SEND: _send_loaded_overlay()

func _set_overlay_actions_enabled(enabled: bool) -> void:
	for id in [GeoJSONAction.FIT, GeoJSONAction.CLEAR, GeoJSONAction.SEND]:
		_geojson_menu.set_item_disabled(_geojson_menu.get_item_index(id), not enabled)

func _set_overlay_status(message: String) -> void:
	_overlay_status.text = message
	_overlay_status.tooltip_text = message
	_overlay_status.visible = not message.is_empty()

func _choose_geojson() -> void:
	if _overlay_job == null:
		_file_dialog.popup_centered_ratio(0.75)

func _load_geojson(path: String) -> void:
	if _overlay_job != null:
		return
	var overlay := GeoJSONOverlay.new()
	_overlay_job = Thread.new()
	var result := _overlay_job.start(overlay.read.bind(path))
	if result != OK:
		_overlay_job = null
		_set_overlay_status(atr("Could not start GeoJSON reader (%s).") % error_string(result))
		return
	_loading_overlay = overlay
	_overlay_path = path
	_set_overlay_status(atr("Loading %s…") % path.get_file())
	set_process(true)

func _process(_delta: float) -> void:
	if _overlay_job != null and not _overlay_job.is_alive():
		_overlay_job.wait_to_finish()
		_overlay_job = null
		set_process(false)
		var overlay := _loading_overlay
		_loading_overlay = null
		if not overlay.error.is_empty():
			_set_overlay_status(overlay.error)
			return
		_loaded_overlay_path = _overlay_path
		_set_overlay_actions_enabled(true)
		_map.overlay = overlay
		_map.fit_overlay()
		_set_overlay_status(atr("%s · %d features · %d skipped") % [
			_overlay_path.get_file(), overlay.feature_count, overlay.skipped])

func _clear_geojson() -> void:
	if _overlay_job != null:
		return
	_loaded_overlay_path = ""
	_set_overlay_actions_enabled(false)
	_map.overlay = null
	_map.queue_redraw()
	_set_overlay_status("")

func _send_loaded_overlay() -> void:
	if FileAccess.file_exists(_loaded_overlay_path):
		region_import_requested.emit(PackedStringArray([_loaded_overlay_path]))
	else:
		_set_overlay_status(atr("The loaded GeoJSON file is unavailable."))

func _exit_tree() -> void:
	if _overlay_job != null:
		_overlay_job.wait_to_finish()
