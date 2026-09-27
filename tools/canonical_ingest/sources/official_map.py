"""Load reviewed label evidence from official resort maps.

An illustrated map proves that a label was published by the resort. It does
not prove that OCR found every label, that a label is one routable identity,
or that source geometry belongs to it. These rows therefore use the
`evidence` source role: they can corroborate exact names and expose map-only
candidates, but never establish a complete inventory or auto-accept a row.
"""

from __future__ import annotations

import json
import re
from pathlib import Path
from typing import Dict, Optional

from canonical_ingest.models import SourceItem, SourceResult


OFFICIAL_MAP_DIR = Path(__file__).resolve().parent.parent / "official_maps"
_SHA256 = re.compile(r"^[0-9a-f]{64}$")


def fetch(resort_id: str, hints: Optional[Dict[str, object]] = None) -> SourceResult:
    del hints
    path = OFFICIAL_MAP_DIR / f"{resort_id}.json"
    if not path.exists():
        return SourceResult(
            source="official_map", resort_id=resort_id, role="evidence"
        )

    raw = json.loads(path.read_text())
    if raw.get("schema_version") != 1:
        raise ValueError(f"unsupported official-map schema in {path}")
    if raw.get("resort_id") != resort_id:
        raise ValueError(f"official-map resort_id mismatch in {path}")
    if raw.get("usage") != "corroboration_only":
        raise ValueError("official-map evidence must be corroboration_only")

    maps = raw.get("maps")
    if not isinstance(maps, list) or not maps:
        raise ValueError("official-map evidence requires at least one map")
    map_metadata = {}
    for source_map in maps:
        if not isinstance(source_map, dict):
            raise ValueError("official-map map entries must be objects")
        map_id = _required_text(source_map.get("id"), "map id")
        source_url = _required_text(source_map.get("source_url"), "source_url")
        fingerprint = _required_text(
            source_map.get("content_sha256"), "content_sha256"
        ).lower()
        if map_id in map_metadata:
            raise ValueError(f"duplicate official-map id: {map_id}")
        if not source_url.startswith("https://"):
            raise ValueError(f"official-map source_url must be https: {source_url}")
        if not _SHA256.fullmatch(fingerprint):
            raise ValueError(f"invalid official-map content_sha256 for {map_id}")
        map_metadata[map_id] = {
            "id": map_id,
            "source_url": source_url,
            "content_sha256": fingerprint,
        }

    season = _required_text(raw.get("season"), "season")
    observed_at = _required_text(raw.get("observed_at"), "observed_at")
    labels = raw.get("labels")
    if not isinstance(labels, list) or not labels:
        raise ValueError("official-map evidence requires reviewed labels")

    items = []
    seen = set()
    for label in labels:
        if not isinstance(label, dict):
            raise ValueError("official-map labels must be objects")
        kind = _required_text(label.get("kind"), "label kind")
        name = _required_text(label.get("name"), "label name")
        if kind not in ("trail", "lift"):
            raise ValueError(f"invalid official-map label kind: {kind}")
        key = (kind, name.casefold())
        if key in seen:
            raise ValueError(f"duplicate official-map label: {kind} {name}")
        seen.add(key)

        observed_on = label.get("map_ids")
        if not isinstance(observed_on, list) or not observed_on:
            raise ValueError(f"official-map label {name!r} requires map_ids")
        normalized_map_ids = tuple(sorted({
            _required_text(value, "map_id") for value in observed_on
        }))
        unknown = set(normalized_map_ids) - set(map_metadata)
        if unknown:
            raise ValueError(
                f"official-map label {name!r} references unknown maps: "
                + ", ".join(sorted(unknown))
            )

        evidence = {
            "season": season,
            "observed_at": observed_at,
            "map_ids": normalized_map_ids,
            "maps": tuple(map_metadata[map_id] for map_id in normalized_map_ids),
            "review_method": _required_text(
                label.get("review_method", "visual"), "review_method"
            ),
        }
        official_number = label.get("official_number")
        if official_number is not None:
            if kind != "lift":
                raise ValueError(f"official number is only valid for lifts: {name!r}")
            if (
                isinstance(official_number, bool)
                or not isinstance(official_number, int)
            ):
                raise ValueError(f"invalid official lift number for {name!r}")
            if official_number <= 0:
                raise ValueError(f"invalid official lift number for {name!r}")
            evidence["official_number"] = official_number

        items.append(SourceItem(
            kind=kind,  # type: ignore[arg-type]
            name=name,
            confidence=1.0,
            extra={"official_map_evidence": evidence},
        ))

    return SourceResult(
        source="official_map",
        resort_id=resort_id,
        role="evidence",
        items=tuple(items),
        fetched_at=observed_at,
    )


def _required_text(value: object, field: str) -> str:
    if not isinstance(value, str) or not value.strip():
        raise ValueError(f"official-map {field} must be nonempty text")
    return value.strip()
