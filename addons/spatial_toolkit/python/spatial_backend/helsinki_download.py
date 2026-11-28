"""Prepare the pinned City of Helsinki CityGML datasets for Map Explorer."""

import gzip
import hashlib
from pathlib import Path
from tempfile import TemporaryDirectory
from urllib.request import Request, urlopen
import xml.etree.ElementTree as ET
from zipfile import ZipFile

from .citygml import _CITY, _EXTRACT_BOUNDS, _GML_ID, _NS, _READ_BLOCK, _ZIP_MEMBER, _envelope


ARCHIVE_ID = "helsinki_kalasatama_archive"
PILOT_ID = "helsinki_kalasatama"
ARCHIVE_URL = "https://3d.hel.ninja/data/citygml/Helsinki3D_CityGML_Kalasatama_20190326.zip"
ARCHIVE_BYTES = 23_546_638
ARCHIVE_SHA256 = "ef6a787068b82642e5a0be5e20268e137075bb41fdbf0ec88619ad79926e2299"
PILOT_XML_SHA256 = "6428edd9a449f12a7b3d3e150c0c40ae766b432a1f4e1fd40a07d0a01ef26220"
_MEMBER = f"{{{_NS['core']}}}cityObjectMember"


def _transfer(source, destination, progress, *, cached=False):
    digest = hashlib.sha256()
    phase = "verify" if cached else "download"
    done = 0
    progress(phase, 0, ARCHIVE_BYTES)
    with destination.open("xb") as output:
        for block in iter(lambda: source.read(_READ_BLOCK), b""):
            done += len(block)
            if done > ARCHIVE_BYTES:
                raise ValueError("The Kalasatama source exceeds its pinned size")
            output.write(block)
            digest.update(block)
            progress(phase, done, ARCHIVE_BYTES)
    if not cached:
        progress("verify", 0, 1)
    if done != ARCHIVE_BYTES or digest.hexdigest() != ARCHIVE_SHA256:
        raise ValueError("The Kalasatama source does not match its pinned size and SHA-256")
    if not cached:
        progress("verify", 1, 1)


def _copy_cached_source(source_archive, destination, progress):
    if not source_archive.is_file() or source_archive.stat().st_size != ARCHIVE_BYTES:
        return False
    try:
        with source_archive.open("rb") as source:
            _transfer(source, destination, progress, cached=True)
    except ValueError:
        destination.unlink(missing_ok=True)
        return False
    return True


def _pilot_members(stream, size, progress):
    """Keep whole buildings that intersect the EPSG:3879 pilot bounds."""
    selected = {}
    west, south, east, north = _EXTRACT_BOUNDS
    events = iter(ET.iterparse(stream, events=("start", "end")))
    _, root = next(events)
    if root.tag != _CITY:
        raise ValueError("The Kalasatama source is not a CityGML 2.0 city model")
    previous_percentage = 0
    depth = 1
    for event, member in events:
        if event == "start":
            depth += 1
            continue
        if depth == 2:
            if member.tag == _MEMBER:
                building = member.find("building:Building", _NS)
                if building is not None:
                    lo_east, lo_north, hi_east, hi_north = _envelope(building)
                    identifier = building.get(_GML_ID)
                    if (identifier and lo_east < east and hi_east > west
                            and lo_north < north and hi_north > south):
                        score = len(building.findall(".//building:lod2MultiSurface//gml:Polygon", _NS))
                        # The original export repeats some GMLIDs. Prefer the most detailed shell.
                        if identifier not in selected or score > selected[identifier][0]:
                            selected[identifier] = (score, member)
            root.remove(member)
            done = stream.tell()
            percentage = 100 * done // size
            if percentage > previous_percentage:
                progress("package", done, size)
                previous_percentage = percentage
        depth -= 1
    return selected


def _prepare_pilot(archive, destination, progress):
    with ZipFile(archive) as zipped:
        info = zipped.getinfo(_ZIP_MEMBER)
        progress("package", 0, info.file_size)
        with zipped.open(info) as stream:
            members = _pilot_members(stream, info.file_size, progress)

    ET.register_namespace("", _NS["core"])
    ET.register_namespace("bldg", _NS["building"])
    ET.register_namespace("gml", _NS["gml"])
    ET.register_namespace("app", "http://www.opengis.net/citygml/appearance/2.0")
    city = ET.Element(_CITY)
    for identity in sorted(members):
        member = members[identity][1]
        member.tail = None
        city.append(member)
    xml = ET.tostring(city, encoding="utf-8", xml_declaration=True)
    if hashlib.sha256(xml).hexdigest() != PILOT_XML_SHA256:
        raise ValueError("The Kalasatama pilot does not match its pinned CityGML extract")
    with destination.open("xb") as output, gzip.GzipFile(filename="", mode="wb", fileobj=output, mtime=0) as zipped:
        zipped.write(xml)
    progress("package", info.file_size, info.file_size)


def prepare(dataset_id, output, progress, *, source_archive=None):
    """Download the official archive or rebuild the reproducible pilot subset."""
    if dataset_id not in (ARCHIVE_ID, PILOT_ID):
        raise ValueError(f"Unsupported Helsinki dataset: {dataset_id}")
    output = Path(output)
    if output.exists():
        raise FileExistsError(output)
    output.parent.mkdir(parents=True, exist_ok=True)
    with TemporaryDirectory(dir=output.parent, prefix=".kalasatama-") as directory:
        archive = Path(directory) / "kalasatama_2019.zip"
        cached = Path(source_archive) if dataset_id == PILOT_ID and source_archive is not None else None
        if cached is None or not _copy_cached_source(cached, archive, progress):
            request = Request(ARCHIVE_URL, headers={"User-Agent": "Godot Spatial Toolkit"})
            with urlopen(request, timeout=75) as source:
                _transfer(source, archive, progress)
        if dataset_id == ARCHIVE_ID:
            output.hardlink_to(archive)
        else:
            prepared = Path(directory) / "kalasatama_350m.citygml.gz"
            _prepare_pilot(archive, prepared, progress)
            output.hardlink_to(prepared)
