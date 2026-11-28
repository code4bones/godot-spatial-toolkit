class_name SpatialNavigationDebugOverlay
extends Node3D
## Attach beneath the map root in a test scene. Positions are map-local gameplay metres.
## Load the CLI's optional debug JSON with load_file(), or assign debug_data_path.
## A failed load retains the previous visualization and exposes last_error.

const MAX_FILE_BYTES := 32 * 1024 * 1024
const MAX_NODES := 50000
const MAX_EDGES := 300000
const MAX_OBSTACLES := 10000
const BOX_EDGES := [[0, 1], [0, 2], [0, 4], [1, 3], [1, 5], [2, 3],
	[2, 6], [3, 7], [4, 5], [4, 6], [5, 7], [6, 7]]

@export_file("*.json") var debug_data_path := ""
@export_range(0.05, 10.0, 0.05, "or_greater") var node_marker_radius_m := 0.35

var last_error := ""
var _display: Node3D
var _counts: Dictionary = {}

func _ready() -> void:
	if not debug_data_path.is_empty() and not load_file(debug_data_path):
		push_warning("Spatial Toolkit: " + last_error)

func load_file(path: String) -> bool:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return _fail("Cannot open navigation debug data: " + path)
	if file.get_length() > MAX_FILE_BYTES:
		return _fail("Navigation debug data exceeds the file size limit.")
	var parser := JSON.new()
	if parser.parse(file.get_as_text()) != OK or not parser.data is Dictionary:
		return _fail("Navigation debug data must be a JSON object.")
	return load_data(parser.data)

func load_data(data: Dictionary) -> bool:
	var error := _validate(data)
	if not error.is_empty():
		return _fail(error)
	var prepared := Node3D.new()
	prepared.name = "NavigationDebug"
	var coverage_lines := PackedVector3Array()
	_append_box(coverage_lines, data["coverage"])
	_add_lines(prepared, "Coverage", coverage_lines, Color(0.2, 0.9, 0.4))
	var obstacle_lines := PackedVector3Array()
	for obstacle: Dictionary in data["obstacles"]:
		_append_box(obstacle_lines, obstacle["bounds"])
	_add_lines(prepared, "Obstacles", obstacle_lines, Color(1.0, 0.55, 0.15))
	var points := PackedVector3Array()
	for coordinate: Array in data["nodes"]:
		points.append(Vector3(coordinate[0], coordinate[1], coordinate[2]))
	var node_lines := PackedVector3Array()
	for point: Vector3 in points:
		for axis: Vector3 in [Vector3.RIGHT, Vector3.UP, Vector3.BACK]:
			node_lines.append(point - axis * node_marker_radius_m)
			node_lines.append(point + axis * node_marker_radius_m)
	_add_lines(prepared, "GraphNodes", node_lines, Color(0.2, 0.85, 1.0))
	var edge_lines := PackedVector3Array()
	for edge: Array in data["edges"]:
		edge_lines.append(points[int(edge[0])])
		edge_lines.append(points[int(edge[1])])
	_add_lines(prepared, "GraphEdges", edge_lines, Color(0.4, 0.6, 0.95))
	if is_instance_valid(_display):
		remove_child(_display)
		_display.free()
	_display = prepared
	# Leave the generated geometry unowned so it stays out of the scene file.
	add_child(_display)
	_counts = {"obstacle_count": data["obstacles"].size(), "node_count": points.size(),
		"edge_count": data["edges"].size()}
	last_error = ""
	return true

func summary() -> Dictionary:
	return _counts.duplicate()

func _validate(data: Dictionary) -> String:
	var axes: Variant = data.get("axes")
	if data.get("schema") != 1 or data.get("units") != "gameplay_meters" \
			or not axes is Dictionary or axes.get("x") != "east" \
			or axes.get("y") != "up" or axes.get("z") != "south":
		return "Unsupported navigation debug schema or coordinate system."
	if not _valid_bounds(data.get("coverage")):
		return "Coverage requires six finite ordered coordinates."
	if not _number(node_marker_radius_m) or node_marker_radius_m <= 0:
		return "Node marker radius must be positive and finite."
	var obstacles: Variant = data.get("obstacles")
	var nodes: Variant = data.get("nodes")
	var edges: Variant = data.get("edges")
	if not obstacles is Array or not nodes is Array or not edges is Array:
		return "Obstacles, nodes and edges must be arrays."
	if obstacles.size() > MAX_OBSTACLES or nodes.size() > MAX_NODES or edges.size() > MAX_EDGES:
		return "Navigation debug data exceeds visualization limits."
	var ids: Dictionary = {}
	for obstacle: Variant in obstacles:
		if not obstacle is Dictionary or not obstacle.get("source_id") is String \
				or obstacle["source_id"].is_empty() or ids.has(obstacle["source_id"]) \
				or not _valid_bounds(obstacle.get("bounds")):
			return "Each obstacle requires a unique source ID and finite ordered bounds."
		ids[obstacle["source_id"]] = true
	for point: Variant in nodes:
		if not _valid_point(point):
			return "Nodes require three finite coordinates."
	for edge: Variant in edges:
		if not edge is Array or edge.size() != 2 \
				or not _valid_index(edge[0], nodes.size()) or not _valid_index(edge[1], nodes.size()) \
				or edge[0] == edge[1]:
			return "Edges require two distinct existing node indices."
	return ""

func _valid_point(value: Variant) -> bool:
	if not value is Array or value.size() != 3:
		return false
	for component: Variant in value:
		if not _number(component):
			return false
	return Vector3(value[0], value[1], value[2]).is_finite()

func _valid_bounds(value: Variant) -> bool:
	if not value is Array or value.size() != 6:
		return false
	for component: Variant in value:
		if not _number(component):
			return false
	var minimum := Vector3(value[0], value[1], value[2])
	var maximum := Vector3(value[3], value[4], value[5])
	return minimum.is_finite() and maximum.is_finite() and (maximum - minimum).is_finite() \
		and minimum.x <= maximum.x and minimum.y <= maximum.y and minimum.z <= maximum.z

func _valid_index(value: Variant, size: int) -> bool:
	return _number(value) and float(value) == floor(float(value)) and float(value) >= 0 \
		and float(value) < size

func _number(value: Variant) -> bool:
	return (value is int or value is float) and is_finite(float(value))

func _append_box(lines: PackedVector3Array, bounds: Array) -> void:
	var corners := PackedVector3Array()
	for index: int in range(8):
		corners.append(Vector3(bounds[3] if index & 1 else bounds[0],
			bounds[4] if index & 2 else bounds[1], bounds[5] if index & 4 else bounds[2]))
	for edge: Array in BOX_EDGES:
		lines.append(corners[edge[0]])
		lines.append(corners[edge[1]])

func _add_lines(parent: Node3D, label: String, lines: PackedVector3Array, color: Color) -> void:
	if lines.is_empty():
		return
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.albedo_color = color
	var mesh := ArrayMesh.new()
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = lines
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_LINES, arrays)
	var instance := MeshInstance3D.new()
	instance.name = label
	instance.mesh = mesh
	instance.material_override = material
	instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	parent.add_child(instance)

func _fail(message: String) -> bool:
	last_error = message
	return false
