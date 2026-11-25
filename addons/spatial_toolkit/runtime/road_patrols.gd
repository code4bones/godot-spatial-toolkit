extends Node3D
## Shares the projected road topology across individually saved robot instances.

const ROBOT := preload("res://addons/spatial_toolkit/runtime/patrol_robot.tscn")
const MODEL_FILE := "export_preview.spatial.json"
const ROBOT_COUNT := 6
const DRIVABLE := ["motorway", "trunk", "primary", "secondary", "tertiary",
	"motorway_link", "trunk_link", "primary_link", "secondary_link", "tertiary_link",
	"unclassified", "residential", "living_street", "service", "road", "track"]

@export_storage var points := PackedVector3Array()
@export_storage var edges := PackedInt32Array()
@export_storage var edge_source_ids := PackedStringArray()
var active := false
var _neighbors: Array[PackedInt32Array] = []

static func add_from_file(map: Node3D, path: String, save_nodes: bool) -> int:
	if map.has_node("RoadPatrols") or not FileAccess.file_exists(path):
		return 0
	var model: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if not model is Dictionary or not model.get("features") is Array:
		push_warning("Spatial Toolkit: invalid road model at " + path)
		return 0
	var scale_m := float(map.get_meta("world_scale", 1.0))
	var vertices := PackedVector3Array()
	var links := PackedInt32Array()
	var source_ids := PackedStringArray()
	var by_point: Dictionary = {}
	var seen: Dictionary = {}
	var features: Array = model["features"]
	var patrol_cuts := _patrol_clearances(model, path.get_base_dir())
	for index in features.size():
		if index > 0 and index % 256 == 0:
			await map.get_tree().process_frame
			if not is_instance_valid(map) or map.is_queued_for_deletion():
				return 0
		var feature: Dictionary = features[index]
		if feature.get("kind") != "road" or feature.get("status") != "existing":
			continue
		var highway: Variant = feature.get("source", {}).get("tags", {}).get("highway")
		if highway not in DRIVABLE:
			continue
		var id := str(feature.get("id", ""))
		var sections: Array = patrol_cuts.get(id, [feature["geometry"]["coordinates"]])
		for section: Array in sections:
			var previous := -1
			for coordinate: Array in section:
				var point := Vector2(snappedf(float(coordinate[0]), 0.00001),
					snappedf(float(coordinate[1]), 0.00001))
				if not by_point.has(point):
					by_point[point] = vertices.size()
					vertices.append(Vector3(point.x * scale_m, 0.08 * scale_m + 0.025, point.y * scale_m))
				var current: int = by_point[point]
				if previous >= 0 and current != previous:
					var link := Vector2i(mini(previous, current), maxi(previous, current))
					if not seen.has(link):
						seen[link] = true
						links.append(previous)
						links.append(current)
						source_ids.append(id)
				previous = current
	if links.is_empty():
		return 0
	var graph := (load("res://addons/spatial_toolkit/runtime/road_patrols.gd") as Script).new() as Node3D
	graph.name = "RoadPatrols"
	graph.points = vertices
	graph.edges = links
	graph.edge_source_ids = source_ids
	graph.set_meta("source", model.get("source", {}))
	graph.set_meta("cut_road_count", patrol_cuts.size())
	map.add_child(graph)
	if save_nodes:
		graph.owner = map
	return graph._spawn_robots(map if save_nodes else null, map.get_node_or_null("FlyPlayer") as Node3D)

static func _patrol_clearances(model: Dictionary, directory: String) -> Dictionary:
	if model.get("patrol_clearances") is Dictionary:
		return model["patrol_clearances"]
	var path := directory.path_join("building_clearances.json")
	if not FileAccess.file_exists(path):
		return {}
	var layout: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if layout is Dictionary and layout.get("version") == 1 and layout.get("patrols") is Dictionary:
		return layout["patrols"]
	return {}

func _ready() -> void:
	# An import builds an unsaved map in the tree before packing it.
	if get_parent().scene_file_path.is_empty():
		return
	var ground := get_parent().get_node_or_null("FlatGround") as MeshInstance3D
	if ground != null and ground.mesh != null and not points.is_empty():
		var ground_y := to_local(ground.to_global(Vector3(0.0, ground.get_aabb().end.y, 0.0))).y
		position.y += ground_y - points[0].y
	_neighbors.resize(points.size())
	for index in range(0, edges.size(), 2):
		var a := edges[index]
		var b := edges[index + 1]
		_neighbors[a].append(b)
		_neighbors[b].append(a)
	active = not edges.is_empty()

func _spawn_robots(scene_owner: Node, player: Node3D) -> int:
	var edge_count := edges.size() / 2
	var count := mini(ROBOT_COUNT, edge_count)
	var nearest := 0
	if player != null:
		var best := INF
		for index in edge_count:
			var center := (points[edges[index * 2]] + points[edges[index * 2 + 1]]) * 0.5
			var offset := center - player.position
			var distance := Vector2(offset.x, offset.z).length_squared()
			if distance < best:
				best = distance
				nearest = index
	for index in count:
		var edge_index := (nearest + floori(float(index) * edge_count / count)) % edge_count
		var start := edges[edge_index * 2]
		var finish := edges[edge_index * 2 + 1]
		var robot := ROBOT.instantiate() as Node3D
		robot.name = "PatrolRobot_%02d" % (index + 1)
		robot.from_vertex = start
		robot.to_vertex = finish
		robot.start_fraction = 0.35
		robot.route_seed = index + 1
		robot.position = points[start].lerp(points[finish], robot.start_fraction)
		var direction := points[finish] - points[start]
		robot.rotation.y = atan2(-direction.x, -direction.z)
		add_child(robot)
		if scene_owner != null:
			robot.owner = scene_owner
	return count

func next_vertex(current: int, previous: int, random: RandomNumberGenerator) -> int:
	var choices := _neighbors[current]
	if choices.size() <= 1:
		return previous
	var choice := random.randi_range(0, choices.size() - 2)
	var reverse := choices.find(previous)
	if reverse >= 0 and choice >= reverse:
		choice += 1
	return choices[choice]
