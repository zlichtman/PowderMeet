"""reconcile: merge OSM, OpenSkiMap and official identities into a manifest.

The manifest lists every trail and lift identity with its `group_id`, display
name, difficulty, source way ids, confidence and status aliases, plus rendezvous
proposals and the review list. An identity with the same normalized name in two
or more sources and a single OSM way cluster is accepted automatically; everything
else is listed for review with a proposed decision.
"""

from __future__ import annotations

import hashlib
import json
import re
from datetime import datetime, timezone
from pathlib import Path
from typing import Dict, List

from .. import catalog, drawn, topology
from . import aliases as alias_matching
from . import decisions as decisions_mod
from . import items, rendezvous
from .identities import compact_name, normalize_name, reconcile, slugify
from .models import Identity

DIFFICULTY_ORDER = ("green", "blue", "park", "black", "double_black")
VOLATILE_KEYS = ("manifest_version", "created_at", "extract_id")


def run(resort: dict, extract: dict, decisions: dict) -> dict:
    """Manifest content for one extract. Pure: no clock, no files. Runs under
    `add_runs` must already be traced (`drawn.prepare`)."""
    added = decisions.get("add_runs") or []
    if any("geometry" not in run for run in added):
        raise decisions_mod.DecisionError("add_runs must be traced on the elevation model before reconcile")
    extract = drawn.extend(decisions_mod.apply_way_names(extract, decisions.get("way_names") or {}), added)
    in_extract = {e["id"] for e in extract["osm"]["elements"] if e.get("type") == "way"}
    _require_known(decisions["exclude_ways"], in_extract, "exclude_ways", "ways that are not in the extract")
    net = topology.network(extract, frozenset(decisions["exclude_ways"]))
    results = decisions_mod.apply_merges(decisions["merges"], items.all_sources(extract, net))
    punctuation = _punctuation_merges(results)
    results = decisions_mod.apply_merges(punctuation, results)
    identities = reconcile(results)

    # A way belongs to the identity its own OSM name falls into.
    owner: Dict[int, tuple] = {}
    for item in next(r for r in results if r.source == "osm").items:
        for way_id in item.osm_way_ids:
            owner[int(way_id)] = (item.kind, normalize_name(item.name))
    ways_of: Dict[tuple, List[int]] = {}
    for way_id, key in sorted(owner.items()):
        ways_of.setdefault(key, []).append(way_id)

    routed = [i for i in identities if (i.kind, normalize_name(i.name)) in ways_of]
    unrouted = [i for i in identities if (i.kind, normalize_name(i.name)) not in ways_of]
    group_ids = _assign_group_ids(routed)
    near = _near_names(routed, group_ids)

    # A trail made only of drawn runs takes the difficulty the trail map gives it,
    # unless the decisions file sets one for it.
    drawn_difficulty = {run["way_id"]: run["difficulty"] for run in added}
    drawn_groups: Dict[str, str] = {}
    for identity in routed:
        key = (identity.kind, normalize_name(identity.name))
        if all(w in drawn_difficulty for w in ways_of[key]):
            drawn_groups[group_ids[key]] = drawn_difficulty[ways_of[key][0]]
    if drawn_groups:
        decisions = {**decisions, "difficulty": {**drawn_groups, **decisions["difficulty"]}}

    known = set(group_ids.values())
    for field in ("accept", "reject"):
        _require_known(decisions[field], known, field)
    for field in ("rename", "difficulty"):
        _require_known(decisions[field], known, field)
    lift_groups = {group_id for (kind, _), group_id in group_ids.items() if kind == "lift"}
    _require_known(set(decisions["operating_hours"]) - {"default"}, lift_groups, "operating_hours",
                   "lifts that do not exist")

    flagged: List[dict] = []
    entries = {"trail": [], "lift": []}
    excluded = set(decisions["exclude_ways"])
    counts = {"auto_accepted": 0, "accepted_by_decision": 0, "needs_review": 0, "rejected": 0}

    for identity in routed:
        key = (identity.kind, normalize_name(identity.name))
        group_id = group_ids[key]
        way_ids = ways_of[key]
        if group_id in decisions["reject"]:
            excluded.update(way_ids)
            counts["rejected"] += 1
            continue
        clusters = topology.way_clusters(net, way_ids)
        first_node = net.ways[way_ids[0]].nodes[0]
        lon, lat = net.coords[first_node]
        entry = {
            "group_id": group_id,
            "name": decisions["rename"].get(group_id, identity.name),
            "way_ids": way_ids,
            "sources": list(identity.sources_seen),
            "confidence": identity.confidence,
            "official": "official" in identity.sources_seen,
            "clusters": len(clusters),
            "name_variants": list(identity.source_name_variants),
        }
        if group_id in drawn_groups:
            entry["approximate"] = True
        notes: List[dict] = []

        def flag(code: str, detail: str, proposed: str, blocking: bool = True) -> None:
            notes.append({
                "code": code, "kind": identity.kind, "group_id": group_id,
                "name": identity.name, "detail": detail, "proposed": proposed,
                "blocking": blocking, "lon": lon, "lat": lat,
            })

        if len(identity.sources_seen) < 2:
            flag("single_source", f"only in {identity.sources_seen[0]}",
                 f"kept; add {group_id} to reject if it is not part of the resort")
        if len(clusters) > 1:
            flag("multi_cluster",
                 f"{len(clusters)} separate pieces: " + "; ".join(
                     "ways " + ",".join(str(w) for w in cluster) for cluster in clusters),
                 f"kept as one {identity.kind} mapped in pieces; "
                 "put a stray piece's ways in exclude_ways if it is not part of it")
        if "name" in identity.unresolved_conflicts:
            flag("name_conflict", "sources disagree on the name: " + ", ".join(identity.source_name_variants),
                 "record a merge with the canonical name")
        if key in near:
            flag("near_name", "nearly the same name as " + ", ".join(near[key]),
                 "kept apart; add a merge if they are one identity")

        if identity.kind == "trail":
            entry.update(_trail_difficulty(identity, group_id, decisions, flag))
            entry["groomed_default"] = identity.is_groomed
        else:
            tagged = [
                topology.LIFT_TYPES[str(net.ways[w].tags.get("aerialway")).lower()] for w in way_ids
            ]
            entry["lift_type"] = identity.lift_type or tagged[0]
            entry["operating_hours"] = decisions["operating_hours"].get(group_id)

        blocking = [n for n in notes if n["blocking"]]
        if not blocking:
            entry["accepted"] = True
            counts["auto_accepted"] += 1
            flagged += notes
        elif group_id in decisions["accept"] or group_id in drawn_groups:
            # A drawn run is the reviewer's reading of the trail map: decided.
            entry["accepted"] = True
            counts["accepted_by_decision"] += 1
            flagged += [n for n in notes if not n["blocking"]]
        else:
            entry["accepted"] = False
            counts["needs_review"] += 1
            flagged += notes
        entries[identity.kind].append(entry)

    for identity in unrouted:
        suggestions = sorted(
            group_ids[k] for k in group_ids
            if k[0] == identity.kind and compact_name(k[1]) == compact_name(identity.name)
        )
        flagged.append({
            "code": "no_ways", "kind": identity.kind, "group_id": None, "name": identity.name,
            "detail": "listed by " + ", ".join(identity.sources_seen) + " but no mapped way has this name",
            "proposed": (
                "merge with " + ", ".join(suggestions) if suggestions
                else "merge with the mapped identity it names, or ignore if it is not skiable terrain"
            ),
            "blocking": False, "lon": None, "lat": None,
        })

    provider = resort.get("status_provider")
    aliases: Dict[str, str] = {}
    # One name maps to one group. When a lift and a trail share a name ("Galaxy",
    # "Cascade") the lift keeps it: live status needs every lift mapped.
    for identity in sorted(routed, key=lambda i: i.kind != "trail"):
        group_id = group_ids[(identity.kind, normalize_name(identity.name))]
        if group_id in decisions["reject"]:
            continue
        for name in identity.source_names.get("official", ()):
            aliases[name] = group_id
    # Lifts the feed names differently from the map ("Stella Express" / "Stella").
    lift_names = {
        group_ids[(i.kind, normalize_name(i.name))]: [i.name, *i.source_name_variants]
        for i in routed
        if i.kind == "lift" and group_ids[(i.kind, normalize_name(i.name))] not in decisions["reject"]
    }
    official_lifts = [str(row.get("name") or "").strip() for row in (extract.get("official") or {}).get("lifts") or []]
    loose = alias_matching.match_lifts(
        [name for name in official_lifts if name],
        lift_names,
        {name: group for name, group in aliases.items() if group in lift_names},
        resort.get("name") or "",
    ) if provider else []
    for official_name, group_id, key in loose:
        aliases[official_name] = group_id
        flagged.append({
            "code": "official_lift_name_matched", "kind": "lift", "group_id": group_id,
            "name": official_name,
            "detail": f"the status feed calls {lift_names[group_id][0]!r} {official_name!r} (matched on {key!r})",
            "proposed": "kept as its status alias; set status_aliases for the lift if the match is wrong",
            "blocking": False, "lon": None, "lat": None,
        })
    _require_known(decisions["status_aliases"], {provider} if provider else set(), "status_aliases",
                   "status providers this resort does not use")
    overrides = decisions["status_aliases"].get(provider or "", {})
    _require_known(overrides.values(), known, "status_aliases")
    aliases.update(overrides)

    # The network build will see: rejected identities' ways are gone, so a
    # meeting point is anchored to a vertex that is still built, and a vertex
    # only a rejected way shared with another is no vertex at all.
    built = topology.network(extract, frozenset(excluded))
    _require_known(decisions["areas"], {f"n{node}" for node in topology.vertices(built)}, "areas",
                   "nodes that are not lift ends, stations or junctions of the built network")
    lifts = sorted(entries["lift"], key=lambda e: e["group_id"])
    official = extract.get("official") or {}
    unnamed = [w for w in net.ways.values() if not w.name and w.id not in excluded]
    return {
        "schema": 1,
        "resort_id": resort["resort_id"],
        "trails": sorted(entries["trail"], key=lambda e: e["group_id"]),
        "lifts": lifts,
        "rendezvous": rendezvous.propose(built, extract, lifts, decisions),
        "status_provider": provider,
        "status_aliases": {provider: dict(sorted(aliases.items()))} if provider else {},
        "snap_tolerance_m": _tolerance(decisions, resort, "snap_tolerance_m", 15.0),
        "link_tolerance_m": _tolerance(decisions, resort, "link_tolerance_m", 200.0),
        # Frozen here like the tolerances, so build reads only its two input files.
        "orphan_join_m": float(resort.get("orphan_join_m") or 0),
        "line_join_m": float(resort.get("line_join_m") or 0),
        "links": decisions["links"],
        # Only when a decisions file names any, so older manifests keep their hash.
        **({"areas": decisions["areas"]} if decisions.get("areas") else {}),
        **({"add_runs": added} if added else {}),
        **({"way_names": decisions["way_names"]} if decisions.get("way_names") else {}),
        "exclude_ways": sorted(excluded),
        "default_hours": decisions["operating_hours"].get("default") or resort.get("default_hours") or [],
        "review": {
            **counts,
            "identities": len(entries["trail"]) + len(entries["lift"]),
            "unnamed_runs": sum(1 for w in unnamed if w.kind == "run"),
            "unnamed_lifts": sum(1 for w in unnamed if w.kind == "lift"),
            "sources": {r.source: len(r.items) for r in results},
            "official_error": official.get("error"),
            "official_matched_ignoring_punctuation": len(punctuation),
            "official_lifts_matched_by_name_key": len(loose),
            "flagged": sorted(
                flagged, key=lambda f: (not f["blocking"], f["code"], f["kind"], f["name"])
            ),
        },
    }


