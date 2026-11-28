"""Versioned, engine-independent storage for navigation chunks and snapshots."""

from dataclasses import dataclass
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import struct
import tempfile

from . import AXES, UNITS
from .graph import Edge, Graph, Point, finite_number, finite_point


SCHEMA = 1

_FORMAT = "spatial_navigation"
_MAGIC = b"SNAV"
# Version, header flags, grid origin, ID bytes, nodes, edges, portals,
# components, metadata bytes. Every record uses little-endian byte order.
_HEADER = struct.Struct("<4sHH3d6I")
_NODE = struct.Struct("<3d")
_EDGE = struct.Struct("<2I3dI")
_CHECKSUM_BYTES = hashlib.sha256().digest_size
_UINT32_MAX = (1 << 32) - 1
_CHUNK_ID = re.compile(r"[A-Za-z0-9_-]{1,80}")
_DIGEST = re.compile(r"[0-9a-f]{64}")


@dataclass(frozen=True)
class StoredChunk:
    chunk_id: str
    origin: Point
    graph: Graph
    metadata: dict


def _count(value, label):
    if type(value) is not int or not 0 <= value <= _UINT32_MAX:
        raise ValueError(f"{label} must be an unsigned 32-bit integer")
    return value


def _check_chunk_id(chunk_id):
    if not isinstance(chunk_id, str) or _CHUNK_ID.fullmatch(chunk_id) is None:
        raise ValueError("Invalid navigation chunk ID")


def _check_digest(digest, label):
    if not isinstance(digest, str) or _DIGEST.fullmatch(digest) is None:
        raise ValueError(f"Invalid navigation {label}")


def _cache_key(metadata, digest, grid_size_m):
    if "grid_size_m" in metadata and _grid_size(metadata["grid_size_m"]) != grid_size_m:
        raise ValueError("Navigation grid size does not match chunk metadata")
    if "cache_key" not in metadata:
        fallback = _json_bytes({"chunk_sha256": digest, "chunk_size_m": grid_size_m})
        return hashlib.sha256(fallback).hexdigest()
    key = metadata["cache_key"]
    _check_digest(key, "cache key")
    return key


def _json_bytes(value):
    try:
        return json.dumps(value, sort_keys=True, separators=(",", ":"), allow_nan=False).encode("ascii")
    except (TypeError, ValueError, RecursionError) as exc:
        raise ValueError(f"Invalid navigation JSON: {exc}") from exc


def _json_object(data):
    try:
        value = json.loads(data)
    except (ValueError, RecursionError) as exc:
        raise ValueError(f"Invalid navigation JSON: {exc}") from exc
    if not isinstance(value, dict):
        raise ValueError("Navigation JSON must be an object")
    return value


def _check_graph(graph):
    node_count = _count(len(graph.nodes), "Node count")
    edge_count = _count(len(graph.edges), "Edge count")
    component_count = _count(graph.component_count, "Component count")
    if bool(node_count) != bool(component_count) or not 0 <= node_count - component_count <= edge_count:
        raise ValueError("Invalid navigation component count")

    previous_point = None
    for position in graph.nodes:
        current_point = finite_point(position, "Node position")
        if previous_point is not None and current_point <= previous_point:
            raise ValueError("Navigation nodes must be sorted and unique")
        previous_point = current_point

    previous_pair = (-1, -1)
    for edge in graph.edges:
        source = _count(edge.source, "Edge source")
        target = _count(edge.target, "Edge target")
        if not source < target < node_count or (source, target) <= previous_pair:
            raise ValueError("Navigation edges must be sorted, unique pairs of existing node IDs")
        previous_pair = (source, target)
        if (finite_number(edge.distance_m, "Edge distance") <= 0
                or finite_number(edge.clearance_m, "Edge clearance") < 0
                or finite_number(edge.cost, "Edge cost") < 0):
            raise ValueError("Invalid navigation edge metrics")
        _count(edge.flags, "Edge flags")


