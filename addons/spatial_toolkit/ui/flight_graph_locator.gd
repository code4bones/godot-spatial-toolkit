@tool
extends RefCounted
## Locates a published graph belonging to a baked map in the editor.

const Graph := preload("res://addons/spatial_toolkit/runtime/patrol_graph.gd")
const FlightGraphService := preload("res://addons/spatial_toolkit/core/flight_graph_service.gd")

static func find_for_map(map_root: Node) -> String:
	if map_root == null:
		return ""
	var bake_manifest := str(map_root.get_meta("bake_manifest_path", ""))
	var candidates := FlightGraphService.manifest_locations(bake_manifest)
	if candidates.is_empty():
		return ""
	var bake_directory := ProjectSettings.localize_path(ProjectSettings.globalize_path(bake_manifest)).get_base_dir()
	candidates.append_array(PackedStringArray([bake_directory + "_navigation_world/manifest.json",
		bake_directory + "_navigation/manifest.json", bake_directory.path_join("manifest.json")]))
	for candidate in candidates:
		if FileAccess.file_exists(candidate) and Graph.read_manifest(candidate)["error"].is_empty():
			return candidate
	return ""
