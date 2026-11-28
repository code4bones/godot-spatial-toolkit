"""Prepare and publish a preset's verified local CityGML archive."""

import argparse
from pathlib import Path


def run(arguments, progress):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("dataset_id")
    parser.add_argument("destination", type=Path)
    parser.add_argument("staging", type=Path)
    args = parser.parse_args(arguments)

    destination = args.destination.resolve()
    staging = args.staging.resolve()
    if not staging.is_dir() or staging.parent != destination.parent or staging == destination:
        raise ValueError("CityGML staging must be a directory inside the destination's cache folder")
    if destination.is_file():
        return {"ok": True, "path": str(destination)}

    prepared = staging / destination.name
    if args.dataset_id in {"helsinki_kalasatama", "helsinki_kalasatama_archive"}:
        from .helsinki_download import prepare

        cached_full = destination.parent / "kalasatama_2019.zip"
        prepare(args.dataset_id, prepared, progress,
                source_archive=cached_full if args.dataset_id == "helsinki_kalasatama" and cached_full.is_file() else None)
    else:
        from .citygml_download_sources import prepare

        prepare(args.dataset_id, prepared, progress)
    try:
        destination.hardlink_to(prepared)
    except FileExistsError:
        # A parallel editor may already have published the same verified preset.
        if not destination.is_file():
            raise
    return {"ok": True, "path": str(destination)}