def encode_chunk(*, chunk_id: str, origin: Point, graph: Graph, metadata: dict) -> bytes:
    """Encode canonical graph data with a trailing SHA-256 over all other bytes."""
    _check_chunk_id(chunk_id)
    origin = finite_point(origin, "Grid origin")
    _check_graph(graph)
    if not isinstance(metadata, dict):
        raise ValueError("Navigation metadata must be an object")
    if "cache_key" in metadata:
        _check_digest(metadata["cache_key"], "cache key")
    metadata_bytes = _json_bytes(metadata)
    chunk_id_bytes = chunk_id.encode("ascii")
    header = _HEADER.pack(
        _MAGIC, SCHEMA, 0, *origin, len(chunk_id_bytes), len(graph.nodes),
        len(graph.edges), 0, graph.component_count, _count(len(metadata_bytes), "Metadata size"),
    )
    payload = bytearray(header)
    payload.extend(chunk_id_bytes)
    for position in graph.nodes:
        payload.extend(_NODE.pack(*finite_point(position, "Node position")))
    for edge in graph.edges:
        payload.extend(_EDGE.pack(
            edge.source, edge.target, edge.distance_m, edge.clearance_m, edge.cost, edge.flags,
        ))
    payload.extend(metadata_bytes)
    payload.extend(hashlib.sha256(payload).digest())
    return bytes(payload)


def decode_chunk(data: bytes) -> StoredChunk:
    """Read an SNAV chunk and check the layout, checksum and graph structure."""
    if len(data) < _HEADER.size + _CHECKSUM_BYTES:
        raise ValueError("Truncated navigation chunk header")
    (magic, version, flags, x, y, z, id_size, node_count, edge_count, portal_count,
     components, metadata_size) = _HEADER.unpack_from(data)
    if magic != _MAGIC or version != SCHEMA or flags or portal_count:
        raise ValueError("Unsupported navigation chunk header")
    nodes_offset = _HEADER.size + id_size
    edges_offset = nodes_offset + node_count * _NODE.size
    metadata_offset = edges_offset + edge_count * _EDGE.size
    checksum_offset = metadata_offset + metadata_size
    if id_size > 80 or checksum_offset + _CHECKSUM_BYTES != len(data):
        raise ValueError("Invalid navigation chunk section sizes")
    view = memoryview(data)
    if hashlib.sha256(view[:checksum_offset]).digest() != view[checksum_offset:]:
        raise ValueError("Navigation chunk checksum mismatch")

    try:
        chunk_id = data[_HEADER.size:nodes_offset].decode("ascii")
    except UnicodeDecodeError as exc:
        raise ValueError("Invalid navigation chunk ID") from exc
    _check_chunk_id(chunk_id)
    origin = finite_point((x, y, z), "Grid origin")
    metadata_bytes = data[metadata_offset:checksum_offset]
    metadata = _json_object(metadata_bytes)
    if _json_bytes(metadata) != metadata_bytes:
        raise ValueError("Navigation chunk metadata must use canonical JSON")
    if "cache_key" in metadata:
        _check_digest(metadata["cache_key"], "cache key")
    nodes = tuple(_NODE.iter_unpack(view[nodes_offset:edges_offset]))
    edges = tuple(Edge(*values) for values in _EDGE.iter_unpack(view[edges_offset:metadata_offset]))
    graph = Graph(nodes, edges, components)
    _check_graph(graph)
    return StoredChunk(chunk_id, origin, graph, metadata)


def load_chunk(path: str | Path) -> StoredChunk:
    return decode_chunk(Path(path).read_bytes())


def _chunk_path(chunk_id, digest):
    return f"chunks/{chunk_id}-{digest}.snav"


def _portal_path(digest):
    return f"portals/{digest}.json"


def _sync_directory(directory):
    if os.name != "posix":
        return
    descriptor = os.open(directory, os.O_RDONLY)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def _write_atomic(path, data, *, replace):
    descriptor, name = tempfile.mkstemp(dir=path.parent, prefix=f".{path.name}.")
    pending = Path(name)
    try:
        with os.fdopen(descriptor, "wb") as stream:
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        if replace:
            os.replace(pending, path)
        else:
            os.link(pending, path)
        _sync_directory(path.parent)
    finally:
        pending.unlink(missing_ok=True)


