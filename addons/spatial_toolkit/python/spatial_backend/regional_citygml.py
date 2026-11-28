"""Read the full municipal CityGML caches used by Map Explorer."""

import hashlib
import json
import math
from pathlib import PurePosixPath
import re
from urllib.parse import urlsplit
import xml.etree.ElementTree as ET
from zipfile import BadZipFile, ZipFile

from .citygml import (_GML_ID, _GROUND, _NS, _READ_BLOCK, _TumGeometry, _building_surfaces, _intersects,
                      _payload, _projected_selection, _scan_zip_members)
from .preview_geometry import FootprintIndex


REGIONAL_DATASETS = {
    "montreal_ville_marie": {
        "dataset": "Ville-Marie CityGML LoD2 (2016)", "provider": "Ville de Montréal",
        "license": "CC-BY-4.0", "license_url": "https://creativecommons.org/licenses/by/4.0/",
        "attribution": "Ville de Montréal, Ville-Marie CityGML LoD2 (2016), CC BY 4.0",
        "source_crs": "EPSG:2950", "source_vertical_datum": "CGVD28 (EPSG:5713)",
        "undeclared_crs": True, "closure_tolerance_m": 0.0002,
    },
    "zurich_citygml": {
        "dataset": "Bauten – Dachmodell, CityGML LoD2", "provider": "Stadt Zürich",
        "license": "CC0-1.0", "license_url": "https://creativecommons.org/publicdomain/zero/1.0/",
        "attribution": "Stadt Zürich, Bauten – Dachmodell, CC0 1.0",
        "source_crs": "EPSG:2056", "crs_aliases": ("CH1903+",),
        "source_vertical_datum": "not specified", "source_ground_below_terrain_m": 3.0,
    },
    "lyon_presquile": {
        "dataset": "Maquettes 3D texturées 2018, Lyon 1er et 2e", "provider": "Métropole de Lyon",
        "license": "Etalab-2.0", "license_url": "https://www.data.gouv.fr/pages/legal/licences/etalab-2-0",
        "attribution": "Métropole de Lyon, Maquettes 3D texturées 2018, Lyon 1er et 2e, Licence Ouverte 2.0",
        "source_crs": "EPSG:3946", "source_vertical_datum": "not specified", "undeclared_crs": True,
        "closure_tolerance_m": 0.0002,
    },
}
_MANIFEST = "citygml_manifest.json"
_MANIFEST_LIMIT = 1024 * 1024
_XML_LIMIT = 8 * 1024**3
_ZIP_LIMIT = 16 * 1024**3
_TOTAL_XML_LIMIT = 32 * 1024**3
_SHA256 = re.compile(r"[0-9a-f]{64}")


def _cache_members(zipped, dataset_id):
    names = zipped.namelist()
    if len(names) != len(set(names)) or _MANIFEST not in names:
        raise ValueError("The prepared CityGML ZIP needs a single manifest and unique files")
    manifest_info = zipped.getinfo(_MANIFEST)
    if not 0 < manifest_info.file_size <= _MANIFEST_LIMIT:
        raise ValueError("Invalid prepared CityGML manifest size")
    manifest = json.loads(zipped.read(manifest_info))
    if (not isinstance(manifest, dict) or manifest.get("schema") != 1 or manifest.get("dataset_id") != dataset_id
            or not isinstance(manifest.get("members"), dict) or not manifest["members"]):
        raise ValueError(f"The prepared CityGML ZIP is not for the {dataset_id} preset")
    members = manifest["members"]
    if set(names) != {*members, _MANIFEST}:
        raise ValueError("The prepared CityGML ZIP files do not match its manifest")
    archive_provenance = manifest.get("provenance", {})
    if not isinstance(archive_provenance, dict):
        raise ValueError("Invalid prepared CityGML archive provenance")
    total = 0
    for member, record in members.items():
        member_path = PurePosixPath(member)
        info = zipped.getinfo(member)
        if (member_path.is_absolute() or ".." in member_path.parts or "\\" in member
                or member_path.suffix.lower() not in (".gml", ".xml")
                or not 0 < info.file_size <= _XML_LIMIT):
            raise ValueError(f"Invalid prepared CityGML member: {member}")
        if (not isinstance(record, dict) or not isinstance(record.get("sha256"), str)
                or not _SHA256.fullmatch(record["sha256"]) or not isinstance(record.get("source_url"), str)
                or not isinstance(record.get("source_member"), str) or not record["source_member"]):
            raise ValueError(f"Missing source provenance for {member}")
        url = urlsplit(record["source_url"])
        if url.scheme != "https" or not url.hostname or url.username is not None:
            raise ValueError(f"Invalid official source URL for {member}")
        if (archive_provenance.get("member") == member
                and archive_provenance.get("xml_sha256") == record["sha256"]
                and isinstance(archive_provenance.get("source_last_modified"), str)):
            record.setdefault("source_updated_at", archive_provenance["source_last_modified"])
        total += info.file_size
    if total > _TOTAL_XML_LIMIT:
        raise ValueError("The prepared CityGML ZIP exceeds its total XML size limit")
    return members


