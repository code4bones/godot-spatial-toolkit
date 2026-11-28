extends Control
## Shows one direction and the current sensing or loss timer for each patrol.

const DETECTION_COLOR := Color(1.0, 0.73, 0.25)
const CHASE_COLOR := Color(1.0, 0.26, 0.28)
const OUTLINE := Color(0.025, 0.045, 0.065, 0.92)
const ARC_HALF_WIDTH := deg_to_rad(15.0)
const LANE_SPACING := 12.0

class Marker:
	var angle: float
	var fraction: float
	var chasing: bool

var _center := Vector2.ZERO
var _radius := 56.0
var _markers: Dictionary[int, Marker] = {}

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	hide()

func clear() -> void:
	_markers.clear()
	hide()

func update_display(center: Vector2, radius: float, origin: Vector3, camera_basis: Basis,
		contacts: Array[SpatialPatrolManager.ThreatIndicator], delta: float) -> void:
	_center = center
	_radius = radius
	var to_camera := camera_basis.orthonormalized().transposed()
	var markers: Dictionary[int, Marker] = {}
	for contact in contacts:
		var patrol := contact.patrol
		if not is_instance_valid(patrol):
			continue
		var id := patrol.get_instance_id()
		var marker: Marker = _markers.get(id)
		if marker == null:
			marker = Marker.new()
			marker.fraction = contact.fraction
		var offset := patrol.get_global_transform_interpolated().origin - origin
		marker.angle = direction_on_ring(to_camera * offset).angle()
		if contact.chasing and not contact.losing:
			marker.fraction = 1.0
		else:
			marker.fraction = move_toward(marker.fraction, contact.fraction, delta * 6.0)
		marker.chasing = contact.chasing
		markers[id] = marker
	_markers = markers
	visible = not _markers.is_empty()
	queue_redraw()

static func direction_on_ring(offset: Vector3) -> Vector2:
	# Camera-local forward is -Z. Keep rear bearings in the lower semicircle.
	var planar := Vector2(offset.x, offset.z)
	if planar.length_squared() <= offset.length_squared() * 0.0001:
		return Vector2.DOWN if offset.y < 0.0 else Vector2.UP
	return planar.normalized()

func _draw() -> void:
	var ids := _markers.keys()
	ids.sort()
	var lanes: Array[PackedFloat32Array] = []
	# Give chasers the innermost lane where several bearings coincide.
	for chasing: bool in [true, false]:
		for id: int in ids:
			var marker := _markers[id]
			if marker.chasing != chasing:
				continue
			var lane := _place_marker(lanes, marker.angle)
			_draw_marker(marker, _radius + lane * LANE_SPACING)

func _place_marker(lanes: Array[PackedFloat32Array], angle: float) -> int:
	for lane in lanes.size():
		var clear := true
		for other in lanes[lane]:
			if absf(angle_difference(angle, other)) < 2.0 * ARC_HALF_WIDTH + deg_to_rad(3.0):
				clear = false
				break
		if clear:
			lanes[lane].append(angle)
			return lane
	lanes.append(PackedFloat32Array([angle]))
	return lanes.size() - 1

func _draw_marker(marker: Marker, radius: float) -> void:
	var half_width := lerpf(deg_to_rad(4.0), ARC_HALF_WIDTH, marker.fraction)
	var thickness := lerpf(2.0, 4.5, marker.fraction)
	var alpha := marker.fraction if marker.chasing else lerpf(0.58, 1.0, marker.fraction)
	var color := Color(CHASE_COLOR if marker.chasing else DETECTION_COLOR, alpha)
	var outline := Color(OUTLINE, OUTLINE.a * alpha)
	var start := marker.angle - half_width
	var finish := marker.angle + half_width
	draw_arc(_center, radius, start, finish, 12, outline, thickness + 3.0, true)
	draw_arc(_center, radius, start, finish, 12, color, thickness, true)
	var direction := Vector2.from_angle(marker.angle)
	var side := direction.orthogonal() * 3.0
	var base := _center + direction * radius
	var chevron := PackedVector2Array([base - side, base + direction * 6.0, base + side])
	draw_polyline(chevron, outline, 4.0, true)
	draw_polyline(chevron, color, 2.0, true)
