"""Skimap.org source fetcher.

Skimap.org is a community-curated ski resort map registry. Useful as
the *named-and-typed* source for trails and lifts (each entry has a
human-confirmed name + difficulty / lift type).

API:
  GET https://skimap.org/SkiAreas/index.json     — full registry index
  GET https://skimap.org/SkiAreas/{id}.json      — per-area details

Coverage skews toward North American + European resorts; Asian /
Southern Hemisphere coverage is patchy. Reconcile against OpenSkiMap
+ Overpass for resorts where Skimap is sparse.
"""

from __future__ import annotations
import json
import math
import os
import time
from pathlib import Path
from typing import Dict, Optional, List
from urllib.request import Request, urlopen
from urllib.error import URLError, HTTPError

from canonical_ingest.models import SourceItem, SourceResult


SKIMAP_REGISTRY_URL = "https://skimap.org/SkiAreas/index.json"
SKIMAP_AREA_URL_FMT = "https://skimap.org/SkiAreas/{id}.json"
USER_AGENT = "powdermeet-canonical-ingest/0.1 (+https://powdermeet.app)"

CACHE_DIR = Path(__file__).resolve().parent.parent / "fixtures" / "skimap"
CACHE_TTL_SECONDS = 7 * 24 * 3600   # 1 week
REQUEST_TIMEOUT = 30


def fetch(resort_id: str, hints: Optional[Dict[str, object]] = None) -> SourceResult:
    """Pull trails + lifts for `resort_id` from Skimap.org.

    `hints` may include:
      - `lat_lon`: (lat, lon) for proximity match against the registry
      - `name_aliases`: list[str] alternate names for fuzzy match
      - `skimap_id`: int — bypass resolution if known
    """
    hints = hints or {}
    skimap_id = hints.get("skimap_id")
    if skimap_id is None:
        skimap_id = _resolve_id(resort_id, hints)
    if skimap_id is None:
        return SourceResult(source="skimap", resort_id=resort_id)

    area = _fetch_area(int(skimap_id))
    if area is None:
        return SourceResult(source="skimap", resort_id=resort_id)

    items: List[SourceItem] = []
    items.extend(_extract_lifts(area))
    items.extend(_extract_trails(area))

    return SourceResult(
        source="skimap",
        resort_id=resort_id,
        items=tuple(items),
        fetched_at=_iso_now(),
    )


# ── Registry resolution ──────────────────────────────────────────────


_REGISTRY_CACHE: Optional[List[dict]] = None


def _registry() -> List[dict]:
    global _REGISTRY_CACHE
    if _REGISTRY_CACHE is not None:
        return _REGISTRY_CACHE
    cache_path = CACHE_DIR / "_registry.json"
    cached = _read_cached_json(cache_path)
    if cached is not None:
        _REGISTRY_CACHE = cached
        return cached
    body = _http_get(SKIMAP_REGISTRY_URL)
    if body is None:
        _REGISTRY_CACHE = []
        return []
    raw = json.loads(body)
    # Skimap registry shape historically: { "skiAreas": [ {id,name,...} ] }
    # tolerate older flat-list format too.
    areas = raw.get("skiAreas") if isinstance(raw, dict) else raw
    if not isinstance(areas, list):
        areas = []
    _write_cached_json(cache_path, areas)
    _REGISTRY_CACHE = areas
    return areas


def _resolve_id(resort_id: str, hints: Dict[str, object]) -> Optional[int]:
    """Resolve `resort_id` to a Skimap area ID using:
       1. exact-name (or alias) match against the registry
       2. lat/lon proximity within 5 km if hints provide one
    """
    aliases = list(hints.get("name_aliases") or [])
    candidates = [resort_id.replace("-", " ")] + aliases

    registry = _registry()
    if not registry:
        return None

    # Exact / case-insensitive match
    norm_candidates = {c.strip().lower() for c in candidates}
    for area in registry:
        name = (area.get("name") or "").strip().lower()
        if name in norm_candidates:
            return _coerce_id(area)

    # Substring fallback (helps when resort_id contains qualifiers)
    for area in registry:
        name = (area.get("name") or "").strip().lower()
        for c in norm_candidates:
            if c and (c in name or name in c):
                return _coerce_id(area)

    # Lat/lon proximity
    lat_lon = hints.get("lat_lon")
    if lat_lon:
        lat, lon = lat_lon  # type: ignore[misc]
        best_id = None
        best_km = float("inf")
        for area in registry:
            a_lat = _to_float(area.get("latitude"))
            a_lon = _to_float(area.get("longitude"))
            if a_lat is None or a_lon is None:
                continue
            km = _haversine_km(lat, lon, a_lat, a_lon)
            if km < best_km:
                best_km = km
                best_id = _coerce_id(area)
        if best_km <= 5.0:
            return best_id
    return None


