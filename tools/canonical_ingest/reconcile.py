"""Multi-source reconciliation.

Takes a list of `SourceResult`s (one per source, all for the same
resort), exact-normalizes names across sources, and emits a
`DraftManifest` with per-row source agreement + confidence scores.

Approximate names are never merged here. They are emitted as deterministic
review suggestions by `review_report.py`; installing an optional package must
not change canonical identity candidates.

Conflict policy: count disagreement between sources NEVER auto-resolves.
If two sources differ on trail / lift identity count, the operator must
supply reviewed canonical identity targets via
`--expected-canonical-trails N --expected-canonical-lifts N`. A resort's
headline statistic is evidence only: it may count named routes, mapped
segments, zones, or non-routable surface lifts differently. Silent
auto-resolution to "max", "modal", or the headline is prohibited.
"""

from __future__ import annotations
import json
import hashlib
import re
from collections import defaultdict
from typing import List, Dict, Tuple, Optional

from canonical_ingest.models import (
    SourceResult, SourceItem, DraftManifest, DraftRow,
)


PRIORITY = ("official", "official_map", "skimap", "openskimap", "overpass")
"""Source priority for tie-breaking name + geometry choices."""

TRAIL_ATTRIBUTES = (
    "difficulty", "is_groomed", "has_moguls", "is_gladed", "length_m", "vert_m",
)
LIFT_ATTRIBUTES = (
    "lift_type", "capacity", "ride_time_s", "vertical_rise_m",
    "weekday_wait_min", "weekend_wait_min", "base_coord", "top_coord",
)


def normalize_name(name: str) -> str:
    """Conservative normalization — strips leading 'The ', collapses
    whitespace, lowercases, strips trailing punctuation. Aggressive
    expansions (e.g. "St" → "Saint") deliberately omitted because
    they can incorrectly merge distinct trails ("St. Bernard" vs
    "St Anton's"). Only universally-safe transforms here.
    """
    n = name.strip()
    n = re.sub(r"^The\s+", "", n, flags=re.IGNORECASE)
    n = re.sub(r"\s+", " ", n)
    n = re.sub(r"[\.\,\;\:]+$", "", n)
    return n.lower()


def reconcile(
    results: List[SourceResult],
    *,
    expected_trail_count: Optional[int] = None,
    expected_lift_count: Optional[int] = None,
) -> DraftManifest:
    if not results:
        raise ValueError("reconcile() requires at least one SourceResult")
    resort_id = results[0].resort_id
    if any(result.resort_id != resort_id for result in results):
        raise ValueError("all SourceResults must describe the same resort")
    if not any(result.items for result in results):
        raise SourceDataUnavailableError(
            resort_id=resort_id,
            per_source=_per_source_counts(results),
        )

    # Bucket items by (kind, normalized_name); preserve source order
    # so PRIORITY ranking applies in tie-break.
    buckets: Dict[Tuple[str, str], List[Tuple[str, SourceItem]]] = defaultdict(list)
    for sr in results:
        for item in sr.items:
            key = (item.kind, normalize_name(item.name))
            buckets[(item.kind, normalize_name(item.name))].append((sr.source, item))

    trail_rows: List[DraftRow] = []
    lift_rows: List[DraftRow] = []
    for (kind, _norm), entries in buckets.items():
        # Choose the canonical name from the highest-priority source
        # that contains this bucket.
        sources_seen = tuple(sorted({s for s, _ in entries}, key=_priority_index))
        canonical = _pick_canonical(entries)
        confidence = _confidence(sources_seen)
        attributes, attribute_conflicts = _merge_attributes(entries, kind=kind)
        source_name_variants = tuple(sorted(
            _observed_names(entries),
            key=lambda name: (normalize_name(name), name.casefold(), name),
        ))
        unresolved_conflicts = set(attribute_conflicts)
        if _has_unresolved_name_conflict(
            entries, canonical.name, source_name_variants
        ):
            unresolved_conflicts.add("name")
        row = DraftRow(
            name=canonical.name,
            kind=kind,                  # type: ignore[arg-type]
            sources_seen=sources_seen,
            confidence=confidence,
            difficulty=attributes.get("difficulty"),
            is_groomed=attributes.get("is_groomed"),
            has_moguls=attributes.get("has_moguls", False),
            is_gladed=attributes.get("is_gladed", False),
            length_m=attributes.get("length_m"),
            vert_m=attributes.get("vert_m"),
            lift_type=attributes.get("lift_type"),
            capacity=attributes.get("capacity"),
            ride_time_s=attributes.get("ride_time_s"),
            vertical_rise_m=attributes.get("vertical_rise_m"),
            weekday_wait_min=attributes.get("weekday_wait_min"),
            weekend_wait_min=attributes.get("weekend_wait_min"),
            base_coord=attributes.get("base_coord"),
            top_coord=attributes.get("top_coord"),
            geometry=_unambiguous_geometry(entries),
            osm_way_ids=_merged_osm_way_ids(entries),
            source_name_variants=source_name_variants,
            source_segment_counts=_source_segment_counts(entries),
            source_attribute_observations=_source_attribute_observations(
                entries, kind=kind
            ),
            source_evidence_fingerprint=_source_evidence_fingerprint(
                entries, kind=kind
            ),
            identity_decision_ids=_identity_decision_ids(entries),
            unresolved_conflicts=tuple(sorted(unresolved_conflicts)),
        )
        if kind == "trail":
            trail_rows.append(row)
        else:
            lift_rows.append(row)

    actual_trail = len(trail_rows)
    actual_lift = len(lift_rows)

    if expected_trail_count is None or expected_lift_count is None:
        # Surface the disagreement as an error rather than guess. The
        # CLI catches this and prints the per-source counts so the
        # operator can supply the official numbers.
        if not _all_sources_agree_on_count(results):
            counts = _per_source_counts(results)
            raise CountDisagreementError(
                resort_id=resort_id,
                per_source=counts,
                message=(
                    f"sources disagree on trail/lift count for {resort_id}; "
                    "supply --expected-canonical-trails N "
                    "--expected-canonical-lifts N after reviewing the unique "
                    "routable identity inventory; headline statistics do not resolve it"
                ),
            )

    return DraftManifest(
        resort_id=resort_id,
        expected_trail_count=(
            expected_trail_count if expected_trail_count is not None else actual_trail
        ),
        expected_lift_count=(
            expected_lift_count if expected_lift_count is not None else actual_lift
        ),
        trail_rows=trail_rows,
        lift_rows=lift_rows,
    )


