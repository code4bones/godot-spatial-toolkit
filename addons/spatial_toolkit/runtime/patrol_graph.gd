class_name SpatialPatrolGraph
extends RefCounted
## Reads one published SNAV graph in the baked map's local gameplay metres.

const MAX_FILE_BYTES := 32 * 1024 * 1024
const MAX_MANIFEST_BYTES := 1024 * 1024
const MAX_NODES := 50000
const MAX_EDGES := 300000
const MAX_PORTALS := 100000
const HEADER_BYTES := 56
const NODE_BYTES := 24
const EDGE_BYTES := 36
const CHECKSUM_BYTES := 32
const FLIGHT_REGION_TOLERANCE := 0.0001

var points := PackedVector3Array()
var coverage := AABB()
var flight_regions: Array[AABB] = []
var flight_portals: Array[FlightPortal] = []
var _neighbors: Array[PackedInt32Array] = []
var _clearances: Array[PackedFloat64Array] = []

class FlightPortal:
	var nodes: Vector2i
	var from_region: AABB
	var to_region: AABB
	var position: Vector3
	var axis: int
	var clearance_m: float

	func _init(endpoints: Vector2i, from: AABB, to: AABB, point: Vector3, seam_axis: int, clearance: float) -> void:
		nodes = endpoints
		from_region = from
		to_region = to
		position = point
		axis = seam_axis
		clearance_m = clearance

class Snapshot extends RefCounted:
	var manifest: Dictionary
	var directory: String

	func open_chunk(chunk_id: String = "") -> Dictionary:
		return SpatialPatrolGraph._open_snapshot_chunk(directory, manifest, chunk_id)

	func read_portals() -> Dictionary:
		return SpatialPatrolGraph._read_snapshot_portals(directory, manifest)

func links(node_id: int, clearance_m: float) -> PackedInt32Array:
	var result := PackedInt32Array()
	if node_id < 0 or node_id >= _neighbors.size() or not is_finite(clearance_m) or clearance_m < 0.0:
		return result
	for index in _neighbors[node_id].size():
		if _clearances[node_id][index] >= clearance_m:
			result.append(_neighbors[node_id][index])
	return result

func covers_flight_segment(start: Vector3, finish: Vector3, clearance_m: float, single_region := false) -> bool:
	# Chunk volumes can meet at a seam. Apply clearance at the altitude limits
	# and join the intervals along the segment without filling unpublished cells.
	var direction := finish - start
	var length := direction.length()
	var axis := direction / length if length > FLIGHT_REGION_TOLERANCE else Vector3.ZERO
	var intervals: Array[Vector2] = []
	var regions := flight_regions
	if single_region and regions.is_empty() and coverage.has_volume():
		regions = [coverage]
	for coverage_region in regions:
		var region := _flight_region_with_clearance(coverage_region, clearance_m)
		if region.size.y <= 0.0:
			continue
		if region.has_point(start) and region.has_point(finish):
			return true
		if single_region:
			continue
		var entry: Variant = region.intersects_segment(start, finish)
		var exit: Variant = region.intersects_segment(finish, start)
		if entry is Vector3 and exit is Vector3:
			intervals.append(Vector2((entry - start).dot(axis), (exit - start).dot(axis)))
	intervals.sort_custom(func(first: Vector2, second: Vector2) -> bool: return first.x < second.x)
	var covered := 0.0
	for interval in intervals:
		if interval.x > covered + FLIGHT_REGION_TOLERANCE:
			break
		covered = maxf(covered, interval.y)
		if covered >= length - FLIGHT_REGION_TOLERANCE:
			return true
	return false

func covers_flight_shortcut(start: Vector3, finish: Vector3, clearance_m: float) -> bool:
	## Allow straight flight inside one tile or through a validated portal on a shared face.
	if covers_flight_segment(start, finish, clearance_m, true):
		return true
	var movement := finish - start
	for portal in flight_portals:
		if portal.clearance_m < clearance_m or is_zero_approx(movement[portal.axis]):
			continue
		var from := _flight_region_with_clearance(portal.from_region, clearance_m)
		var to := _flight_region_with_clearance(portal.to_region, clearance_m)
		if not from.has_volume() or not to.has_volume():
			continue
		if not ((from.has_point(start) and to.has_point(finish)) or (to.has_point(start) and from.has_point(finish))):
			continue
		var seam := minf(portal.from_region.end[portal.axis], portal.to_region.end[portal.axis])
		var fraction := (seam - start[portal.axis]) / movement[portal.axis]
		if fraction < 0.0 or fraction > 1.0:
			continue
		var crossing := start.lerp(finish, fraction)
		var margin := portal.clearance_m - clearance_m
		if crossing.distance_squared_to(portal.position) <= margin * margin \
				and from.has_point(crossing) and to.has_point(crossing):
			return true
	return false

