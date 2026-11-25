"""OpenSkiMap runs and lifts for resort bounding boxes.

The published GeoJSON downloads are whole-world files with one feature per line
(about 280 MB compressed). They are downloaded once into the cache and scanned in a
single pass for every resort asked for, so a batch of resorts costs one pass.

OpenSkiMap is derived from OSM: it corroborates names, normalizes difficulty and
says which ski area a run belongs to, but it is not independent official evidence.
"""

from __future__ import annotations

import gzip
import json
import re
import time
from email.utils import parsedate_to_datetime
from pathlib import Path
from urllib.request import Request, urlopen

URLS = {
    "runs": "https://tiles.openskimap.org/geojson/runs.geojson",
    "lifts": "https://tiles.openskimap.org/geojson/lifts.geojson",
}
USER_AGENT = "powdermeet-pipeline/1.0 (+https://powdermeet.app)"
WORLD_MAX_AGE_S = 7 * 24 * 3600
MARGIN_DEG = 0.05
"""Features are collected this far beyond the catalog bbox, so a ski area that
spills over a tight catalog box is still seen whole."""

_FIRST_POSITION = re.compile(rb'"coordinates":\[+(-?[0-9.]+),(-?[0-9.]+)')
_KEPT_PROPERTIES = (
    "id", "name", "ref", "type", "status", "uses", "difficulty", "difficultyConvention",
    "grooming", "oneway", "liftType", "capacity", "duration", "sources",
)


def fetch(bbox, cache_dir: Path) -> dict:
    return fetch_many({"resort": bbox}, cache_dir)["resort"]


def fetch_many(boxes: dict[str, list[float]], cache_dir: Path) -> dict[str, dict]:
    """Features near each box, keyed like `boxes`."""
    files = ensure_world(cache_dir)
    margins = {
        key: [b[0] - MARGIN_DEG, b[1] - MARGIN_DEG, b[2] + MARGIN_DEG, b[3] + MARGIN_DEG]
        for key, b in boxes.items()
    }
    # One-degree cells, so each line is tested against the few boxes near it.
    cells: dict[tuple[int, int], list[str]] = {}
    for key, box in margins.items():
        for x in range(int(box[0] // 1) - 1, int(box[2] // 1) + 2):
            for y in range(int(box[1] // 1) - 1, int(box[3] // 1) + 2):
                cells.setdefault((x, y), []).append(key)

    out = {
        key: {"source": "openskimap", "published_at": files["published_at"], "runs": [], "lifts": []}
        for key in boxes
    }
    for kind in ("runs", "lifts"):
        with gzip.open(files[kind], "rb") as stream:
            for line in stream:
                match = _FIRST_POSITION.search(line)
                if not match:
                    continue
                lon, lat = float(match.group(1)), float(match.group(2))
                near = cells.get((int(lon // 1), int(lat // 1)))
                if not near:
                    continue
                feature = _parse(line)
                if feature is None:
                    continue
                extent = _extent(feature)
                if extent is None:
                    continue
                slimmed = None
                for key in near:
                    box = margins[key]
                    if extent[0] <= box[2] and extent[2] >= box[0] and extent[1] <= box[3] and extent[3] >= box[1]:
                        slimmed = slimmed or slim(feature, extent)
                        out[key][kind].append(slimmed)
    for data in out.values():
        for kind in ("runs", "lifts"):
            data[kind].sort(key=lambda f: str(f.get("id")))
    return out


def ensure_world(cache_dir: Path) -> dict:
    """Download the world files unless a recent copy is cached."""
    directory = Path(cache_dir) / "openskimap"
    directory.mkdir(parents=True, exist_ok=True)
    published = []
    files: dict = {}
    for kind, url in URLS.items():
        path = directory / f"{kind}.geojson.gz"
        headers = directory / f"{kind}.headers"
        if not path.exists() or time.time() - path.stat().st_mtime > WORLD_MAX_AGE_S:
            _download(url, path, headers)
        files[kind] = path
        if headers.exists():
            match = re.search(r"(?im)^last-modified:\s*(.+?)\s*$", headers.read_text())
            if match:
                published.append(_http_date(match.group(1)))
    files["published_at"] = min(filter(None, published), default=None)
    return files


def _download(url: str, path: Path, headers_path: Path) -> None:
    request = Request(url, headers={"User-Agent": USER_AGENT, "Accept-Encoding": "gzip"})
    partial = path.with_suffix(".part")
    with urlopen(request, timeout=120) as response:
        gzipped = response.headers.get("Content-Encoding", "").lower() == "gzip"
        sink = open(partial, "wb") if gzipped else gzip.open(partial, "wb", compresslevel=1)
        with sink:
            while True:
                chunk = response.read(1 << 20)
                if not chunk:
                    break
                sink.write(chunk)
        headers_path.write_text(f"last-modified: {response.headers.get('Last-Modified', '')}\n")
    partial.replace(path)


def _parse(line: bytes) -> dict | None:
    text = line.strip().rstrip(b",")
    if text.endswith(b"]}") and not text.endswith(b"}}"):
        text = text[:-2]
    try:
        feature = json.loads(text)
    except ValueError:
        return None
    return feature if isinstance(feature, dict) else None


def _extent(feature: dict) -> list[float] | None:
    positions = list(_positions((feature.get("geometry") or {}).get("coordinates")))
    if not positions:
        return None
    return [
        round(min(p[0] for p in positions), 5), round(min(p[1] for p in positions), 5),
        round(max(p[0] for p in positions), 5), round(max(p[1] for p in positions), 5),
    ]


def slim(feature: dict, extent: list[float] | None = None) -> dict:
    """The properties reconcile reads. Geometry is dropped (the OSM ways the
    feature cites carry it); only its extent is kept."""
    properties = feature.get("properties") or {}
    kept = {key: properties[key] for key in _KEPT_PROPERTIES if properties.get(key) is not None}
    kept["ski_areas"] = sorted({
        str((area.get("properties") or {}).get("name"))
        for area in properties.get("skiAreas") or []
        if (area.get("properties") or {}).get("name")
    })
    kept["geometry_type"] = (feature.get("geometry") or {}).get("type")
    if extent:
        kept["extent"] = extent
    return kept


def _positions(value):
    if not isinstance(value, list) or not value:
        return
    if isinstance(value[0], (int, float)):
        if len(value) >= 2:
            yield value[:2]
    else:
        for part in value:
            yield from _positions(part)


def _http_date(value: str | None) -> str | None:
    if not value:
        return None
    try:
        return parsedate_to_datetime(value).strftime("%Y-%m-%dT%H:%M:%SZ")
    except (TypeError, ValueError):
        return None