def _chunk_summary(graph, byte_count):
    return {
        "byte_count": byte_count,
        "node_count": len(graph.nodes),
        "edge_count": len(graph.edges),
        "component_count": graph.component_count,
    }


def _grid_size(value):
    value = finite_number(value, "Grid size")
    if value <= 0:
        raise ValueError("Grid size must be positive")
    return value


def _check_manifest_header(manifest):
    if (manifest.get("format") != _FORMAT or type(manifest.get("schema")) is not int
            or manifest["schema"] != SCHEMA or manifest.get("units") != UNITS
            or manifest.get("axes") != AXES):
        raise ValueError("Unsupported navigation manifest")


def _has_navigation_manifest(path):
    try:
        file_mode = path.lstat().st_mode
    except FileNotFoundError:
        return False
    if not stat.S_ISREG(file_mode):
        raise ValueError(f"Navigation manifest must be a regular file: {path}")
    _check_manifest_header(_json_object(path.read_bytes()))
    return True


MANIFEST_NAMES = ("manifest.json", "manifest.flight_graph.json")


def validate_output(output_dir: str | Path, manifest_name: str = MANIFEST_NAMES[0]) -> None:
    """Check that publication can use this directory without replacing unrelated data."""
    output_dir = Path(output_dir)
    if output_dir.exists() and not output_dir.is_dir():
        raise ValueError(f"Navigation output must be a directory: {output_dir}")
    chunks = output_dir / "chunks"
    if chunks.is_symlink() or (chunks.exists() and not chunks.is_dir()):
        raise ValueError(f"Navigation chunks must be a directory: {chunks}")
    if manifest_name not in MANIFEST_NAMES:
        raise ValueError("Unsupported navigation manifest filename")
    _has_navigation_manifest(output_dir / manifest_name)


def _write_immutable(path, content):
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.parent.is_symlink():
        raise ValueError(f"Navigation data directory may not be a symbolic link: {path.parent}")
    try:
        _write_atomic(path, content, replace=False)
    except FileExistsError:
        if path.is_symlink() or not path.is_file() or path.read_bytes() != content:
            raise ValueError(f"Existing navigation file has a different digest: {path}") from None
        _sync_directory(path.parent)


def _publish_manifest(path, data):
    if not _has_navigation_manifest(path):
        try:
            _write_atomic(path, data, replace=False)
            return
        except FileExistsError:
            # A first-time publisher won the race. Check the existing file before replacing.
            if not _has_navigation_manifest(path):
                raise
    _write_atomic(path, data, replace=True)


def _store_chunk(output_dir, chunk_id, origin, grid_size_m, graph, metadata):
    encoded = encode_chunk(chunk_id=chunk_id, origin=origin, graph=graph, metadata=metadata)
    digest = hashlib.sha256(encoded).hexdigest()
    relative_path = _chunk_path(chunk_id, digest)
    summary = _chunk_summary(graph, len(encoded))
    summary.update({"sha256": digest, "cache_key": _cache_key(metadata, digest, grid_size_m)})
    _write_immutable(output_dir / relative_path, encoded)
    return {"path": relative_path, **summary}


def _manifest(origin, grid_size_m, chunks):
    return {
        "format": _FORMAT,
        "schema": SCHEMA,
        "units": UNITS,
        "axes": AXES,
        "origin": origin,
        "chunk_size_m": grid_size_m,
        "chunks": chunks,
    }


def publish_chunk(output_dir: str | Path, *, chunk_id: str, origin: Point,
                  grid_size_m: float, graph: Graph, metadata: dict) -> dict:
    """Publish one immutable chunk, then atomically replace its manifest."""
    output_dir = Path(output_dir)
    validate_output(output_dir)
    origin = finite_point(origin, "Grid origin")
    grid_size_m = _grid_size(grid_size_m)
    summary = _store_chunk(output_dir, chunk_id, origin, grid_size_m, graph, metadata)
    manifest = _manifest(origin, grid_size_m, {chunk_id: summary})
    manifest_path = output_dir / "manifest.json"
    _publish_manifest(manifest_path, _json_bytes(manifest) + b"\n")
    chunk_path = output_dir / summary.pop("path")
    return {"manifest": str(manifest_path), "chunk": str(chunk_path), **summary}


