@tool
class_name SpatialWindowStyle
extends Resource
## Window frame and its painted representation on building facades.

const Localization := preload("res://addons/spatial_toolkit/ui/editor_localization.gd")

enum DistantGrille { CENTER, NONE, CROSS, INDUSTRIAL }

## Optional frame mesh. Width runs along X, height along Y, and +Z faces outside.
@export var mesh: Mesh:
	set(value):
		mesh = value
		emit_changed()
## Overrides the frame mesh surface materials when assigned.
@export var material: Material:
	set(value):
		material = value
		emit_changed()
@export var frame_color := Color(0.19, 0.23, 0.25):
	set(value):
		frame_color = value
		emit_changed()
@export var glass_color := Color(0.19, 0.27, 0.32):
	set(value):
		glass_color = value
		emit_changed()
@export var distant_grille: DistantGrille = DistantGrille.CENTER:
	set(value):
		distant_grille = value
		emit_changed()


func validation_error() -> String:
	if not _finite_color(frame_color) or not _finite_color(glass_color):
		return Localization.translate("Window frame and glass colours must be finite.")
	if distant_grille not in DistantGrille.values():
		return Localization.translate("Unknown distant window grille pattern.")
	if mesh != null:
		var bounds := mesh.get_aabb()
		if mesh.get_surface_count() == 0 or not bounds.position.is_finite() or not bounds.end.is_finite() \
				or not bounds.size.is_finite() or bounds.size.z < 0.0 \
				or bounds.size.x <= 0.0 or is_zero_approx(bounds.size.x) \
				or bounds.size.y <= 0.0 or is_zero_approx(bounds.size.y):
			return Localization.translate("The frame mesh must have finite dimensions and nonzero width and height in the XY plane.")
	return ""


## Store inline style settings independently and keep explicit project resource references.
func copy_for_storage() -> SpatialWindowStyle:
	return duplicate() as SpatialWindowStyle if is_built_in() else self


func matches(other: SpatialWindowStyle) -> bool:
	if self == other:
		return true
	return other != null and is_built_in() and other.is_built_in() \
		and mesh == other.mesh and material == other.material \
		and frame_color == other.frame_color and glass_color == other.glass_color \
		and distant_grille == other.distant_grille


static func _finite_color(value: Color) -> bool:
	return is_finite(value.r) and is_finite(value.g) and is_finite(value.b) and is_finite(value.a)
