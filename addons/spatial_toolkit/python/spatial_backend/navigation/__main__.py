"""Build static navigation graphs from a locally baked map."""

import argparse
from dataclasses import asdict
import hashlib
import json
import os
from pathlib import Path
import sys
import tempfile

from . import AXES, UNITS
from .graph import AABB, GraphProfile, build_graph, finite_number, relevant_obstacles
from .storage import MANIFEST_NAMES, SCHEMA as STORAGE_SCHEMA, publish_chunk, validate_output
from .world_data import _read_object, bounds_array, load_world_data


GENERATOR_VERSION = 1


def _canonical_json(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":"), allow_nan=False).encode("utf-8")


def _write_debug_json(output, cache_key, coverage, obstacles, graph):
    directory = output / "debug"
    if directory.is_symlink():
        raise ValueError(f"Navigation debug directory may not be a symbolic link: {directory}")
    directory.mkdir(parents=True, exist_ok=True)
    path = directory / f"{cache_key}.json"
    value = {"schema": 1, "units": UNITS, "axes": AXES, "coverage": coverage,
             "obstacles": obstacles, "nodes": graph.nodes,
             "edges": [[edge.source, edge.target] for edge in graph.edges]}
    encoded = _canonical_json(value) + b"\n"
    descriptor, name = tempfile.mkstemp(dir=directory, prefix=".pending-")
    staging = Path(name)
    try:
        with os.fdopen(descriptor, "wb") as pending:
            pending.write(encoded)
        try:
            os.link(staging, path)
        except FileExistsError:
            if path.is_symlink() or path.read_bytes() != encoded:
                raise ValueError(f"Existing navigation debug file has different data: {path}") from None
    finally:
        staging.unlink(missing_ok=True)
    return str(path)


def build_chunk(world_data, output, *, chunk, heights, grid_origin=(0, 0), grid_size_m=256.0,
                profile, bake_manifest=None, debug_json=False):
    """Build and publish a caller-selected cell of known map coverage."""
    cell_x, cell_z = chunk
    if any(type(index) is not int or not -(2**31) <= index < 2**31 for index in chunk):
        raise ValueError("Chunk coordinates must be signed 32-bit indices")
    size = finite_number(grid_size_m, "Grid size")
    if size <= 0:
        raise ValueError("Grid size must be positive")
    origin_x, origin_z = (finite_number(value, "Grid origin") for value in grid_origin)
    low_y, high_y = (finite_number(value, "Height bound") for value in heights)
    minimum = (origin_x + cell_x * size, low_y, origin_z + cell_z * size)
    maximum = (origin_x + (cell_x + 1) * size, high_y, origin_z + (cell_z + 1) * size)
    minimum = tuple(finite_number(value, "Coverage minimum") for value in minimum)
    maximum = tuple(finite_number(value, "Coverage maximum") for value in maximum)
    coverage = AABB(minimum, maximum)
    world = load_world_data(world_data, coverage, bake_manifest=bake_manifest)
    obstacles = relevant_obstacles(world.coverage, world.obstacles, profile.clearance_m)
    graph = build_graph(world.coverage, obstacles, profile)
    chunk_id = f"{cell_x}_{cell_z}"
    origin = (origin_x, 0.0, origin_z)
    obstacle_data = [{"source_id": item.source_id, "bounds": bounds_array(item.bounds)} for item in obstacles]
    settings = {"generator_version": GENERATOR_VERSION, "storage_schema": STORAGE_SCHEMA,
                "coverage": bounds_array(world.coverage),
                "chunk_id": chunk_id, "origin": origin, "grid_size_m": size, "profile": asdict(profile),
                "clearance_m": profile.clearance_m, "obstacle_model": "closed_aabb"}
    cache_key = hashlib.sha256(_canonical_json({**settings, "obstacles": obstacle_data})).hexdigest()
    metadata = {**settings, "provenance": world.provenance, "cache_key": cache_key,
                "obstacle_source_ids": [item.source_id for item in obstacles]}
    output = Path(output).resolve()
    debug_path = None
    if debug_json:
        validate_output(output)
        debug_path = _write_debug_json(output, cache_key, settings["coverage"], obstacle_data, graph)
    result = publish_chunk(output, chunk_id=chunk_id, origin=origin, grid_size_m=size, graph=graph, metadata=metadata)
    result["obstacle_count"] = len(obstacles)
    if debug_path is not None:
        result["debug_json"] = debug_path
    return result


def _report_progress(done, total):
    payload = json.dumps({"done": done, "total": total}, separators=(",", ":"))
    print("PROGRESS " + payload, file=sys.stderr, flush=True)


