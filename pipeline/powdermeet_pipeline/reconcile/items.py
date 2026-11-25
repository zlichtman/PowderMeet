"""Turn a frozen extract into one `SourceResult` per source."""

from __future__ import annotations

import re
from typing import List, Optional

from ..topology import DIFFICULTIES, LIFT_TYPES, Network
from .common import merge_duplicate_items, normalize_grooming
from .identities import normalize_name
from .models import SourceItem, SourceResult

_NON_TRANSPORT = {"station", "pylon", "zip_line"}


def all_sources(extract: dict, net: Network) -> List[SourceResult]:
    resort_id = extract["resort_id"]
    return [
        SourceResult(
            source="official", resort_id=resort_id, role="inventory",
            items=tuple(official_items(extract.get("official") or {})),
            fetched_at=(extract.get("official") or {}).get("fetched_at"),
        ),
        SourceResult(
            source="openskimap", resort_id=resort_id,
            items=tuple(openskimap_items(extract.get("openskimap") or {}, net)),
            fetched_at=(extract.get("openskimap") or {}).get("fetched_at"),
        ),
        SourceResult(
            source="osm", resort_id=resort_id, items=tuple(osm_items(net)),
            fetched_at=extract["osm"].get("fetched_at"),
        ),
    ]


def osm_items(net: Network) -> List[SourceItem]:
    """Named lifts and downhill runs of the routable network."""
    out: List[SourceItem] = []
    for way_id in sorted(net.ways):
        way = net.ways[way_id]
        if way.kind == "connection" or not way.name:
            continue
        extra: dict = {}
        if way.kind == "run":
            extra["difficulty"] = DIFFICULTIES.get(str(way.tags.get("piste:difficulty") or "").lower())
            extra["is_groomed"] = normalize_grooming(way.tags.get("piste:grooming"))
        else:
            extra["lift_type"] = LIFT_TYPES.get(str(way.tags.get("aerialway")).lower())
            extra["capacity"] = _to_int(way.tags.get("aerialway:capacity"))
            extra["ride_time_s"] = duration_seconds(way.tags.get("aerialway:duration"))
        out.append(SourceItem(
            kind="trail" if way.kind == "run" else "lift",
            name=way.name,
            confidence=0.7,
            osm_way_ids=(str(way_id),),
            extra=extra,
        ))
    return merge_duplicate_items(out)


def openskimap_items(ski_map: dict, net: Network) -> List[SourceItem]:
    """OpenSkiMap features that cite at least one way of the routable network."""
    out: List[SourceItem] = []
    for kind, features in (("trail", ski_map.get("runs") or []), ("lift", ski_map.get("lifts") or [])):
        for properties in features:
            if properties.get("status") not in (None, "operating"):
                continue
            if kind == "trail" and "uses" in properties and "downhill" not in properties["uses"]:
                continue
            lift_type = str(properties.get("liftType") or "").lower()
            if kind == "lift" and lift_type in _NON_TRANSPORT:
                continue
            name = str(properties.get("name") or "").strip()
            if not name:
                continue
            way_ids = [w for w in _osm_way_ids(properties) if int(w) in net.ways]
            if not way_ids:
                continue
            extra: dict = {}
            if kind == "trail":
                extra["difficulty"] = DIFFICULTIES.get(str(properties.get("difficulty") or "").lower())
                extra["is_groomed"] = normalize_grooming(properties.get("grooming"))
            else:
                extra["lift_type"] = LIFT_TYPES.get(lift_type)
            # OpenSkiMap joins the names of merged ways and of several languages
            # with ", ". A part that is exactly the name of a way the feature
            # cites is that way's name; anything else stays as published.
            parts = {normalize_name(part): part.strip() for part in name.split(", ")}
            named: dict[str, list[str]] = {}
            for way_id in way_ids:
                part = parts.get(normalize_name(net.ways[int(way_id)].name))
                named.setdefault(part or name, []).append(way_id)
            if not any(part in parts.values() for part in named):
                named = {name: way_ids}
            for item_name, item_ways in sorted(named.items()):
                if item_name == name and len(named) > 1:
                    continue  # ways the joined name does not account for
                out.append(SourceItem(
                    kind=kind,  # type: ignore[arg-type]
                    name=item_name,
                    confidence=0.85,
                    osm_way_ids=tuple(item_ways),
                    # One difficulty for a feature that joins several names says
                    # nothing reliable about each of them.
                    extra=dict(extra) if item_name == name else {"lift_type": extra.get("lift_type")},
                ))
    return merge_duplicate_items(out)


def official_items(official: dict) -> List[SourceItem]:
    out: List[SourceItem] = []
    for kind, rows in (("trail", official.get("trails") or []), ("lift", official.get("lifts") or [])):
        for row in rows:
            name = str(row.get("name") or "").strip()
            if not name:
                continue
            extra = {}
            if kind == "trail" and row.get("difficulty"):
                extra["difficulty"] = row["difficulty"]
            out.append(SourceItem(kind=kind, name=name, confidence=1.0, extra=extra))  # type: ignore[arg-type]
    return merge_duplicate_items(out)


def duration_seconds(raw: object) -> Optional[float]:
    """`aerialway:duration` is minutes, or `mm:ss` / `hh:mm:ss`."""
    if raw is None:
        return None
    text = str(raw).strip()
    try:
        if re.fullmatch(r"\d+(\.\d+)?", text):
            return float(text) * 60.0
        parts = [int(p) for p in text.split(":")]
    except ValueError:
        return None
    if len(parts) == 2:
        return parts[0] * 60.0 + parts[1]
    if len(parts) == 3:
        return parts[0] * 3600.0 + parts[1] * 60.0 + parts[2]
    return None


def _osm_way_ids(properties: dict) -> List[str]:
    ids = set()
    for source in properties.get("sources") or []:
        source_id = str(source.get("id") or "")
        if source.get("type") == "openstreetmap" and source_id.startswith("way/"):
            way_id = source_id.split("/", 1)[1]
            if way_id.isdigit():
                ids.add(way_id)
    return sorted(ids, key=int)


def _to_int(value: object) -> Optional[int]:
    try:
        return int(value) if value is not None else None
    except (TypeError, ValueError):
        return None