static func _flight_region_with_clearance(volume: AABB, clearance_m: float) -> AABB:
	var region := volume.grow(FLIGHT_REGION_TOLERANCE)
	region.position.y += clearance_m
	region.size.y -= 2.0 * clearance_m
	return region

static func open_manifest(path: String, chunk_id: String = "") -> Dictionary:
	var opened := read_manifest(path)
	if not opened["error"].is_empty():
		return _error(opened["error"])
	var snapshot: Snapshot = opened["snapshot"]
	return snapshot.open_chunk(chunk_id)

static func read_manifest(path: String) -> Dictionary:
	## Keep this snapshot while opening chunks so publication cannot mix generations.
	var raw := _read_bytes(path, MAX_MANIFEST_BYTES)
	if raw.is_empty():
		return {"snapshot": null, "error": "Cannot read navigation manifest: " + path}
	var parsed := JSON.new()
	if parsed.parse(raw.get_string_from_utf8()) != OK or not parsed.data is Dictionary:
		return {"snapshot": null, "error": "Navigation manifest must be a JSON object."}
	var manifest: Dictionary = parsed.data
	var axes: Variant = manifest.get("axes")
	if manifest.get("format") != "spatial_navigation" or manifest.get("schema") != 1 \
			or manifest.get("units") != "gameplay_meters" or not axes is Dictionary \
			or axes != {"x": "east", "y": "up", "z": "south"}:
		return {"snapshot": null, "error": "Unsupported navigation manifest or coordinate system."}
	var chunks: Variant = manifest.get("chunks")
	if not chunks is Dictionary or chunks.is_empty():
		return {"snapshot": null, "error": "Navigation manifest must contain at least one chunk."}
	var snapshot := Snapshot.new()
	snapshot.directory = path.get_base_dir()
	snapshot.manifest = manifest
	return {"snapshot": snapshot, "error": ""}

static func _open_snapshot_chunk(directory: String, manifest: Dictionary, chunk_id: String) -> Dictionary:
	var chunks: Dictionary = manifest["chunks"]
	if chunk_id.is_empty():
		if chunks.size() != 1:
			return _error("Select a chunk ID from the navigation world manifest.")
		chunk_id = str(chunks.keys()[0])
	if not _matches(chunk_id, "^[A-Za-z0-9_-]{1,80}$") or not chunks.get(chunk_id) is Dictionary:
		return _error("Requested navigation chunk is missing or invalid.")
	var entry: Dictionary = chunks[chunk_id]
	var digest: Variant = entry.get("sha256")
	if not digest is String or not _matches(digest, "^[0-9a-f]{64}$"):
		return _error("Navigation chunk checksum is invalid.")
	var relative := "chunks/%s-%s.snav" % [chunk_id, digest]
	if entry.get("path") != relative:
		return _error("Navigation chunk path must stay inside the manifest directory.")
	var chunk_path := directory.path_join(relative)
	if _is_link(chunk_path) or _is_link(chunk_path.get_base_dir()):
		return _error("Navigation chunk path must be a regular local file.")
	var data := _read_bytes(chunk_path, MAX_FILE_BYTES)
	if data.is_empty() or _sha256(data).hex_encode() != digest:
		return _error("Navigation chunk checksum does not match the manifest.")
	return _decode(data, chunk_id, manifest, entry)

