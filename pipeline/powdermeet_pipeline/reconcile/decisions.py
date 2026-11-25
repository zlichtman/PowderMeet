"""Reviewed decisions for one resort, from `decisions/<resort_id>.yaml`.

The pipeline runs unattended and no resort needs this file. It exists for the
cases where someone who knows the mountain wants to correct what the sources say.

Reconciliation is exact-only. When a reviewer concludes that differently named
source rows are one identity, that judgment is a `merges` entry here instead of
fuzzy matching in code. A merge renames its members into one reconciliation
bucket; it must match exactly one source item per member or the run fails.

    resort_id: whistler-blackcomb
    review_minutes: 25            # time spent reviewing; recorded at publish
    snap_tolerance_m: 15          # 0..15, overrides the catalog default; 0 turns it off
    link_tolerance_m: 200         # 0..250, overrides the catalog default; 0 turns it off
    merges:
      - id: trail:avanti
        kind: trail
        canonical_name: Avanti
        members:
          - {source: official, name: Avanti}
          - {source: osm, name: "Avanti - Lower"}
    links:                        # a gap wider than the automatic limit that skiers do cross
      - {from: n123, to: n456}    # ids from a `link_proposed` flag in the report; 250 m at most
    areas: [n789]                 # a node in a separate ski area whose base is above the
                                  # lowest 15 % (Snowshoe's Silver Creek); see validate.separate_areas
    accept: ["trail:some-run"]    # accept a flagged identity as reconciled
    reject: ["trail:not-ours"]    # not part of the resort; its ways are not built
    exclude_ways: [123456]        # OSM ways to leave out of the graph
    rename: {"trail:some-run": "Some Run"}
    way_names: {256778791: "Boston Mills Lift 1"}  # one OSM way's name, in every source that
                                  # cites it: two lifts or runs in different areas the map
                                  # names alike become two identities
    difficulty: {"trail:some-run": blue}
    status_aliases: {epic: {"Provider Name": "lift:some-lift"}}
    operating_hours:
      default: [{days: [1,2,3,4,5,6,7], open: "08:30", close: "15:30"}]
      "lift:some-lift": [{days: [6,7], open: "09:00", close: "15:00"}]
    add_runs:                     # a run on the resort's list and trail map with no mapped line,
      - name: "Lower Ferk's"      # drawn along the fall line and marked approximate
        difficulty: black         # green | blue | black | double_black
        from: n123456             # where it starts: a lift end or station, or a run node
        to: n789012               # where it ends, lower down and 4 km away at most
        source: "https://..."     # the trail map it came from
    rendezvous:
      reject: [some-id]
      rename: {some-id: "Better Name"}
      confidence: {some-id: 0.9}
"""

from __future__ import annotations

import re
from dataclasses import replace
from pathlib import Path
from typing import Dict, List, Tuple

import yaml

from .models import SourceItem, SourceResult

MAX_SNAP_TOLERANCE_M = 15.0
MAX_LINK_TOLERANCE_M = 250.0
DIFFICULTIES = ("green", "blue", "black", "double_black", "park", "unknown")
DRAWN_DIFFICULTIES = ("green", "blue", "black", "double_black")
KEYS = frozenset({
    "resort_id", "review_minutes", "snap_tolerance_m", "link_tolerance_m", "merges", "links",
    "areas", "add_runs", "accept", "reject", "exclude_ways", "rename", "way_names",
    "difficulty", "status_aliases", "operating_hours", "rendezvous",
})
RENDEZVOUS_KEYS = frozenset({"reject", "rename", "confidence"})


class DecisionError(ValueError):
    pass


def load(resort_id: str, directory: Path) -> dict:
    """Read and validate the decisions file; a missing file means no decisions."""
    path = Path(directory) / f"{resort_id}.yaml"
    raw: dict = {}
    if path.exists():
        try:
            raw = yaml.safe_load(path.read_text()) or {}
        except (OSError, yaml.YAMLError) as error:
            raise DecisionError(f"decisions file cannot be read: {path}: {error}") from error
    decisions = normalize(resort_id, raw)
    decisions["present"] = path.exists()
    return decisions


