@tool
extends RefCounted

# Small MVP only: Polygon outer rings; no holes, roads or MultiPolygon geometry.
# Uses a local equirectangular approximation around the first WGS84 point.
const EARTH_RADIUS_M := 6378137.0

func generate(path: String) -> Dictionary:
    if not FileAccess.file_exists(path):
        return {"ok": false, "error": "File not found: " + path}
    var doc: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
    if typeof(doc) != TYPE_DICTIONARY or doc.get("type") != "FeatureCollection":
        return {"ok": false, "error": "Expected GeoJSON FeatureCollection"}
    var features: Array = doc.get("features", [])
    var origin := Vector2.ZERO
    var found_origin := false
    for feature in features:
        if typeof(feature) != TYPE_DICTIONARY:
            continue
        var geometry: Dictionary = feature.get("geometry", {})
        if geometry.get("type") != "Polygon":
            continue
        var rings: Array = geometry.get("coordinates", [])
        if rings.is_empty() or rings[0].is_empty():
            continue
        var first: Array = rings[0][0]
        if first.size() < 2:
            continue
        origin = Vector2(float(first[0]), float(first[1]))
        found_origin = true
        break
    if not found_origin:
        return {"ok": false, "error": "No Polygon coordinate found"}
    var group := Node3D.new()
    group.set_meta("geojson_source", path)
    group.set_meta("origin_lon_lat", origin)
    var count := 0
    for i in features.size():
        var feature: Variant = features[i]
        if typeof(feature) != TYPE_DICTIONARY:
            continue
        var properties: Dictionary = feature.get("properties", {})
        if not properties.has("building"):
            continue
        var geometry: Dictionary = feature.get("geometry", {})
        if geometry.get("type") != "Polygon":
            continue
        var rings: Array = geometry.get("coordinates", [])
        if rings.size() != 1:
            push_warning("Skipping Polygon with holes; support not yet implemented")
            continue
        var points := PackedVector2Array()
        for pair in rings[0]:
            if pair.size() < 2:
                continue
            points.append(_project(float(pair[0]), float(pair[1]), origin))
        if points.size() > 1 and points[0].distance_to(points[points.size()-1]) < 0.001:
            points.remove_at(points.size()-1)
        if points.size() < 3:
            continue
        var height := 3.0
        if properties.has("height"):
            height = max(0.1, _parse_metres(properties["height"], 3.0))
        elif properties.has("building:levels"):
            height = max(0.1, _parse_metres(properties["building:levels"], 1.0) * 3.0)
        var mesh := _extrude(points, height)
        if mesh == null:
            continue
        var instance := MeshInstance3D.new()
        instance.name = "Building_%d" % i
        instance.mesh = mesh
        instance.set_meta("source_id", str(feature.get("id", "feature_%d" % i)))
        instance.set_meta("height_m", height)
        group.add_child(instance)
        count += 1
    return {"ok": true, "node": group, "count": count}

func _parse_metres(value: Variant, fallback: float) -> float:
    var normalized := str(value).strip_edges().trim_suffix("m").strip_edges()
    if not normalized.is_valid_float():
        return fallback
    return float(normalized)

func _project(lon: float, lat: float, origin: Vector2) -> Vector2:
    var lon_rad := deg_to_rad(lon - origin.x)
    var lat_rad := deg_to_rad(lat - origin.y)
    return Vector2(EARTH_RADIUS_M * lon_rad * cos(deg_to_rad(origin.y)), EARTH_RADIUS_M * lat_rad)

func _extrude(poly: PackedVector2Array, height: float) -> ArrayMesh:
    var indices := Geometry2D.triangulate_polygon(poly)
    if indices.is_empty():
        push_warning("Polygon triangulation failed")
        return null
    var st := SurfaceTool.new()
    st.begin(Mesh.PRIMITIVE_TRIANGLES)
    # Top and bottom, double-sided via explicit opposite winding.
    for k in range(0, indices.size(), 3):
        var a: Vector2 = poly[indices[k]]
        var b: Vector2 = poly[indices[k+1]]
        var c: Vector2 = poly[indices[k+2]]
        _tri(st, Vector3(a.x, height, -a.y), Vector3(c.x, height, -c.y), Vector3(b.x, height, -b.y))
        _tri(st, Vector3(a.x, 0, -a.y), Vector3(b.x, 0, -b.y), Vector3(c.x, 0, -c.y))
    # Walls: emit both winding directions to tolerate original ring orientation.
    for i in poly.size():
        var p: Vector2 = poly[i]
        var q: Vector2 = poly[(i + 1) % poly.size()]
        var lo_p := Vector3(p.x, 0, -p.y)
        var lo_q := Vector3(q.x, 0, -q.y)
        var hi_p := Vector3(p.x, height, -p.y)
        var hi_q := Vector3(q.x, height, -q.y)
        _tri(st, lo_p, hi_p, hi_q)
        _tri(st, lo_p, hi_q, lo_q)
        _tri(st, hi_q, hi_p, lo_p)
        _tri(st, lo_q, hi_q, lo_p)
    st.generate_normals()
    return st.commit()

func _tri(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3) -> void:
    st.add_vertex(a)
    st.add_vertex(b)
    st.add_vertex(c)
