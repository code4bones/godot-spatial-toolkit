extends Node3D
## Loads the deterministic relief layout recorded beside a map preview.

const Hill := preload("res://addons/spatial_toolkit/runtime/terrain_preview.gd")
const BATCH_SIZE := 8

@export_file("*.json") var layout_path := ""
@export_range(1.0, 100.0) var world_scale := 1.0

func _ready() -> void:
	if not FileAccess.file_exists(layout_path):
		return
	var layout: Variant = JSON.parse_string(FileAccess.get_file_as_string(layout_path))
	if not layout is Dictionary or layout.get("version") != 1 or not layout.get("hills") is Array:
		push_warning("Spatial Toolkit: invalid landscape relief layout " + layout_path)
		return
	var entries: Array = layout["hills"]
	for index in entries.size():
		var entry: Dictionary = entries[index]
		var center: Array = entry["center_m"]
		var hill := Hill.new()
		hill.name = "Hill%02d" % (index + 1)
		hill.world_scale = world_scale
		hill.position = Vector3(float(center[0]), 0.0, float(center[1])) * world_scale
		hill.radius_m = float(entry["radius_m"])
		hill.height_m = float(entry["height_m"])
		hill.source_id = str(entry["source_id"])
		hill.shape_seed = str(entry["seed"])
		add_child(hill)
		if (index + 1) % BATCH_SIZE == 0 and index + 1 < entries.size():
			await get_tree().process_frame
			if is_queued_for_deletion():
				return