def _pick_canonical(entries: List[Tuple[str, SourceItem]]) -> SourceItem:
    ranked = sorted(entries, key=_entry_sort_key)
    return ranked[0][1]


def _observed_names(entries: List[Tuple[str, SourceItem]]) -> set[str]:
    names = {item.name for _, item in entries}
    for _, item in entries:
        decision = item.extra.get("identity_decision")
        if isinstance(decision, dict):
            observed = decision.get("observed_name")
            if isinstance(observed, str) and observed.strip():
                names.add(observed.strip())
    return names


def _has_unresolved_name_conflict(
    entries: List[Tuple[str, SourceItem]],
    canonical_name: str,
    source_name_variants: Tuple[str, ...],
) -> bool:
    canonical_key = normalize_name(canonical_name)
    if all(normalize_name(name) == canonical_key for name in source_name_variants):
        return False
    decision_ids = set()
    for _, item in entries:
        decision = item.extra.get("identity_decision")
        observed = item.name
        if isinstance(decision, dict):
            observed = str(decision.get("observed_name") or item.name)
        if normalize_name(observed) == canonical_key:
            continue
        decision_id = decision.get("id") if isinstance(decision, dict) else None
        decision_canonical = (
            decision.get("canonical_name") if isinstance(decision, dict) else None
        )
        if (
            not isinstance(decision_id, str)
            or not decision_id.strip()
            or normalize_name(str(decision_canonical or "")) != canonical_key
        ):
            return True
        decision_ids.add(decision_id)
    return len(decision_ids) != 1


def _identity_decision_ids(
    entries: List[Tuple[str, SourceItem]],
) -> Tuple[str, ...]:
    return tuple(sorted({
        str(decision["id"]).strip()
        for _, item in entries
        for decision in (item.extra.get("identity_decision"),)
        if isinstance(decision, dict)
        and isinstance(decision.get("id"), str)
        and str(decision["id"]).strip()
    }))


def _merge_attributes(
    entries: List[Tuple[str, SourceItem]], *, kind: str,
) -> Tuple[Dict[str, object], Tuple[str, ...]]:
    attributes = TRAIL_ATTRIBUTES if kind == "trail" else LIFT_ATTRIBUTES
    ranked = sorted(entries, key=_entry_sort_key)
    chosen: Dict[str, object] = {}
    conflicts = {
        str(conflict)
        for _, item in entries
        for conflict in (item.extra.get("attribute_conflicts") or ())
        if str(conflict) in attributes
    }
    for attribute in attributes:
        observations = [
            item.extra[attribute]
            for _, item in ranked
            if item.extra.get(attribute) is not None
        ]
        if observations:
            chosen[attribute] = observations[0]
        if len({_value_key(value) for value in observations}) > 1:
            conflicts.add(attribute)
    return chosen, tuple(sorted(conflicts))


def _merged_osm_way_ids(entries: List[Tuple[str, SourceItem]]) -> Tuple[str, ...]:
    return tuple(sorted(
        {way_id for _, item in entries for way_id in item.osm_way_ids},
        key=lambda value: (0, int(value)) if value.isdigit() else (1, value),
    ))


