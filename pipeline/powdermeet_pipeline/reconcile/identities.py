"""Multi-source reconciliation.

Takes one `SourceResult` per source for a resort, buckets items by exact
normalized name, and returns one `Identity` per bucket with source agreement, a
confidence score and every attribute conflict.

Approximate names are never merged here. They surface as review suggestions and
are merged only by a reviewed decision in `decisions/<resort_id>.yaml`.
"""

from __future__ import annotations

import hashlib
import re
import unicodedata
from collections import defaultdict
from typing import Dict, List, Tuple

from .common import identifier_sort_key, value_key
from .models import Identity, SourceItem, SourceResult

PRIORITY = ("official", "openskimap", "osm")
"""Source priority for tie-breaking names and attributes."""

CONFIDENCE_WEIGHT = {"openskimap": 0.35, "osm": 0.2}

TRAIL_ATTRIBUTES = ("difficulty", "is_groomed")
LIFT_ATTRIBUTES = ("lift_type", "capacity", "ride_time_s")


class SourceDataUnavailableError(RuntimeError):
    def __init__(self, *, resort_id: str, per_source: Dict[str, Dict[str, int]]):
        super().__init__(
            f"no trails or lifts were returned by any source for {resort_id}; "
            "refusing to create an empty manifest"
        )
        self.resort_id = resort_id
        self.per_source = per_source


def normalize_name(name: str) -> str:
    """Conservative normalization: strips a leading 'The ', collapses whitespace,
    lowercases, strips trailing punctuation. Expansions such as "St" -> "Saint" are
    deliberately left out because they can merge distinct trails."""
    n = name.strip()
    n = re.sub(r"^The\s+", "", n, flags=re.IGNORECASE)
    n = re.sub(r"\s+", " ", n)
    n = re.sub(r"[\.\,\;\:]+$", "", n)
    return n.lower()


def compact_name(name: str) -> str:
    """Letters and digits only: "Wild Card" and "Wildcard" compare equal. Used to
    suggest merges, never to perform one."""
    folded = unicodedata.normalize("NFKD", normalize_name(name))
    return "".join(ch for ch in folded if ch.isalnum())


def slugify(name: str) -> str:
    """`Franz's Run` -> `franzs-run`, `Pähtli` -> `pahtli`. A name with no Latin
    letters or digits (`山頂レストラン`) is `u-` and a hash of the name: every such
    name used to be `unnamed`, so lodges named in Japanese or Cyrillic collapsed
    into one and their numbered ids shifted whenever one was added."""
    normalized = normalize_name(name)
    folded = unicodedata.normalize("NFKD", normalized)
    folded = folded.encode("ascii", "ignore").decode("ascii")
    folded = re.sub(r"['’`]", "", folded)
    slug = re.sub(r"[^a-z0-9]+", "-", folded).strip("-")
    if slug:
        return slug
    if not normalized:
        return "unnamed"
    return "u-" + hashlib.sha256(unicodedata.normalize("NFC", normalized).encode("utf-8")).hexdigest()[:8]


def reconcile(results: List[SourceResult]) -> List[Identity]:
    if not results:
        raise ValueError("reconcile() requires at least one SourceResult")
    resort_id = results[0].resort_id
    if any(result.resort_id != resort_id for result in results):
        raise ValueError("all SourceResults must describe the same resort")
    if not any(result.items for result in results):
        raise SourceDataUnavailableError(
            resort_id=resort_id, per_source=per_source_counts(results),
        )

    buckets: Dict[Tuple[str, str], List[Tuple[str, SourceItem]]] = defaultdict(list)
    for result in results:
        for item in result.items:
            buckets[(item.kind, normalize_name(item.name))].append((result.source, item))

    identities: List[Identity] = []
    for (kind, _norm), entries in sorted(buckets.items()):
        sources_seen = tuple(sorted({s for s, _ in entries}, key=_priority_index))
        canonical = sorted(entries, key=_entry_sort_key)[0][1]
        attributes, attribute_conflicts = _merge_attributes(entries, kind=kind)
        variants = tuple(sorted(
            _observed_names(entries),
            key=lambda name: (normalize_name(name), name.casefold(), name),
        ))
        conflicts = set(attribute_conflicts)
        if _has_unresolved_name_conflict(entries, canonical.name, variants):
            conflicts.add("name")
        identities.append(Identity(
            name=canonical.name,
            kind=kind,  # type: ignore[arg-type]
            sources_seen=sources_seen,
            confidence=_confidence(sources_seen),
            difficulty=attributes.get("difficulty"),
            is_groomed=attributes.get("is_groomed"),
            lift_type=attributes.get("lift_type"),
            capacity=attributes.get("capacity"),
            ride_time_s=attributes.get("ride_time_s"),
            osm_way_ids=_merged_osm_way_ids(entries),
            source_name_variants=variants,
            source_names=_source_names(entries),
            source_segment_counts=_source_segment_counts(entries),
            source_attribute_observations=_source_attribute_observations(entries, kind=kind),
            identity_decision_ids=_identity_decision_ids(entries),
            unresolved_conflicts=tuple(sorted(conflicts)),
        ))
    return identities


