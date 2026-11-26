"""Consolidate local GeoJSON exports containing complete OSM objects."""

import argparse
import hashlib
import json
import os
import re
import tempfile
from pathlib import Path


OSM_ID = re.compile(r"(?:node|way|relation)/[1-9][0-9]*")


def validate_declared_crs(document):
    crs = document.get("crs")
    if crs:
        properties = crs.get("properties") if isinstance(crs, dict) else None
        name = properties.get("name", "") if isinstance(properties, dict) else ""
        if name not in ("urn:ogc:def:crs:OGC:1.3:CRS84", "urn:ogc:def:crs:OGC::CRS84", "EPSG:4326"):
            raise ValueError(f"Unsupported declared CRS: {name}")


def merge_whole_osm(sources):
    """Keep one copy per typed OSM ID and report mismatched duplicates."""
    features = {}
    sources_by_id = {}
    source_records = []
    conflicts = {}
    for path in sources:
        raw = path.read_bytes()
        document = json.loads(raw)
        if not isinstance(document, dict) or document.get("type") != "FeatureCollection":
            raise ValueError(f"Expected a FeatureCollection in {path.name}")
        validate_declared_crs(document)
        items = document.get("features")
        if not isinstance(items, list):
            raise ValueError(f"Missing feature array in {path.name}")
        record = {"file": path.name, "sha256": hashlib.sha256(raw).hexdigest(), "features": len(items),
                  "new_ids": 0, "identical_duplicates": 0, "conflicts": 0}
        if isinstance(document.get("source"), dict):
            record["source"] = document["source"]
        source_records.append(record)
        for index, item in enumerate(items, start=1):
            identity = item.get("id") if isinstance(item, dict) else None
            if not isinstance(identity, str) or OSM_ID.fullmatch(identity) is None:
                raise ValueError(f"Expected a typed OSM ID in feature {index} of {path.name}")
            if item.get("type") != "Feature" or not isinstance(item.get("geometry"), dict):
                raise ValueError(f"Missing feature geometry for {identity} in {path.name}")
            if identity not in features:
                features[identity] = item
                sources_by_id[identity] = path.name
                record["new_ids"] += 1
                continue
            original = features[identity]
            geometry_differs = original["geometry"] != item["geometry"]
            tags_differ = original.get("properties") != item.get("properties")
            if geometry_differs or tags_differ:
                record["conflicts"] += 1
                conflicts.setdefault(identity, []).append({"kept_source": sources_by_id[identity],
                    "incoming_source": path.name, "geometry_differs": geometry_differs, "tags_differ": tags_differ})
            else:
                record["identical_duplicates"] += 1
    report = {"sources": source_records, "unique_osm_ids": len(features),
              "identical_duplicates": sum(source["identical_duplicates"] for source in source_records),
              "conflicts": conflicts}
    if conflicts:
        return None, report
    merged = {"type": "FeatureCollection", "generator": "Godot Spatial Toolkit",
              "copyright": "© OpenStreetMap contributors", "features": list(features.values()),
              "merge": report}
    return merged, report


def _save_new_export(output, merged):
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(mode="w", encoding="utf-8", dir=output.parent, delete=False) as file:
            temporary = Path(file.name)
            json.dump(merged, file, ensure_ascii=False, separators=(",", ":"))
            file.write("\n")
        os.link(temporary, output)
    finally:
        if temporary is not None:
            temporary.unlink()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("sources", nargs="+", type=Path, help="Local exports with complete OSM GeoJSON features")
    parser.add_argument("--output", type=Path, help="Write a new combined GeoJSON after a conflict-free preview")
    args = parser.parse_args()
    try:
        merged, report = merge_whole_osm(args.sources)
        if args.output is not None and merged is not None:
            _save_new_export(args.output, merged)
    except (OSError, ValueError) as error:
        parser.exit(1, f"{error}\n")
    print(json.dumps(report, ensure_ascii=False, indent=2))
    return int(merged is None)


if __name__ == "__main__":
    raise SystemExit(main())
