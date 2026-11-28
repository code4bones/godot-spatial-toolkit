@tool
extends VBoxContainer

signal material_imported(material: StandardMaterial3D)

const POLY := "https://api.polyhaven.com"
const AMBIENT := "https://ambientcg.com/api/v3/assets"
const AMBIENT_PAGE_SIZE := 500
const TEXTURES := "res://assets/textures"
const MATERIALS := "res://assets/materials"
const USER_AGENT := "GodotSpatialToolkit/0.7"
const Localization := preload("res://addons/spatial_toolkit/ui/editor_localization.gd")
const Network := preload("res://addons/spatial_toolkit/core/spatial_network_settings.gd")
const Request := preload("res://addons/spatial_toolkit/core/spatial_http_request.gd")
const PREVIEW_SIZE := 96
const PREVIEW_CACHE_LIMIT := 96
const MAPS := {
	"color": ["Diffuse", "Color"],
	"normal": ["nor_gl", "NormalGL"],
	"roughness": ["Rough", "Roughness"],
	"height": ["Displacement", "Displacement"],
	"metal": ["Metal", "Metalness"],
}

var _editor: EditorInterface
var _provider := OptionButton.new()
var _query := LineEdit.new()
var _results := ItemList.new()
var _message := Label.new()
var _load: Button
var _busy := false
var _preview_request: Request
var _preview_proxy: Variant
var _preview_url := ""
var _preview_refresh_queued := false
var _preview_placeholder: Texture2D
var _preview_cache: Dictionary = {}
var _window_thumbnails: Dictionary = {}
var _thumbnail_rows: Dictionary = {}
var _request := Request.new()
var _catalogs: Dictionary = {}
var _local_files: Dictionary = {}
var _recent_imports: Dictionary = {}

func setup(editor: EditorInterface) -> void:
	_editor = editor
	set_translation_domain(Localization.DOMAIN)
	var row := HBoxContainer.new()
	row.name = "CatalogToolbar"
	add_child(row)
	_provider.name = "MaterialProvider"
	_provider.add_item("Poly Haven")
	_provider.add_item("ambientCG")
	_provider.item_selected.connect(func(_index: int) -> void:
		_refresh_filter(_query.text, false))
	row.add_child(_provider)
	_load = Button.new()
	_load.name = "CatalogLoadButton"
	_load.pressed.connect(_load_catalog)
	row.add_child(_load)
	_query.name = "MaterialFilter"
	_query.placeholder_text = atr("Filter materials")
	_query.clear_button_enabled = true
	_query.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_query.text_changed.connect(_refresh_filter)
	row.add_child(_query)

	var editor_scale := EditorInterface.get_editor_scale() if _editor != null else 1.0
	var icon_size := roundi(PREVIEW_SIZE * editor_scale)
	_results.name = "MaterialResults"
	_results.custom_minimum_size.y = roundi(150 * editor_scale)
	_results.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_results.max_columns = 0
	_results.fixed_column_width = icon_size + roundi(24 * editor_scale)
	_results.same_column_width = true
	_results.max_text_lines = 1
	_results.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_results.icon_mode = ItemList.ICON_MODE_TOP
	_results.fixed_icon_size = Vector2i(icon_size, icon_size)
	_results.item_activated.connect(_activate_item)
	_results.set_drag_forwarding(_drag_material, Callable(), Callable())
	add_child(_results)
	_results.resized.connect(_schedule_preview_refresh)
	_results.get_v_scroll_bar().value_changed.connect(func(_value: float) -> void:
		_schedule_preview_refresh())
	visibility_changed.connect(_preview_visibility_changed)
	var placeholder := Image.create_empty(1, 1, false, Image.FORMAT_RGBA8)
	placeholder.fill(Color(0.55, 0.55, 0.55, 0.12))
	_preview_placeholder = ImageTexture.create_from_image(placeholder)

	_message.name = "CatalogStatus"
	_message.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	add_child(_message)
	_request.timeout = 25.0
	_request.body_size_limit = 64 * 1024 * 1024
	add_child(_request)
	_preview_proxy = Network.proxy_for(Network.TEXTURES)
	if Network.is_available():
		Network.changes().changed.connect(_refresh_preview_proxy)
	if _editor != null:
		_editor.get_resource_filesystem().filesystem_changed.connect(_refresh_local_materials)
	_refresh_local_materials(true)