def normalize(resort_id: str, raw: dict) -> dict:
    if not isinstance(raw, dict):
        raise DecisionError("decisions file must be a mapping")
    if raw.get("resort_id", resort_id) != resort_id:
        raise DecisionError(f"decisions file is for {raw.get('resort_id')}, not {resort_id}")
    # A misspelt key ("exclude_way") would otherwise be dropped and its decision
    # silently not applied.
    unknown = sorted(str(k) for k in set(raw) - KEYS)
    if unknown:
        raise DecisionError(f"decisions file has unknown keys: {', '.join(unknown)}")
    unknown = sorted(str(k) for k in set(raw.get("rendezvous") or {}) - RENDEZVOUS_KEYS)
    if unknown:
        raise DecisionError(f"decisions rendezvous has unknown keys: {', '.join(unknown)}")
    # Absent means "use the catalog default"; 0 turns the joining off.
    snap = None if raw.get("snap_tolerance_m") is None else float(raw["snap_tolerance_m"])
    if snap is not None and not 0 <= snap <= MAX_SNAP_TOLERANCE_M:
        raise DecisionError(f"snap_tolerance_m must be between 0 and {MAX_SNAP_TOLERANCE_M:g}")
    link = None if raw.get("link_tolerance_m") is None else float(raw["link_tolerance_m"])
    if link is not None and not 0 <= link <= MAX_LINK_TOLERANCE_M:
        raise DecisionError(f"link_tolerance_m must be between 0 and {MAX_LINK_TOLERANCE_M:g}")
    difficulty = dict(raw.get("difficulty") or {})
    for group_id, value in difficulty.items():
        if value not in DIFFICULTIES:
            raise DecisionError(f"invalid difficulty {value!r} for {group_id}")
    rendezvous = raw.get("rendezvous") or {}
    confidence = {str(k): float(v) for k, v in (rendezvous.get("confidence") or {}).items()}
    for rendezvous_id, value in confidence.items():
        if not 0.0 <= value <= 1.0:
            raise DecisionError(f"rendezvous confidence for {rendezvous_id} must be between 0 and 1")
    operating_hours = dict(raw.get("operating_hours") or {})
    for group_id, hours in operating_hours.items():
        _validate_hours(hours, str(group_id))
    return {
        "resort_id": resort_id,
        "present": bool(raw),
        "review_minutes": int(raw.get("review_minutes") or 0),
        "snap_tolerance_m": snap,
        "link_tolerance_m": link,
        "merges": _validate_merges(raw.get("merges") or []),
        "links": _validate_links(raw.get("links") or []),
        "areas": _validate_areas(raw.get("areas") or []),
        "add_runs": _validate_add_runs(raw.get("add_runs") or []),
        "accept": sorted(str(g) for g in raw.get("accept") or []),
        "reject": sorted(str(g) for g in raw.get("reject") or []),
        "exclude_ways": sorted(int(w) for w in raw.get("exclude_ways") or []),
        "rename": {str(k): str(v) for k, v in (raw.get("rename") or {}).items()},
        "way_names": _validate_way_names(raw.get("way_names") or {}),
        "difficulty": {str(k): str(v) for k, v in difficulty.items()},
        "status_aliases": {
            str(provider): {str(name): str(group) for name, group in (names or {}).items()}
            for provider, names in (raw.get("status_aliases") or {}).items()
        },
        "operating_hours": operating_hours,
        "rendezvous": {
            "reject": sorted(str(r) for r in rendezvous.get("reject") or []),
            "rename": {str(k): str(v) for k, v in (rendezvous.get("rename") or {}).items()},
            "confidence": confidence,
        },
    }


