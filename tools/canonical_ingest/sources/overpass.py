"""Overpass (raw OSM) source fetcher.

Mirrors the query shape used by the existing
`supabase/functions/snapshot-resort/index.ts:fetchOverpass` so this
fetcher's results align with what the build pipeline sees today. The
goal is parity: if reconcile.py says Overpass disagrees with Skimap on
a name, that disagreement is real, not a query-shape difference.

Confidence weight is the lowest of the four sources because raw OSM
tags are inconsistent (unnamed ways, conflicting `piste:type` values,
`name` fields that include difficulty markers, etc.).
"""

from __future__ import annotations
import json
import time
from pathlib import Path
from typing import Dict, Optional, List, Tuple
from urllib.request import Request, urlopen
from urllib.error import URLError, HTTPError

from canonical_ingest.models import SourceItem, SourceResult


OVERPASS_URL = "https://overpass-api.de/api/interpreter"
USER_AGENT = "powdermeet-canonical-ingest/0.1 (+https://powdermeet.app)"
CACHE_DIR = Path(__file__).resolve().parent.parent / "fixtures" / "overpass"
CACHE_TTL_SECONDS = 24 * 3600
REQUEST_TIMEOUT = 120


def fetch(resort_id: str, hints: Optional[Dict[str, object]] = None) -> SourceResult:
    """Query Overpass for trails + lifts within `bbox`.

    `hints` MUST include `bbox: (south, west, north, east)`.
    """
    hints = hints or {}
    bbox = hints.get("bbox")
    if not bbox:
        return SourceResult(source="overpass", resort_id=resort_id)

    south, west, north, east = bbox  # type: ignore[misc]
    cache_path = CACHE_DIR / f"{resort_id}.json"
    cached = _read_cached_json(cache_path)
    if cached is not None:
        data = cached
    else:
        data = _post_overpass(_build_query(south, west, north, east))
        if data is None:
            return SourceResult(source="overpass", resort_id=resort_id)
        _write_cached_json(cache_path, data)

    items = _extract_items(data)
    return SourceResult(
        source="overpass",
        resort_id=resort_id,
        items=tuple(items),
        fetched_at=_iso_now(),
    )


def _build_query(south: float, west: float, north: float, east: float) -> str:
    """Mirror the query in supabase/functions/snapshot-resort/index.ts.

    Hits the three relevant tag families:
      - way[piste:type=downhill]
      - way[aerialway]
      - way[piste:type=connection]
    in the resort bbox, and returns ways with their nodes resolved.
    """
    bbox = f"({south},{west},{north},{east})"
    return f"""
    [out:json][timeout:60];
    (
      way[piste:type=downhill]{bbox};
      way[aerialway]{bbox};
      way[piste:type=connection]{bbox};
    );
    out body;
    >;
    out skel qt;
    """.strip()


def _post_overpass(query: str) -> Optional[dict]:
    body = ("data=" + query).encode()
    req = Request(
        OVERPASS_URL,
        data=body,
        headers={"User-Agent": USER_AGENT, "Content-Type": "application/x-www-form-urlencoded"},
    )
    try:
        with urlopen(req, timeout=REQUEST_TIMEOUT) as resp:
            return json.loads(resp.read())
    except (URLError, HTTPError, ValueError):
        return None


def _extract_items(data: dict) -> List[SourceItem]:
    elements = data.get("elements") or []
    nodes_by_id: Dict[int, Tuple[float, float]] = {}
    ways: List[dict] = []

    for el in elements:
        if el.get("type") == "node":
            nid = el.get("id")
            lat = el.get("lat")
            lon = el.get("lon")
            if nid is not None and lat is not None and lon is not None:
                nodes_by_id[int(nid)] = (float(lon), float(lat))
        elif el.get("type") == "way":
            ways.append(el)

    out: List[SourceItem] = []
    seen = set()
    for way in ways:
        tags = way.get("tags") or {}
        if tags.get("aerialway"):
            kind = "lift"
        elif tags.get("piste:type") == "downhill":
            kind = "trail"
        else:
            continue

        name = (tags.get("name") or tags.get("piste:name") or "").strip()
        if not name:
            continue

        key = (kind, name.lower())
        if key in seen:
            continue
        seen.add(key)

        geometry = _resolve_way_geometry(way, nodes_by_id)
        way_id = str(way.get("id"))

        extra: Dict[str, object] = {}
        if kind == "trail":
            extra["difficulty"] = _normalize_difficulty(tags.get("piste:difficulty"))
            extra["is_groomed"] = tags.get("piste:grooming") in ("classic", "classic+skating", "skating")
        else:
            extra["lift_type"] = _normalize_aerialway(tags.get("aerialway"))
            extra["capacity"] = _to_int(tags.get("aerialway:capacity"))

        out.append(SourceItem(
            kind=kind,                       # type: ignore[arg-type]
            name=name,
            confidence=0.7,
            geometry=geometry,
            osm_way_ids=(way_id,),
            extra=extra,
        ))
    return out


def _resolve_way_geometry(way: dict, nodes_by_id: Dict[int, Tuple[float, float]]):
    refs = way.get("nodes") or []
    coords = []
    for ref in refs:
        c = nodes_by_id.get(int(ref))
        if c is not None:
            coords.append(c)
    return coords or None


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


def _to_int(x: object) -> Optional[int]:
    try:
        return int(x) if x is not None else None
    except (TypeError, ValueError):
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
