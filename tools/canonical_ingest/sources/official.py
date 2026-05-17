"""Official-resort source fetcher.

When an operator has access to a resort's official trail-map data
(extracted from a PDF, scraped from the resort's website, or pasted
from press kits), they place a CSV / JSON file at:

  tools/canonical_ingest/official/{resort_id}.csv
  tools/canonical_ingest/official/{resort_id}.json

This source has the highest confidence weight in reconcile.py — when
the operator has manually entered the official count + names, we treat
that as ground truth and only use the other sources for geometry +
attribute attachment.

CSV format (one row per item):
  kind,name,difficulty,length_m,vert_m,lift_type,capacity,osm_way_ids
  trail,Riva Ridge,blue,4500,400,,,
  lift,Riva Bahn,,,,gondola,2400,

JSON format (mirror of CanonicalManifest dataclass):
  {
    "resort_id": "...",
    "expected_trail_count": 195,
    "expected_lift_count": 31,
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


OFFICIAL_DIR = Path(__file__).resolve().parent.parent / "official"


def fetch(resort_id: str, hints: Optional[Dict[str, object]] = None) -> SourceResult:
    csv_path = OFFICIAL_DIR / f"{resort_id}.csv"
    json_path = OFFICIAL_DIR / f"{resort_id}.json"

    if json_path.exists():
        return _from_json(resort_id, json_path)
    if csv_path.exists():
        return _from_csv(resort_id, csv_path)
    return SourceResult(source="official", resort_id=resort_id)


def _from_csv(resort_id: str, path: Path) -> SourceResult:
    items: list[SourceItem] = []
    with path.open() as fh:
        reader = csv.DictReader(fh)
        for row in reader:
            kind = row.get("kind", "").strip()
            name = row.get("name", "").strip()
            if kind not in ("trail", "lift") or not name:
                continue
            extra: Dict[str, object] = {}
            for key in ("difficulty", "length_m", "vert_m", "lift_type", "capacity"):
                value = row.get(key)
                if value:
                    extra[key] = value
            items.append(SourceItem(
                kind=kind,            # type: ignore[arg-type]
                name=name,
                confidence=1.0,
                osm_way_ids=tuple(
                    s.strip() for s in (row.get("osm_way_ids", "").split("|"))
                    if s.strip()
                ),
                extra=extra,
            ))
    return SourceResult(source="official", resort_id=resort_id, items=tuple(items))


def _from_json(resort_id: str, path: Path) -> SourceResult:
    raw = json.loads(path.read_text())
    items: list[SourceItem] = []
    for trail in raw.get("trails") or []:
        items.append(_item_from_dict("trail", trail))
    for lift in raw.get("lifts") or []:
        items.append(_item_from_dict("lift", lift))
    return SourceResult(source="official", resort_id=resort_id, items=tuple(items))


def _item_from_dict(kind: str, d: Dict[str, object]) -> SourceItem:
    name = str(d.get("name", "")).strip()
    osm_way_ids = tuple(str(s) for s in (d.get("osm_way_ids") or ()))
    extra = {k: v for k, v in d.items() if k not in ("name", "osm_way_ids")}
    return SourceItem(
        kind=kind,                # type: ignore[arg-type]
        name=name,
        confidence=1.0,
        osm_way_ids=osm_way_ids,
        extra=extra,
    )
