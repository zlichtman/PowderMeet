"""Deterministic source-item aggregation shared by all source adapters.

OSM commonly represents one named trail as several ways. An identity must retain
every source way id; keeping only the first segment would leave the rest of the
trail unclaimed. Conflicting source attributes are preserved as explicit review
flags rather than guessed.
"""

from __future__ import annotations

import json
from collections import defaultdict
from typing import Iterable, List

from .models import SourceItem

_INTERNAL_EXTRA_KEYS = frozenset({
    "attribute_conflicts", "attribute_observations", "source_segment_count",
    "identity_decision",
})


def normalize_grooming(value: object):
    """Tri-state grooming without inventing `False`: a missing or unknown tag means
    unknown, never explicitly ungroomed."""
    if isinstance(value, bool):
        return value
    if value is None:
        return None
    normalized = str(value).strip().casefold()
    if normalized in ("classic", "classic+skating", "skating", "groomed", "yes", "true", "1"):
        return True
    if normalized in ("backcountry", "mogul", "ungroomed", "no", "false", "0"):
        return False
    return None



def is_mogul_run(value: object) -> bool:
    """`piste:grooming=mogul`: left ungroomed on purpose to bump up. Grooming still
    reads it as not groomed; this keeps the difference for the run card."""
    return isinstance(value, str) and value.strip().casefold() == "mogul"

def merge_duplicate_items(items: Iterable[SourceItem]) -> List[SourceItem]:
    """Merge exact same-name candidates of one source, keeping all evidence.

    Names are grouped only by trimmed case-folding. Anything fuzzier belongs in a
    reviewed decision, where it stays visible.
    """
    buckets = defaultdict(list)
    for item in items:
        buckets[(item.kind, item.name.strip().casefold())].append(item)

    merged: List[SourceItem] = []
    for key in sorted(buckets):
        entries = buckets[key]
        name = min(
            (entry.name.strip() for entry in entries),
            key=lambda candidate: (candidate.casefold(), candidate),
        )
        osm_way_ids = tuple(sorted(
            {way_id for entry in entries for way_id in entry.osm_way_ids},
            key=identifier_sort_key,
        ))
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
                        attribute_observations[str(attribute)].update(str(v) for v in values)
        attribute_keys = sorted({
            attribute
            for entry in entries
            for attribute in entry.extra
            if attribute not in _INTERNAL_EXTRA_KEYS
        })
        for attribute in attribute_keys:
            values = [
                entry.extra[attribute] for entry in entries
                if entry.extra.get(attribute) is not None
            ]
            attribute_observations[attribute].update(value_key(value) for value in values)
            distinct = {value_key(value) for value in values}
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
            osm_way_ids=osm_way_ids,
            extra=extra,
        ))
    return merged


def value_key(value: object) -> str:
    return json.dumps(value, sort_keys=True, separators=(",", ":"), default=str)


def identifier_sort_key(value: str):
    return (0, int(value)) if value.isdigit() else (1, value)


def _positive_int(value: object, *, fallback: int) -> int:
    try:
        parsed = int(value) if value is not None else fallback
    except (TypeError, ValueError):
        return fallback
    return parsed if parsed > 0 else fallback