def write(content: dict, extract_id: str, now: datetime | None = None) -> tuple[dict, Path]:
    """Store the manifest. The version increments only when the content changes, so
    reconciling the same inputs again returns the existing version."""
    resort_id = content["resort_id"]
    directory = catalog.manifest_dir(resort_id)
    digest = content_hash(content)
    latest = 0
    for version, path in _existing(resort_id):
        latest = max(latest, version)
        existing = json.loads(path.read_text())
        if content_hash(existing) == digest:
            target = directory / f"v{version}.json"
            if not target.exists():
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_text(path.read_text())
            return existing, target
    stamp = (now or datetime.now(timezone.utc)).strftime("%Y-%m-%dT%H:%M:%SZ")
    manifest = {"manifest_version": latest + 1, "created_at": stamp, "extract_id": extract_id, **content}
    target = directory / f"v{latest + 1}.json"
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(json.dumps(manifest, indent=1, sort_keys=True, ensure_ascii=False) + "\n")
    return manifest, target


def load(resort_id: str, reference: str) -> dict:
    """`reference` is `v<N>` or a path to a manifest file."""
    path = Path(reference)
    if not path.is_file():
        if not re.fullmatch(r"v\d+", reference):
            raise catalog.PipelineError(f"manifest must be v<N> or a file path, got {reference!r}")
        found = {version: p for version, p in _existing(resort_id)}
        path = found.get(int(reference[1:]))
        if path is None:
            raise catalog.PipelineError(f"manifest {reference} not found for {resort_id}")
    manifest = json.loads(path.read_text())
    if manifest.get("resort_id") != resort_id:
        raise catalog.PipelineError(f"manifest is for {manifest.get('resort_id')}, not {resort_id}")
    return manifest


