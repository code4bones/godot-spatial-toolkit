@tool
class_name SpatialBuildingLayer3D
extends "res://addons/spatial_toolkit/core/spatial_layer_3d.gd"
## Additional appearance controls shared by the building layer and its groups.

enum DecorativeWindows { INHERIT, SHOW, HIDE }

var _observed_roofs: Array[SpatialLayerAppearance] = []

@export_group("Building Appearance")
@export_storage var roof_material: Material:
	set(value):
		roof_material = value
		request_style_update(&"roof_material")
## Empty arrays inherit. Each building picks one variant using its source ID.
@export var roof_variants: Array[SpatialLayerAppearance] = []:
	set(value):
		for variant in _observed_roofs:
			variant.changed.disconnect(_roof_palette_changed)
		_observed_roofs.clear()
		roof_variants = value
		for variant in roof_variants:
			if variant != null and not variant.changed.is_connected(_roof_palette_changed):
				variant.changed.connect(_roof_palette_changed)
				_observed_roofs.append(variant)
		_roof_palette_changed()
## Set to -1 to inherit the facade's texture variation.
@export_range(-1.0, 1.0, 0.05) var facade_variation := -1.0:
	set(value):
		facade_variation = value
		request_style_update(&"facade_variation")
## Set to -1 to inherit the strength of the wear.
@export_range(-1.0, 1.0, 0.05) var facade_weathering := -1.0:
	set(value):
		facade_weathering = value
		request_style_update(&"facade_weathering")
@export_group("Windows")
@export var decorative_windows: DecorativeWindows = DecorativeWindows.INHERIT:
	set(value):
		decorative_windows = value
		request_style_update(&"decorative_windows")
## Leave empty to inherit the window style from the parent building group.
@export var window_style: SpatialWindowStyle:
	set(value):
		if window_style == value:
			return
		if window_style != null:
			window_style.changed.disconnect(_window_style_changed)
		window_style = value
		if window_style != null:
			window_style.changed.connect(_window_style_changed)
		_window_style_changed()
## Leave empty to inherit decorative window placement and night occupancy.
@export var window_layout: SpatialWindowLayout:
	set(value):
		if window_layout == value:
			return
		if window_layout != null:
			window_layout.changed.disconnect(_window_layout_changed)
		window_layout = value
		if window_layout != null:
			window_layout.changed.connect(_window_layout_changed)
		_window_layout_changed()


func _roof_palette_changed() -> void:
	request_style_update(&"roof_variants")


func _window_style_changed() -> void:
	request_style_update(&"window_style")


func _window_layout_changed() -> void:
	request_style_update(&"window_layout")


func style_values() -> Dictionary:
	var values := super.style_values()
	if roof_variants.any(func(variant: SpatialLayerAppearance) -> bool: return variant != null):
		values["roof_variants"] = roof_variants
	elif roof_material != null:
		values["roof_material"] = roof_material
	if facade_variation >= 0.0:
		values["facade_variation"] = facade_variation
	if facade_weathering >= 0.0:
		values["facade_weathering"] = facade_weathering
	if decorative_windows != DecorativeWindows.INHERIT:
		values["decorative_windows"] = decorative_windows
	if window_style != null:
		values["window_style"] = window_style
	if window_layout != null:
		values["window_layout"] = window_layout
	return values
