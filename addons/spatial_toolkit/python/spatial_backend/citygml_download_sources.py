"""Entry point for the bundled, pinned regional CityGML downloads."""

from functools import partial

from .citygml_downloaders import lyon, montreal, tum, zurich


_SOURCES = {
    "lyon_presquile": lyon.prepare,
    "montreal_ville_marie": montreal.prepare,
    "tum2twin_lod3": partial(tum.prepare, pilot=True),
    "tum2twin_lod3_full": tum.prepare,
    "zurich_citygml": zurich.prepare,
}


def prepare(dataset_id, output, progress):
    """Download and verify a built-in dataset at a new output path."""
    recipe = _SOURCES.get(dataset_id)
    if recipe is None:
        raise ValueError(f"Unknown regional CityGML download: {dataset_id}")
    if output.exists():
        raise FileExistsError(f"Destination already exists: {output}")
    recipe(output, progress=progress)
