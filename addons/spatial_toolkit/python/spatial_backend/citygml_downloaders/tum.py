"""Build a pinned TUM2TWIN LoD3 archive for Map Explorer."""

import argparse
from contextlib import closing
import hashlib
from io import BytesIO
import json
from pathlib import Path
import sys
from tempfile import TemporaryDirectory
from urllib.parse import quote, urlencode
from urllib.request import Request
from zipfile import BadZipFile, ZIP_DEFLATED, ZipFile, ZipInfo

from .common import Progress, open_https


CATALOG = Path(__file__).resolve().parents[1] / "tum2twin_lod3_catalog.json"
PILOT_MEMBERS = {"DEBY_LOD3_4906970.gml", "DEBY_LOD3_4959321.gml"}
LICENSE_SIZE = 18657
LICENSE_SHA256 = "9ba9550ad48438d0836ddab3da480b3b69ffa0aac7b7878b5a0039e7ab429411"
FOLDER = "citygml/lod3-building-datasets"
API = "https://gitlab.lrz.de/api/v4/projects/tum-gis%2Ftum2twin-datasets/repository/files"
BUFFER_SIZE = 1024 * 1024


def original_stream(member, revision, source_directory):
    name = member["file"]
    if source_directory is not None:
        return (source_directory / name).open("rb")
    encoded = quote(f"{FOLDER}/{name}", safe="")
    query = urlencode({"ref": revision, "lfs": "true"})
    request = Request(f"{API}/{encoded}/raw?{query}", headers={"User-Agent": "Godot Spatial Toolkit"})
    return open_https(request, timeout=75)


def _copy_original(source, target, member, downloaded):
    digest = hashlib.sha256()
    size = 0
    while block := source.read(BUFFER_SIZE):
        size += len(block)
        if size > member["size_bytes"]:
            raise ValueError(f"{member['file']} exceeds its pinned size")
        digest.update(block)
        target.write(block)
        downloaded.advance(len(block))
    if size != member["size_bytes"] or digest.hexdigest() != member["sha256"]:
        raise ValueError(f"{member['file']} does not match its pinned size and SHA-256")


def write_original(archive, member, source, downloaded, *, pilot):
    info = ZipInfo(member["file"])
    info.compress_type = ZIP_DEFLATED
    info.file_size = member["size_bytes"]
    if pilot:
        # The pilot contains two small pinned files and keeps the original compression level.
        with BytesIO() as target:
            _copy_original(source, target, member, downloaded)
            archive.writestr(info, target.getvalue(), compresslevel=9)
    else:
        with archive.open(info, mode="w") as target:
            _copy_original(source, target, member, downloaded)


def _license(license_url, source_directory, packaged_pilot):
    license_path = source_directory / "LICENSE.txt" if source_directory is not None else None
    if license_path is not None and license_path.is_file():
        with license_path.open("rb") as stream:
            license_text = stream.read(LICENSE_SIZE + 1)
    elif source_directory is not None and packaged_pilot is not None and packaged_pilot.is_file():
        with ZipFile(packaged_pilot) as archive, archive.open("LICENSE.txt") as stream:
            license_text = stream.read(LICENSE_SIZE + 1)
    else:
        request = Request(license_url, headers={"User-Agent": "Godot Spatial Toolkit"})
        with open_https(request, timeout=75) as stream:
            license_text = stream.read(LICENSE_SIZE + 1)
    if len(license_text) != LICENSE_SIZE or hashlib.sha256(license_text).hexdigest() != LICENSE_SHA256:
        raise ValueError("The TUM2TWIN license does not match the pinned source revision")
    return license_text


def prepare(output, source_directory=None, *, pilot=False, progress=None, packaged_pilot=None):
    with CATALOG.open(encoding="utf-8") as file:
        catalog = json.load(file)
    revision = catalog["revision"]
    license_url = f"{catalog['repository']}/-/raw/{revision}/LICENSE"
    originals = [member for member in catalog["members"] if not pilot or member["file"] in PILOT_MEMBERS]
    downloaded = Progress(progress, "download", sum(member["size_bytes"] for member in originals) + LICENSE_SIZE)
    license_text = _license(license_url, source_directory, packaged_pilot)
    downloaded.advance(len(license_text))
    provenance = {**catalog, "license": "CC-BY-4.0", "horizontal_crs": "EPSG:25832", "lod": 3,
                  "license_url": license_url}
    output.parent.mkdir(parents=True, exist_ok=True)
    # Publish only after all original XML hashes have been checked. Existing bakes pin the ZIP hash.
    with TemporaryDirectory(dir=output.parent, prefix=output.name + ".") as directory:
        staging = Path(directory) / "cache.zip"
        with ZipFile(staging, mode="w") as archive:
            if not pilot:
                archive.writestr(ZipInfo("LICENSE.txt"), license_text)
                archive.writestr(ZipInfo("provenance.json"), json.dumps(provenance, indent=2) + "\n")
            for member in originals:
                if progress is None:
                    print(member["file"], flush=True)
                with closing(original_stream(member, revision, source_directory)) as source:
                    write_original(archive, member, source, downloaded, pilot=pilot)
            if pilot:
                archive.writestr(ZipInfo("LICENSE.txt"), license_text, compress_type=ZIP_DEFLATED, compresslevel=9)
            packaging = Progress(progress, "package", 1)
        output.hardlink_to(staging)
        packaging.advance(1)


def main(packaged_pilot=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", type=Path, help="Destination ZIP, for example tum2twin_lod3_full.zip")
    parser.add_argument("--source-directory", type=Path, help="Local copies of the pinned original GML files")
    args = parser.parse_args()
    output = args.output.expanduser().absolute()
    if output.exists():
        parser.error(f"Destination already exists: {output}")
    try:
        prepare(output, args.source_directory, packaged_pilot=packaged_pilot)
    except (BadZipFile, OSError, ValueError) as error:
        print(error, file=sys.stderr)
        return 1
    print(f"Saved {output} ({output.stat().st_size:,} bytes)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
