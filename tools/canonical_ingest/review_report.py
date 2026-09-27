"""Pure, deterministic review reporting for canonical resort drafts.

The report deliberately never accepts, rejects, renames, or resolves a row.
It turns source evidence and OSM topology into a finite operator checklist.
"""

from __future__ import annotations

import json
import math
import re
import unicodedata
from collections import Counter, defaultdict
from difflib import SequenceMatcher
from typing import Dict, Iterable, Optional

from canonical_ingest.reconcile import normalize_name


_POSITIONAL_SUFFIX = re.compile(
    r"\s+-\s+(lower|middle|upper|east|west)$", re.IGNORECASE
)


def build_report(
    draft: dict,
    overpass_fixture: Optional[dict] = None,
    *,
    apply_validation_checked: bool = False,
    apply_validation_error: Optional[str] = None,
) -> dict:
    rows = list(draft.get("trail_rows") or []) + list(draft.get("lift_rows") or [])
    topology = _topology_index(overpass_fixture or {})
    report_rows = []
    for row in sorted(
        rows, key=lambda value: (str(value.get("kind")), _text_key(value.get("name")))
    ):
        way_ids = tuple(str(value) for value in (row.get("osm_way_ids") or ()))
        report_rows.append({
            "kind": row.get("kind"),
            "name": row.get("name"),
            "decision": _decision(row),
            "confidence": row.get("confidence"),
            "sources_seen": list(row.get("sources_seen") or ()),
            "source_name_variants": list(row.get("source_name_variants") or ()),
            "source_segment_counts": dict(row.get("source_segment_counts") or {}),
            "source_attribute_observations": dict(
                row.get("source_attribute_observations") or {}
            ),
            "source_evidence_fingerprint": row.get("source_evidence_fingerprint"),
            "identity_decision_ids": list(row.get("identity_decision_ids") or ()),
            "osm_way_ids": list(way_ids),
            "canonical_values": _canonical_values(row),
            "unresolved_conflicts": list(row.get("unresolved_conflicts") or ()),
            "topology": topology_for_way_ids(topology, way_ids),
            "notes": row.get("notes"),
        })

    decisions = Counter(row["decision"] for row in report_rows)
    conflicts = [row for row in report_rows if row["unresolved_conflicts"]]
    multi_way = [
        row for row in report_rows
        if (row.get("topology") or {}).get("way_count", 0) > 1
    ]
    topology_counts = Counter(
        row["topology"]["classification"] for row in multi_way
    )
    segment_families = _segment_family_suggestions(report_rows, topology)
    near_names = _near_name_suggestions(report_rows)
    applied_decisions = sorted({
        decision_id
        for row in report_rows
        for decision_id in row.get("identity_decision_ids") or ()
    })
    accepted_trails = sum(
        row["decision"] == "accepted" and row["kind"] == "trail"
        for row in report_rows
    )
    accepted_lifts = sum(
        row["decision"] == "accepted" and row["kind"] == "lift"
        for row in report_rows
    )
    expected_trails = int(draft.get("expected_trail_count") or 0)
    expected_lifts = int(draft.get("expected_lift_count") or 0)
    blockers = []
    if not draft.get("canonical_counts_reviewed", False):
        blockers.append("canonical identity counts are not operator-reviewed")
    if accepted_trails != expected_trails:
        blockers.append(
            f"accepted trail count {accepted_trails} does not match target {expected_trails}"
        )
    if accepted_lifts != expected_lifts:
        blockers.append(
            f"accepted lift count {accepted_lifts} does not match target {expected_lifts}"
        )
    accepted_conflicts = [
        row["name"] for row in conflicts if row["decision"] == "accepted"
    ]
    if accepted_conflicts:
        blockers.append(
            "accepted rows retain unresolved conflicts: "
            + ", ".join(sorted(str(name) for name in accepted_conflicts))
        )
    if not apply_validation_checked:
        blockers.append("full manifest validation has not run")
    elif apply_validation_error:
        blockers.append(f"manifest validation: {apply_validation_error}")

    return {
        "schema_version": 1,
        "resort_id": draft.get("resort_id"),
        "canonical_counts_reviewed": bool(
            draft.get("canonical_counts_reviewed", False)
        ),
        "expected_canonical_counts": {
            "trails": expected_trails,
            "lifts": expected_lifts,
        },
        "headline_statistics": {
            "trails_or_runs": draft.get("headline_trail_count"),
            "lifts": draft.get("headline_lift_count"),
        },
        "candidate_counts": {
            "trails": sum(row["kind"] == "trail" for row in report_rows),
            "lifts": sum(row["kind"] == "lift" for row in report_rows),
        },
        "decision_counts": dict(sorted(decisions.items())),
        "unresolved_conflict_count": len(conflicts),
        "multi_way_topology_counts": dict(sorted(topology_counts.items())),
        "segment_family_suggestions": segment_families,
        "near_name_suggestions": near_names,
        "applied_identity_decisions": applied_decisions,
        "apply_ready": not blockers,
        "apply_blockers": blockers,
        "rows": report_rows,
    }


