"""Deterministic source-item aggregation shared by all ingest adapters.

OSM and map exporters commonly represent one named trail as several ways. A
canonical identity candidate must retain every source way ID; silently keeping
the first segment makes whitelist validation incomplete. Conflicting source
attributes are preserved as explicit review flags rather than guessed.
"""

from __future__ import annotations

import json
from collections import defaultdict
from typing import Iterable, List

from canonical_ingest.models import SourceItem


_INTERNAL_EXTRA_KEYS = frozenset({
    "attribute_conflicts", "attribute_observations", "source_segment_count",
})


def normalize_grooming(value: object):
    """Return a tri-state grooming observation without inventing `False`.

    Missing or unknown tags mean unknown. They must not override a canonical
    value or tell the client that a trail is explicitly ungroomed.
    """
    if isinstance(value, bool):
        return value
    if value is None:
        return None
    normalized = str(value).strip().casefold()
    if normalized in (
        "classic", "classic+skating", "skating", "groomed", "yes", "true", "1",
    ):
        return True
    if normalized in ("backcountry", "mogul", "ungroomed", "no", "false", "0"):
        return False
    return None


def merge_duplicate_items(items: Iterable[SourceItem]) -> List[SourceItem]:
    """Merge exact same-name candidates while retaining all source evidence.

    Names are grouped only by trimmed case-folding. More aggressive/fuzzy name
    reconciliation belongs in `reconcile.py`, where it remains visible to the
    operator. Multiple distinct geometries cannot be represented honestly by
    the manifest's single LineString field, so geometry is kept only when all
    observed non-empty geometries agree.
    """
    buckets = defaultdict(list)
    for item in items:
        key = (item.kind, item.name.strip().casefold())
        buckets[key].append(item)

    merged: List[SourceItem] = []
    for key in sorted(buckets):
        entries = buckets[key]
        name = min(
            (entry.name.strip() for entry in entries),
            key=lambda candidate: (candidate.casefold(), candidate),
        )
        osm_way_ids = tuple(sorted(
            {way_id for entry in entries for way_id in entry.osm_way_ids},
            key=_identifier_sort_key,
        ))

        geometries = [entry.geometry for entry in entries if entry.geometry]
        geometry_keys = {_value_key(geometry) for geometry in geometries}
        geometry = geometries[0] if len(geometry_keys) == 1 else None

        conflicts = {
            str(conflict)
            for entry in entries
            for conflict in (entry.extra.get("attribute_conflicts") or ())
        }
        extra = {}
        attribute_observations = defaultdict(set)
        for entry in entries:
            carried = entry.extra.get("attribute_observations") or {}
            if isinstance(carried, dict):
                for attribute, values in carried.items():
                    if isinstance(values, (list, tuple)):
                        attribute_observations[str(attribute)].update(
                            str(value) for value in values
                        )
        attribute_keys = sorted({
            attribute
            for entry in entries
            for attribute in entry.extra
            if attribute not in _INTERNAL_EXTRA_KEYS
        })
        for attribute in attribute_keys:
            values = [
                entry.extra[attribute]
                for entry in entries
                if entry.extra.get(attribute) is not None
            ]
            attribute_observations[attribute].update(
                _value_key(value) for value in values
            )
            distinct = {_value_key(value) for value in values}
            if len(distinct) == 1:
                extra[attribute] = values[0]
            elif len(distinct) > 1:
                conflicts.add(attribute)

        extra["source_segment_count"] = sum(
            _positive_int(entry.extra.get("source_segment_count"), fallback=1)
            for entry in entries
        )
        if attribute_observations:
            extra["attribute_observations"] = {
                attribute: tuple(sorted(values))
                for attribute, values in sorted(attribute_observations.items())
                if values
            }
        if conflicts:
            extra["attribute_conflicts"] = tuple(sorted(conflicts))

        merged.append(SourceItem(
            kind=entries[0].kind,
            name=name,
            confidence=max(entry.confidence for entry in entries),
            geometry=geometry,
            osm_way_ids=osm_way_ids,
            extra=extra,
        ))
    return merged


def _value_key(value: object) -> str:
    return json.dumps(value, sort_keys=True, separators=(",", ":"), default=str)


def _identifier_sort_key(value: str):
    return (0, int(value)) if value.isdigit() else (1, value)


def _positive_int(value: object, *, fallback: int) -> int:
    try:
        parsed = int(value) if value is not None else fallback
    except (TypeError, ValueError):
        return fallback
    return parsed if parsed > 0 else fallback
