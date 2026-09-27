"""OpenSkiData/OpenSkiMap candidate inventory adapter.

The documented GeoJSON downloads are worldwide files, not bbox endpoints.
Cache each world file once and filter locally before reconciling a resort.
Schema and download policy: https://openskidata.org/ (checked 2026-09-20).
This OSM-derived source is not independent official inventory evidence.
"""

from __future__ import annotations
import json
import math
import time
from pathlib import Path
from typing import Dict, Optional, List, Tuple
from urllib.request import Request, urlopen
from urllib.error import URLError, HTTPError

from canonical_ingest.models import SourceItem, SourceResult
from canonical_ingest.sources.common import merge_duplicate_items, normalize_grooming


RUNS_URL = "https://tiles.openskimap.org/geojson/runs.geojson"
LIFTS_URL = "https://tiles.openskimap.org/geojson/lifts.geojson"
USER_AGENT = "powdermeet-canonical-ingest/0.1 (+https://powdermeet.app)"

CACHE_DIR = Path(__file__).resolve().parents[3] / "_local" / "source-cache" / "openskimap"
CACHE_TTL_SECONDS = 7 * 24 * 3600
REQUEST_TIMEOUT = 300


def fetch(resort_id: str, hints: Optional[Dict[str, object]] = None) -> SourceResult:
    """Pull trails + lifts for `resort_id` from OpenSkiMap.

    `hints` MUST include `bbox: (south, west, north, east)` since this
    source is bbox-bound. Without a bbox, returns an empty SourceResult
    so reconcile.py can fail loudly instead of silently underreporting.
    """
    hints = hints or {}
    bbox = hints.get("bbox")
    if not bbox:
        raise ValueError("OpenSkiMap source requires a bbox hint")

    runs = _fetch_geojson(resort_id, "runs", bbox)
    lifts = _fetch_geojson(resort_id, "lifts", bbox)
    if runs is None or lifts is None:
        missing = [
            kind for kind, payload in (("runs", runs), ("lifts", lifts))
            if payload is None
        ]
        raise RuntimeError(f"OpenSkiMap request failed for {', '.join(missing)}")

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
    # These are static world downloads. Per-resort query strings are ignored
    # upstream and previously made every mountain ingest the same world data.
    cache_path = CACHE_DIR / f"world-v16-{kind}.json"
    data = _read_cached_json(cache_path)
    if data is None:
        body = _http_get(RUNS_URL if kind == "runs" else LIFTS_URL)
        if body is None:
            return None
        try:
            data = json.loads(body)
        except ValueError:
            return None
        if not isinstance(data, dict) or not isinstance(data.get("features"), list):
            return None
        _write_cached_json(cache_path, data)
    return _filter_bbox(data, bbox)


def _filter_bbox(data: dict, bbox: Tuple[float, float, float, float]) -> dict:
    south, west, north, east = bbox
    if not all(math.isfinite(v) for v in bbox) or not (-90 <= south < north <= 90 and -180 <= west < east <= 180):
        raise ValueError("invalid resort bbox")

    def positions(value):
        if not isinstance(value, list) or not value:
            return
        if len(value) >= 2 and all(isinstance(v, (int, float)) for v in value[:2]):
            if all(math.isfinite(v) for v in value[:2]):
                yield value[:2]
        else:
            for part in value:
                yield from positions(part)

    def intersects(feature):
        coordinates = list(positions((feature.get("geometry") or {}).get("coordinates")))
        if not coordinates:
            return False
        return (min(c[0] for c in coordinates) <= east and max(c[0] for c in coordinates) >= west
                and min(c[1] for c in coordinates) <= north and max(c[1] for c in coordinates) >= south)

    # Extent overlap yields candidates only, including ways crossing the box.
    # Exact resort ownership still requires the canonical identity review.
    return {"type": "FeatureCollection", "features": [f for f in data.get("features", []) if intersects(f)]}


def _extract_features(geojson: Optional[dict], *, kind: str) -> List[SourceItem]:
    if not geojson:
        return []
    out: List[SourceItem] = []
    for feat in geojson.get("features") or []:
        props = feat.get("properties") or {}
        if props.get("status") not in (None, "operating"):
            continue
        if kind == "trail" and "uses" in props and "downhill" not in props["uses"]:
            continue
        if kind == "lift" and str(props.get("liftType") or props.get("aerialway") or "").lower() in {
            "station", "pylon", "zip_line",
        }:
            continue
        name = (props.get("name") or "").strip()
        if not name:
            continue
        geometry = _coerce_linestring(feat.get("geometry"))
        osm_ids = _extract_osm_ids(props)
        extra: Dict[str, object] = {}
        if kind == "trail":
            extra["difficulty"] = _normalize_difficulty(props.get("difficulty"))
            extra["is_groomed"] = normalize_grooming(props.get("grooming"))
        else:
            extra["lift_type"] = _normalize_aerialway(props.get("liftType") or props.get("aerialway"))
        out.append(SourceItem(
            kind=kind,                       # type: ignore[arg-type]
            name=name,
            confidence=0.85,
            geometry=geometry,
            osm_way_ids=tuple(osm_ids),
            extra=extra,
        ))
    return merge_duplicate_items(out)


def _coerce_linestring(geometry: Optional[dict]):
    if not geometry:
        return None
    if geometry.get("type") == "LineString":
        coords = geometry.get("coordinates") or []
        return [(float(c[0]), float(c[1])) for c in coords if len(c) >= 2]
    # A disconnected MultiLineString cannot be represented as one line.
    # Keep source IDs for review, without drawing a fabricated joining segment.
    return None


def _extract_osm_ids(props: dict) -> List[str]:
    ids = []
    for source in props.get("sources") or []:
        source_id = str(source.get("id") or "")
        if source.get("type") == "openstreetmap" and source_id.startswith("way/"):
            way_id = source_id.split("/", 1)[1]
            if way_id.isdigit():
                ids.append(way_id)
    for key in ("osmId", "osmid", "way_id"):
        raw = props.get(key)
        if raw is not None:
            ids.append(str(raw))
    osm_uri = props.get("@id") or props.get("id")
    if isinstance(osm_uri, str) and osm_uri.startswith("way/"):
        ids.append(osm_uri.split("/", 1)[1])
    return sorted(set(ids))


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
        return "chair_lift"
    if s == "mixed_lift":
        return "unknown"
    if s == "funicular":
        return "funicular"
    if s in ("t-bar", "j-bar", "drag_lift"):
        return s
    if s == "platter":
        return "platter"
    if s == "magic_carpet":
        return "magic_carpet"
    if s == "rope_tow":
        return "rope_tow"
    if s == "cable_car":
        return "cable_car"
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
