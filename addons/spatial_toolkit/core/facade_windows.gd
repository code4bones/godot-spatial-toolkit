@tool
extends RefCounted
## Prepares generic decorative windows on saved building geometry during import.

const Layout := preload("res://addons/spatial_toolkit/runtime/facade_window_layout.gd")
const Atlas := preload("res://addons/spatial_toolkit/runtime/facade_window_atlas.gd")
const Footprint := preload("res://addons/spatial_toolkit/core/legacy_facade_footprint.gd")
const METADATA := &"facade_window_layout"
const GEOMETRY := &"spatial_facade_footprint"
const BASE_LAYOUT := &"spatial_default_window_layout"
const APPLIED_LAYOUT := &"spatial_applied_window_layout"
const INDUSTRIAL_TYPES := ["industrial", "warehouse", "factory", "service", "garage", "garages"]


static func floor_height_for(building: MeshInstance3D) -> float:
	var tags: Dictionary = building.get_meta("source_tags", {})
	var levels := str(tags.get("building:levels", ""))
	if levels.is_valid_float() and levels.to_float() > 0.0:
		return clampf(_wall_height(building) / levels.to_float(), 2.0, 6.0)
	return 3.0


static func prepare(building: MeshInstance3D, geometry: Dictionary, paint: bool) -> Dictionary:
	building.set_meta(GEOMETRY, geometry)
	return _prepare_layout(building, geometry, paint, SpatialWindowLayout.new())


static func is_citygml(building: MeshInstance3D) -> bool:
	return str(building.get_meta("source_id", "")).begins_with("citygml/")


static func prepare_citygml(building: MeshInstance3D, paint: bool) -> Dictionary:
	var source: Dictionary = building.get_meta("source", {})
	if source.get("modeled_openings", false):
		return prepare(building, {}, paint)
	var geometry: Dictionary = building.get_meta(GEOMETRY, {})
	if geometry.is_empty():
		geometry = Footprint.recover_ground(building.mesh, float(building.get_meta("world_scale", 1.0)))
	return prepare(building, geometry, paint)


## Return the current atlas for custom layouts. Clearing a rule restores the saved source layout.
static func relayout(building: MeshInstance3D, settings: SpatialWindowLayout, paint: bool) -> Dictionary:
	if not building.has_meta(METADATA):
		return {}
	if settings == null:
		if building.has_meta(BASE_LAYOUT):
			building.set_meta(METADATA, building.get_meta(BASE_LAYOUT))
			building.remove_meta(BASE_LAYOUT)
			building.remove_meta(APPLIED_LAYOUT)
		return {}
	var existing: Dictionary = building.get_meta(APPLIED_LAYOUT, {})
	if not settings.validation_error().is_empty():
		return existing
	var values := settings.values()
	if existing.get("values") == values and existing.get("paint") == paint:
		return existing
	var geometry: Dictionary = building.get_meta(GEOMETRY, {})
	if geometry.is_empty() and not is_citygml(building):
		geometry = Footprint.recover(building.mesh, float(building.get_meta("world_scale", 1.0)))
		if geometry.is_empty():
			return existing
		building.set_meta(GEOMETRY, geometry)
	if not building.has_meta(BASE_LAYOUT):
		building.set_meta(BASE_LAYOUT, building.get_meta(METADATA))
	var layout := _prepare_layout(building, geometry, paint, settings)
	layout["wall_count"] = layout["walls"].size()
	layout.erase("walls")
	layout["values"] = values
	layout["paint"] = paint
	building.set_meta(APPLIED_LAYOUT, layout)
	return layout


static func _prepare_layout(building: MeshInstance3D, geometry: Dictionary, paint: bool,
		settings: SpatialWindowLayout) -> Dictionary:
	var polygons: Array = geometry.get("coordinates", [])
	if geometry.get("type", "") == "Polygon":
		polygons = [polygons]
	var id := str(building.get_meta("source_id"))
	var tags: Dictionary = building.get_meta("source_tags", {})
	var kind := str(tags.get("building", ""))
	var industrial := kind in INDUSTRIAL_TYPES
	var wall_height := _wall_height(building)
	var floor_height := floor_height_for(building)
	var scale_factor := float(building.get_meta("world_scale", 1.0))
	var single_storey := wall_height <= floor_height + 0.001 or str(tags.get("building:levels", "")).to_float() == 1.0
	var runs: Array[Dictionary] = []
	if kind not in ["roof", "carport"] and not (single_storey and industrial):
		runs = Layout.build(polygons, Layout.long_facade_axis(polygons), industrial,
			id.hash(), settings.width_m * 0.5, settings)
	var openings: Dictionary = building.get_meta("facade_openings", {})
	var layout := Atlas.build(building.mesh, runs, scale_factor, floor_height, wall_height,
		0 if single_storey else 1, id.sha256_text().substr(0, 8).hex_to_int() % 997,
		openings.get("samples", []), paint, settings)
	var stored_walls: Array[Dictionary] = []
	var count := 0
	for wall: Dictionary in layout["walls"]:
		var normal: Vector2 = wall["normal"]
		var windows: Array[Dictionary] = []
		for window: Dictionary in wall["windows"]:
			var frame: Transform3D = window["frame"]
			var center := frame.origin * scale_factor
			var address: Vector2 = window["address"]
			var light: Color = window["light"]
			windows.append({"center": [center.x, center.y, center.z], "section": int(address.x),
				"floor": int(address.y), "emission": [light.r, light.g, light.b]})
		stored_walls.append({"normal": [normal.x, 0.0, normal.y], "windows": windows})
		count += windows.size()
	var vertical: Vector2 = layout["vertical"]
	building.set_meta(METADATA, {"version": 1, "coordinate_space": "building_local_gameplay_meters",
		"width_m": settings.width_m * scale_factor, "height_m": vertical.y * 2.0 * scale_factor,
		"count": count, "walls": stored_walls})
	return layout


static func _wall_height(building: MeshInstance3D) -> float:
	var dimensions: Dictionary = building.get_meta("source_dimensions_m", {})
	return float(dimensions.get("wall_height_m", building.get_meta("wall_height_m",
		building.get_meta("height_m", 3.0))))
