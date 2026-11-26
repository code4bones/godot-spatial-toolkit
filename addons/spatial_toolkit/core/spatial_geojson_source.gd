@tool
class_name SpatialGeoJSONSource
extends Resource
## A GeoJSON file to include when creating a map in Spatial.

@export_global_file("*.geojson", "*.json") var geojson_path := "":
	set(value):
		if resource_name.is_empty() or resource_name == geojson_path.get_file():
			resource_name = value.get_file()
		geojson_path = value
		emit_changed()
