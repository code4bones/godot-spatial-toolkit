@tool
extends RefCounted
## Compact descriptions derived from the OSM features present in an editable square.

const Localization := preload("res://addons/spatial_toolkit/ui/editor_localization.gd")
const LAYERS: Array[String] = ["Water", "Landuse", "Roads", "Buildings", "Paths", "PlannedRoads"]
const LABELS := {
	"Water": "Water", "Landuse": "Land use", "Roads": "Roads",
	"Buildings": "Buildings", "Paths": "Paths", "PlannedRoads": "Planned roads",
}
const MAX_NAMES := 8
const MAX_NAME_LENGTH := 120

static func collect(chunk: Node) -> Dictionary:
	var counts := {}
	var names := {}
	for layer: String in LAYERS:
		var root := chunk.get_node_or_null("Generated/" + layer)
		if root == null:
			continue
		var ids := {}
		var labels := {}
		for feature: MeshInstance3D in root.find_children("*", "MeshInstance3D", true, false):
			var id := str(feature.get_meta("source_id", ""))
			if id.is_empty():
				continue
			ids[id] = true
			var tags: Variant = feature.get_meta("source_tags", {})
			if tags is Dictionary:
				var label := _name(tags)
				if not label.is_empty():
					labels[label] = true
		if ids.is_empty():
			continue
		counts[layer] = ids.size()
		var sorted := labels.keys()
		sorted.sort()
		names[layer] = sorted.slice(0, MAX_NAMES)
	return {"counts": counts, "names": names}

static func title(info: Dictionary) -> String:
	var names: Variant = info.get("names", {})
	if not names is Dictionary:
		return ""
	for layer: String in LAYERS:
		var labels := _labels(names.get(layer, []))
		if not labels.is_empty():
			return labels[0]
	return ""

static func describe(info: Dictionary) -> String:
	var counts: Variant = info.get("counts", {})
	var names: Variant = info.get("names", {})
	if not counts is Dictionary:
		return Localization.translate("OSM feature information is unavailable.")
	if not names is Dictionary:
		names = {}
	var lines := PackedStringArray()
	for layer: String in LAYERS:
		var count: Variant = counts.get(layer, 0)
		if not (count is int or count is float) or not is_finite(float(count)) or count <= 0:
			continue
		var line := "%s · %d" % [Localization.translate(LABELS[layer]), int(count)]
		var labels := _labels(names.get(layer, []))
		if not labels.is_empty():
			line += " — " + ", ".join(labels)
		lines.append(line)
	return "\n".join(lines) if not lines.is_empty() else Localization.translate("This square contains no OSM features.")

static func _name(tags: Dictionary) -> String:
	var raw: Variant = tags.get("name:ru", "")
	var value: String = raw.strip_edges() if raw is String else ""
	if value.is_empty():
		raw = tags.get("name", "")
		value = raw.strip_edges() if raw is String else ""
	return _clean_name(value)

static func _labels(value: Variant) -> PackedStringArray:
	var labels := PackedStringArray()
	if value is Array or value is PackedStringArray:
		for raw: Variant in value:
			if raw is String:
				var label := _clean_name(raw)
				if not label.is_empty() and not labels.has(label):
					labels.append(label)
			if labels.size() == MAX_NAMES:
				break
	return labels

static func _clean_name(value: String) -> String:
	var clean := ""
	for index in value.length():
		var character := value.unicode_at(index)
		clean += " " if character < 32 or character == 127 else value[index]
	return " ".join(clean.split(" ", false)).left(MAX_NAME_LENGTH)