def summary_text(report: dict) -> str:
    counts = report["candidate_counts"]
    targets = report["expected_canonical_counts"]
    reviewed = "REVIEWED" if report["canonical_counts_reviewed"] else "UNREVIEWED"
    decisions = report.get("decision_counts") or {}
    lines = [
        f"resort_id: {report['resort_id']}",
        f"canonical identity target ({reviewed}): "
        f"{targets['trails']} trails / {targets['lifts']} lifts",
        f"candidate rows: {counts['trails']} trails / {counts['lifts']} lifts",
        "decisions: "
        f"{decisions.get('accepted', 0)} accepted / "
        f"{decisions.get('rejected', 0)} rejected / "
        f"{decisions.get('pending', 0)} pending",
        f"unresolved conflicts: {report['unresolved_conflict_count']}",
    ]
    topology = report.get("multi_way_topology_counts") or {}
    if topology:
        formatted = ", ".join(
            f"{name}={count}" for name, count in sorted(topology.items())
        )
        lines.append(f"multi-way topology: {formatted}")
    segment_families = report.get("segment_family_suggestions") or []
    near_names = report.get("near_name_suggestions") or []
    lines.append(
        f"identity suggestions: {len(segment_families)} segment families / "
        f"{len(near_names)} near-name pairs (review only; never auto-merged)"
    )
    lines.append(
        "evidence-pinned identity decisions: "
        f"{len(report.get('applied_identity_decisions') or ())} applied"
    )
    if report.get("apply_ready"):
        lines.append("apply gate: READY")
    else:
        lines.append("apply gate: BLOCKED")
        lines.extend(f"  - {reason}" for reason in report.get("apply_blockers") or ())

    conflicted = [row for row in report["rows"] if row["unresolved_conflicts"]]
    if conflicted:
        lines.append("conflict checklist:")
        for row in conflicted:
            observed = _format_observations(row["source_attribute_observations"])
            suffix = f"; observed {observed}" if observed else ""
            lines.append(
                f"  [{row['kind']}] {row['name']}: "
                f"{', '.join(row['unresolved_conflicts'])}{suffix}"
            )

    disconnected = [
        row for row in report["rows"]
        if (row.get("topology") or {}).get("classification") == "disconnected"
    ]
    if disconnected:
        lines.append("disconnected same-name geometry checklist:")
        for row in disconnected:
            topology = row["topology"]
            gap = topology.get("minimum_component_gap_m")
            gap_text = f", nearest gap {gap:.1f} m" if isinstance(gap, float) else ""
            lines.append(
                f"  [{row['kind']}] {row['name']}: "
                f"{topology['component_count']} components{gap_text}"
            )
    if segment_families:
        lines.append("positional segment-family checklist:")
        for family in segment_families:
            official = "; official-map label present" if family[
                "official_map_label_present"
            ] else ""
            lines.append(
                f"  [{family['kind']}] {family['base_name']}: "
                + ", ".join(family["members"])
                + official
            )
    if near_names:
        lines.append("near-name checklist:")
        for suggestion in near_names:
            lines.append(
                f"  [{suggestion['kind']}] {suggestion['left']} <> "
                f"{suggestion['right']} ({suggestion['reason']}, "
                f"score {suggestion['similarity']:.3f})"
            )
    return "\n".join(lines)