def _coerce_id(area: dict) -> Optional[int]:
    raw = area.get("id") or area.get("areaId")
    try:
        return int(raw) if raw is not None else None
    except (TypeError, ValueError):
        return None


# ── Per-area fetch ───────────────────────────────────────────────────


def _fetch_area(skimap_id: int) -> Optional[dict]:
    cache_path = CACHE_DIR / f"{skimap_id}.json"
    cached = _read_cached_json(cache_path)
    if cached is not None:
        return cached
    url = SKIMAP_AREA_URL_FMT.format(id=skimap_id)
    body = _http_get(url)
    if body is None:
        return None
    raw = json.loads(body)
    _write_cached_json(cache_path, raw)
    return raw


def _extract_lifts(area: dict) -> List[SourceItem]:
    out: List[SourceItem] = []
    for lift in area.get("lifts") or []:
        name = (lift.get("name") or "").strip()
        if not name:
            continue
        out.append(SourceItem(
            kind="lift",
            name=name,
            confidence=0.95,
            extra={
                "lift_type": _normalize_lift_type(lift.get("type")),
                "capacity": _to_int(lift.get("capacity")),
            },
        ))
    return out


def _extract_trails(area: dict) -> List[SourceItem]:
    out: List[SourceItem] = []
    pistes = area.get("pistes") or area.get("trails") or area.get("runs") or []
    for trail in pistes:
        name = (trail.get("name") or "").strip()
        if not name:
            continue
        out.append(SourceItem(
            kind="trail",
            name=name,
            confidence=0.9,
            extra={
                "difficulty": _normalize_difficulty(trail.get("difficulty")),
                "is_groomed": _to_bool(trail.get("groomed")),
            },
        ))
    return out


def _normalize_lift_type(raw: object) -> Optional[str]:
    if not raw:
        return None
    s = str(raw).lower()
    if "gondola" in s:
        return "gondola"
    if "chair" in s:
        return "chairlift"
    if "funicular" in s:
        return "funicular"
    if "t-bar" in s or "tbar" in s:
        return "tBar"
    if "platter" in s:
        return "platter"
    if "magic" in s:
        return "magicCarpet"
    if "rope" in s:
        return "rope"
    if "cable" in s and "car" in s:
        return "cableCar"
    return None


def _normalize_difficulty(raw: object) -> Optional[str]:
    if not raw:
        return None
    s = str(raw).lower()
    if s in ("novice", "easy", "green"):
        return "green"
    if s in ("intermediate", "blue"):
        return "blue"
    if s in ("advanced", "black"):
        return "black"
    if s in ("expert", "doubleblack", "double black", "freeride", "extreme"):
        return "doubleBlack"
    if s in ("park", "terrain park", "terrainpark"):
        return "terrainPark"
    return None


# ── HTTP / cache ─────────────────────────────────────────────────────


def _http_get(url: str) -> Optional[bytes]:
    req = Request(url, headers={"User-Agent": USER_AGENT, "Accept": "application/json"})
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


# ── Misc ─────────────────────────────────────────────────────────────


def _to_float(x: object) -> Optional[float]:
    try:
        return float(x) if x is not None else None        # type: ignore[arg-type]
    except (TypeError, ValueError):
        return None


def _to_int(x: object) -> Optional[int]:
    try:
        return int(x) if x is not None else None         # type: ignore[arg-type]
    except (TypeError, ValueError):
        return None


def _to_bool(x: object) -> Optional[bool]:
    if isinstance(x, bool):
        return x
    if x is None:
        return None
    s = str(x).strip().lower()
    if s in ("true", "yes", "1", "groomed"):
        return True
    if s in ("false", "no", "0", "ungroomed"):
        return False
    return None


def _haversine_km(lat1: float, lon1: float, lat2: float, lon2: float) -> float:
    r = 6371.0
    p = math.pi / 180
    a = (
        0.5
        - math.cos((lat2 - lat1) * p) / 2
        + math.cos(lat1 * p) * math.cos(lat2 * p) *
        (1 - math.cos((lon2 - lon1) * p)) / 2
    )
    return 2 * r * math.asin(math.sqrt(a))


def _iso_now() -> str:
    from datetime import datetime, timezone
    return datetime.now(timezone.utc).isoformat()
