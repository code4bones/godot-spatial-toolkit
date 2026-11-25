@tool
extends VBoxContainer

signal material_imported(material: StandardMaterial3D)

const POLY := "https://api.polyhaven.com"
const AMBIENT := "https://ambientcg.com/api/v3/assets"
const AMBIENT_PAGE_SIZE := 500
const TEXTURES := "res://assets/textures"
const MATERIALS := "res://assets/materials"
const USER_AGENT := "GodotSpatialToolkit/0.7"
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
var _thumb := TextureRect.new()
var _message := Label.new()
var _import: Button
var _load: Button
var _busy := false
var _preview_request := HTTPRequest.new()
var _request := HTTPRequest.new()
var _catalogs: Dictionary = {}
var _local_files: Dictionary = {}

func setup(editor: EditorInterface) -> void:
	_editor = editor
	add_child(HSeparator.new())
	_provider.add_item("Poly Haven")
	_provider.add_item("ambientCG")
	_provider.item_selected.connect(func(_index: int) -> void:
		_refresh_filter(_query.text, false))
	add_child(_provider)
	var row := HBoxContainer.new()
	add_child(row)
	_query.placeholder_text = "Фильтр материалов"
	_query.clear_button_enabled = true
	_query.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_query.text_changed.connect(_refresh_filter)
	row.add_child(_query)
	_load = Button.new()
	_load.pressed.connect(_load_catalog)
	row.add_child(_load)
	_results.custom_minimum_size.y = 125
	_results.item_selected.connect(_select_item)
	add_child(_results)
	_thumb.custom_minimum_size.y = 88
	_thumb.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_thumb.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	add_child(_thumb)
	_import = Button.new()
	_import.text = "Импортировать 1K"
	_import.disabled = true
	_import.pressed.connect(_import_selected)
	add_child(_import)
	_message.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	add_child(_message)
	_request.timeout = 25.0
	_request.body_size_limit = 64 * 1024 * 1024
	add_child(_request)
	_preview_request.timeout = 10.0
	_preview_request.body_size_limit = 2 * 1024 * 1024
	_preview_request.request_completed.connect(_preview_completed)
	add_child(_preview_request)
	if _editor != null:
		_editor.get_resource_filesystem().filesystem_changed.connect(_refresh_local_materials)
	_refresh_local_materials()
	_refresh_filter(_query.text)

func _set_busy(value: bool, message: String) -> void:
	_busy = value
	_load.disabled = value
	_provider.disabled = value
	_update_import_button()
	_message.text = message

func _load_catalog() -> void:
	if _busy:
		return
	var provider := _provider.selected
	_set_busy(true, "Загрузка каталога…")
	var entries: Variant
	if provider == 0:
		entries = await _poly_catalog()
	else:
		entries = await _ambient_catalog()
	if entries == null:
		_set_busy(false, "Не удалось загрузить каталог %s." % _provider.get_item_text(provider))
		return
	entries.sort_custom(_entry_less)
	_catalogs[provider] = entries
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
	_results.clear()
	var loaded := _catalogs.has(_provider.selected)
	var entries: Array = _catalogs.get(_provider.selected, [])
	var terms := query.strip_edges().to_lower().split(" ", false)
	for entry: Dictionary in entries:
		if not _matches(terms, entry["filter_text"]):
			continue
		var index := _results.add_item(entry["title"])
		_results.set_item_metadata(index, entry)
		_mark_local_result(index, entry)
		if not selected_id.is_empty() and entry["id"] == selected_id:
			_results.select(index)
	var has_selection := not _results.get_selected_items().is_empty()
	if not has_selection:
		_preview_request.cancel_request()
		_thumb.texture = null
	_update_import_button()
	_load.text = "Обновить" if loaded else "Загрузить"
	if not _busy:
		_message.text = "Найдено: %d из %d" % [_results.item_count, entries.size()] if loaded else "Загрузите каталог материалов."

func _supplier() -> String:
	return "polyhaven" if _provider.selected == 0 else "ambientcg"

func _material_prefix(supplier: String, id: String) -> String:
	return "%s_%s_1k" % [supplier, id]