func _set_busy(value: bool, message: String) -> void:
	_busy = value
	_load.disabled = value
	_provider.disabled = value
	_message.text = message

func _load_catalog() -> void:
	if _busy or _missing_proxy_address():
		return
	var provider := _provider.selected
	_set_busy(true, atr("Loading catalog…"))
	var entries: Variant
	if provider == 0:
		entries = await _poly_catalog()
	else:
		entries = await _ambient_catalog()
	if entries == null:
		_set_busy(false, atr("Could not load the %s catalog.") % _provider.get_item_text(provider))
		return
	entries.sort_custom(_entry_less)
	_catalogs[provider] = entries
	_forget_failed_previews()
	_set_busy(false, "")
	_refresh_filter(_query.text)

func _poly_catalog() -> Variant:
	var listing := await _get_json(POLY + "/assets?t=textures")
	if listing.is_empty():
		return null
	var entries: Array[Dictionary] = []
	for id: String in listing:
		var asset: Dictionary = listing[id]
		entries.append(_entry(id, str(asset.get("name", id)), str(asset.get("thumbnail_url", "")), asset))
	return entries

func _ambient_catalog() -> Variant:
	var entries: Array[Dictionary] = []
	var offset := 0
	while true:
		var url := AMBIENT + "?type=material&sort=alphabet&include=title,tags,thumbnails&limit=%d&offset=%d" % [AMBIENT_PAGE_SIZE, offset]
		var listing := await _get_json(url)
		if not listing.get("assets") is Array:
			return null
		var assets: Array = listing["assets"]
		for asset: Dictionary in assets:
			var id := str(asset.get("id", ""))
			entries.append(_entry(id, str(asset.get("title", id)), str(asset.get("thumbnails", {}).get("256-PNG", "")), asset))
		offset += assets.size()
		if listing.has("totalResults") and offset >= int(listing["totalResults"]):
			return entries
		if not listing.has("totalResults") and assets.size() < AMBIENT_PAGE_SIZE:
			return entries
		if assets.is_empty():
			return null
	return entries

func _entry(id: String, title: String, thumb: String, asset: Dictionary) -> Dictionary:
	return {"id": id, "title": title, "thumb": thumb, "data": asset,
		"filter_text": ("%s %s %s" % [id, title, asset.get("tags", [])]).to_lower()}

func _entry_less(a: Dictionary, b: Dictionary) -> bool:
	var title_order: int = String(a["title"]).naturalnocasecmp_to(b["title"])
	return title_order < 0 if title_order != 0 else String(a["id"]).casecmp_to(b["id"]) < 0

func _matches(terms: PackedStringArray, text: String) -> bool:
	for term in terms:
		if not text.contains(term):
			return false
	return true

func _refresh_filter(query: String, keep_selection := true) -> void:
	var selected := _results.get_selected_items()
	var selected_id := ""
	if keep_selection and not selected.is_empty():
		selected_id = _results.get_item_metadata(selected[0])["id"]
	_cancel_preview()
	_window_thumbnails.clear()
	_thumbnail_rows.clear()
	_results.clear()
	var loaded := _catalogs.has(_provider.selected)
	var entries: Array = _catalogs.get(_provider.selected, [])
	var terms := query.strip_edges().to_lower().split(" ", false)
	for entry in _visible_entries(entries, terms):
		var index := _results.add_item(entry["title"], _preview_placeholder)
		_results.set_item_metadata(index, entry)
		_mark_local_result(index, entry)
		if not selected_id.is_empty() and entry["id"] == selected_id:
			_results.select(index)
	_load.text = atr("Refresh catalog") if loaded else atr("Load catalog")
	if not _busy:
		_message.text = atr("Showing %d of %d materials") % [_results.item_count, entries.size()] \
			if loaded else atr("Load a material catalog.")
	_schedule_preview_refresh()

func _visible_entries(entries: Array, terms: PackedStringArray) -> Array[Dictionary]:
	var imported: Array[Dictionary] = []
	var remote: Array[Dictionary] = []
	for entry: Dictionary in entries:
		if not _matches(terms, entry["filter_text"]):
			continue
		if _local_material_path(entry).is_empty():
			remote.append(entry)
		else:
			imported.append(entry)
	imported.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		var a_order: int = _recent_imports.get(_local_material_path(a), 0)
		var b_order: int = _recent_imports.get(_local_material_path(b), 0)
		return a_order > b_order if a_order != b_order else _entry_less(a, b))
	imported.append_array(remote)
	return imported