def _segment_family_suggestions(rows: list[dict], topology: dict) -> list[dict]:
    by_kind_and_name = {
        (str(row.get("kind")), normalize_name(str(row.get("name") or ""))): row
        for row in rows
    }
    families: Dict[tuple[str, str], list[dict]] = defaultdict(list)
    display_names: Dict[tuple[str, str], str] = {}
    for row in rows:
        name = str(row.get("name") or "").strip()
        match = _POSITIONAL_SUFFIX.search(name)
        if not match:
            continue
        base = name[:match.start()].strip()
        key = (str(row.get("kind")), normalize_name(base))
        families[key].append(row)
        display_names.setdefault(key, base)

    suggestions = []
    for key, suffix_rows in families.items():
        base_row = by_kind_and_name.get(key)
        members = ([base_row] if base_row is not None else []) + suffix_rows
        if len(members) < 2:
            continue
        way_ids = sorted(
            {
                str(way_id)
                for row in members
                for way_id in (row.get("osm_way_ids") or ())
            },
            key=_identifier_key,
        )
        suggestions.append({
            "kind": key[0],
            "base_name": (
                str(base_row.get("name")) if base_row else display_names[key]
            ),
            "members": sorted(
                {str(row.get("name")) for row in members}, key=_text_key
            ),
            "official_map_label_present": bool(
                base_row and "official_map" in (base_row.get("sources_seen") or ())
            ),
            "combined_osm_way_ids": way_ids,
            "combined_topology": topology_for_way_ids(topology, way_ids),
        })
    return sorted(
        suggestions, key=lambda value: (value["kind"], _text_key(value["base_name"]))
    )


def _near_name_suggestions(rows: list[dict]) -> list[dict]:
    suggestions = []
    ordered = sorted(
        rows, key=lambda value: (str(value.get("kind")), _text_key(value.get("name")))
    )
    for index, left in enumerate(ordered):
        left_name = str(left.get("name") or "").strip()
        left_key = normalize_name(left_name)
        if len(left_key) < 5:
            continue
        for right in ordered[index + 1:]:
            if right.get("kind") != left.get("kind"):
                continue
            right_name = str(right.get("name") or "").strip()
            right_key = normalize_name(right_name)
            if left_key == right_key or len(right_key) < 5:
                continue
            left_family = _positional_base_name(left_name)
            right_family = _positional_base_name(right_name)
            if left_family and right_family and (
                normalize_name(left_family) == normalize_name(right_family)
            ):
                continue
            compact_equal = (
                _compact_name_key(left_name) == _compact_name_key(right_name)
            )
            similarity = SequenceMatcher(
                None, left_key, right_key, autojunk=False
            ).ratio()
            lift_suffix_equal = (
                left.get("kind") == "lift"
                and _lift_label_key(left_name) == _lift_label_key(right_name)
            )
            official_involved = (
                "official_map" in (left.get("sources_seen") or ())
                or "official_map" in (right.get("sources_seen") or ())
            )
            cutoff = 0.90 if official_involved else 0.92
            if not compact_equal and not lift_suffix_equal and similarity < cutoff:
                continue
            reason = "similar_spelling"
            if compact_equal:
                reason = "compact_equivalent"
            elif lift_suffix_equal:
                reason = "lift_suffix_equivalent"
            suggestions.append({
                "kind": left.get("kind"),
                "left": left_name,
                "right": right_name,
                "reason": reason,
                "similarity": round(similarity, 6),
                "official_map_involved": official_involved,
            })
    return suggestions


def _compact_name_key(value: str) -> str:
    normalized = unicodedata.normalize("NFKC", value).casefold()
    return "".join(character for character in normalized if character.isalnum())


def _lift_label_key(value: str) -> str:
    normalized = normalize_name(value)
    normalized = re.sub(r"\s*\(\s*#?\d+\s*\)\s*$", "", normalized)
    normalized = re.sub(r"\s+lift\s*$", "", normalized)
    return _compact_name_key(normalized)


def _positional_base_name(value: str) -> Optional[str]:
    match = _POSITIONAL_SUFFIX.search(value.strip())
    return value[:match.start()].strip() if match else None


