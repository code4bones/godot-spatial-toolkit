"""Cache the pinned official CityGML model of the whole city of Zürich."""

import argparse
import hashlib
import json
from pathlib import Path
import sys
from tempfile import TemporaryDirectory
from urllib.request import Request
from zipfile import BadZipFile, ZipFile, ZipInfo

from .common import Progress, open_https


CATALOG = Path(__file__).resolve().parents[1] / "zurich_citygml_catalog.json"
BUFFER_SIZE = 1024 * 1024


def checked_copy(source, target, expected_size, expected_sha256, progress):
    digest = hashlib.sha256()
    size = 0
    while block := source.read(BUFFER_SIZE):
        size += len(block)
        if size > expected_size:
            raise ValueError("The Zürich source exceeds its pinned size")
        digest.update(block)
        if target is not None:
            target.write(block)
        progress.advance(len(block))
    if size != expected_size or digest.hexdigest() != expected_sha256:
        raise ValueError("The Zürich source does not match its pinned size and SHA-256")


def prepare(output, source_archive=None, *, progress=None):
    catalog = json.loads(CATALOG.read_text(encoding="utf-8"))
    output.parent.mkdir(parents=True, exist_ok=True)
    # Preserve original compressed XML and publish only after checking both hashes.
    with TemporaryDirectory(dir=output.parent, prefix=output.name + ".") as directory:
        staging = Path(directory) / "cache.zip"
        downloaded = Progress(progress, "download", catalog["archive_size_bytes"])
        if source_archive is not None:
            source = source_archive.open("rb")
        else:
            request = Request(catalog["source_url"], headers={"User-Agent": "Godot Spatial Toolkit"})
            source = open_https(request, timeout=90)
        with source, staging.open("wb") as target:
            checked_copy(source, target, catalog["archive_size_bytes"], catalog["archive_sha256"], downloaded)
        verified = Progress(progress, "verify", catalog["xml_size_bytes"])
        with ZipFile(staging) as archive:
            if archive.namelist() != [catalog["member"]]:
                raise ValueError("Unexpected members in the Zürich source archive")
            with archive.open(catalog["member"]) as member:
                checked_copy(member, None, catalog["xml_size_bytes"], catalog["xml_sha256"], verified)
        manifest = {
            "schema": 1,
            "dataset_id": "zurich_citygml",
            "members": {catalog["member"]: {
                "sha256": catalog["xml_sha256"],
                "source_url": catalog["source_url"],
                "source_member": catalog["member"],
            }},
            "provenance": catalog,
        }
        packaged = Progress(progress, "package", 1)
        with ZipFile(staging, mode="a") as archive:
            archive.writestr(ZipInfo("citygml_manifest.json"), json.dumps(manifest, indent=2) + "\n")
        output.hardlink_to(staging)
        packaged.advance(1)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", type=Path, help="Destination ZIP, for example zurich_citygml.zip")
    parser.add_argument("--source-archive", type=Path, help="Local copy of the pinned official ZIP")
    args = parser.parse_args()
    output = args.output.expanduser().absolute()
    if output.exists():
        parser.error(f"Destination already exists: {output}")
    try:
        prepare(output, args.source_archive)
    except (BadZipFile, OSError, ValueError) as error:
        print(error, file=sys.stderr)
        return 1
    print(f"Saved {output} ({output.stat().st_size:,} bytes)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