func _supplier() -> String:
	return "polyhaven" if _provider.selected == 0 else "ambientcg"

func _material_prefix(supplier: String, id: String) -> String:
	return "%s_%s_1k" % [supplier, id]

func _local_material_path(entry: Dictionary) -> String:
	var filename := _material_prefix(_supplier(), entry["id"]) + ".tres"
	return MATERIALS.path_join(filename) if _local_files.has(filename) else ""

func _refresh_local_materials(force_reorder := false) -> void:
	var files := {}
	var directory := DirAccess.open(MATERIALS)
	if directory != null:
		for filename in directory.get_files():
			files[filename] = true
	if force_reorder or files != _local_files:
		_local_files = files
		_refresh_filter(_query.text)
		return
	for key: String in _window_thumbnails.keys():
		if key.begins_with("res://"):
			_window_thumbnails.erase(key)
	_schedule_preview_refresh()

func _mark_local_result(index: int, entry: Dictionary) -> void:
	var title: String = entry["title"]
	var local := not _local_material_path(entry).is_empty()
	_results.set_item_text(index, "✓ " + title if local else title)
	var action := atr("Drag to a material field in the Inspector.") if local \
		else atr("Double-click or press Enter to import 1K PBR.")
	_results.set_item_tooltip(index, (atr("%s · In project") % title if local else title) + "\n" + action)

func _drag_material(position: Vector2) -> Variant:
	var index := _results.get_item_at_position(position, true)
	if index < 0:
		return null
	var path := _local_material_path(_results.get_item_metadata(index))
	if path.is_empty() or not FileAccess.file_exists(path):
		return null
	var material := load(path) as StandardMaterial3D
	if material == null:
		return null
	if material.albedo_texture != null:
		var preview := TextureRect.new()
		preview.texture = material.albedo_texture
		preview.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		preview.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		preview.size = Vector2(_results.fixed_icon_size) * 0.5
		_results.set_drag_preview(preview)
	return {"type": "resource", "resource": material}

func _preview_visibility_changed() -> void:
	if is_visible_in_tree():
		_schedule_preview_refresh()
	else:
		_cancel_preview()
		for index: int in _thumbnail_rows:
			_results.set_item_icon(index, _preview_placeholder)
		_thumbnail_rows.clear()
		_window_thumbnails.clear()

func _schedule_preview_refresh() -> void:
	if not _preview_refresh_queued:
		_preview_refresh_queued = true
		_update_preview_window.call_deferred()

func _refresh_preview_proxy() -> void:
	var proxy: Variant = Network.proxy_for(Network.TEXTURES)
	if proxy == _preview_proxy:
		return
	_preview_proxy = proxy
	_cancel_preview()
	_window_thumbnails.clear()
	_forget_failed_previews()
	_schedule_preview_refresh()

func _forget_failed_previews() -> void:
	for url: String in _preview_cache.keys():
		if _preview_cache[url] == null:
			_preview_cache.erase(url)