def _validate_hours(hours, group_id: str) -> None:
    """Hours as the bundle stores them. YAML reads an unquoted 15:30 as the number
    930, so a time must be quoted text."""
    if not isinstance(hours, list) or not hours:
        raise DecisionError(f"operating_hours {group_id} must be a list of {{days, open, close}}")
    for entry in hours:
        if not isinstance(entry, dict) or set(entry) != {"days", "open", "close"}:
            raise DecisionError(f"operating_hours {group_id} entries take days, open and close: {entry}")
        days = entry["days"]
        if not isinstance(days, list) or not days or any(d not in range(1, 8) for d in days):
            raise DecisionError(f"operating_hours {group_id} days are ISO weekdays 1 to 7: {days}")
        for field in ("open", "close"):
            if not isinstance(entry[field], str) or not re.fullmatch(r"([01]\d|2[0-3]):[0-5]\d", entry[field]):
                raise DecisionError(
                    f"operating_hours {group_id} {field} must be a quoted time like \"08:30\": {entry[field]!r}")
        if entry["open"] >= entry["close"]:
            raise DecisionError(f"operating_hours {group_id} opens at {entry['open']}, after it closes")


def apply_merges(merges: List[dict], results: List[SourceResult]) -> List[SourceResult]:
    """Rename each merge's members to its canonical name."""
    item_index = _item_index(results)
    claimed = set()
    replacements: Dict[Tuple[int, int], SourceItem] = {}
    for merge in merges:
        for member in merge["members"]:
            key = (member["source"], merge["kind"], member["name"])
            matches = item_index.get(key, ())
            if len(matches) != 1:
                raise DecisionError(
                    f"merge {merge['id']!r} expected exactly one source item for "
                    f"{key}, found {len(matches)}"
                )
            location, item = matches[0]
            if location in claimed:
                raise DecisionError(f"source item {key} is claimed by multiple merges")
            claimed.add(location)
            extra = dict(item.extra)
            extra["identity_decision"] = {
                "id": merge["id"],
                "canonical_name": merge["canonical_name"],
                "observed_name": item.name,
                "source": member["source"],
            }
            replacements[location] = replace(item, name=merge["canonical_name"], extra=extra)

    return [
        replace(result, items=tuple(
            replacements.get((result_index, index), item)
            for index, item in enumerate(result.items)
        ))
        for result_index, result in enumerate(results)
    ]


def _validate_links(links) -> List[dict]:
    validated = []
    for link in links:
        if not isinstance(link, dict):
            raise DecisionError("links must be mappings with from and to")
        ends = [str(link.get("from") or ""), str(link.get("to") or "")]
        if not all(end.startswith("n") and end[1:].isdigit() for end in ends) or ends[0] == ends[1]:
            raise DecisionError(f"link needs two different node ids like n123: {link}")
        validated.append({"from": ends[0], "to": ends[1]})
    return validated


def _validate_way_names(raw) -> Dict[str, str]:
    if not isinstance(raw, dict):
        raise DecisionError("way_names must map OSM way ids to names")
    names = {}
    for way_id, name in raw.items():
        if not str(way_id).isdigit():
            raise DecisionError(f"way_names key must be an OSM way id: {way_id!r}")
        names[str(int(way_id))] = _text(name, f"way_names {way_id}")
    return dict(sorted(names.items(), key=lambda item: int(item[0])))


def apply_way_names(extract: dict, way_names: Dict[str, str]) -> dict:
    """The extract with each named OSM way renamed, and every OpenSkiMap feature
    that cites only renamed ways given their name, so both sources still agree."""
    if not way_names:
        return extract
    wanted = {int(way_id): name for way_id, name in way_names.items()}
    found = set()
    elements = []
    for element in extract["osm"]["elements"]:
        if element.get("type") == "way" and element.get("id") in wanted:
            found.add(element["id"])
            element = {**element, "tags": {**element.get("tags", {}), "name": wanted[element["id"]]}}
        elements.append(element)
    missing = sorted(set(wanted) - found)
    if missing:
        raise DecisionError(f"way_names names way {missing[0]}, which is not in the extract")
    ski_map = dict(extract.get("openskimap") or {})
    for kind in ("lifts", "runs"):
        features = []
        for feature in ski_map.get(kind) or []:
            cited = [int(s["id"][4:]) for s in feature.get("sources") or ()
                     if str(s.get("id", "")).startswith("way/") and s["id"][4:].isdigit()]
            names = {wanted.get(way_id) for way_id in cited}
            if cited and len(names) == 1 and None not in names:
                feature = {**feature, "name": names.pop()}
            features.append(feature)
        if kind in ski_map:
            ski_map[kind] = features
    return {**extract, "osm": {**extract["osm"], "elements": elements},
            **({"openskimap": ski_map} if "openskimap" in extract else {})}


