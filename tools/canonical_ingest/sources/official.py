"""Official-resort source fetcher.

When an operator has access to a resort's official trail-map data
(extracted from a PDF, scraped from the resort's website, or pasted
from press kits), they place a CSV / JSON file at:

  tools/canonical_ingest/official/{resort_id}.csv
  tools/canonical_ingest/official/{resort_id}.json

This source has the highest confidence weight in reconcile.py — when
the operator has manually entered an official identity list, we treat
those names as ground truth and only use the other sources for geometry +
attribute attachment. Resort headline statistics are not identity lists and
must not be copied into canonical expected counts.

CSV format (one row per item; optional columns may be omitted):
  kind,name,difficulty,is_groomed,has_moguls,is_gladed,length_m,vert_m,
  lift_type,capacity,ride_time_s,vertical_rise_m,weekday_wait_min,
  weekend_wait_min,base_lon,base_lat,top_lon,top_lat,osm_way_ids

JSON format (identity list; counts are derived from the unique rows):
  {
    "resort_id": "...",
    "trails": [...],
    "lifts": [...]
  }
"""

from __future__ import annotations
import csv
import json
from pathlib import Path
from typing import Dict, Optional
from canonical_ingest.models import SourceItem, SourceResult
from canonical_ingest.sources.common import merge_duplicate_items


OFFICIAL_DIR = Path(__file__).resolve().parent.parent / "official"


def fetch(resort_id: str, hints: Optional[Dict[str, object]] = None) -> SourceResult:
    csv_path = OFFICIAL_DIR / f"{resort_id}.csv"
    json_path = OFFICIAL_DIR / f"{resort_id}.json"

    if json_path.exists():
        return _from_json(resort_id, json_path)
    if csv_path.exists():
        return _from_csv(resort_id, csv_path)
    return SourceResult(
        source="official", resort_id=resort_id, role="inventory"
    )


def _from_csv(resort_id: str, path: Path) -> SourceResult:
    items: list[SourceItem] = []
    with path.open() as fh:
        reader = csv.DictReader(fh)
        for row in reader:
            kind = str(row.get("kind") or "").strip()
            name = str(row.get("name") or "").strip()
            if kind not in ("trail", "lift") or not name:
                continue
            extra = _typed_extra(kind, row)
            items.append(SourceItem(
                kind=kind,            # type: ignore[arg-type]
                name=name,
                confidence=1.0,
                osm_way_ids=tuple(
                    s.strip() for s in str(row.get("osm_way_ids") or "").split("|")
                    if s.strip()
                ),
                extra=extra,
            ))
    return SourceResult(
        source="official", resort_id=resort_id, role="inventory",
        items=tuple(merge_duplicate_items(items)),
    )


def _from_json(resort_id: str, path: Path) -> SourceResult:
    raw = json.loads(path.read_text())
    items: list[SourceItem] = []
    for trail in raw.get("trails") or []:
        item = _item_from_dict("trail", trail)
        if item.name:
            items.append(item)
    for lift in raw.get("lifts") or []:
        item = _item_from_dict("lift", lift)
        if item.name:
            items.append(item)
    return SourceResult(
        source="official", resort_id=resort_id, role="inventory",
        items=tuple(merge_duplicate_items(items)),
    )


def _item_from_dict(kind: str, d: Dict[str, object]) -> SourceItem:
    name = str(d.get("name", "")).strip()
    osm_way_ids = tuple(str(s) for s in (d.get("osm_way_ids") or ()))
    geometry = _geometry(d.get("canonical_geometry") or d.get("geometry"))
    extra = _typed_extra(kind, d)
    return SourceItem(
        kind=kind,                # type: ignore[arg-type]
        name=name,
        confidence=1.0,
        geometry=geometry,
        osm_way_ids=osm_way_ids,
        extra=extra,
    )


def _typed_extra(kind: str, raw: Dict[str, object]) -> Dict[str, object]:
    extra: Dict[str, object] = {}
    string_fields = ("difficulty",) if kind == "trail" else ("lift_type",)
    float_fields = (
        ("length_m", "vert_m") if kind == "trail" else
        (
            "ride_time_s", "vertical_rise_m", "weekday_wait_min",
            "weekend_wait_min",
        )
    )
    bool_fields = (
        ("is_groomed", "has_moguls", "is_gladed") if kind == "trail" else ()
    )
    int_fields = ("capacity",) if kind == "lift" else ()

    for field in string_fields:
        value = _present(raw.get(field))
        if value is not None:
            extra[field] = str(value).strip()
    for field in float_fields:
        value = _present(raw.get(field))
        if value is not None:
            extra[field] = _float(value, field)
    for field in bool_fields:
        value = _present(raw.get(field))
        if value is not None:
            extra[field] = _bool(value, field)
    for field in int_fields:
        value = _present(raw.get(field))
        if value is not None:
            extra[field] = _int(value, field)

    if kind == "lift":
        base_coord = _coord(raw, "base")
        top_coord = _coord(raw, "top")
        if base_coord is not None:
            extra["base_coord"] = base_coord
        if top_coord is not None:
            extra["top_coord"] = top_coord
    return extra


def _present(value: object) -> Optional[object]:
    if value is None:
        return None
    if isinstance(value, str) and not value.strip():
        return None
    return value


def _float(value: object, field: str) -> float:
    try:
        return float(value)
    except (TypeError, ValueError) as exc:
        raise ValueError(f"invalid {field}: {value!r}") from exc


def _int(value: object, field: str) -> int:
    if isinstance(value, bool):
        raise ValueError(f"invalid {field}: {value!r}")
    try:
        parsed = int(value)
    except (TypeError, ValueError) as exc:
        raise ValueError(f"invalid {field}: {value!r}") from exc
    if isinstance(value, float) and not value.is_integer():
        raise ValueError(f"invalid {field}: {value!r}")
    return parsed


def _bool(value: object, field: str) -> bool:
    if isinstance(value, bool):
        return value
    normalized = str(value).strip().casefold()
    if normalized in ("true", "1", "yes"):
        return True
    if normalized in ("false", "0", "no"):
        return False
    raise ValueError(f"invalid {field}: {value!r}")


def _coord(raw: Dict[str, object], prefix: str):
    direct = _present(raw.get(f"{prefix}_coord"))
    if isinstance(direct, dict):
        direct = direct.get("coordinates")
    if isinstance(direct, (list, tuple)) and len(direct) >= 2:
        return (_float(direct[0], f"{prefix}_lon"), _float(direct[1], f"{prefix}_lat"))
    lon = _present(raw.get(f"{prefix}_lon"))
    lat = _present(raw.get(f"{prefix}_lat"))
    if lon is None and lat is None:
        return None
    if lon is None or lat is None:
        raise ValueError(f"{prefix}_lon and {prefix}_lat must be supplied together")
    return (_float(lon, f"{prefix}_lon"), _float(lat, f"{prefix}_lat"))


def _geometry(raw: object):
    if raw is None:
        return None
    if isinstance(raw, dict) and raw.get("type") != "LineString":
        raise ValueError("canonical_geometry must be a GeoJSON LineString")
    coordinates = raw.get("coordinates") if isinstance(raw, dict) else raw
    if not isinstance(coordinates, (list, tuple)):
        raise ValueError("canonical_geometry must be a LineString or coordinate list")
    return [
        (_float(coord[0], "geometry lon"), _float(coord[1], "geometry lat"))
        for coord in coordinates
        if isinstance(coord, (list, tuple)) and len(coord) >= 2
    ] or None
