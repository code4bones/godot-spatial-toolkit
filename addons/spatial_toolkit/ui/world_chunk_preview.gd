@tool
extends Control
## Read-only rendering of the selected square's saved geometry.

const PreviewViewport := preload("res://addons/spatial_toolkit/core/chunk_preview_viewport.gd")
const ChunkThumbnail := preload("res://addons/spatial_toolkit/core/chunk_thumbnail.gd")
const MAX_CACHED_PREVIEWS := 8

var _path := ""
var _scene_hash := ""
var _cached_previews := {}
var _renders_remaining := 0
var _dirty := true
var _has_meshes := false
var _canvas: TextureRect
var _viewport: PreviewViewport
var _render_timeout: Timer
var _status: Label

func _ready() -> void:
	name = "ChunkPreview"
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_canvas = TextureRect.new()
	_canvas.name = "ChunkPreviewCanvas"
	_canvas.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_canvas.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_canvas.stretch_mode = TextureRect.STRETCH_SCALE
	add_child(_canvas)
	_canvas.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_ensure_viewport()
	_render_timeout = Timer.new()
	_render_timeout.one_shot = true
	_render_timeout.timeout.connect(_stop_rendering)
	add_child(_render_timeout)
	_status = Label.new()
	_status.name = "ChunkPreviewStatus"
	_status.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_status.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	add_child(_status)
	_status.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_canvas.resized.connect(_frame_preview)
	visibility_changed.connect(_on_visibility_changed)
	_on_visibility_changed()

func set_scene_path(path: String) -> void:
	if path == _path:
		return
	_path = path
	_dirty = true
	_has_meshes = false
	if is_node_ready():
		_show_status(atr("Select a square to preview.") if path.is_empty() else atr("Loading square preview…"))
		set_process(true)

func _on_visibility_changed() -> void:
	if not is_visible_in_tree():
		_stop_rendering()
	elif _dirty or not _has_preview_viewport() or _viewport.is_building():
		set_process(true)
	else:
		_frame_preview()

func _process(_delta: float) -> void:
	_ensure_viewport()
	if _dirty and not _viewport.clear_geometry():
		return
	if not is_visible_in_tree():
		set_process(false)
	elif _dirty:
		_load_preview()
	elif _viewport.is_building():
		if _viewport.step_geometry():
			_finish_geometry()
	else:
		set_process(false)

func _ensure_viewport() -> void:
	if _has_preview_viewport():
		return
	# An open dock can still own the plain SubViewport from before a script reload.
	_stop_rendering()
	var existing := get_node_or_null(^"ChunkPreviewViewport") as SubViewport
	if existing is PreviewViewport:
		_viewport = existing
		return
	if existing != null:
		remove_child(existing)
		existing.queue_free()
	_viewport = PreviewViewport.new()
	_viewport.name = "ChunkPreviewViewport"
	add_child(_viewport)
	_canvas.texture = _viewport.get_texture()
	_dirty = true
	_has_meshes = false

func _has_preview_viewport() -> bool:
	return is_instance_valid(_viewport) and _viewport is PreviewViewport

func _load_preview() -> void:
	_dirty = false
	_scene_hash = ""
	if _path.is_empty():
		_show_status(atr("Select a square to preview."))
		return
	if not _path.begins_with("res://"):
		_show_status(atr("Square preview unavailable."))
		return
	if DisplayServer.get_name() != "headless" and FileAccess.file_exists(_path):
		_scene_hash = FileAccess.get_sha256(_path)
		if _show_cached_preview():
			return
		if not _scene_hash.is_empty():
			var thumbnail := ChunkThumbnail.load_for_scene(_path, _scene_hash)
			if thumbnail != null:
				_show_thumbnail(_remember_preview(_path, _scene_hash, thumbnail))
				return

	# Saved scenes may reference script and graphics resources used by the editor.
	if not ResourceLoader.exists(_path, "PackedScene"):
		_show_status(atr("Square preview unavailable."))
		return
	var scene := ResourceLoader.load(_path, "PackedScene", ResourceLoader.CACHE_MODE_IGNORE) as PackedScene
	if scene == null:
		_show_status(atr("Square preview unavailable."))
		return
	_viewport.begin_geometry(scene.get_state())

func _show_cached_preview() -> bool:
	if _scene_hash.is_empty() or not _cached_previews.has(_path):
		return false
	var cached: Dictionary = _cached_previews[_path]
	_cached_previews.erase(_path)
	if cached["hash"] != _scene_hash:
		return false
	_cached_previews[_path] = cached
	_show_thumbnail(cached["texture"])
	return true

func _show_thumbnail(texture: Texture2D) -> void:
	_canvas.texture = texture
	_canvas.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_status.hide()
	_canvas.show()

func _remember_preview(path: String, digest: String, image: Image) -> ImageTexture:
	var texture := ImageTexture.create_from_image(image)
	_cached_previews.erase(path)
	_cached_previews[path] = {"hash": digest, "texture": texture}
	if _cached_previews.size() > MAX_CACHED_PREVIEWS:
		_cached_previews.erase(_cached_previews.keys()[0])
	return texture

func _cache_preview(path: String, digest: String) -> void:
	if path != _path or digest != _scene_hash or digest.is_empty() or not _has_meshes or not is_visible_in_tree():
		return
	var image := _viewport.get_texture().get_image()
	if image != null and not image.is_empty():
		_remember_preview(path, digest, image)

func _show_status(message: String) -> void:
	_canvas.hide()
	_stop_rendering()
	_status.text = message
	_status.show()

func _finish_geometry() -> void:
	_has_meshes = _viewport.has_geometry()
	if not _has_meshes:
		_show_status(atr("Square preview unavailable."))
		return
	_status.hide()
	_canvas.texture = _viewport.get_texture()
	_canvas.stretch_mode = TextureRect.STRETCH_SCALE
	_canvas.show()
	_frame_preview()

func _frame_preview() -> void:
	if not _has_meshes or not _has_preview_viewport() or not _canvas.is_visible_in_tree() \
			or minf(_canvas.size.x, _canvas.size.y) < 2.0:
		return
	var scale := minf(0.5, 512.0 / maxf(_canvas.size.x, _canvas.size.y))
	var dimensions := Vector2i(_canvas.size * scale).max(Vector2i(2, 2))
	_viewport.frame_geometry(dimensions)
	if DisplayServer.get_name() == "headless":
		_viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
		return
	# The Compatibility renderer can still use the old target size on the first draw.
	_renders_remaining = 2
	if not RenderingServer.frame_post_draw.is_connected(_on_frame_drawn):
		RenderingServer.frame_post_draw.connect(_on_frame_drawn)
	_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	# An idle editor may not draw both frames before it stops processing graphics.
	_render_timeout.start(0.75)

func _on_frame_drawn() -> void:
	_renders_remaining -= 1
	if _renders_remaining == 0:
		_stop_rendering()
		_cache_preview.call_deferred(_path, _scene_hash)

func _stop_rendering() -> void:
	if RenderingServer.frame_post_draw.is_connected(_on_frame_drawn):
		RenderingServer.frame_post_draw.disconnect(_on_frame_drawn)
	if is_instance_valid(_viewport):
		_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	if is_instance_valid(_render_timeout):
		_render_timeout.stop()
	_renders_remaining = 0

func _exit_tree() -> void:
	_stop_rendering()
