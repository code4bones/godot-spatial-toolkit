@tool
class_name SpatialWindowLayout
extends Resource
## Placement and deterministic night occupancy of decorative facade windows.

const Localization := preload("res://addons/spatial_toolkit/ui/editor_localization.gd")
const DEFAULT_WIDTH_M := 1.42
const DEFAULT_MAX_HEIGHT_M := 1.25
const DEFAULT_SILL_M := 0.90
const DEFAULT_CEILING_CLEARANCE_M := 0.55
const DEFAULT_CORNER_CLEARANCE_M := 1.60
const DEFAULT_ROOM_PITCH_M := 2.75
const DEFAULT_RESIDENTIAL_SECTION_PITCH_M := 11.0
const DEFAULT_INDUSTRIAL_PITCH_M := 6.0
const DEFAULT_LIT_SECTION_FRACTION := 0.51

@export_group("Dimensions · Source Metres")
@export_range(0.1, 12.0, 0.01, "suffix:m") var width_m := DEFAULT_WIDTH_M:
	set(value):
		width_m = value
		emit_changed()
@export_range(0.1, 6.0, 0.01, "suffix:m") var max_height_m := DEFAULT_MAX_HEIGHT_M:
	set(value):
		max_height_m = value
		emit_changed()
@export_range(0.0, 6.0, 0.01, "suffix:m") var sill_m := DEFAULT_SILL_M:
	set(value):
		sill_m = value
		emit_changed()
@export_range(0.0, 6.0, 0.01, "suffix:m") var ceiling_clearance_m := DEFAULT_CEILING_CLEARANCE_M:
	set(value):
		ceiling_clearance_m = value
		emit_changed()
@export_range(0.0, 30.0, 0.01, "suffix:m") var corner_clearance_m := DEFAULT_CORNER_CLEARANCE_M:
	set(value):
		corner_clearance_m = value
		emit_changed()

@export_group("Window Groups")
@export_range(2.0, 30.0, 0.01, "suffix:m") var room_pitch_m := DEFAULT_ROOM_PITCH_M:
	set(value):
		room_pitch_m = value
		emit_changed()
@export_range(2.0, 100.0, 0.01, "suffix:m") var residential_section_pitch_m := DEFAULT_RESIDENTIAL_SECTION_PITCH_M:
	set(value):
		residential_section_pitch_m = value
		emit_changed()
@export_range(2.0, 100.0, 0.01, "suffix:m") var industrial_pitch_m := DEFAULT_INDUSTRIAL_PITCH_M:
	set(value):
		industrial_pitch_m = value
		emit_changed()
## Fraction of facade sections with illuminated windows at night.
@export_range(0.0, 1.0, 0.01) var lit_section_fraction := DEFAULT_LIT_SECTION_FRACTION:
	set(value):
		lit_section_fraction = value
		emit_changed()


func _validate_property(property: Dictionary) -> void:
	Localization.localize_inspector_group(property)


func values() -> Array[float]:
	return [width_m, max_height_m, sill_m, ceiling_clearance_m, corner_clearance_m,
		room_pitch_m, residential_section_pitch_m, industrial_pitch_m, lit_section_fraction]


func validation_error() -> String:
	for value in values():
		if not is_finite(value):
			return "Параметры раскладки окон должны быть конечными."
	if (width_m < 0.1 or width_m > 12.0 or max_height_m < 0.1 or max_height_m > 6.0
			or sill_m < 0.0 or sill_m > 6.0 or ceiling_clearance_m < 0.0 or ceiling_clearance_m > 6.0
			or corner_clearance_m < 0.0 or corner_clearance_m > 30.0 or room_pitch_m < 2.0 or room_pitch_m > 30.0
			or residential_section_pitch_m < 2.0 or residential_section_pitch_m > 100.0
			or industrial_pitch_m < 2.0 or industrial_pitch_m > 100.0
			or lit_section_fraction < 0.0 or lit_section_fraction > 1.0):
		return "Параметры раскладки окон выходят за допустимые пределы."
	return ""


func copy_for_storage() -> SpatialWindowLayout:
	return duplicate() as SpatialWindowLayout if is_built_in() else self


func matches(other: SpatialWindowLayout) -> bool:
	return self == other or (other != null and is_built_in() and other.is_built_in() and values() == other.values())