def _portal_records(portals, chunks):
    records = {}
    endpoint_pairs = set()
    for portal in portals:
        if not isinstance(portal, dict):
            raise ValueError("A navigation portal must be an object")
        portal_id = portal.get("id")
        _check_digest(portal_id, "portal ID")
        endpoints = []
        for role in ("from", "to"):
            chunk_id = portal.get(f"{role}_chunk")
            _check_chunk_id(chunk_id)
            node = _count(portal.get(f"{role}_node"), "Portal node ID")
            entry = chunks.get(chunk_id)
            if not isinstance(entry, dict) or node >= _count(entry.get("node_count"), "Node count"):
                raise ValueError("Navigation portal refers to an unknown chunk or node")
            endpoints.append((chunk_id, node))
        if endpoints[0][0] == endpoints[1][0]:
            raise ValueError("Navigation portal must connect different chunks")
        pair = tuple(sorted(endpoints))
        if portal_id in records or pair in endpoint_pairs:
            raise ValueError("Duplicate navigation portal")
        distance = finite_number(portal.get("distance_m"), "Portal distance")
        clearance = finite_number(portal.get("clearance_m"), "Portal clearance")
        if distance <= 0 or clearance < 0:
            raise ValueError("Invalid navigation portal metrics")
        position = finite_point(portal.get("position"), "Portal position")
        records[portal_id] = {
            "id": portal_id,
            "from_chunk": endpoints[0][0],
            "from_node": endpoints[0][1],
            "to_chunk": endpoints[1][0],
            "to_node": endpoints[1][1],
            "position": list(position),
            "distance_m": distance,
            "clearance_m": clearance,
        }
        endpoint_pairs.add(pair)
    return tuple(records[portal_id] for portal_id in sorted(records))


def publish_world(output_dir: str | Path, *, origin: Point, grid_size_m: float,
                  chunks, portals, metadata: dict, manifest_name: str = MANIFEST_NAMES[0]) -> dict:
    """Stream chunk records, then publish one manifest for the complete snapshot."""
    output_dir = Path(output_dir)
    validate_output(output_dir, manifest_name)
    directory = output_dir / "portals"
    if directory.is_symlink() or (directory.exists() and not directory.is_dir()):
        raise ValueError(f"Navigation portals must be a directory: {directory}")
    if not isinstance(metadata, dict):
        raise ValueError("Navigation world metadata must be an object")
    origin = finite_point(origin, "Grid origin")
    grid_size_m = _grid_size(grid_size_m)
    entries = {}
    for chunk_id, graph, chunk_metadata in chunks:
        _check_chunk_id(chunk_id)
        if chunk_id in entries:
            raise ValueError(f"Duplicate navigation chunk {chunk_id}")
        entries[chunk_id] = _store_chunk(output_dir, chunk_id, origin, grid_size_m, graph, chunk_metadata)
    if not entries:
        raise ValueError("A navigation world must publish at least one chunk")

    records = _portal_records(portals, entries)
    portal_data = _json_bytes({"schema": SCHEMA, "portals": records}) + b"\n"
    portal_digest = hashlib.sha256(portal_data).hexdigest()
    portal_path = _portal_path(portal_digest)
    _write_immutable(output_dir / portal_path, portal_data)
    manifest = _manifest(origin, grid_size_m, entries)
    manifest["world"] = metadata
    manifest["portals"] = {"path": portal_path, "sha256": portal_digest, "count": len(records)}
    manifest_path = output_dir / manifest_name
    _publish_manifest(manifest_path, _json_bytes(manifest) + b"\n")
    return {
        "manifest": str(manifest_path),
        "portal_index": str(output_dir / portal_path),
        "chunk_count": len(entries),
        "portal_count": len(records),
        **{key: sum(entry[key] for entry in entries.values())
           for key in ("node_count", "edge_count", "byte_count")},
    }