static func _read_snapshot_portals(directory: String, manifest: Dictionary) -> Dictionary:
	if not manifest.has("portals"):
		if manifest["chunks"].size() > 1:
			return {"portals": [], "error": "Navigation world is missing its portal catalog."}
		return {"portals": [], "error": ""}
	var entry: Variant = manifest["portals"]
	if not entry is Dictionary or not entry.get("sha256") is String \
			or not _matches(entry["sha256"], "^[0-9a-f]{64}$") or not _number(entry.get("count")) \
			or entry["count"] < 0 or entry["count"] > MAX_PORTALS or entry["count"] != floor(entry["count"]):
		return {"portals": [], "error": "Invalid navigation portal descriptor."}
	var relative := "portals/%s.json" % entry["sha256"]
	var portal_path := directory.path_join(relative)
	if entry.get("path") != relative or _is_link(portal_path) or _is_link(portal_path.get_base_dir()):
		return {"portals": [], "error": "Navigation portal path must be a regular file inside the manifest directory."}
	var raw := _read_bytes(portal_path, MAX_FILE_BYTES)
	if raw.is_empty() or _sha256(raw).hex_encode() != entry["sha256"]:
		return {"portals": [], "error": "Navigation portal checksum failed."}
	var parsed := JSON.new()
	if parsed.parse(raw.get_string_from_utf8()) != OK or not parsed.data is Dictionary:
		return {"portals": [], "error": "Navigation portals must be a JSON object."}
	var document: Dictionary = parsed.data
	var portals: Variant = document.get("portals")
	if not _number(document.get("schema")) or document["schema"] != 1 or not portals is Array or portals.size() > MAX_PORTALS \
			or portals.size() != entry.get("count"):
		return {"portals": [], "error": "Navigation portal schema or count is invalid."}
	var previous_id := ""
	var endpoint_pairs: Dictionary = {}
	for portal: Variant in portals:
		if not portal is Dictionary or not portal.get("id") is String \
				or not _matches(portal["id"], "^[0-9a-f]{64}$") or portal["id"] <= previous_id:
			return {"portals": [], "error": "Navigation portal IDs must be sorted and unique."}
		previous_id = portal["id"]
		for side: String in ["from", "to"]:
			var node: Variant = portal.get(side + "_node")
			if not portal.get(side + "_chunk") is String or not _number(node) \
					or not _matches(portal[side + "_chunk"], "^[A-Za-z0-9_-]{1,80}$") \
					or node < 0 or node != floor(node):
				return {"portals": [], "error": "Navigation portal endpoints are invalid."}
			var chunk: Variant = manifest["chunks"].get(portal[side + "_chunk"])
			if not chunk is Dictionary or not _number(chunk.get("node_count")) \
					or chunk["node_count"] < 0 or chunk["node_count"] > MAX_NODES \
					or chunk["node_count"] != floor(chunk["node_count"]) or node >= chunk["node_count"]:
				return {"portals": [], "error": "A navigation portal references a missing chunk or node."}
		if portal["from_chunk"] == portal["to_chunk"] or _point(portal.get("position")) == null \
				or not _number(portal.get("distance_m")) or portal["distance_m"] <= 0 \
				or not _number(portal.get("clearance_m")) or portal["clearance_m"] < 0:
			return {"portals": [], "error": "Navigation portal coordinates or metrics are invalid."}
		var endpoints: Array[String] = ["%s:%d" % [portal["from_chunk"], int(portal["from_node"])],
			"%s:%d" % [portal["to_chunk"], int(portal["to_node"])]]
		endpoints.sort()
		var pair := endpoints[0] + "/" + endpoints[1]
		if endpoint_pairs.has(pair):
			return {"portals": [], "error": "Navigation portals repeat an endpoint pair."}
		endpoint_pairs[pair] = true
	return {"portals": portals, "error": ""}