def content_hash(manifest: dict) -> str:
    content = {k: v for k, v in manifest.items() if k not in VOLATILE_KEYS}
    encoded = json.dumps(content, sort_keys=True, separators=(",", ":"), ensure_ascii=False)
    return hashlib.sha256(encoded.encode("utf-8")).hexdigest()


def _existing(resort_id: str) -> List[tuple[int, Path]]:
    """Versions in the work directory, then the committed fixtures."""
    found: Dict[int, Path] = {}
    for directory, pattern in (
        (catalog.manifest_dir(resort_id), r"v(\d+)\.json"),
        (catalog.FIXTURES_DIR / resort_id, r"manifest-v(\d+)\.json"),
    ):
        if directory.is_dir():
            for path in sorted(directory.iterdir()):
                match = re.fullmatch(pattern, path.name)
                if match:
                    found.setdefault(int(match.group(1)), path)
    return sorted(found.items())


def _punctuation_merges(results) -> List[dict]:
    """Official names that differ from a mapped name only in spacing or punctuation
    ("Bear Cub Lower" and "Bear Cub - Lower"). The official list is matched to the
    map by these when the match is one to one; nothing looser is ever merged.
    The mapped name stays the identity's name, so its group id does not depend on
    whether the official list could be fetched."""
    mapped = next(r for r in results if r.source == "osm").items
    official = next(r for r in results if r.source == "official").items
    merges = []
    for kind in ("trail", "lift"):
        by_compact: Dict[str, List[str]] = {}
        exact = set()
        for item in mapped:
            if item.kind == kind:
                by_compact.setdefault(compact_name(item.name), []).append(item.name)
                exact.add(normalize_name(item.name))
        wanted: Dict[str, List[str]] = {}
        for item in official:
            if item.kind == kind and "identity_decision" not in item.extra:
                wanted.setdefault(compact_name(item.name), []).append(item.name)
        for compact, names in sorted(wanted.items()):
            candidates = by_compact.get(compact, [])
            if len(names) != 1 or len(candidates) != 1 or normalize_name(names[0]) in exact:
                continue
            merges.append({
                "id": f"punctuation:{kind}:{slugify(candidates[0])}", "kind": kind,
                "canonical_name": candidates[0], "members": [{"source": "official", "name": names[0]}],
            })
    return merges


