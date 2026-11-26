"""Defaults and validation for a reproducible OSM generation policy."""
import json
import math


DEFAULT_WIDTHS = {"tertiary": 9.0, "residential": 6.0, "service": 4.0,
                  "footway": 2.0, "steps": 2.0, "path": 2.0, "cycleway": 2.5}
DEFAULT_OSM_RULES = {"building_height_limits_m": (10.0, 24.0, 55.0),
                     "building_area_limits_m2": (250.0, 900.0, 2500.0),
                     "road_widths_m": DEFAULT_WIDTHS, "fallback_road_width_m": 4.0,
                     "lane_width_m": 3.2}


def _positive(value, field):
    if type(value) not in (int, float) or not math.isfinite(value) or value <= 0:
        raise ValueError(f"OSM {field} must be a finite positive number")
    return float(value)


def _ordered_limits(values, field):
    if not isinstance(values, (list, tuple)) or len(values) != 3:
        raise ValueError(f"OSM {field} must have three limits")
    limits = [_positive(value, field) for value in values]
    if not limits[0] < limits[1] < limits[2]:
        raise ValueError(f"OSM {field} must be in strictly increasing order")
    return limits


def normalize_osm_rules(rules=None):
    if rules is None:
        rules = {}
    if not isinstance(rules, dict) or rules.keys() - DEFAULT_OSM_RULES.keys():
        raise ValueError("OSM import settings contain unknown fields or are not an object")
    values = {**DEFAULT_OSM_RULES, **rules}
    widths = values["road_widths_m"]
    if not isinstance(widths, dict) or widths.keys() - DEFAULT_WIDTHS.keys():
        raise ValueError("OSM road widths contain unknown highway types or are not an object")
    return {
        "building_height_limits_m": _ordered_limits(values["building_height_limits_m"], "building height limits"),
        "building_area_limits_m2": _ordered_limits(values["building_area_limits_m2"], "building area limits"),
        "road_widths_m": {name: _positive(widths.get(name, default), f"{name} width in metres")
                          for name, default in DEFAULT_WIDTHS.items()},
        "fallback_road_width_m": _positive(values["fallback_road_width_m"], "fallback road width in metres"),
        "lane_width_m": _positive(values["lane_width_m"], "single-lane width in metres"),
    }


def parse_osm_rules(value):
    try:
        rules = json.loads(value)
    except json.JSONDecodeError as error:
        raise ValueError("OSM import settings are not valid JSON") from error
    return normalize_osm_rules(rules)