def topology_for_way_ids(index: dict, way_ids: Iterable[str]) -> Optional[dict]:
    requested = tuple(sorted(set(way_ids), key=_identifier_key))
    if not requested:
        return None
    ways = index.get("ways") or {}
    nodes = index.get("nodes") or {}
    found = {way_id: ways[way_id] for way_id in requested if way_id in ways}
    missing = [way_id for way_id in requested if way_id not in found]
    if not found:
        return {
            "classification": "missing",
            "way_count": len(requested),
            "found_way_count": 0,
            "missing_way_ids": missing,
            "component_count": 0,
            "component_sizes": [],
            "branch_node_count": 0,
            "minimum_component_gap_m": None,
        }

    owners: Dict[int, list[str]] = defaultdict(list)
    for way_id, refs in found.items():
        for node_id in set(refs):
            owners[node_id].append(way_id)
    adjacency = {way_id: set() for way_id in found}
    for members in owners.values():
        for way_id in members:
            adjacency[way_id].update(other for other in members if other != way_id)
    components = []
    unseen = set(found)
    while unseen:
        first = min(unseen, key=_identifier_key)
        stack = [first]
        unseen.remove(first)
        component = []
        while stack:
            way_id = stack.pop()
            component.append(way_id)
            for neighbor in sorted(adjacency[way_id], key=_identifier_key):
                if neighbor in unseen:
                    unseen.remove(neighbor)
                    stack.append(neighbor)
        components.append(tuple(sorted(component, key=_identifier_key)))
    components.sort(key=lambda value: (-len(value), tuple(map(_identifier_key, value))))
    branch_nodes = sum(len(members) > 2 for members in owners.values())
    if missing:
        classification = "incomplete"
    elif len(found) == 1:
        classification = "single_way"
    elif len(components) > 1:
        classification = "disconnected"
    elif branch_nodes:
        classification = "connected_branch"
    else:
        classification = "connected_chain"
    return {
        "classification": classification,
        "way_count": len(requested),
        "found_way_count": len(found),
        "missing_way_ids": missing,
        "component_count": len(components),
        "component_sizes": [len(component) for component in components],
        "branch_node_count": branch_nodes,
        "minimum_component_gap_m": _minimum_component_gap(
            components, found, nodes
        ),
    }


def _topology_index(fixture: dict) -> dict:
    nodes = {
        int(element["id"]): (float(element["lon"]), float(element["lat"]))
        for element in fixture.get("elements") or ()
        if element.get("type") == "node"
        and element.get("id") is not None
        and element.get("lon") is not None
        and element.get("lat") is not None
    }
    ways = {
        str(element["id"]): tuple(int(value) for value in element.get("nodes") or ())
        for element in fixture.get("elements") or ()
        if element.get("type") == "way" and element.get("id") is not None
    }
    return {"nodes": nodes, "ways": ways}


def _minimum_component_gap(components, ways, nodes) -> Optional[float]:
    if len(components) < 2:
        return None
    component_nodes = []
    for component in components:
        component_nodes.append({
            node_id
            for way_id in component
            for node_id in ways.get(way_id, ())
            if node_id in nodes
        })
    best = math.inf
    for left_index, left in enumerate(component_nodes):
        for right in component_nodes[left_index + 1:]:
            for left_node in left:
                for right_node in right:
                    best = min(best, _haversine(nodes[left_node], nodes[right_node]))
    return round(best, 1) if math.isfinite(best) else None


def _haversine(left, right) -> float:
    lon1, lat1 = left
    lon2, lat2 = right
    radius = 6_371_000.0
    phi1, phi2 = math.radians(lat1), math.radians(lat2)
    d_phi = math.radians(lat2 - lat1)
    d_lambda = math.radians(lon2 - lon1)
    value = (
        math.sin(d_phi / 2) ** 2
        + math.cos(phi1) * math.cos(phi2) * math.sin(d_lambda / 2) ** 2
    )
    value = min(1.0, max(0.0, value))
    return 2 * radius * math.atan2(math.sqrt(value), math.sqrt(1 - value))


def _canonical_values(row: dict) -> dict:
    fields = (
        (
            "difficulty", "is_groomed", "has_moguls", "is_gladed",
            "length_m", "vert_m", "geometry",
        )
        if row.get("kind") == "trail"
        else (
            "lift_type", "capacity", "ride_time_s", "vertical_rise_m",
            "weekday_wait_min", "weekend_wait_min", "base_coord",
            "top_coord", "geometry",
        )
    )
    return {field: row.get(field) for field in fields}


def _decision(row: dict) -> str:
    notes = str(row.get("notes") or "").lstrip()
    if notes.upper().startswith("REJECT:"):
        return "rejected"
    return "accepted" if row.get("accepted") is True else "pending"


def _format_observations(observations: dict) -> str:
    parts = []
    for source, attributes in sorted(observations.items()):
        for attribute, values in sorted((attributes or {}).items()):
            display = "/".join(_display_value(value) for value in values)
            parts.append(f"{source}.{attribute}={display}")
    return ", ".join(parts)


def _display_value(value: object) -> str:
    if isinstance(value, str):
        return value
    return json.dumps(value, sort_keys=True, separators=(",", ":"))


def _text_key(value: object) -> tuple[str, str]:
    text = str(value or "")
    return (text.casefold(), text)


def _identifier_key(value: str):
    return (0, int(value)) if value.isdigit() else (1, value)
