@tool
extends RefCounted
## Recover projected footprint rings from older generated meshes with flat roofs.


static func recover(mesh: Mesh, scale_factor: float) -> Dictionary:
	if mesh == null or not is_finite(scale_factor) or scale_factor <= 0.0:
		return {}
	var roof_y := mesh.get_aabb().end.y
	var edges := {}
	for surface in mesh.get_surface_count():
		var arrays := mesh.surface_get_arrays(surface)
		if not arrays[Mesh.ARRAY_NORMAL] is PackedVector3Array:
			continue
		var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
		var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX] if arrays[Mesh.ARRAY_INDEX] != null else PackedInt32Array()
		for offset in range(0, vertices.size() if indices.is_empty() else indices.size(), 3):
			var a := offset if indices.is_empty() else indices[offset]
			var b := offset + 1 if indices.is_empty() else indices[offset + 1]
			var c := offset + 2 if indices.is_empty() else indices[offset + 2]
			if (normals[a].y < 0.99 or normals[b].y < 0.99 or normals[c].y < 0.99
					or absf(vertices[a].y - roof_y) > 0.0001 or absf(vertices[b].y - roof_y) > 0.0001
					or absf(vertices[c].y - roof_y) > 0.0001):
				continue
			var points := PackedVector2Array([
				Vector2(vertices[a].x, vertices[a].z), Vector2(vertices[b].x, vertices[b].z),
				Vector2(vertices[c].x, vertices[c].z)])
			for index in 3:
				var from := points[index]
				var to := points[(index + 1) % 3]
				var edge := Vector4(from.x, from.y, to.x, to.y)
				var reverse := Vector4(to.x, to.y, from.x, from.y)
				if not edges.erase(reverse):
					if edges.has(edge):
						return {}
					edges[edge] = true
	var next := {}
	for edge: Vector4 in edges:
		var from := Vector2(edge.x, edge.y)
		var to := Vector2(edge.z, edge.w)
		if next.has(from) or from == to:
			return {}
		next[from] = to
	var polygons: Array = []
	var holes: Array[PackedVector2Array] = []
	while not next.is_empty():
		var start: Vector2 = next.keys()[0]
		var point := start
		var ring := PackedVector2Array()
		while next.has(point):
			ring.append(point / scale_factor)
			var step: Vector2 = next[point]
			next.erase(point)
			point = step
		if point != start or ring.size() < 3:
			return {}
		var area := _signed_area(ring)
		if area < 0.0:
			polygons.append({"boundary": ring, "area": -area, "rings": [_coordinates(ring)]})
		elif area > 0.0:
			holes.append(ring)
		else:
			return {}
	for hole in holes:
		var owner := {}
		for polygon: Dictionary in polygons:
			if ((owner.is_empty() or polygon["area"] < owner["area"])
					and Geometry2D.is_point_in_polygon(hole[0], polygon["boundary"])):
				owner = polygon
		if owner.is_empty():
			return {}
		owner["rings"].append(_coordinates(hole))
	if polygons.is_empty():
		return {}
	var parts: Array = []
	for polygon: Dictionary in polygons:
		parts.append(polygon["rings"])
	if parts.size() == 1:
		return {"type": "Polygon", "coordinates": parts[0]}
	return {"type": "MultiPolygon", "coordinates": parts}


static func _coordinates(ring: PackedVector2Array) -> Array:
	var coordinates := []
	for point in ring:
		coordinates.append([point.x, point.y])
	coordinates.append(coordinates[0])
	return coordinates


static func _signed_area(ring: PackedVector2Array) -> float:
	var doubled := 0.0
	var origin := ring[0]
	for index in range(1, ring.size() - 1):
		doubled += (ring[index] - origin).cross(ring[index + 1] - origin)
	return doubled * 0.5
