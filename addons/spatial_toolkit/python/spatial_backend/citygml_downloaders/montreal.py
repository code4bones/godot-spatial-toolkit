"""Cache all 18 Ville-Marie 2016 CityGML tiles without downloading their textures."""

import argparse
from contextlib import closing
import hashlib
import io
import json
from pathlib import Path
import struct
import sys
from tempfile import TemporaryDirectory
import time
from urllib.request import Request
from zipfile import BadZipFile, ZIP_DEFLATED, ZIP_STORED, ZipFile, ZipInfo
import zlib

from .common import Progress, open_https


DATASET = "https://www.donneesquebec.ca/recherche/dataset/vmtl-batiment-3d-2016-maquette-citygml-lod2-avec-textures2"
CATALOG = Path(__file__).resolve().parents[1] / "montreal_citygml_catalog.json"
RESOURCES = (
    ("7d178ff5-4626-467f-9c57-0e038b44f9eb", "vm_2016_gml_01_09.zip"),
    ("a0c45e78-4092-4575-b9f3-486c13df2f33", "vm_2016_gml_10_18.zip"),
)
BLOCK = 1024 * 1024
XML_LIMIT = 1024 * 1024 * 1024


class RemoteZip(io.RawIOBase):
    """Seek the publisher's ZIP with bounded, validated HTTP range requests."""

    def __init__(self, url):
        self.url = url
        self.position = 0
        self.cache_start = 0
        self.cache = b""
        with self._request(url, 0, 0) as response:
            self.url = response.geturl()
            self.size = int(response.headers["Content-Range"].split("/")[-1])
            self.etag = response.headers.get("ETag")

    @staticmethod
    def _request(url, start, end):
        request = Request(url, headers={"Range": f"bytes={start}-{end}",
                                        "User-Agent": "Godot-Spatial-Toolkit/0.10.1"})
        for attempt in range(3):
            try:
                response = open_https(request, timeout=75)
                if response.status != 206 or not response.headers.get("Content-Range", "").startswith(
                        f"bytes {start}-{end}/"):
                    response.close()
                    raise ValueError("The Montréal server did not honor the requested byte range")
                return response
            except OSError:
                if attempt == 2:
                    raise
                time.sleep(attempt + 1)

    def readable(self):
        return True

    def seekable(self):
        return True

    def tell(self):
        return self.position

    def seek(self, offset, whence=io.SEEK_SET):
        base = {io.SEEK_SET: 0, io.SEEK_CUR: self.position, io.SEEK_END: self.size}[whence]
        position = base + offset
        if position < 0:
            raise ValueError("Negative archive position")
        self.position = position
        return position

    def read(self, size=-1):
        if size < 0:
            size = self.size - self.position
        size = min(size, self.size - self.position)
        if size <= 0:
            return b""
        start = self.position
        if not (self.cache_start <= start and start + size <= self.cache_start + len(self.cache)):
            end = min(self.size, start + max(size, BLOCK)) - 1
            with self._request(self.url, start, end) as response:
                if (response.headers.get("ETag") != self.etag
                        or response.headers.get("Content-Range") != f"bytes {start}-{end}/{self.size}"):
                    raise ValueError("The Montréal source archive changed during download")
                self.cache = response.read(end - start + 1)
            if len(self.cache) != end - start + 1:
                raise ValueError("Truncated Montréal archive range")
            self.cache_start = start
        offset = start - self.cache_start
        data = self.cache[offset:offset + size]
        self.position += len(data)
        return data


def read_exact(stream, size):
    data = stream.read(size)
    if len(data) != size:
        raise ValueError("Truncated nested Montréal ZIP")
    return data


