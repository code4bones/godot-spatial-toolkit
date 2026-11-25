"""Small JSON transport for local map preparation; no downloads or installs."""
import argparse
import platform
from pathlib import Path

from .preview import positive_number, prepare
from .preview_geometry import Geometry


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


def run(arguments):
    parser = JsonParser(description=__doc__, add_help=False)
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("check", add_help=False)
    generate = commands.add_parser("generate", add_help=False)
    generate.add_argument("--source", required=True, type=Path)
    generate.add_argument("--output", required=True, type=Path)
    generate.add_argument("--default-height", default="3")
    generate.add_argument("--level-height", default="3")
    generate.add_argument("--world-scale", type=float, default=1.0)
    generate.add_argument("--open-windows", action="store_true")
    generate.add_argument("--window-density", choices=("limited", "auto", "full"), default="auto")
    generate.add_argument("--window-limit", type=int, default=6)
    generate.add_argument("--window-every-n", type=int, default=5)
    generate.add_argument("--breakable-windows", action="store_true")
    args = parser.parse_args(arguments)
    if args.command == "check":
        return {"ok": True, "dependencies": check_dependencies()}
    if not args.source.is_absolute() or not args.output.is_absolute():
        raise ValueError("Source and output paths must be absolute")
    if not args.source.is_file():
        raise ValueError(f"Source file does not exist: {args.source}")
    default_height, level_height = positive_number(args.default_height), positive_number(args.level_height)
    if default_height is None or level_height is None:
        raise ValueError("Default height and level height must be finite positive metres")
    report = prepare(args.source, args.output, default_height, level_height,
                     overwrite=False, snapshot_source=True,
                     world_scale=args.world_scale, open_windows=args.open_windows,
                     window_density=args.window_density, window_limit=args.window_limit,
                     window_every_n=args.window_every_n, breakable_windows=args.breakable_windows)
    # Full reasons/provenance live in the report artifact. Bound the response even for
    # very large sources, and never include vertex arrays or source tags here.
    summary = {k: report[k] for k in ("input_features", "generated", "height_sources", "width_sources",
               "polygon_holes", "shared_road_vertices", "bounds_xz_m", "triangles", "settings", "dependencies",
               "game_transform", "facade_openings", "foundation")}
    summary["skipped_count"] = len(report["skipped"])
    summary["coincident_building_count"] = len(report.get("coincident_buildings", []))
    summary["skipped"] = [{"id": s["id"][:200], "reason": s["reason"][:300]} for s in report["skipped"][:20]]
    files = {
        suffix: str((args.output / f"export_preview.{suffix}.json").resolve())
        for suffix in ("meshes", "spatial", "report")}
    files["source"] = str((args.output / "source.geojson").resolve())
    return {"ok": True, "report": summary, "files": files}