def _envelope(element):
    if element is None:
        return None, None
    envelope = element.find("gml:Envelope", _NS)
    if envelope is None:
        return None, None
    lower = tuple(map(float, envelope.findtext("gml:lowerCorner", "", _NS).split()))
    upper = tuple(map(float, envelope.findtext("gml:upperCorner", "", _NS).split()))
    if (len(lower) != len(upper) or len(lower) not in (2, 3)
            or any(not math.isfinite(a) or not math.isfinite(b) or a > b for a, b in zip(lower, upper))):
        raise ValueError("Invalid regional CityGML envelope")
    return (lower[0], lower[1], upper[0], upper[1]), envelope.get("srsName")


def _normalize_namespaces(building):
    # CityGML 1.0 uses the same LoD2 semantic surfaces and GML rings as 2.0.
    if not building.tag.startswith("{http://www.opengis.net/citygml/building/1.0}"):
        return
    for node in building.iter():
        if node.tag.startswith(("{http://www.opengis.net/citygml/building/1.0}",
                                "{http://www.opengis.net/citygml/generics/1.0}")):
            node.tag = node.tag.replace("/1.0}", "/2.0}", 1)


def _stable_identity(dataset_id, identifier, member):
    stem = re.sub(r"[^A-Za-z0-9_.-]", "_", identifier)[:190]
    # Ville-Marie reuses some GMLIDs for distinct buildings in different tiles.
    qualified = f"{member}\0{identifier}" if dataset_id == "montreal_ville_marie" else identifier
    digest = hashlib.sha256(qualified.encode("utf-8")).hexdigest()[:16]
    return f"citygml/{dataset_id}.{stem}.{digest}"


def _footprint_entry(identity, feature):
    shape = feature["geometry"]
    polygons = [shape["coordinates"]] if shape["type"] == "Polygon" else shape["coordinates"]
    x, y = zip(*(point for polygon in polygons for ring in polygon for point in ring))
    return identity, polygons, (min(x), min(y), max(x), max(y))


def _prefer_lyon_landmarks(buildings, geometry):
    ordinary, landmarks = [], []
    for identity, (mesh, feature) in buildings.items():
        entries = landmarks if "_BATI_REMARQUABLE/" in mesh["source"]["source_member"] else ordinary
        entries.append(_footprint_entry(identity, feature))
    index = FootprintIndex(ordinary)
    matches, counts = {}, {}
    for identity, polygons, bounds in landmarks:
        agreeing = [key for key, other in index.candidates(bounds)
                    if min(geometry.footprint_overlap(polygons, other)) >= 0.8]
        if len(agreeing) == 1:
            matches[identity] = agreeing[0]
            counts[agreeing[0]] = counts.get(agreeing[0], 0) + 1
    for landmark, ordinary_id in matches.items():
        if counts[ordinary_id] == 1:
            buildings[landmark][0]["source"]["equivalent_citygml_ids"] = [ordinary_id]
            del buildings[ordinary_id]