def _tolerance(decisions: dict, resort: dict, key: str, fallback: float) -> float:
    if decisions.get(key) is not None:
        return float(decisions[key])
    return float(resort.get(key, fallback))


def _assign_group_ids(identities: List[Identity]) -> Dict[tuple, str]:
    ids: Dict[tuple, str] = {}
    used: Dict[str, int] = {}
    for identity in sorted(identities, key=lambda i: (i.kind, slugify(i.name), normalize_name(i.name))):
        base = f"{identity.kind}:{slugify(identity.name)}"
        count = used.get(base, 0) + 1
        used[base] = count
        ids[(identity.kind, normalize_name(identity.name))] = base if count == 1 else f"{base}-{count}"
    return ids


def _near_names(identities: List[Identity], group_ids: Dict[tuple, str]) -> Dict[tuple, List[str]]:
    by_compact: Dict[tuple, List[tuple]] = {}
    for identity in identities:
        key = (identity.kind, normalize_name(identity.name))
        by_compact.setdefault((identity.kind, compact_name(identity.name)), []).append(key)
    near: Dict[tuple, List[str]] = {}
    for keys in by_compact.values():
        if len(keys) > 1:
            for key in keys:
                near[key] = sorted(group_ids[other] for other in keys if other != key)
    return near


def _trail_difficulty(identity: Identity, group_id: str, decisions: dict, flag) -> dict:
    observed = {
        source: {json.loads(v) for v in attributes.get("difficulty", ())}
        for source, attributes in identity.source_attribute_observations.items()
    }
    observed = {source: values for source, values in observed.items() if values}
    if group_id in decisions["difficulty"]:
        return {"difficulty": decisions["difficulty"][group_id], "difficulty_source": "decision"}
    official = observed.get("official")
    mapped = [values for source, values in observed.items() if source != "official"]
    if official and len(official) == 1:
        value = next(iter(official))
        # Build gives each edge the harder of its own way's tag and this value, so
        # a feed never makes a section easier than the map draws it (a stale feed
        # or a wrong icon would route a beginner down a black); only a decision can.
        # The trail shows its hardest section: what a skier must ski to take it all.
        harder = [v for v in set().union(*mapped) if DIFFICULTY_ORDER.index(v) > DIFFICULTY_ORDER.index(value)]
        if harder:
            hardest = max(harder, key=DIFFICULTY_ORDER.index)
            flag("difficulty_differs_from_official",
                 f"official says {value}; the map says " + ", ".join(sorted(set().union(*mapped))),
                 f"sections mapped harder keep the map's value and the rest take {value}, so the "
                 f"trail shows {hardest}; set difficulty for {group_id} to override",
                 blocking=False)
            return {"difficulty": hardest, "difficulty_source": "map_harder_than_official",
                    "official_difficulty": value}
        if any(values != official for values in mapped):
            flag("difficulty_differs_from_official",
                 f"official says {value}; the map says " + ", ".join(sorted(set().union(*mapped))),
                 f"keep {value}, or set difficulty for {group_id}", blocking=False)
        return {"difficulty": value, "difficulty_source": "official", "official_difficulty": value}
    # Several official values for one name (runs in two areas called alike) cannot
    # say which section is which: each edge keeps its own mapped value, and the
    # trail and any untagged way take the hardest the sources give.
    considered = list(observed.values()) if official else mapped
    union = set().union(*considered) if considered else set()
    hardest = max(union, key=DIFFICULTY_ORDER.index) if union else "unknown"
    if official or any(values != mapped[0] for values in mapped):
        flag("difficulty_conflict",
             "sources disagree: " + "; ".join(
                 f"{source} {'/'.join(sorted(values))}" for source, values in sorted(observed.items())),
             f"the harder value, {hardest}, is used; set difficulty for {group_id} to override")
    elif len(union) > 1:
        flag("mixed_difficulty",
             "its ways are tagged " + ", ".join(sorted(union, key=DIFFICULTY_ORDER.index)),
             f"each edge keeps its own way's difficulty; the group shows {hardest}", blocking=False)
    return {"difficulty": hardest, "difficulty_source": "osm"}


def _require_known(names, known: set, field: str, what: str = "identities that do not exist") -> None:
    unknown = sorted(str(n) for n in names if n not in known)
    if unknown:
        raise decisions_mod.DecisionError(f"decisions {field} names {what}: {', '.join(unknown)}")
