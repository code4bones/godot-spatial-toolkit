@tool
extends RefCounted
## Source selection edited by the Spatial dock's native Inspector.

signal sources_changed

const GeoJSONSource := preload("res://addons/spatial_toolkit/core/spatial_geojson_source.gd")

@export var geojson_sources: Array[GeoJSONSource] = []:
	set(value):
		geojson_sources = value
		sources_changed.emit()
