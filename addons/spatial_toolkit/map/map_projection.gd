@tool
extends RefCounted

const MAX_LATITUDE := 85.0511287798066
const METRES_PER_LATITUDE_DEGREE := 111_195.0

# Measure the east-west span at the box's midpoint latitude.
static func bbox_size_m(bbox: Dictionary) -> Vector2:
	var south := float(bbox["south"])
	var north := float(bbox["north"])
	var longitude_span := float(bbox["east"]) - float(bbox["west"])
	if longitude_span < 0.0:
		longitude_span += 360.0
	var latitude := (north + south) * 0.5
	return Vector2(longitude_span * cos(deg_to_rad(latitude)), north - south) * METRES_PER_LATITUDE_DEGREE

# Keep normalized map coordinates in scalar doubles at high zoom levels.
static func longitude_to_x(longitude: float) -> float:
	return (longitude + 180.0) / 360.0

static func latitude_to_y(latitude: float) -> float:
	var phi := deg_to_rad(clampf(latitude, -MAX_LATITUDE, MAX_LATITUDE))
	return clampf((1.0 - asinh(tan(phi)) / PI) * 0.5, 0.0, 1.0)

static func x_to_longitude(x: float) -> float:
	return wrapf(x * 360.0 - 180.0, -180.0, 180.0)

static func y_to_latitude(y: float) -> float:
	return rad_to_deg(atan(sinh(PI * (1.0 - 2.0 * clampf(y, 0.0, 1.0)))))