def extract_geometry(stream, target, expected_name, expected_size, progress):
    """Read the first file in a nested tile ZIP and verify its own CRC and size."""
    while True:
        header = struct.unpack("<4s5H3L2H", read_exact(stream, 30))
        signature, _, flags, method, _, _, crc, compressed_size, size, name_size, extra_size = header
        if signature != b"PK\x03\x04" or flags & (1 | 8):
            raise ValueError("Unsupported nested Montréal ZIP header")
        name = read_exact(stream, name_size).decode("utf-8" if flags & 2048 else "cp437")
        read_exact(stream, extra_size)
        if name.endswith("/") and size == 0:
            read_exact(stream, compressed_size)
            continue
        if Path(name).name != expected_name or not 0 < size <= XML_LIMIT:
            raise ValueError(f"Expected {expected_name} as the first nested tile file, got {name}")
        if size != expected_size:
            raise ValueError(f"The Montréal source member does not match its pinned size: {name}")
        if method not in (ZIP_STORED, ZIP_DEFLATED):
            raise ValueError("Unsupported Montréal GML compression")
        break
    inflater = zlib.decompressobj(-15) if method == ZIP_DEFLATED else None
    digest = hashlib.sha256()
    checksum = 0
    written = 0
    while compressed_size:
        data = read_exact(stream, min(BLOCK, compressed_size))
        compressed_size -= len(data)
        data = inflater.decompress(data, size - written + 1) if inflater else data
        written += len(data)
        if written > size:
            raise ValueError("Montréal GML exceeds its declared size")
        checksum = zlib.crc32(data, checksum)
        digest.update(data)
        target.write(data)
        progress.advance(len(data))
    if written != size or checksum != crc or (inflater and not inflater.eof):
        raise ValueError("Montréal GML does not match its declared size and CRC")
    return name, digest.hexdigest(), written


def prepare(output, source_directory=None, *, progress=None):
    pinned = json.loads(CATALOG.read_text(encoding="utf-8"))["members"]
    manifest = {"schema": 1, "dataset_id": "montreal_ville_marie", "members": {},
                "dataset_url": DATASET, "provider": "Ville de Montréal", "license": "CC-BY-4.0",
                "license_url": "https://creativecommons.org/licenses/by/4.0/",
                "source_crs": "EPSG:2950", "source_vertical_datum": "CGVD28 (EPSG:5713)",
                "lod": 2, "textures_included": False,
                "processing": "Original CityGML XML retained byte-for-byte; JPEG textures omitted."}
    output.parent.mkdir(parents=True, exist_ok=True)
    downloaded = Progress(progress, "download", sum(item["size_bytes"] for item in pinned.values()))
    with TemporaryDirectory(dir=output.parent, prefix=output.name + ".") as directory:
        staging = Path(directory) / "cache.zip"
        with ZipFile(staging, "w") as target:
            for resource, filename in RESOURCES:
                url = ("https://donnees.montreal.ca/fr/dataset/5eabd047-872e-425a-bbc2-3669e732a132/"
                       f"resource/{resource}/download/{filename}")
                original = (source_directory / filename).open("rb") if source_directory else RemoteZip(url)
                with closing(original), ZipFile(original) as source:
                    tiles = sorted(member for member in source.namelist() if member.lower().endswith(".zip"))
                    if len(tiles) != 9:
                        raise ValueError(f"Expected nine CityGML tile ZIPs in {filename}")
                    for tile in tiles:
                        name = Path(tile).name.replace("_GML.zip", ".gml")
                        if name not in pinned or name in manifest["members"]:
                            raise ValueError(f"Unexpected or duplicate Montréal CityGML tile: {name}")
                        if progress is None:
                            print(name, flush=True)
                        info = ZipInfo(name)
                        info.compress_type = ZIP_DEFLATED
                        with source.open(tile) as nested, target.open(info, "w") as member:
                            source_name, digest, size = extract_geometry(nested, member, name,
                                                                         pinned[name]["size_bytes"], downloaded)
                        record = {"sha256": digest, "size_bytes": size, "source_url": url,
                                  "source_member": f"{tile}/{source_name}"}
                        if record != pinned[name]:
                            raise ValueError(f"The Montréal source member does not match its pinned revision: {name}")
                        manifest["members"][name] = record
            if manifest["members"].keys() != pinned.keys():
                raise ValueError("The Montréal source archive is missing pinned tiles")
            packaged = Progress(progress, "package", 1)
            target.writestr(ZipInfo("citygml_manifest.json"), json.dumps(manifest, indent=2) + "\n")
        output.hardlink_to(staging)
        packaged.advance(1)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", type=Path, help="Destination ZIP, for example montreal_ville_marie.zip")
    parser.add_argument("--source-directory", type=Path, help="Directory containing both original publisher ZIPs")
    args = parser.parse_args()
    output = args.output.expanduser().absolute()
    if output.exists():
        parser.error(f"Destination already exists: {output}")
    try:
        prepare(output, args.source_directory)
    except (BadZipFile, OSError, ValueError, zlib.error) as error:
        print(error, file=sys.stderr)
        return 1
    print(f"Saved {output} ({output.stat().st_size:,} bytes)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
