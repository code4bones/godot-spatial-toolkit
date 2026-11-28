"""Normalize building bounds from a Spatial Toolkit bake."""

from dataclasses import dataclass
import hashlib
import json
from pathlib import Path
import re

from ..merge import OSM_ID

from . import AXES, UNITS
from .graph import AABB, Obstacle, finite_number


CITYGML_ID = re.compile(r"citygml/[A-Za-z_][A-Za-z0-9_.-]{0,255}")


@dataclass(frozen=True)
class BakedWorld:
    obstacles: tuple[Obstacle, ...]
    provenance: dict


@dataclass(frozen=True)
class SpatialWorld:
    coverage: AABB
    obstacles: tuple[Obstacle, ...]
    provenance: dict


def _unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError(f"Duplicate JSON key {key!r}")
        result[key] = value
    return result


def _read_object(path):
    raw = path.read_bytes()
    try:
        result = json.loads(raw, object_pairs_hook=_unique_object)
    except (ValueError, RecursionError) as exc:
        raise ValueError(f"{path}: {exc}") from exc
    if not isinstance(result, dict):
        raise ValueError(f"{path}: expected a JSON object")
    return result, raw


def bounds_array(bounds):
    return [*bounds.minimum, *bounds.maximum]


def _building(source_id, data):
    if not (OSM_ID.fullmatch(source_id) or CITYGML_ID.fullmatch(source_id)):
        raise ValueError(f"Invalid building source ID {source_id!r}")
    bounds = data.get("bounds") if isinstance(data, dict) else None
    if not isinstance(bounds, list) or len(bounds) != 6:
        raise ValueError(f"Building {source_id} must have six bounds coordinates")
    coordinates = tuple(finite_number(value, f"Building {source_id} bounds") for value in bounds)
    if any(coordinates[axis] > coordinates[axis + 3] for axis in range(3)):
        raise ValueError(f"Building {source_id} bounds are reversed")
    return Obstacle(source_id, AABB(coordinates[:3], coordinates[3:]))


def _provenance(data):
    origin = data.get("local_origin")
    if not isinstance(origin, dict):
        raise ValueError("world_data.json is missing its geographic local_origin")
    longitude = finite_number(origin.get("longitude"), "local_origin.longitude")
    latitude = finite_number(origin.get("latitude"), "local_origin.latitude")
    if abs(longitude) > 180 or abs(latitude) > 90:
        raise ValueError("world_data.json local_origin is outside WGS84")
    scale = finite_number(data.get("world_scale"), "world_scale")
    if not 1 <= scale <= 100:
        raise ValueError("world_scale must be between 1 and 100")
    projection = data.get("projection")
    if not isinstance(projection, str) or not projection.strip():
        raise ValueError("world_data.json is missing its projection")
    revision = data.get("source_revision")
    if type(revision) is not int or revision < 1:
        raise ValueError("world_data.json source_revision must be a positive integer")
    result = {"source_revision": revision, "world_scale": scale, "projection": projection,
              "local_origin": {"longitude": longitude, "latitude": latitude}}
    for field in ("source_world_sha256", "source_registry_sha256"):
        digest = data.get(field)
        if not isinstance(digest, str) or not re.fullmatch(r"[a-f0-9]{64}", digest):
            raise ValueError(f"world_data.json {field} must be a SHA-256 digest")
        result[field] = digest
    return result


def load_world_data(path: Path, coverage: AABB, *, bake_manifest: Path | None = None) -> SpatialWorld:
    """Read an explicit coverage cell in the sidecar's already scaled map space."""
    if not isinstance(coverage, AABB) or any(a >= b for a, b in zip(coverage.minimum, coverage.maximum)):
        raise ValueError("Explicit navigation coverage must have positive extent on all three axes")
    world = load_baked_world(path, bake_manifest=bake_manifest)
    return SpatialWorld(coverage, world.obstacles, world.provenance)


def load_baked_world(path: Path, *, bake_manifest: Path | None = None) -> BakedWorld:
    """Read geometry and provenance once, independently of the navigation grid."""
    path = Path(path)
    data, _ = _read_object(path)
    if type(data.get("schema")) is not int or data["schema"] != 1:
        raise ValueError("Unsupported world_data.json schema; expected 1")
    if data.get("units") != UNITS or data.get("axes") != AXES:
        raise ValueError("world_data.json must use gameplay metres with X east, Y up and Z south")
    buildings = data.get("buildings")
    if not isinstance(buildings, dict):
        raise ValueError("world_data.json is missing its buildings object")
    provenance = _provenance(data)
    if bake_manifest is not None:
        manifest, raw = _read_object(Path(bake_manifest))
        for field in ("source_revision", "source_world_sha256", "world_scale"):
            if manifest.get(field) != provenance[field]:
                raise ValueError(f"Bake manifest and world_data.json disagree on {field}")
        provenance["bake_manifest_sha256"] = hashlib.sha256(raw).hexdigest()
    obstacles = tuple(_building(identity, buildings[identity]) for identity in sorted(buildings))
    return BakedWorld(obstacles, provenance)
