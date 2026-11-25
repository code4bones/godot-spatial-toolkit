@tool
extends RefCounted

const Rings := preload("osm_rings.gd")
const LAYERS := {
	"buildings": {"label": "Buildings", "filter": '["building"]["building"!="no"]'},
	"roads": {"label": "Roads", "filter": '["highway"]'},
	"water": {"label": "Water", "filter": '["natural"="water"]'},
	"landuse": {"label": "Land use", "filter": '["landuse"]'},
	"parks": {"label": "Parks", "filter": '["leisure"="park"]'},
}
const DEFAULT_LAYERS := ["buildings", "roads"]
const ENDPOINT := "https://overpass-api.de/api/interpreter"

static func normalize_endpoint(value: String) -> String:
	var address := value.strip_edges().rstrip("/")
	var scheme_end := address.find("://")
	if not address.begins_with("https://") and not address.begins_with("http://"):
		return ""
	var remainder := address.substr(scheme_end + 3)
	var authority := remainder.get_slice("/", 0)
	if authority.is_empty() or "@" in authority or "?" in remainder or "#" in remainder:
		return ""
	if address.contains(" ") or address.contains("\t") or address.contains("\n"):
		return ""
	return address if address.ends_with("/interpreter") else address + "/interpreter"

static func query(bbox: Dictionary, layers: Array) -> String:
	var box := "%.8f,%.8f,%.8f,%.8f" % [bbox["south"], bbox["west"], bbox["north"], bbox["east"]]
	var clauses := PackedStringArray()
	for layer: String in layers:
		var filter: String = LAYERS[layer]["filter"]
		clauses.append("way%s(%s);" % [filter, box])
		if layer != "roads":
			clauses.append('relation["type"="multipolygon"]%s(%s);' % [filter, box])
	return "[out:json][timeout:25];(%s);out geom;" % "".join(clauses)

static func area_km2(bbox: Dictionary) -> float:
	var latitude := (float(bbox["north"]) + float(bbox["south"])) * 0.5
	var width := fposmod(float(bbox["east"]) - float(bbox["west"]), 360.0)
	return width * (float(bbox["north"]) - float(bbox["south"])) * cos(deg_to_rad(latitude)) * 12364.0

static func convert(body: PackedByteArray, bbox: Dictionary, endpoint: String, layers: Array) -> Dictionary:
	var result: Variant = JSON.parse_string(body.get_string_from_utf8())
	if not result is Dictionary or not result.get("elements") is Array:
		return {"error": "Invalid Overpass response."}
	if result.has("remark"):
		return {"error": str(result["remark"])}
	var features: Array[Dictionary] = []
	var skipped := 0
	var relation_members: Dictionary = {}
	# A tagged outer member can also match the way query. The relation owns that area.
	for element: Variant in result["elements"]:
		if not element is Dictionary or element.get("type") != "relation":
			continue
		var tags: Variant = element.get("tags")
		if not tags is Dictionary or not _layer(tags) in layers or not element.has("id"):
			continue
		var members: Variant = element.get("members")
		if members is Array:
			for member: Variant in members:
				if member is Dictionary and member.get("type") == "way" and member.get("role", "") in ["outer", ""]:
					relation_members[[int(member.get("ref", 0)), _layer(tags)]] = true
		var polygons := Rings.polygons(members)
		if polygons.is_empty():
			skipped += 1
			continue
		features.append(_feature(element, tags, "Polygon" if polygons.size() == 1 else "MultiPolygon",
			polygons[0] if polygons.size() == 1 else polygons))
	for element: Variant in result["elements"]:
		if not element is Dictionary or element.get("type") != "way":
			continue
		var tags: Variant = element.get("tags")
		if not tags is Dictionary or not element.has("id"):
			skipped += 1
			continue
		var layer := _layer(tags)
		if not layer in layers or relation_members.has([int(element["id"]), layer]):
			continue
		var positions := Rings.position_list(element.get("geometry"))
		if positions.size() < 2 or (layer != "roads" and not Rings.closed(positions)):
			skipped += 1
			continue
		features.append(_feature(element, tags, "LineString" if layer == "roads" else "Polygon",
			positions if layer == "roads" else [positions]))
	return {"type": "FeatureCollection", "features": features,
		"source": {"provider": endpoint, "bbox": bbox, "layers": layers, "skipped": skipped,
			"osm3s": result.get("osm3s", {}), "attribution": "© OpenStreetMap contributors"}}

static func _layer(tags: Dictionary) -> String:
	if tags.get("building", "no") != "no":
		return "buildings"
	if tags.has("highway"):
		return "roads"
	if tags.has("landuse"):
		return "landuse"
	if tags.get("natural") == "water":
		return "water"
	if tags.get("leisure") == "park":
		return "parks"
	return ""

static func _feature(element: Dictionary, tags: Dictionary, geometry_type: String,
		coordinates: Array) -> Dictionary:
	return {"type": "Feature", "id": "%s/%d" % [element["type"], int(element["id"])],
		"properties": tags, "geometry": {"type": geometry_type, "coordinates": coordinates}}
