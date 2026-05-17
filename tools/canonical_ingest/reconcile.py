"""Multi-source reconciliation.

Takes a list of `SourceResult`s (one per source, all for the same
resort), normalizes names, fuzzy-matches across sources, and emits a
`DraftManifest` with per-row source agreement + confidence scores.

Conflict policy: count disagreement between sources NEVER auto-resolves.
If two sources differ on trail / lift count, the operator must enter
the official count via `--expected-trails N --expected-lifts N` (or
provide an `official` source with the count baked in). Silent
auto-resolution to "max" or "modal" is exactly what we are trying to
eliminate.
"""

from __future__ import annotations
import re
from collections import defaultdict
from typing import List, Dict, Tuple, Optional

from canonical_ingest.models import (
    SourceResult, SourceItem, DraftManifest, DraftRow,
)


PRIORITY = ("official", "skimap", "openskimap", "overpass")
"""Source priority for tie-breaking name + geometry choices."""


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
    fuzzy_cutoff: float = 0.88,
) -> DraftManifest:
    if not results:
        raise ValueError("reconcile() requires at least one SourceResult")
    resort_id = results[0].resort_id

    # Bucket items by (kind, normalized_name); preserve source order
    # so PRIORITY ranking applies in tie-break.
    buckets: Dict[Tuple[str, str], List[Tuple[str, SourceItem]]] = defaultdict(list)
    for sr in results:
        for item in sr.items:
            key = (item.kind, normalize_name(item.name))
            buckets[(item.kind, normalize_name(item.name))].append((sr.source, item))

    # Optional fuzzy cluster pass: merge close-but-not-equal name buckets
    # using rapidfuzz when available. If unavailable, keep exact-match
    # buckets only — explicit dependency surfaces in the CLI.
    try:
        from rapidfuzz import fuzz  # type: ignore
        buckets = _fuzzy_merge(buckets, fuzz, cutoff=fuzzy_cutoff)
    except ImportError:
        pass

    trail_rows: List[DraftRow] = []
    lift_rows: List[DraftRow] = []
    for (kind, _norm), entries in buckets.items():
        # Choose the canonical name from the highest-priority source
        # that contains this bucket.
        sources_seen = tuple(sorted({s for s, _ in entries}, key=PRIORITY.index))
        canonical = _pick_canonical(entries)
        confidence = _confidence(sources_seen)
        row = DraftRow(
            name=canonical.name,
            kind=kind,                  # type: ignore[arg-type]
            sources_seen=sources_seen,
            confidence=confidence,
            geometry=canonical.geometry,
            osm_way_ids=canonical.osm_way_ids,
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
                    "supply --expected-trails N --expected-lifts N (from the "
                    "resort's official site) to resolve"
                ),
            )

    return DraftManifest(
        resort_id=resort_id,
        expected_trail_count=expected_trail_count or actual_trail,
        expected_lift_count=expected_lift_count or actual_lift,
        trail_rows=trail_rows,
        lift_rows=lift_rows,
    )


def _pick_canonical(entries: List[Tuple[str, SourceItem]]) -> SourceItem:
    ranked = sorted(entries, key=lambda pair: PRIORITY.index(pair[0]))
    return ranked[0][1]


def _confidence(sources_seen: Tuple[str, ...]) -> float:
    if "official" in sources_seen:
        return 1.0
    weight = {"skimap": 0.45, "openskimap": 0.35, "overpass": 0.2}
    return min(1.0, sum(weight.get(s, 0.0) for s in sources_seen))


def _fuzzy_merge(buckets, fuzz, *, cutoff: float):
    # Merge buckets within the same `kind` whose normalized names
    # have token-set ratio >= cutoff. Conservative: only merge into
    # a target if the ratio is high; do not chain across two merges.
    keys = list(buckets.keys())
    merged: Dict[Tuple[str, str], List] = {}
    consumed: set = set()
    for i, key in enumerate(keys):
        if key in consumed:
            continue
        target_kind, target_name = key
        items = list(buckets[key])
        for other in keys[i + 1:]:
            if other in consumed:
                continue
            kind2, name2 = other
            if kind2 != target_kind:
                continue
            score = fuzz.token_set_ratio(target_name, name2) / 100.0
            if score >= cutoff:
                items.extend(buckets[other])
                consumed.add(other)
        merged[key] = items
    return merged


def _per_source_counts(results: List[SourceResult]) -> Dict[str, Dict[str, int]]:
    out: Dict[str, Dict[str, int]] = {}
    for sr in results:
        trails = sum(1 for i in sr.items if i.kind == "trail")
        lifts = sum(1 for i in sr.items if i.kind == "lift")
        out[sr.source] = {"trails": trails, "lifts": lifts}
    return out


def _all_sources_agree_on_count(results: List[SourceResult]) -> bool:
    populated = [sr for sr in results if sr.items]
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