def _unambiguous_geometry(entries: List[Tuple[str, SourceItem]]):
    geometries = [item.geometry for _, item in entries if item.geometry]
    if not geometries:
        return None
    return geometries[0] if len({_value_key(value) for value in geometries}) == 1 else None


def _source_segment_counts(entries: List[Tuple[str, SourceItem]]) -> Dict[str, int]:
    counts: Dict[str, int] = {}
    for source, item in entries:
        raw = item.extra.get("source_segment_count", 1)
        try:
            count = max(1, int(raw))
        except (TypeError, ValueError):
            count = 1
        counts[source] = counts.get(source, 0) + count
    return dict(sorted(counts.items(), key=lambda pair: _priority_index(pair[0])))


def _source_attribute_observations(
    entries: List[Tuple[str, SourceItem]], *, kind: str,
) -> Dict[str, Dict[str, Tuple[str, ...]]]:
    attributes = TRAIL_ATTRIBUTES if kind == "trail" else LIFT_ATTRIBUTES
    observations: Dict[str, Dict[str, set[str]]] = {}
    for source, item in entries:
        by_attribute = observations.setdefault(source, {})
        carried = item.extra.get("attribute_observations") or {}
        for attribute in attributes:
            values = by_attribute.setdefault(attribute, set())
            if isinstance(carried, dict):
                raw_values = carried.get(attribute)
                if isinstance(raw_values, (list, tuple)):
                    values.update(str(value) for value in raw_values)
            if item.extra.get(attribute) is not None:
                values.add(_value_key(item.extra[attribute]))
    return {
        source: {
            attribute: tuple(sorted(values))
            for attribute, values in sorted(by_attribute.items())
            if values
        }
        for source, by_attribute in sorted(
            observations.items(), key=lambda pair: _priority_index(pair[0])
        )
        if any(by_attribute.values())
    }


def _source_evidence_fingerprint(
    entries: List[Tuple[str, SourceItem]], *, kind: str,
) -> str:
    payload = {
        "kind": kind,
        "entries": [
            {
                "source": source,
                "name": item.name,
                "confidence": item.confidence,
                "geometry": item.geometry,
                "osm_way_ids": list(item.osm_way_ids),
                "extra": item.extra,
            }
            for source, item in sorted(entries, key=_entry_sort_key)
        ],
    }
    encoded = json.dumps(
        payload, sort_keys=True, separators=(",", ":"), default=str
    ).encode()
    return hashlib.sha256(encoded).hexdigest()


def _entry_sort_key(pair: Tuple[str, SourceItem]):
    source, item = pair
    return (
        _priority_index(source), normalize_name(item.name), item.name,
        tuple(item.osm_way_ids),
    )


def _priority_index(source: str) -> int:
    try:
        return PRIORITY.index(source)
    except ValueError:
        return len(PRIORITY)


def _value_key(value: object) -> str:
    return json.dumps(value, sort_keys=True, separators=(",", ":"), default=str)


def _confidence(sources_seen: Tuple[str, ...]) -> float:
    if "official" in sources_seen:
        return 1.0
    weight = {
        "official_map": 0.55,
        "skimap": 0.45,
        "openskimap": 0.35,
        "overpass": 0.2,
    }
    return min(1.0, sum(weight.get(s, 0.0) for s in sources_seen))


def _per_source_counts(results: List[SourceResult]) -> Dict[str, Dict[str, int]]:
    out: Dict[str, Dict[str, int]] = {}
    for sr in results:
        trails = sum(1 for i in sr.items if i.kind == "trail")
        lifts = sum(1 for i in sr.items if i.kind == "lift")
        out[sr.source] = {"trails": trails, "lifts": lifts}
    return out


def _all_sources_agree_on_count(results: List[SourceResult]) -> bool:
    populated = [
        sr for sr in results if sr.items and sr.role != "evidence"
    ]
    if len(populated) < 2:
        return True   # nothing to disagree about
    counts = _per_source_counts(populated)
    trail_counts = {c["trails"] for c in counts.values()}
    lift_counts = {c["lifts"] for c in counts.values()}
    return len(trail_counts) == 1 and len(lift_counts) == 1


class CountDisagreementError(RuntimeError):
    def __init__(self, *, resort_id: str, per_source: Dict[str, Dict[str, int]], message: str):
        super().__init__(message)
        self.resort_id = resort_id
        self.per_source = per_source


class SourceDataUnavailableError(RuntimeError):
    def __init__(self, *, resort_id: str, per_source: Dict[str, Dict[str, int]]):
        super().__init__(
            f"no trails or lifts were returned by any source for {resort_id}; "
            "refusing to create an empty canonical draft"
        )
        self.resort_id = resort_id
        self.per_source = per_source
