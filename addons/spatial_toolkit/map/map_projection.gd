@tool
extends RefCounted

const MAX_LATITUDE := 85.0511287798066

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