func _update_preview_window() -> void:
	_preview_refresh_queued = false
	if not is_visible_in_tree() or _results.size.x <= 0.0 or _results.size.y <= 0.0 \
			or _results.item_count == 0:
		return
	_results.force_update_list_size()
	var scroll := _results.get_v_scroll_bar()
	var viewport_top := _results.get_item_rect(0).position.y + scroll.value
	var viewport_bottom := viewport_top + (scroll.page if scroll.visible else _results.size.y)
	var first := _first_visible_item(viewport_top)
	var prefetch_top := INF
	var thumbnails := {}
	var thumbnail_rows := {}
	var wanted_urls := {}
	for index in range(first, _results.item_count):
		var item_top := _results.get_item_rect(index).position.y
		if item_top >= viewport_bottom:
			if prefetch_top != INF and item_top > prefetch_top:
				break
			prefetch_top = item_top
		var item: Dictionary = _results.get_item_metadata(index)
		var local_path := _local_material_path(item)
		var url: String = item["thumb"]
		var key := local_path if not local_path.is_empty() else url
		if not thumbnails.has(key):
			if _window_thumbnails.has(key):
				thumbnails[key] = _window_thumbnails[key]
			elif not local_path.is_empty():
				var material := load(local_path) as StandardMaterial3D if FileAccess.file_exists(local_path) else null
				thumbnails[key] = material.albedo_texture if material != null else null
			elif _preview_cache.has(url):
				thumbnails[key] = _preview_cache[url]
				_preview_cache.erase(url)
				_preview_cache[url] = thumbnails[key]
			elif url.begins_with("https://"):
				wanted_urls[url] = true
		var texture: Texture2D = thumbnails.get(key)
		if texture != null:
			thumbnail_rows[index] = true
			if _results.get_item_icon(index) != texture:
				_results.set_item_icon(index, texture)
	for index: int in _thumbnail_rows:
		if not thumbnail_rows.has(index):
			_results.set_item_icon(index, _preview_placeholder)
	_thumbnail_rows = thumbnail_rows
	_window_thumbnails = thumbnails
	if _preview_request != null and not wanted_urls.has(_preview_url):
		_cancel_preview()
	if _preview_request == null and not wanted_urls.is_empty():
		_start_preview(wanted_urls.keys()[0])

func _first_visible_item(top: float) -> int:
	var low := 0
	var high := _results.item_count
	while low < high:
		var middle := (low + high) >> 1
		if _results.get_item_rect(middle).end.y <= top:
			low = middle + 1
		else:
			high = middle
	return low

func _start_preview(url: String) -> void:
	var request := Request.new()
	request.timeout = 10.0
	request.body_size_limit = 2 * 1024 * 1024
	add_child(request)
	_preview_request = request
	_preview_url = url
	request.request_completed.connect(_preview_completed.bind(request))
	if _request_thumbnail(url) != OK and _preview_request == request:
		_finish_preview(null)

func _request_thumbnail(url: String) -> Error:
	if not url.begins_with("https://"):
		return ERR_INVALID_PARAMETER
	return _preview_request.request(url, ["User-Agent: " + USER_AGENT],
		HTTPClient.METHOD_GET, "", Network.proxy_for(Network.TEXTURES))

func _cancel_preview() -> void:
	if _preview_request != null:
		var request := _preview_request
		_preview_request = null
		_preview_url = ""
		request.cancel_request()
		request.queue_free()

func _preview_completed(result: int, code: int, _headers: PackedStringArray, body: PackedByteArray,
		request: Request) -> void:
	if request != _preview_request:
		return
	var texture: Texture2D
	if result == HTTPRequest.RESULT_SUCCESS and code == 200:
		texture = _decode_preview(body)
	_finish_preview(texture)

func _finish_preview(texture: Texture2D) -> void:
	_preview_cache[_preview_url] = texture
	if _preview_cache.size() > PREVIEW_CACHE_LIMIT:
		_preview_cache.erase(_preview_cache.keys()[0])
	_cancel_preview()
	_schedule_preview_refresh()

func _decode_preview(body: PackedByteArray) -> Texture2D:
	var image := Image.new()
	var webp := body.size() >= 12 and body.slice(0, 4).get_string_from_ascii() == "RIFF" \
		and body.slice(8, 12).get_string_from_ascii() == "WEBP"
	var decoded := image.load_webp_from_buffer(body) if webp else _load_png_or_jpg(image, body)
	if decoded != OK or image.is_empty():
		return null
	var width := image.get_width()
	var height := image.get_height()
	var longest := maxi(width, height)
	if longest > PREVIEW_SIZE:
		var factor := float(PREVIEW_SIZE) / longest
		image.resize(maxi(1, roundi(width * factor)), maxi(1, roundi(height * factor)),
			Image.INTERPOLATE_LANCZOS)
	return ImageTexture.create_from_image(image)

func _download(url: String) -> PackedByteArray:
	if not url.begins_with("https://") or _request.request(url, ["User-Agent: " + USER_AGENT],
			HTTPClient.METHOD_GET, "", Network.proxy_for(Network.TEXTURES)) != OK:
		return PackedByteArray()
	var response: Array = await _request.request_completed
	if response[0] != HTTPRequest.RESULT_SUCCESS or response[1] != 200:
		return PackedByteArray()
	return response[3]

