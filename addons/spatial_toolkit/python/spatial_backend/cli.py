"""Small JSON transport for local map preparation; no downloads or installs."""
import argparse
import json
import platform
from pathlib import Path

from .osm_rules import parse_osm_rules
from .preview import MergeConflictError, positive_number, prepare
from .preview_geometry import Geometry
from .world_chunks import DEFAULT_CHUNK_SIZE_M, prepare_world_chunks
from .world_data import write_world_data


class JsonParser(argparse.ArgumentParser):
    def error(self, message):
        raise ValueError(message)


def check_dependencies():
    try:
        import pyproj
    except ImportError as exc:
        raise RuntimeError("Map generation requires pyproj installed in the selected Python environment") from exc
    with Geometry() as geometry:
        # Actually exercise constrained triangulation, including its area validation.
        geometry.polygon([[[0, 0], [1, 0], [1, 1], [0, 1], [0, 0]]])
        version = geometry.version
    return {"python": platform.python_version(), "pyproj": pyproj.__version__, "GEOS": version}


def _merge_summary(report):
    return {"source_count": len(report["sources"]), "unique_osm_ids": report["unique_osm_ids"],
            "identical_duplicates": report["identical_duplicates"], "conflict_count": len(report["conflicts"])}


def run(arguments, *, progress=None):
    parser = JsonParser(description=__doc__, add_help=False)
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("check", add_help=False)
    generate = commands.add_parser("generate", add_help=False)
    generate.add_argument("--source", required=True, type=Path)
    generate.add_argument("--merge-source", action="append", default=[], type=Path)
    generate.add_argument("--output", required=True, type=Path)
    generate.add_argument("--default-height", default="3")
    generate.add_argument("--level-height", default="3")
    generate.add_argument("--osm-rules")
    generate.add_argument("--world-scale", type=float, default=1.0)
    generate.add_argument("--open-windows", action="store_true")
    generate.add_argument("--window-density", choices=("limited", "auto", "full"), default="auto")
    generate.add_argument("--window-limit", type=int, default=6)
    generate.add_argument("--window-every-n", type=int, default=5)
    generate.add_argument("--aperture-options", type=json.loads)
    generate.add_argument("--breakable-windows", action="store_true")
    generate.add_argument("--origin-longitude", type=float)
    generate.add_argument("--origin-latitude", type=float)
    world = commands.add_parser("world-chunks", add_help=False)
    world.add_argument("--source", action="append", required=True, type=Path)
    world.add_argument("--output", required=True, type=Path)
    world.add_argument("--previous", type=Path)
    world.add_argument("--chunk-size", type=float, default=DEFAULT_CHUNK_SIZE_M)
    world.add_argument("--world-scale", type=float, default=1.0)
    world.add_argument("--default-height", type=float, default=3.0)
    world.add_argument("--level-height", type=float, default=3.0)
    world.add_argument("--osm-rules")
    data = commands.add_parser("world-data", add_help=False)
    data.add_argument("--world", required=True, type=Path)
    data.add_argument("--bake-features", required=True, type=Path)
    data.add_argument("--output", required=True, type=Path)
    args = parser.parse_args(arguments)
    if args.command == "check":
        return {"ok": True, "dependencies": check_dependencies()}
    if args.command == "world-data":
        return write_world_data(args.world, args.bake_features, args.output, progress=progress)
    osm_rules = parse_osm_rules(args.osm_rules) if args.osm_rules is not None else None
    if args.command == "world-chunks":
        try:
            plan = prepare_world_chunks(args.source, args.output, previous=args.previous,
                                        chunk_size=args.chunk_size, world_scale=args.world_scale,
                                        default_height=args.default_height, level_height=args.level_height,
                                        progress=progress, osm_rules=osm_rules)
        except MergeConflictError as error:
            return {"ok": False, "error": str(error), "merge": _merge_summary(error.report),
                    "conflict_report": str((args.output / "merge_conflicts.json").resolve())}
        return {"ok": True, "plan": str(plan)}
    if not args.output.is_absolute() or any(not path.is_absolute() for path in [args.source, *args.merge_source]):
        raise ValueError("Source and output paths must be absolute")
    for path in [args.source, *args.merge_source]:
        if not path.is_file():
            raise ValueError(f"Source file does not exist: {path}")
    if any(path.suffix.lower() not in {".geojson", ".json"} for path in args.merge_source):
        raise ValueError("Each merge source must be a .geojson or .json file")
    default_height, level_height = positive_number(args.default_height), positive_number(args.level_height)
    if default_height is None or level_height is None:
        raise ValueError("Default height and level height must be finite positive metres")
    if (args.origin_longitude is None) != (args.origin_latitude is None):
        raise ValueError("Specify both --origin-longitude and --origin-latitude")
    origin = (args.origin_longitude, args.origin_latitude) if args.origin_longitude is not None else None
    try:
        report = prepare(args.source, args.output, default_height, level_height,
                         overwrite=False, snapshot_source=True,
                         world_scale=args.world_scale, open_windows=args.open_windows,
                         window_density=args.window_density, window_limit=args.window_limit,
                         window_every_n=args.window_every_n, breakable_windows=args.breakable_windows,
                         local_origin=origin, additional_sources=args.merge_source,
                         progress=progress, osm_rules=osm_rules, aperture_options=args.aperture_options)
    except MergeConflictError as error:
        return {"ok": False, "error": str(error), "merge": _merge_summary(error.report)}
    # Full reasons/provenance live in the report artifact. Bound the response even for
    # very large sources, and never include vertex arrays or source tags here.
    summary = {k: report[k] for k in ("input_features", "generated", "height_sources", "width_sources",
               "polygon_holes", "shared_road_vertices", "bounds_xz_m", "triangles", "settings", "dependencies",
               "game_transform", "facade_openings", "foundation", "local_origin", "projection", "osm_rules")}
    summary["skipped_count"] = len(report["skipped"])
    summary["coincident_building_count"] = len(report.get("coincident_buildings", []))
    if "merge" in report:
        summary["merge"] = _merge_summary(report["merge"])
    summary["skipped"] = [{"id": s["id"][:200], "reason": s["reason"][:300]} for s in report["skipped"][:20]]
    files = {
        suffix: str((args.output / f"export_preview.{suffix}.json").resolve())
        for suffix in ("meshes", "spatial", "report")}
    files["source"] = str((args.output / "source.geojson").resolve())
    return {"ok": True, "report": summary, "files": files}
