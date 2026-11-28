"""Cache the complete Lyon 1er and 2e CityGML building layers from official ZIPs."""

import argparse
import hashlib
import io
import json
from pathlib import Path
import re
import sys
from tempfile import TemporaryDirectory
from urllib.request import Request
from zipfile import BadZipFile, ZIP_DEFLATED, ZipFile, ZipInfo

from .common import Progress, open_https

CATALOG = Path(__file__).resolve().parents[1] / "lyon_citygml_catalog.json"
BLOCK_SIZE = 4 * 1024 * 1024


class RemoteZip(io.RawIOBase):
    """Seek over a fixed official ZIP using bounded HTTP byte ranges."""

    def __init__(self, url, expected_size):
        self.url = url
        self.size = expected_size
        self.position = 0
        self.block_start = 0
        self.block = b""
        request = Request(url, headers={"Range": "bytes=-65536", "User-Agent": "Godot Spatial Toolkit"})
        with open_https(request, timeout=75) as response:
            header = response.headers.get("Content-Range", "")
            match = re.fullmatch(r"bytes (\d+)-(\d+)/(\d+)", header)
            if response.status != 206 or match is None or int(match[3]) != expected_size:
                raise ValueError("The official Lyon ZIP changed or does not support byte ranges")
            self.etag = response.headers.get("ETag")
            self.block_start = int(match[1])
            self.block = response.read(65537)
            if len(self.block) != int(match[2]) - self.block_start + 1:
                raise ValueError("Truncated Lyon ZIP directory response")

    def seekable(self):
        return True

    def readable(self):
        return True

    def tell(self):
        return self.position

    def seek(self, offset, whence=0):
        if whence not in (0, 1, 2):
            raise ValueError("Invalid seek mode")
        base = 0 if whence == 0 else self.position if whence == 1 else self.size
        position = base + offset
        if position < 0:
            raise ValueError("Negative ZIP seek")
        self.position = position
        return position

    def read(self, count=-1):
        count = self.size - self.position if count < 0 else min(count, self.size - self.position)
        if count <= 0:
            return b""
        chunks = []
        while count:
            if not self.block_start <= self.position < self.block_start + len(self.block):
                end = min(self.size - 1, self.position + max(count, BLOCK_SIZE) - 1)
                headers = {"Range": f"bytes={self.position}-{end}", "User-Agent": "Godot Spatial Toolkit"}
                if self.etag:
                    headers["If-Match"] = self.etag
                with open_https(Request(self.url, headers=headers), timeout=75) as response:
                    expected = f"bytes {self.position}-{end}/{self.size}"
                    if response.status != 206 or response.headers.get("Content-Range") != expected:
                        raise ValueError("The official Lyon ZIP changed during download")
                    self.block_start = self.position
                    self.block = response.read(end - self.position + 2)
                    if len(self.block) != end - self.position + 1:
                        raise ValueError("Truncated Lyon ZIP range response")
            offset = self.position - self.block_start
            data = self.block[offset:offset + count]
            chunks.append(data)
            self.position += len(data)
            count -= len(data)
        return b"".join(chunks)


def prepare(output, source_directory=None, *, progress=None):
    catalog = json.loads(CATALOG.read_text(encoding="utf-8"))
    manifest = {key: value for key, value in catalog.items() if key != "archives"}
    manifest["members"] = {}
    manifest["source_archives"] = [
        {key: value for key, value in entry.items() if key != "members"}
        for entry in catalog["archives"]
    ]
    manifest["appearance"] = "Original image references retained; texture images are outside this building-geometry cache."
    output.parent.mkdir(parents=True, exist_ok=True)
    downloaded = Progress(progress, "download", sum(member["size_bytes"] for entry in catalog["archives"]
                                                    for member in entry["members"]))
    with TemporaryDirectory(dir=output.parent, prefix=output.name + ".") as directory:
        staging = Path(directory) / "cache.zip"
        with ZipFile(staging, "w", compression=ZIP_DEFLATED) as target:
            for entry in catalog["archives"]:
                filename = entry["url"].rsplit("/", 1)[1]
                source = ((source_directory / filename).open("rb") if source_directory
                          else RemoteZip(entry["url"], entry["size_bytes"]))
                with source, ZipFile(source) as archive:
                    for member in entry["members"]:
                        name = member["file"]
                        original = archive.getinfo(name)
                        if (original.file_size != member["size_bytes"]
                                or f"{original.CRC:08x}" != member["crc32"]):
                            raise ValueError("The official Lyon source member changed: " + name)
                        if progress is None:
                            print(name, flush=True)
                        digest = hashlib.sha256()
                        info = ZipInfo(name)
                        info.compress_type = ZIP_DEFLATED
                        with archive.open(original) as data, target.open(info, "w") as destination:
                            while block := data.read(BLOCK_SIZE):
                                digest.update(block)
                                destination.write(block)
                                downloaded.advance(len(block))
                        if digest.hexdigest() != member["sha256"]:
                            raise ValueError("The Lyon source SHA-256 changed: " + name)
                        manifest["members"][name] = {"sha256": digest.hexdigest(), "source_url": entry["url"],
                                                       "source_member": name, "size_bytes": original.file_size,
                                                       "source_updated_at": member["source_updated_at"]}
            packaged = Progress(progress, "package", 1)
            target.writestr(ZipInfo("citygml_manifest.json"), json.dumps(manifest, ensure_ascii=False, indent=2) + "\n")
        output.hardlink_to(staging)
        packaged.advance(1)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", type=Path)
    parser.add_argument("--source-directory", type=Path, help="Directory with the two original full arrondissement ZIPs")
    args = parser.parse_args()
    output = args.output.expanduser().absolute()
    if output.exists():
        parser.error("Destination already exists: " + str(output))
    try:
        prepare(output, args.source_directory)
    except (OSError, ValueError, BadZipFile, EOFError) as error:
        print(error, file=sys.stderr)
        return 1
    print(f"Saved {output} ({output.stat().st_size:,} bytes)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