func _get_json(url: String) -> Dictionary:
	var body := await _download(url)
	var parsed: Variant = JSON.parse_string(body.get_string_from_utf8()) if not body.is_empty() else null
	return parsed if parsed is Dictionary else {}

func _missing_proxy_address() -> bool:
	var proxy: Variant = Network.proxy_for(Network.TEXTURES)
	if proxy is String and proxy.is_empty():
		_message.text = atr(Network.SETTINGS_PATH)
		return true
	return false

func _activate_item(index: int) -> void:
	if _busy or index < 0 or index >= _results.item_count:
		return
	var entry: Dictionary = _results.get_item_metadata(index)
	var supplier := _supplier()
	var id: String = entry["id"]
	if not _valid_id(id):
		_message.text = atr("Invalid asset ID.")
		return
	var prefix := _material_prefix(supplier, id)
	var material_path := MATERIALS.path_join(prefix + ".tres")
	if FileAccess.file_exists(material_path):
		var existing := load(material_path) as StandardMaterial3D
		if existing != null:
			_use_material(existing, atr("%s is already in the project.") % entry["title"])
			return
	if _missing_proxy_address():
		return
	_set_busy(true, atr("Downloading %s…") % entry["title"])
	var images: Dictionary
	if supplier == "polyhaven":
		images = await _poly_images(id)
	else:
		images = await _ambient_images(id, prefix)
	if not images.has("color"):
		_set_busy(false, atr("Could not download the 1K color map."))
		return
	var material := await _save_material(entry, supplier, prefix, material_path, images)
	if material == null:
		_set_busy(false, atr("Could not import the textures into Godot."))
		return
	_recent_imports[material_path] = Time.get_ticks_usec()
	_use_material(material, atr("Imported %s.") % entry["title"], id)

func _use_material(material: StandardMaterial3D, message: String, imported_id := "") -> void:
	_refresh_local_materials(not imported_id.is_empty())
	var selected := _results.get_selected_items()
	if not imported_id.is_empty() and not selected.is_empty() \
			and _results.get_item_metadata(selected[0])["id"] == imported_id:
		_results.ensure_current_is_visible()
	_set_busy(false, message)
	material_imported.emit(material)

func _valid_id(id: String) -> bool:
	if id.is_empty() or id.length() > 100:
		return false
	for c in id:
		if not "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-".contains(c):
			return false
	return true

func _poly_images(id: String) -> Dictionary:
	var files := await _get_json(POLY + "/files/" + id)
	var images := {}
	for key: String in MAPS:
		var formats: Dictionary = files.get(MAPS[key][0], {}).get("1k", {})
		var item: Dictionary = formats.get("png", formats.get("jpg", {}))
		if not item.has("url"):
			continue
		var body := await _download(item["url"])
		var hash := HashingContext.new()
		hash.start(HashingContext.HASH_MD5)
		hash.update(body)
		if not body.is_empty() and hash.finish().hex_encode() == item.get("md5", ""):
			var image := _decode(body)
			if image != null:
				images[key] = image
	return images

func _ambient_images(id: String, prefix: String) -> Dictionary:
	var listing := await _get_json(AMBIENT + "?include=downloads&id=" + id.uri_encode())
	var assets: Array = listing.get("assets", [])
	if assets.is_empty() or str(assets[0].get("id", "")) != id:
		return {}
	var options: Array = assets[0].get("downloads", [])
	var url := ""
	for quality: String in ["1K-PNG", "1K-JPG"]:
		for option: Dictionary in options:
			if option.get("attributes") == quality and option.get("extension") == "zip":
				url = str(option.get("url", ""))
				break
		if not url.is_empty():
			break
	var body := await _download(url)
	if body.is_empty():
		return {}
	var path := "user://%s_download.zip" % prefix
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return {}
	file.store_buffer(body)
	file.close()
	var zip := ZIPReader.new()
	var images := {}
	if zip.open(path) == OK:
		for member in zip.get_files():
			var name := member.get_file().get_basename()
			for key: String in MAPS:
				if name.ends_with("_" + MAPS[key][1]) and not images.has(key):
					var image := _decode(zip.read_file(member))
					if image != null:
						images[key] = image
		zip.close()
	DirAccess.remove_absolute(path)
	return images

