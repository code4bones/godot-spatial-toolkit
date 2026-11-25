@tool
extends RefCounted

const DIRECTORY := "user://spatial_toolkit/tiles"
const FALLBACK_TTL := 7 * 24 * 60 * 60
const MONTHS := ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

static func read_tile(url: String) -> Dictionary:
	var file := FileAccess.open(_path(url), FileAccess.READ)
	if file == null:
		return {}
	var record: Variant = file.get_var()
	return record if record is Dictionary else {}

static func store_tile(url: String, body: PackedByteArray, response: PackedStringArray,
		previous: Dictionary) -> void:
	var headers: Dictionary = previous.get("headers", {}).duplicate()
	for header in response:
		var split := header.find(":")
		if split > 0:
			var name := header.left(split).to_lower()
			if name in ["cache-control", "expires", "age", "etag", "last-modified"]:
				headers[name] = header.substr(split + 1).strip_edges()
	var path := _path(url)
	var ttl := FALLBACK_TTL
	var must_validate := false
	var now := int(Time.get_unix_time_from_system())
	var expires := _http_time(headers.get("expires", ""))
	if expires >= 0:
		ttl = maxi(0, expires - now)
	for directive in str(headers.get("cache-control", "")).to_lower().split(","):
		var value := directive.strip_edges()
		if value == "no-store":
			if FileAccess.file_exists(path):
				DirAccess.remove_absolute(path)
			return
		if value == "no-cache":
			must_validate = true
		if value.begins_with("max-age="):
			ttl = maxi(0, value.substr(8).strip_edges().trim_prefix('"').trim_suffix('"').to_int()
				- str(headers.get("age", "0")).to_int())
	if must_validate:
		ttl = 0
	if DirAccess.make_dir_recursive_absolute(DIRECTORY) != OK:
		return
	var file := FileAccess.open(path + ".tmp", FileAccess.WRITE)
	if file != null:
		file.store_var({"body": body, "headers": headers, "expires": now + ttl})
		var error := file.get_error()
		file.close()
		if error == OK:
			DirAccess.rename_absolute(path + ".tmp", path)

static func _path(url: String) -> String:
	return DIRECTORY.path_join(url.sha256_text() + ".tile")

static func _http_time(value: String) -> int:
	var parts := value.split(" ", false)
	if parts.size() != 6 or parts[5] != "GMT":
		return -1
	var month := MONTHS.find(parts[2]) + 1
	if month == 0:
		return -1
	return Time.get_unix_time_from_datetime_string("%s-%02d-%sT%s" % [
		parts[3], month, parts[1], parts[4]])