def per_source_counts(results: List[SourceResult]) -> Dict[str, Dict[str, int]]:
    return {
        result.source: {
            "trails": sum(1 for i in result.items if i.kind == "trail"),
            "lifts": sum(1 for i in result.items if i.kind == "lift"),
        }
        for result in results
    }


def _observed_name(item: SourceItem) -> str:
    decision = item.extra.get("identity_decision")
    if isinstance(decision, dict):
        observed = decision.get("observed_name")
        if isinstance(observed, str) and observed.strip():
            return observed.strip()
    return item.name


def _observed_names(entries: List[Tuple[str, SourceItem]]) -> set[str]:
    return {item.name for _, item in entries} | {_observed_name(item) for _, item in entries}


def _source_names(entries: List[Tuple[str, SourceItem]]) -> Dict[str, Tuple[str, ...]]:
    """The names each source used before any decision renamed them."""
    names: Dict[str, set[str]] = defaultdict(set)
    for source, item in entries:
        names[source].add(_observed_name(item))
    return {
        source: tuple(sorted(values))
        for source, values in sorted(names.items(), key=lambda pair: _priority_index(pair[0]))
    }


def _has_unresolved_name_conflict(entries, canonical_name: str, variants) -> bool:
    canonical_key = normalize_name(canonical_name)
    if all(normalize_name(name) == canonical_key for name in variants):
        return False
    decision_ids = set()
    for _, item in entries:
        decision = item.extra.get("identity_decision")
        if normalize_name(_observed_name(item)) == canonical_key:
            continue
        decision_id = decision.get("id") if isinstance(decision, dict) else None
        decision_canonical = decision.get("canonical_name") if isinstance(decision, dict) else None
        if (
            not isinstance(decision_id, str)
            or not decision_id.strip()
            or normalize_name(str(decision_canonical or "")) != canonical_key
        ):
            return True
        decision_ids.add(decision_id)
    return len(decision_ids) != 1


def _identity_decision_ids(entries) -> Tuple[str, ...]:
    return tuple(sorted({
        str(decision["id"]).strip()
        for _, item in entries
        for decision in (item.extra.get("identity_decision"),)
        if isinstance(decision, dict)
        and isinstance(decision.get("id"), str)
        and str(decision["id"]).strip()
    }))


def _merge_attributes(entries, *, kind: str) -> Tuple[Dict[str, object], Tuple[str, ...]]:
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
            item.extra[attribute] for _, item in ranked
            if item.extra.get(attribute) is not None
        ]
        if observations:
            chosen[attribute] = observations[0]
        if len({value_key(value) for value in observations}) > 1:
            conflicts.add(attribute)
    return chosen, tuple(sorted(conflicts))


def _merged_osm_way_ids(entries) -> Tuple[str, ...]:
    return tuple(sorted(
        {way_id for _, item in entries for way_id in item.osm_way_ids},
        key=identifier_sort_key,
    ))


def _source_segment_counts(entries) -> Dict[str, int]:
    counts: Dict[str, int] = {}
    for source, item in entries:
        raw = item.extra.get("source_segment_count", 1)
        try:
            count = max(1, int(raw))
        except (TypeError, ValueError):
            count = 1
        counts[source] = counts.get(source, 0) + count
    return dict(sorted(counts.items(), key=lambda pair: _priority_index(pair[0])))


def _source_attribute_observations(entries, *, kind: str):
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
                values.add(value_key(item.extra[attribute]))
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


def _entry_sort_key(pair: Tuple[str, SourceItem]):
    source, item = pair
    return (_priority_index(source), normalize_name(item.name), item.name, tuple(item.osm_way_ids))


def _priority_index(source: str) -> int:
    try:
        return PRIORITY.index(source)
    except ValueError:
        return len(PRIORITY)


def _confidence(sources_seen: Tuple[str, ...]) -> float:
    if "official" in sources_seen:
        return 1.0
    return round(min(1.0, sum(CONFIDENCE_WEIGHT.get(s, 0.0) for s in sources_seen)), 2)