func _decode(bytes: PackedByteArray) -> Image:
	var image := Image.new()
	if _load_png_or_jpg(image, bytes) != OK:
		return null
	if image.get_width() > 2048 or image.get_height() > 2048:
		return null
	return image

func _load_png_or_jpg(image: Image, bytes: PackedByteArray) -> Error:
	if bytes.size() < 8:
		return ERR_FILE_CORRUPT
	if bytes[0] == 137 and bytes.slice(1, 4).get_string_from_ascii() == "PNG":
		return image.load_png_from_buffer(bytes)
	if bytes[0] == 255 and bytes[1] == 216:
		return image.load_jpg_from_buffer(bytes)
	return ERR_FILE_UNRECOGNIZED

func _save_material(entry: Dictionary, supplier: String, prefix: String, path: String, images: Dictionary) -> StandardMaterial3D:
	DirAccess.make_dir_recursive_absolute(TEXTURES)
	DirAccess.make_dir_recursive_absolute(MATERIALS)
	var paths := {}
	for key: String in images:
		var texture_path := "%s/%s_%s.png" % [TEXTURES, prefix, key]
		if not FileAccess.file_exists(texture_path) and images[key].save_png(texture_path) != OK:
			return null
		if not FileAccess.file_exists(texture_path + ".import"):
			var settings := ConfigFile.new()
			settings.set_value("remap", "importer", "texture")
			settings.set_value("remap", "type", "CompressedTexture2D")
			settings.set_value("deps", "source_file", texture_path)
			settings.set_value("params", "mipmaps/generate", true)
			settings.set_value("params", "detect_3d/compress_to", 0)
			settings.set_value("params", "compress/normal_map", 1 if key == "normal" else 2)
			settings.set_value("params", "roughness/mode", 1)
			if settings.save(texture_path + ".import") != OK:
				return null
		paths[key] = texture_path
	var filesystem := _editor.get_resource_filesystem()
	var deadline := Time.get_ticks_msec() + 30000
	while _editor_import_busy(filesystem) and Time.get_ticks_msec() < deadline:
		await get_tree().process_frame
	if not _textures_imported(paths.values()) and not _editor_import_busy(filesystem):
		filesystem.scan()
	while (_editor_import_busy(filesystem) or not _textures_imported(paths.values())) \
			and Time.get_ticks_msec() < deadline:
		await get_tree().process_frame
	if _editor_import_busy(filesystem) or not _textures_imported(paths.values()):
		return null
	var color := load(paths["color"]) as Texture2D
	if color == null:
		return null
	var material := StandardMaterial3D.new()
	material.resource_name = entry["title"]
	material.albedo_texture = color
	if paths.has("normal"):
		material.normal_enabled = true
		material.normal_texture = load(paths["normal"]) as Texture2D
	if paths.has("roughness"):
		material.roughness_texture = load(paths["roughness"]) as Texture2D
	if paths.has("metal"):
		material.metallic = 1.0
		material.metallic_texture = load(paths["metal"]) as Texture2D
	if paths.has("height"):
		material.heightmap_texture = load(paths["height"]) as Texture2D
	var dimensions: Variant = entry["data"].get("dimensions")
	if supplier == "polyhaven" and dimensions is Array and not dimensions.is_empty() \
			and float(dimensions[0]) > 0.0:
		material.set_meta("repeat_m", float(dimensions[0]) / 1000.0)
	var site := "https://polyhaven.com/a/" if supplier == "polyhaven" else "https://ambientcg.com/a/"
	material.set_meta("asset_source", site + str(entry["id"]))
	material.set_meta("asset_license", "CC0-1.0")
	if ResourceSaver.save(material, path) != OK:
		return null
	material.take_over_path(path)
	filesystem.update_file(path)
	return material

func _textures_imported(paths: Array) -> bool:
	for path: String in paths:
		var settings := ConfigFile.new()
		if settings.load(path + ".import") != OK:
			return false
		var destinations: Array = settings.get_value("deps", "dest_files", [])
		if destinations.is_empty():
			return false
		for imported: String in destinations:
			if not FileAccess.file_exists(imported):
				return false
	return true

func _editor_import_busy(filesystem: EditorFileSystem) -> bool:
	return filesystem.is_scanning() or (filesystem.has_method("is_importing") and filesystem.call("is_importing"))
