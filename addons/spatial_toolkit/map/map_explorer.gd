@tool
extends VBoxContainer

signal region_import_requested(paths: PackedStringArray)

const DEFAULT_ATTRIBUTION := "© OpenStreetMap contributors"
const MapView := preload("map_view.gd")
const GeoJSONOverlay := preload("geojson_overlay.gd")
const Mercator := preload("map_projection.gd")
const TileProvider := preload("tile_provider.gd")
const Localization := preload("res://addons/spatial_toolkit/ui/editor_localization.gd")

var _map: MapView
var _url: LineEdit
var _coordinates: LineEdit
var _position: Label
var _status: Label
var _credit: LinkButton
var _overlay_status: Label
var _file_dialog: FileDialog
var _overlay_job: Thread
var _loading_overlay: GeoJSONOverlay
var _overlay_path := ""
var _loaded_overlay_path := ""
var _send_overlay: Button

func map_view() -> MapView:
	return _map

func _ready() -> void:
	set_translation_domain(Localization.DOMAIN)
	var source_bar := HBoxContainer.new()
	add_child(source_bar)
	_url = _add_input(source_bar, atr("XYZ URL"), "https://host/{z}/{x}/{y}.png")
	_url.text = TileProvider.OSM_URL
	_add_button(source_bar, atr("Connect"), _connect_provider)
	_url.text_submitted.connect(func(_value: String) -> void: _connect_provider())

	var navigation := HBoxContainer.new()
	add_child(navigation)
	_coordinates = _add_input(navigation, atr("Coordinates"), atr("Latitude, longitude"))
	_coordinates.text_submitted.connect(func(_value: String) -> void: _go_to())
	_add_button(navigation, atr("Go to"), _go_to)
	_add_button(navigation, "−", func() -> void: _map.change_zoom(-1, _map.size * 0.5))
	_add_button(navigation, "+", func() -> void: _map.change_zoom(1, _map.size * 0.5))

	var layers := HBoxContainer.new()
	add_child(layers)
	_add_button(layers, atr("Open GeoJSON…"), _choose_geojson)
	_add_button(layers, atr("Fit GeoJSON"), func() -> void: _map.fit_overlay())
	_add_button(layers, atr("Clear GeoJSON"), _clear_geojson)
	_send_overlay = _add_button(layers, atr("Send GeoJSON to Spatial"), _send_loaded_overlay)
	_send_overlay.disabled = true
	_overlay_status = Label.new()
	_overlay_status.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_overlay_status.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	layers.add_child(_overlay_status)

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
	_credit = LinkButton.new()
	_credit.hide()
	_credit.pressed.connect(func() -> void:
		OS.shell_open("https://www.openstreetmap.org/copyright"))
	footer.add_child(_credit)
	_map.view_changed.connect(_update_position)
	_map.tile_status.connect(func(message: String) -> void: _status.text = message)
	_map.zoom = 11
	_map.go_to(37.6176, 55.7558)
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
				_map.go_to(lon, lat)
				return
	_status.text = atr("Enter latitude (−90 to 90), longitude (−180 to 180).")

func _update_position() -> void:
	_position.text = "%.6f, %.6f  ·  z%d" % [
		Mercator.y_to_latitude(_map.center_y), Mercator.x_to_longitude(_map.center_x), _map.zoom]

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
		_overlay_status.text = atr("Could not start GeoJSON reader (%s).") % error_string(result)
		return
	_loading_overlay = overlay
	_overlay_path = path
	_overlay_status.text = atr("Loading %s…") % path.get_file()
	set_process(true)

func _process(_delta: float) -> void:
	if _overlay_job != null and not _overlay_job.is_alive():
		_overlay_job.wait_to_finish()
		_overlay_job = null
		set_process(false)
		var overlay := _loading_overlay
		_loading_overlay = null
		if not overlay.error.is_empty():
			_overlay_status.text = overlay.error
			return
		_loaded_overlay_path = _overlay_path
		_send_overlay.disabled = false
		_map.overlay = overlay
		_map.fit_overlay()
		_overlay_status.text = atr("%s · %d features · %d skipped") % [
			_overlay_path.get_file(), overlay.feature_count, overlay.skipped]

func _clear_geojson() -> void:
	if _overlay_job != null:
		return
	_loaded_overlay_path = ""
	_send_overlay.disabled = true
	_map.overlay = null
	_map.queue_redraw()
	_overlay_status.text = ""

func _send_loaded_overlay() -> void:
	if FileAccess.file_exists(_loaded_overlay_path):
		region_import_requested.emit(PackedStringArray([_loaded_overlay_path]))
	else:
		_overlay_status.text = atr("The loaded GeoJSON file is unavailable.")

func _exit_tree() -> void:
	if _overlay_job != null:
		_overlay_job.wait_to_finish()
