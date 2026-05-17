"""OpenSkiMap source fetcher.

OpenSkiMap is an OSM-derived ski-aware GeoJSON exporter. It does the
hard work of joining piste / aerialway tags into coherent ski-area
polygons and resolving connectivity across way fragments.

API:
  GET https://tiles.skimap.org/geojson/runs.geojson?bbox=...
  GET https://tiles.skimap.org/geojson/lifts.geojson?bbox=...

Returned features carry properties.name, properties.difficulty,
properties.aerialway / piste:type, properties.osmId so we can join
back to GraphBuilder edges later.
"""

from __future__ import annotations
import json
import time
from pathlib import Path
from typing import Dict, Optional, List, Tuple
from urllib.request import Request, urlopen
from urllib.error import URLError, HTTPError

from canonical_ingest.models import SourceItem, SourceResult


RUNS_URL = "https://tiles.skimap.org/geojson/runs.geojson"
LIFTS_URL = "https://tiles.skimap.org/geojson/lifts.geojson"
USER_AGENT = "powdermeet-canonical-ingest/0.1 (+https://powdermeet.app)"

CACHE_DIR = Path(__file__).resolve().parent.parent / "fixtures" / "openskimap"
CACHE_TTL_SECONDS = 7 * 24 * 3600
REQUEST_TIMEOUT = 60


def fetch(resort_id: str, hints: Optional[Dict[str, object]] = None) -> SourceResult:
    """Pull trails + lifts for `resort_id` from OpenSkiMap.

    `hints` MUST include `bbox: (south, west, north, east)` since this
    source is bbox-bound. Without a bbox, returns an empty SourceResult
    so reconcile.py can fail loudly instead of silently underreporting.
    """
    hints = hints or {}
    bbox = hints.get("bbox")
    if not bbox:
        return SourceResult(source="openskimap", resort_id=resort_id)

    runs = _fetch_geojson(resort_id, "runs", bbox)
    lifts = _fetch_geojson(resort_id, "lifts", bbox)

    items: List[SourceItem] = []
    items.extend(_extract_features(runs, kind="trail"))
    items.extend(_extract_features(lifts, kind="lift"))

    return SourceResult(
        source="openskimap",
        resort_id=resort_id,
        items=tuple(items),
        fetched_at=_iso_now(),
    )


def _fetch_geojson(
    resort_id: str,
    kind: str,
    bbox: Tuple[float, float, float, float],
) -> Optional[dict]:
    cache_path = CACHE_DIR / f"{resort_id}-{kind}.json"
    cached = _read_cached_json(cache_path)
    if cached is not None:
        return cached
    url = RUNS_URL if kind == "runs" else LIFTS_URL
    south, west, north, east = bbox
    full = f"{url}?bbox={west},{south},{east},{north}"
    body = _http_get(full)
    if body is None:
        return None
    try:
        data = json.loads(body)
    except ValueError:
        return None
    _write_cached_json(cache_path, data)
    return data


def _extract_features(geojson: Optional[dict], *, kind: str) -> List[SourceItem]:
    if not geojson:
        return []
    out: List[SourceItem] = []
    seen_keys = set()
    for feat in geojson.get("features") or []:
        props = feat.get("properties") or {}
        name = (props.get("name") or "").strip()
        if not name:
            continue
        key = (kind, name.lower())
        if key in seen_keys:
            # OSM splits a single trail into many ways; collapse by name.
            continue
        seen_keys.add(key)
        geometry = _coerce_linestring(feat.get("geometry"))
        osm_ids = _extract_osm_ids(props)
        extra: Dict[str, object] = {}
        if kind == "trail":
            extra["difficulty"] = _normalize_difficulty(props.get("difficulty"))
            extra["is_groomed"] = props.get("grooming") in ("classic", "groomed")
        else:
            extra["lift_type"] = _normalize_aerialway(props.get("aerialway"))
        out.append(SourceItem(
            kind=kind,                       # type: ignore[arg-type]
            name=name,
            confidence=0.85,
            geometry=geometry,
            osm_way_ids=tuple(osm_ids),
            extra=extra,
        ))
    return out


def _coerce_linestring(geometry: Optional[dict]):
    if not geometry:
        return None
    if geometry.get("type") == "LineString":
        coords = geometry.get("coordinates") or []
        return [(float(c[0]), float(c[1])) for c in coords if len(c) >= 2]
    # MultiLineString: flatten with simple concat (loses topology — fine for
    # name-key reconciliation, geometry-quality checks happen in geometry_tool)
    if geometry.get("type") == "MultiLineString":
        out = []
        for line in geometry.get("coordinates") or []:
            for c in line:
                if len(c) >= 2:
                    out.append((float(c[0]), float(c[1])))
        return out or None
    return None


def _extract_osm_ids(props: dict) -> List[str]:
    ids = []
    for key in ("osmId", "osmid", "way_id"):
        raw = props.get(key)
        if raw is not None:
            ids.append(str(raw))
    osm_uri = props.get("@id") or props.get("id")
    if isinstance(osm_uri, str) and osm_uri.startswith("way/"):
        ids.append(osm_uri.split("/", 1)[1])
    return ids


def _normalize_difficulty(raw: object) -> Optional[str]:
    if not raw:
        return None
    s = str(raw).lower()
    if s in ("novice", "easy"):
        return "green"
    if s == "intermediate":
        return "blue"
    if s == "advanced":
        return "black"
    if s in ("expert", "freeride", "extreme"):
        return "doubleBlack"
    return None


def _normalize_aerialway(raw: object) -> Optional[str]:
    if not raw:
        return None
    s = str(raw).lower()
    if s == "gondola":
        return "gondola"
    if s in ("chair_lift", "chairlift"):
        return "chairlift"
    if s == "funicular":
        return "funicular"
    if s == "t-bar":
        return "tBar"
    if s == "platter":
        return "platter"
    if s == "magic_carpet":
        return "magicCarpet"
    if s == "rope_tow":
        return "rope"
    if s == "cable_car":
        return "cableCar"
    return None


def _http_get(url: str) -> Optional[bytes]:
    req = Request(url, headers={"User-Agent": USER_AGENT})
    try:
        with urlopen(req, timeout=REQUEST_TIMEOUT) as resp:
            return resp.read()
    except (URLError, HTTPError):
        return None


def _read_cached_json(path: Path) -> Optional[object]:
    if not path.exists():
        return None
    if time.time() - path.stat().st_mtime > CACHE_TTL_SECONDS:
        return None
    try:
        return json.loads(path.read_text())
    except (OSError, ValueError):
        return None


def _write_cached_json(path: Path, data: object) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    try:
        path.write_text(json.dumps(data))
    except OSError:
        pass


def _iso_now() -> str:
    from datetime import datetime, timezone
    return datetime.now(timezone.utc).isoformat()