def _read_manifest(manifest_path):
    manifest = _json_object(manifest_path.read_bytes())
    _check_manifest_header(manifest)
    chunks = manifest.get("chunks")
    if not isinstance(chunks, dict) or not chunks:
        raise ValueError("Navigation manifest must publish at least one chunk")
    return manifest, chunks


def _read_published_file(manifest_path, relative_path, digest):
    path = manifest_path.parent / relative_path
    if path.is_symlink() or path.parent.is_symlink():
        raise ValueError("Published navigation data path may not be a symbolic link")
    if path.exists() and not path.is_file():
        raise ValueError("Published navigation data must be a regular file")
    data = path.read_bytes()
    if hashlib.sha256(data).hexdigest() != digest:
        raise ValueError("Navigation manifest checksum mismatch")
    return data


def load_published_chunk(manifest_path: str | Path, chunk_id: str | None = None) -> StoredChunk:
    """Load an explicit chunk, or the sole chunk of a legacy manifest."""
    manifest_path = Path(manifest_path)
    manifest, chunks = _read_manifest(manifest_path)
    origin = finite_point(manifest.get("origin"), "Grid origin")
    grid_size_m = _grid_size(manifest.get("chunk_size_m"))
    if chunk_id is None:
        if len(chunks) != 1:
            raise ValueError("Select a navigation chunk ID from the world manifest")
        chunk_id = next(iter(chunks))
    _check_chunk_id(chunk_id)
    entry = chunks.get(chunk_id)
    if not isinstance(entry, dict):
        raise ValueError(f"Unknown or invalid navigation manifest chunk {chunk_id}")
    digest = entry.get("sha256")
    _check_digest(digest, "chunk digest")
    relative_path = _chunk_path(chunk_id, digest)
    if entry.get("path") != relative_path:
        raise ValueError("Invalid navigation manifest chunk path")
    data = _read_published_file(manifest_path, relative_path, digest)
    chunk = decode_chunk(data)
    if (chunk.chunk_id != chunk_id or chunk.origin != origin
            or _cache_key(chunk.metadata, digest, grid_size_m) != entry.get("cache_key")):
        raise ValueError("Navigation manifest does not match the chunk header")
    for key, value in _chunk_summary(chunk.graph, len(data)).items():
        if _count(entry.get(key), key) != value:
            raise ValueError(f"Navigation manifest does not match chunk {key}")
    return chunk


def load_published_portals(manifest_path: str | Path) -> tuple[dict, ...]:
    """Load the verified portal index, or an empty tuple for a legacy chunk."""
    manifest_path = Path(manifest_path)
    manifest, chunks = _read_manifest(manifest_path)
    if "portals" not in manifest and "world" not in manifest and len(chunks) == 1:
        return ()
    descriptor = manifest.get("portals")
    if not isinstance(descriptor, dict) or not isinstance(manifest.get("world"), dict):
        raise ValueError("Invalid navigation world manifest or missing portal index")
    count = _count(descriptor.get("count"), "Portal count")
    digest = descriptor.get("sha256")
    _check_digest(digest, "portal index digest")
    relative_path = _portal_path(digest)
    if descriptor.get("path") != relative_path:
        raise ValueError("Invalid navigation manifest portal path")
    data = _read_published_file(manifest_path, relative_path, digest)
    index = _json_object(data)
    portals = index.get("portals")
    if type(index.get("schema")) is not int or index["schema"] != SCHEMA or not isinstance(portals, list):
        raise ValueError("Unsupported navigation portal index")
    if count != len(portals):
        raise ValueError("Navigation manifest does not match portal count")
    records = _portal_records(portals, chunks)
    if list(records) != portals or _json_bytes(index) + b"\n" != data:
        raise ValueError("Navigation portal index must use sorted records and canonical JSON")
    return records