static func _decode(data: PackedByteArray, chunk_id: String, manifest: Dictionary, entry: Dictionary) -> Dictionary:
	if data.size() < HEADER_BYTES + CHECKSUM_BYTES or data.slice(0, 4).get_string_from_ascii() != "SNAV" \
			or data.decode_u16(4) != 1 or data.decode_u16(6) != 0 or data.decode_u32(44) != 0:
		return _error("Unsupported or truncated navigation chunk header.")
	var origin := _point(manifest.get("origin"))
	var binary_origin := Vector3(data.decode_double(8), data.decode_double(16), data.decode_double(24))
	if origin == null or not binary_origin.is_finite() or origin != binary_origin:
		return _error("Navigation chunk origin does not match the manifest.")
	for axis in 3:
		if data.decode_double(8 + axis * 8) != float(manifest["origin"][axis]):
			return _error("Navigation chunk origin does not match the manifest.")
	var id_size := int(data.decode_u32(32))
	var node_count := int(data.decode_u32(36))
	var edge_count := int(data.decode_u32(40))
	var components := int(data.decode_u32(48))
	var metadata_size := int(data.decode_u32(52))
	if id_size < 1 or id_size > 80 or node_count > MAX_NODES or edge_count > MAX_EDGES \
			or components > node_count or (node_count > 0 and components == 0) \
			or node_count - components > edge_count:
		return _error("Navigation chunk counts exceed supported limits.")
	var nodes_offset := HEADER_BYTES + id_size
	var edges_offset := nodes_offset + node_count * NODE_BYTES
	var metadata_offset := edges_offset + edge_count * EDGE_BYTES
	var checksum_offset := metadata_offset + metadata_size
	if checksum_offset + CHECKSUM_BYTES != data.size() \
			or data.slice(HEADER_BYTES, nodes_offset).get_string_from_ascii() != chunk_id:
		return _error("Navigation chunk section sizes or ID are invalid.")
	if _sha256(data.slice(0, checksum_offset)) != data.slice(checksum_offset):
		return _error("Navigation chunk internal checksum failed.")
	if entry.get("byte_count") != data.size() or entry.get("node_count") != node_count \
			or entry.get("edge_count") != edge_count or entry.get("component_count") != components:
		return _error("Navigation manifest counts disagree with the chunk.")
	var parsed := JSON.new()
	if parsed.parse(data.slice(metadata_offset, checksum_offset).get_string_from_utf8()) != OK \
			or not parsed.data is Dictionary:
		return _error("Navigation metadata must be a JSON object.")
	var metadata: Dictionary = parsed.data
	var grid: Variant = manifest.get("chunk_size_m")
	if not _number(grid) or grid <= 0.0 or metadata.get("grid_size_m", grid) != grid \
			or metadata.get("cache_key") != entry.get("cache_key"):
		return _error("Navigation grid or cache key differs from the manifest.")
	var bounds: Variant = metadata.get("coverage")
	if not bounds is Array or bounds.size() != 6:
		return _error("Navigation coverage must contain six finite ordered coordinates.")
	var low: Variant = _point(bounds.slice(0, 3))
	var high: Variant = _point(bounds.slice(3, 6))
	if low == null or high == null or low.x >= high.x or low.y >= high.y or low.z >= high.z \
			or not (high - low).is_finite():
		return _error("Navigation coverage must have a finite positive extent.")
	var graph := SpatialPatrolGraph.new()
	graph.coverage = AABB(low, high - low)
	var previous_coordinates: Array[float] = []
	for index in node_count:
		var offset := nodes_offset + index * NODE_BYTES
		var coordinates: Array[float] = [data.decode_double(offset), data.decode_double(offset + 8), data.decode_double(offset + 16)]
		var point := Vector3(coordinates[0], coordinates[1], coordinates[2])
		if not point.is_finite() or not graph.coverage.grow(0.0001).has_point(point):
			return _error("Navigation node has invalid coordinates or is outside coverage.")
		if not previous_coordinates.is_empty() and not _point_precedes(previous_coordinates, coordinates):
			return _error("Navigation nodes must be sorted and unique.")
		previous_coordinates = coordinates
		graph.points.append(point)
		graph._neighbors.append(PackedInt32Array())
		graph._clearances.append(PackedFloat64Array())
	var previous_source := -1
	var previous_target := -1
	for index in edge_count:
		var offset := edges_offset + index * EDGE_BYTES
		var source := int(data.decode_u32(offset))
		var target := int(data.decode_u32(offset + 4))
		var distance := data.decode_double(offset + 8)
		var clearance := data.decode_double(offset + 16)
		var cost := data.decode_double(offset + 24)
		if source >= target or target >= node_count or source < previous_source \
				or (source == previous_source and target <= previous_target) \
				or not is_finite(distance) or distance <= 0.0 or not is_finite(clearance) \
				or clearance < 0.0 or not is_finite(cost) or cost < 0.0 or data.decode_u32(offset + 32) != 0:
			return _error("Navigation edge indices, order or metrics are invalid.")
		if graph.points[source] == graph.points[target]:
			return _error("Navigation edge collapses at Godot coordinate precision.")
		graph._neighbors[source].append(target)
		graph._clearances[source].append(clearance)
		graph._neighbors[target].append(source)
		graph._clearances[target].append(clearance)
		previous_source = source
		previous_target = target
	return {"graph": graph, "error": ""}

static func _read_bytes(path: String, limit: int) -> PackedByteArray:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null or file.get_length() < 1 or file.get_length() > limit:
		return PackedByteArray()
	return file.get_buffer(file.get_length())

static func _sha256(data: PackedByteArray) -> PackedByteArray:
	var hash := HashingContext.new()
	hash.start(HashingContext.HASH_SHA256)
	hash.update(data)
	return hash.finish()

static func _is_link(path: String) -> bool:
	var directory := DirAccess.open(path.get_base_dir())
	return directory != null and directory.is_link(path.get_file())

static func _matches(value: String, pattern: String) -> bool:
	var expression := RegEx.new()
	expression.compile(pattern)
	return expression.search(value) != null

static func _point(value: Variant) -> Variant:
	if not value is Array or value.size() != 3:
		return null
	for coordinate: Variant in value:
		if not _number(coordinate):
			return null
	var point := Vector3(value[0], value[1], value[2])
	return point if point.is_finite() else null

static func _number(value: Variant) -> bool:
	return (value is float or value is int) and is_finite(float(value))

static func _point_precedes(first: Array[float], second: Array[float]) -> bool:
	for axis in 3:
		if first[axis] != second[axis]:
			return first[axis] < second[axis]
	return false

static func _error(message: String) -> Dictionary:
	return {"graph": null, "error": message}