def _project_path(value, project_root, label):
    if isinstance(value, str) and value.startswith("res://"):
        path = project_root / value[6:]
    elif isinstance(value, (str, Path)) and Path(value).is_absolute():
        path = Path(value)
    else:
        raise ValueError(f"{label} must be a res:// or absolute project path")
    resolved = path.resolve()
    if not resolved.is_relative_to(project_root) or resolved == project_root:
        raise ValueError(f"{label} must be inside the Godot project")
    return resolved


def _bake_inputs(bake_manifest, project_root):
    if not project_root.is_absolute():
        raise ValueError("Godot project root must be an absolute path")
    root = project_root.resolve()
    manifest_path = _project_path(bake_manifest, root, "Bake manifest")
    manifest, _ = _read_object(manifest_path)
    if not manifest.get("source_world"):
        raise ValueError("The bake has no source world. Assemble and bake a world to build its flight graph.")
    source = _project_path(manifest["source_world"], root, "Bake source_world")
    sidecar = _project_path(manifest.get("world_data_path", manifest_path.with_name("world_data.json")),
                            root, "Bake world_data_path")
    return root, manifest_path, source, sidecar


def run(arguments=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("world_data", type=Path, nargs="?", help="Path to the bake's world_data.json")
    parser.add_argument("--bake-manifest", type=Path, help="Record and cross-check the original bake manifest")
    parser.add_argument("--output", type=Path, required=True, help="Dedicated navigation output directory")
    parser.add_argument("--manifest-name", choices=MANIFEST_NAMES, help="Filename for a whole-map manifest")
    selection = parser.add_mutually_exclusive_group(required=True)
    selection.add_argument("--chunk", type=int, nargs=2, metavar=("X", "Z"),
                           help="Explicitly select one covered navigation cell by grid index")
    selection.add_argument("--world-index", type=Path,
                           help="Publish every covered cell using the bake's original world.json")
    selection.add_argument("--from-bake", type=Path, metavar="BAKE_MANIFEST",
                           help="Read whole-map inputs from a saved bake manifest")
    parser.add_argument("--project-root", type=Path, help="Root for resolving res:// paths in a saved bake")
    parser.add_argument("--height", type=float, nargs=2, required=True, metavar=("MIN_Y", "MAX_Y"),
                        help="Covered altitude range in local gameplay metres")
    parser.add_argument("--grid-origin", type=float, nargs=2, default=(0.0, 0.0), metavar=("X", "Z"))
    parser.add_argument("--grid-size", type=float, default=256.0, metavar="METRES")
    parser.add_argument("--agent-radius", type=float, required=True, metavar="METRES")
    parser.add_argument("--safety-margin", type=float, required=True, metavar="METRES")
    parser.add_argument("--sample-step", type=float, default=32.0, metavar="METRES")
    parser.add_argument("--max-neighbors", type=int, default=12)
    parser.add_argument("--debug-json", action="store_true", help="Also export geometry for the Godot overlay")
    parser.add_argument("--progress", action="store_true", help="Write JSON progress records to stderr")
    args = parser.parse_args(arguments)
    if args.from_bake is not None:
        if args.project_root is None or args.world_data is not None or args.bake_manifest is not None:
            parser.error("--from-bake requires --project-root and supplies world_data and the bake manifest")
        root, args.bake_manifest, args.world_index, args.world_data = _bake_inputs(args.from_bake, args.project_root)
        if args.output.is_symlink():
            raise ValueError("Navigation output directory may not be a symbolic link")
        args.output = _project_path(args.output, root, "Navigation output directory")
        if args.output == args.bake_manifest.parent:
            raise ValueError("Navigation output must have its own directory")
    elif args.world_data is None or args.project_root is not None:
        parser.error("Provide world_data for --chunk or --world-index. --project-root is for --from-bake.")
    if args.world_index is not None and args.debug_json:
        parser.error("Use the published manifest for the world preview; --debug-json is for --chunk")
    if args.world_index is None and args.manifest_name is not None:
        parser.error("--manifest-name requires a whole-map build")
    profile = GraphProfile(args.agent_radius, args.safety_margin, args.sample_step, args.max_neighbors)
    settings = {"heights": args.height, "grid_origin": args.grid_origin, "grid_size_m": args.grid_size,
                "profile": profile, "bake_manifest": args.bake_manifest}
    progress = _report_progress if args.progress else None
    if args.world_index is None:
        if progress is not None:
            progress(0, 1)
        summary = build_chunk(args.world_data, args.output, chunk=args.chunk, debug_json=args.debug_json, **settings)
        if progress is not None:
            progress(1, 1)
        return summary
    from .world import build_world
    return build_world(args.world_data, args.world_index, args.output, progress=progress,
                       manifest_name=args.manifest_name or MANIFEST_NAMES[0], **settings)


def main():
    try:
        summary = run()
    except (OSError, ValueError) as exc:
        raise SystemExit(f"error: {exc}") from None
    print(json.dumps(summary, sort_keys=True))


if __name__ == "__main__":
    main()