def _validate_add_runs(entries) -> List[dict]:
    if not isinstance(entries, list):
        raise DecisionError("add_runs must be a list")
    validated, names = [], set()
    for entry in entries:
        if not isinstance(entry, dict):
            raise DecisionError("add_runs entries must be mappings")
        unknown = sorted(set(entry) - {"name", "difficulty", "from", "to", "source"})
        if unknown:
            raise DecisionError(f"add_runs entry has unknown keys: {', '.join(unknown)}")
        name = _text(entry.get("name"), "add_runs name")
        if name.casefold() in names:
            raise DecisionError(f"add_runs names {name!r} twice")
        names.add(name.casefold())
        difficulty = entry.get("difficulty")
        if difficulty not in DRAWN_DIFFICULTIES:
            raise DecisionError(
                f"add_runs {name!r}: difficulty must be one of {', '.join(DRAWN_DIFFICULTIES)}")
        ends = [str(entry.get("from") or ""), str(entry.get("to") or "")]
        if not all(end.startswith("n") and end[1:].isdigit() for end in ends) or ends[0] == ends[1]:
            raise DecisionError(f"add_runs {name!r} needs two different node ids like n123 in from and to")
        source = _text(entry.get("source"), f"add_runs {name!r} source")
        validated.append({"name": name, "difficulty": difficulty, "from": ends[0], "to": ends[1],
                          "source": source})
    return validated


def _validate_areas(areas) -> List[str]:
    nodes = [str(node) for node in areas]
    if not all(node.startswith("n") and node[1:].isdigit() for node in nodes):
        raise DecisionError(f"areas are node ids like n123: {areas}")
    return sorted(set(nodes))


def _validate_merges(merges) -> List[dict]:
    if not isinstance(merges, list):
        raise DecisionError("merges must be a list")
    merge_ids, targets, claimed = set(), set(), set()
    validated = []
    for merge in merges:
        if not isinstance(merge, dict):
            raise DecisionError("merges must be mappings")
        merge_id = _text(merge.get("id"), "merge id")
        if merge_id in merge_ids:
            raise DecisionError(f"duplicate merge id: {merge_id}")
        merge_ids.add(merge_id)
        kind = _text(merge.get("kind"), "merge kind")
        if kind not in ("trail", "lift"):
            raise DecisionError(f"invalid merge kind: {kind}")
        canonical_name = _text(merge.get("canonical_name"), "canonical_name")
        target = (kind, canonical_name.casefold())
        if target in targets:
            raise DecisionError(f"multiple merges target {kind} {canonical_name!r}")
        targets.add(target)
        members = merge.get("members")
        if not isinstance(members, list) or len(members) < 2:
            raise DecisionError(f"merge {merge_id!r} requires at least two members")
        local = set()
        clean_members = []
        for member in members:
            if not isinstance(member, dict):
                raise DecisionError("merge members must be mappings")
            key = (
                _text(member.get("source"), "member source"), kind,
                _text(member.get("name"), "member name"),
            )
            if key in local:
                raise DecisionError(f"duplicate member in merge {merge_id!r}: {key}")
            if key in claimed:
                raise DecisionError(f"member is claimed by multiple merges: {key}")
            local.add(key)
            claimed.add(key)
            clean_members.append({"source": key[0], "name": key[2]})
        validated.append({
            "id": merge_id, "kind": kind, "canonical_name": canonical_name,
            "members": clean_members,
        })
    return validated


def _item_index(results: List[SourceResult]):
    index: Dict[Tuple[str, str, str], list] = {}
    for result_index, result in enumerate(results):
        for item_index, item in enumerate(result.items):
            key = (result.source, item.kind, item.name)
            index.setdefault(key, []).append(((result_index, item_index), item))
    return index


def _text(value: object, field: str) -> str:
    if not isinstance(value, str) or not value.strip():
        raise DecisionError(f"{field} must be nonempty text")
    return value.strip()