def _collect_member(zipped, member, metadata, provenance, selections, geometry, to_wgs84, to_world, scale,
                    buildings, skips, on_read):
    crs = provenance["source_crs"]
    code = crs.split(":", 1)[1]
    allowed_crs = {crs, f"urn:ogc:def:crs:EPSG::{code}", f"http://www.opengis.net/def/crs/EPSG/0/{code}",
                   *provenance.get("crs_aliases", ())}
    member_crs = None
    source = {key: value for key, value in provenance.items() if key not in ("crs_aliases", "undeclared_crs")}
    source.update(archive_member=member, source_member=metadata["source_member"],
                  source_url=metadata["source_url"], xml_sha256=metadata["sha256"])
    if isinstance(metadata.get("source_updated_at"), str):
        source["source_updated_at"] = metadata["source_updated_at"]

    def check_crs(declared):
        if declared is not None and declared not in allowed_crs:
            raise ValueError(f"Expected {crs} in {member}, got {declared}")

    def keep_envelope(element):
        nonlocal member_crs
        bounds, member_crs = _envelope(element)
        check_crs(member_crs)
        return bounds is None or any(_intersects(native, bounds) for native, _ in selections)

    def collect(building):
        identifier = building.get(_GML_ID)
        identity = _stable_identity(source["dataset_id"], identifier, source["source_member"]) if identifier else member
        try:
            bounds, declared_crs = _envelope(building.find("gml:boundedBy", _NS))
            check_crs(declared_crs)
            candidates = [wgs84 for native, wgs84 in selections if bounds is None or _intersects(native, bounds)]
            if not candidates:
                return
            _normalize_namespaces(building)
            declared = {node.get("srsName") for node in building.iter() if node.get("srsName")}
            for value in declared:
                check_crs(value)
            if not (member_crs or declared or provenance.get("undeclared_crs")):
                raise ValueError(f"The CityGML source does not declare {crs}")
            diagnostics = {}
            closure_tolerance = source.get("closure_tolerance_m", 1e-8)
            surfaces = list(_building_surfaces(building, include_parts=True, closure_tolerance=closure_tolerance,
                                               diagnostics=diagnostics))
            ground = [sheet for tag, sheet in surfaces if tag == _GROUND]
            if not ground:
                raise ValueError("Selected CityGML building has no GroundSurface")
            footprint = geometry.ground_footprint(ground, to_wgs84, diagnostics=diagnostics)
            polygons = [footprint["coordinates"]] if footprint["type"] == "Polygon" else footprint["coordinates"]
            if not any(geometry.intersects_box(polygons, *box) for box in candidates):
                return
            if not identifier:
                raise ValueError("Selected CityGML building is missing its GMLID")
            if identity in buildings:
                return  # Adjacent exports can repeat an entire building. Sorted archive paths break ties.
            building_source = {**source, **diagnostics, "source_id": identifier}
            if not (member_crs or declared):
                building_source["source_crs_assumption"] = f"{crs} assigned from the dataset profile; XML omits srsName"
            mesh, feature = _payload(building, identity, building_source, surfaces, ground, footprint,
                                     geometry, to_world, scale, repair_shell_faces=True)
            if source.get("source_ground_below_terrain_m"):
                mesh["assumptions"].append("Source floor lies 3 m below the inferred visible terrain baseline")
            buildings[identity] = mesh, feature
            skips.pop(identity, None)
        except ValueError as exc:
            if identity not in buildings:
                skips[identity] = str(exc)

    with zipped.open(member) as stream:
        actual = _scan_zip_members(stream, collect, source["provider"], keep_envelope=keep_envelope,
                                   version=None, xml_limit=_XML_LIMIT, on_read=on_read)
    if actual is not None and actual != metadata["sha256"]:
        raise ValueError(f"The prepared CityGML member changed: {member}")


def read_regional_archive(dataset_id, source, source_sha256, boxes, projection, world_scale, *,
                          on_skipped, progress=None):
    """Select whole LoD2 buildings from a prepared geometry-only city cache."""
    from pyproj import CRS, Transformer

    provenance = {**REGIONAL_DATASETS[dataset_id], "dataset_id": dataset_id, "path": str(source),
                  "sha256": source_sha256, "units": "metres", "lod": 2}
    crs = provenance["source_crs"]
    to_native = Transformer.from_crs("EPSG:4326", crs, always_xy=True)
    selections = [_projected_selection(box, to_native) for box in boxes]
    to_world = Transformer.from_crs(crs, CRS.from_proj4(projection), always_xy=True)
    to_wgs84 = Transformer.from_crs(crs, "EPSG:4326", always_xy=True)
    buildings, skips = {}, {}
    try:
        with source.open("rb") as stream:
            if not 0 < stream.seek(0, 2) <= _ZIP_LIMIT:
                raise ValueError("The prepared CityGML ZIP has an invalid size")
            stream.seek(0)
            digest = hashlib.sha256()
            for block in iter(lambda: stream.read(_READ_BLOCK), b""):
                digest.update(block)
            if digest.hexdigest() != source_sha256:
                raise ValueError("The CityGML archive changed since the area was fetched")
            stream.seek(0)
            with ZipFile(stream) as zipped, _TumGeometry() as geometry:
                members = _cache_members(zipped, dataset_id)
                total = sum(zipped.getinfo(member).file_size for member in members)
                finished = 0
                last_percent = -1

                def update_progress(read_bytes):
                    nonlocal last_percent
                    percent = (finished + read_bytes) * 100 // total
                    if progress is not None and percent != last_percent:
                        progress("citygml", percent, 100)
                        last_percent = percent

                update_progress(0)
                for member, record in sorted(members.items()):
                    _collect_member(zipped, member, record, provenance, selections, geometry, to_wgs84,
                                    to_world, world_scale, buildings, skips, update_progress)
                    finished += zipped.getinfo(member).file_size
                    update_progress(0)
                if dataset_id == "lyon_presquile":
                    _prefer_lyon_landmarks(buildings, geometry)
    except (ET.ParseError, BadZipFile, OSError) as exc:
        raise ValueError(f"Could not read the prepared {dataset_id} CityGML archive: {exc}") from exc
    on_skipped(skips)
    return dict(sorted(buildings.items()))
