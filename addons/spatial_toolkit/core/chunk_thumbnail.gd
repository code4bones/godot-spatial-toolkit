@tool
extends RefCounted
## Optional image cache kept with each saved world revision.

const PreviewViewport := preload("res://addons/spatial_toolkit/core/chunk_preview_viewport.gd")
const SIZE := Vector2i(512, 320)
const DRAW_TIMEOUT_MSEC := 750

static func thumbnail_path(scene_path: String, digest: String) -> String:
	if digest.length() != 64 or not digest.is_valid_hex_number():
		return ""
	var filename := "%s.%s.png" % [scene_path.get_file().get_basename(), digest]
	return scene_path.get_base_dir().path_join(".previews").path_join(filename)

static func load_for_scene(scene_path: String, digest: String) -> Image:
	var path := thumbnail_path(scene_path, digest)
	if path.is_empty() or not FileAccess.file_exists(path):
		return null
	var image := Image.new()
	if image.load(path) != OK or image.get_size() != SIZE:
		return null
	return image

static func save_for_scene(parent: Node, state: SceneState, scene_path: String, cancelled: Callable) -> Error:
	if DisplayServer.get_name() == "headless":
		return ERR_SKIP
	var path := thumbnail_path(scene_path, FileAccess.get_sha256(scene_path))
	if path.is_empty():
		return ERR_FILE_CANT_READ
	var tree := parent.get_tree()
	var preview := PreviewViewport.new()
	parent.add_child(preview)
	preview.begin_geometry(state)
	while not preview.step_geometry():
		await tree.process_frame
		if not is_instance_valid(preview) or cancelled.call():
			if is_instance_valid(preview):
				preview.queue_free()
			return ERR_SKIP
	if not preview.has_geometry():
		preview.queue_free()
		return ERR_SKIP
	preview.frame_geometry(SIZE)
	var drawn := [false]
	var finish_draw := func() -> void: drawn[0] = true
	RenderingServer.frame_post_draw.connect(finish_draw, CONNECT_DEFERRED)
	preview.render_target_update_mode = SubViewport.UPDATE_ONCE
	var deadline := Time.get_ticks_msec() + DRAW_TIMEOUT_MSEC
	while not drawn[0] and Time.get_ticks_msec() < deadline:
		await tree.process_frame
		if not is_instance_valid(preview) or cancelled.call():
			break
	RenderingServer.frame_post_draw.disconnect(finish_draw)
	if not is_instance_valid(preview):
		return ERR_SKIP
	preview.render_target_update_mode = SubViewport.UPDATE_DISABLED
	var image: Image
	if drawn[0] and not cancelled.call():
		image = preview.get_texture().get_image()
	preview.queue_free()
	if cancelled.call():
		return ERR_SKIP
	if image == null or image.get_size() != SIZE:
		return ERR_TIMEOUT
	return _publish_image(image, path)

static func _publish_image(image: Image, path: String) -> Error:
	var error := DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	if error != OK:
		return error
	var temporary := path + ".tmp"
	error = image.save_png(temporary)
	if error == OK:
		error = DirAccess.rename_absolute(temporary, path)
	if error != OK and FileAccess.file_exists(temporary):
		DirAccess.remove_absolute(temporary)
	return error