func _selected_entry() -> Dictionary:
	var selected := _results.get_selected_items()
	return {} if selected.is_empty() else _results.get_item_metadata(selected[0])

func _is_local(entry: Dictionary) -> bool:
	return not entry.is_empty() and _local_files.has(_material_prefix(_supplier(), entry["id"]) + ".tres")

func _refresh_local_materials() -> void:
	_local_files.clear()
	var directory := DirAccess.open(MATERIALS)
	if directory != null:
		for filename in directory.get_files():
			_local_files[filename] = true
	for index in _results.item_count:
		_mark_local_result(index, _results.get_item_metadata(index))
	_update_import_button()

func _mark_local_result(index: int, entry: Dictionary) -> void:
	var title: String = entry["title"]
	var local := _is_local(entry)
	_results.set_item_text(index, "✓ " + title if local else title)
	_results.set_item_tooltip(index, "%s · В проекте" % title if local else title)

func _update_import_button() -> void:
	var entry := _selected_entry()
	_import.text = "Выбрать из проекта" if _is_local(entry) else "Импортировать 1K"
	_import.disabled = _busy or entry.is_empty()

func _select_item(index: int) -> void:
	_update_import_button()
	_thumb.texture = null
	_preview_request.cancel_request()
	var item: Dictionary = _results.get_item_metadata(index)
	if _is_local(item):
		var path := MATERIALS.path_join(_material_prefix(_supplier(), item["id"]) + ".tres")
		var material := load(path) as StandardMaterial3D if FileAccess.file_exists(path) else null
		if material != null:
			_thumb.texture = material.albedo_texture
			return
	var url: String = item["thumb"]
	if url.begins_with("https://"):
		_preview_request.request(url, ["User-Agent: " + USER_AGENT])

func _preview_completed(result: int, code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	if result != HTTPRequest.RESULT_SUCCESS or code != 200:
		return
	var preview := Image.new()
	var decoded := preview.load_webp_from_buffer(body) if body.slice(0, 4).get_string_from_ascii() == "RIFF" \
		else _load_png_or_jpg(preview, body)
	if decoded == OK:
		_thumb.texture = ImageTexture.create_from_image(preview)

func _download(url: String) -> PackedByteArray:
	if not url.begins_with("https://") or _request.request(url, ["User-Agent: " + USER_AGENT]) != OK:
		return PackedByteArray()
	var response: Array = await _request.request_completed
	if response[0] != HTTPRequest.RESULT_SUCCESS or response[1] != 200:
		return PackedByteArray()
	return response[3]

func _get_json(url: String) -> Dictionary:
	var body := await _download(url)
	var parsed: Variant = JSON.parse_string(body.get_string_from_utf8()) if not body.is_empty() else null
	return parsed if parsed is Dictionary else {}

func _import_selected() -> void:
	var entry := _selected_entry()
	if _busy or entry.is_empty():
		return
	var supplier := _supplier()
	var id: String = entry["id"]
	if not _valid_id(id):
		_message.text = "Недопустимый идентификатор ассета."
		return
	var prefix := _material_prefix(supplier, id)
	var material_path := MATERIALS.path_join(prefix + ".tres")
	if FileAccess.file_exists(material_path):
		var existing := load(material_path) as StandardMaterial3D
		if existing != null:
			_use_material(entry, existing, "Материал выбран из проекта.")
			return
	_set_busy(true, "Загрузка %s…" % entry["title"])
	var images: Dictionary
	if supplier == "polyhaven":
		images = await _poly_images(id)
	else:
		images = await _ambient_images(id, prefix)
	if not images.has("color"):
		_set_busy(false, "Не удалось загрузить карту цвета 1K.")
		return
	var material := await _save_material(entry, supplier, prefix, material_path, images)
	if material == null:
		_set_busy(false, "Не удалось импортировать текстуры в Godot.")
		return
	_use_material(entry, material, "Импортирован %s." % entry["title"])

func _use_material(entry: Dictionary, material: StandardMaterial3D, message: String) -> void:
	_refresh_local_materials()
	if _selected_entry().get("id") == entry["id"]:
		_preview_request.cancel_request()
		_thumb.texture = material.albedo_texture
	material_imported.emit(material)
	_set_busy(false, message)

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
