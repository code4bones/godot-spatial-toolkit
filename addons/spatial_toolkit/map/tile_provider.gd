@tool
extends RefCounted

const OSM_URL := "https://tile.openstreetmap.org/{z}/{x}/{y}.png"

var template: String

func _init(url_template: String) -> void:
	template = url_template

func is_valid() -> bool:
	var web_url := template.begins_with("http://") or template.begins_with("https://")
	return web_url and "{z}" in template and "{x}" in template and "{y}" in template

func tile_url(tile: Vector3i) -> String:
	return template.replace("{z}", str(tile.z)).replace("{x}", str(tile.x)).replace(
		"{y}", str(tile.y)).replace("{format}", "png")
