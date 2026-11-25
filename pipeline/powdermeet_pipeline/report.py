"""The review report for one bundle: Markdown for the reviewer and a GeoJSON
preview with edges colored by flag."""

from __future__ import annotations

import json
from collections import defaultdict

FLAG_COLORS = {
    "lift_exit_dead_end": "#d81b60",
    "lift_cut_off": "#d81b60",
    "run_uphill": "#e65100",
    "orphan_edge": "#8e24aa",
    "run_reversed": "#f9a825",
    "unnamed_run": "#9e9e9e",
    "unnamed_lift": "#9e9e9e",
    "lift_reversed": "#f9a825",
    "line_join": "#00acc1",
    "run_drawn": "#43a047",
}
DIFFICULTY_COLORS = {
    "green": "#2e7d32", "blue": "#1565c0", "black": "#212121",
    "double_black": "#000000", "park": "#ef6c00", "unknown": "#757575",
}
FLAG_HELP = {
    "lift_exit_dead_end": "Nothing is mapped leaving this lift's top station, and nothing that connects is within the automatic link limit. Map the missing run in OSM, or add a `links` entry. Counts against `lift_tops_reaching_base` and blocks `live`.",
    "lift_cut_off": "This lift is not part of the connected network: either nothing leads to it, or its runs never lead back. Counts against `lift_tops_reaching_base`.",
    "auto_link": "A gap the map leaves at a lift, joined automatically within `link_tolerance_m` and 30 m of height: a lift station no run touches, a run drawn from near a lift's top or down to near its bottom without a shared node, or a lift cut off from the network. Built as a short connection.",
    "run_uphill": "The elevation model says this piece climbs. Check the way direction in OSM, or `exclude_ways` it.",
    "orphan_edge": "This piece is not connected to any lift. Fix the shared node in OSM or `exclude_ways` it.",
    "run_dead_end": "Nothing leaves the end of this run: no further run, no lift. Usually a lift base or the next run starts a few metres away without a shared node.",
    "run_reversed": "Mapped uphill; the build turned it around. No action unless the direction looks wrong on the preview.",
    "unnamed_run": "Kept with its mapped difficulty, or unknown when the way has none. Name it in OSM if it is a real run.",
    "unnamed_lift": "Kept; it can never get a status alias, so it counts against status alias coverage, which `live` needs at 80 %.",
    "way_skipped": "Left out of the graph for the reason given (`other_ski_area` means OpenSkiMap puts it in a neighbouring resort; `not_operating` that it is planned, being built or closed for good).",
    "rendezvous_dropped": "A proposed meeting point that is not in the connected network (and not a lift bottom skiers can ski to from it), so two skiers could not both reach it. Removed.",
    "snap": "A gap closed under `snap_tolerance_m`, built as a short connection.",
    "separate_area": "A ski area of its own beside the main network: strongly connected, at least one lift and run, more than 250 m from the main network, with a base in the lowest 15 % of the lift range (or named under `areas` in the decisions file). Its lifts count as connected and its meeting points are kept, but nobody can ski between it and the main network.",
    "line_join": "A run end drawn a few metres short of another run's line, or a run start just below one, joined to the nearest point on that line within `line_join_m` (a T-junction): only into a line that leads on to a lift, or from one skiers reach from a lift, never more than 5 m uphill or across a lift's cable. The line is split there, at a new `v…` vertex when no vertex of it is within 3 m. Built as a short one-way connection.",
    "orphan_link":"A run that touched nothing with a lift, tied to the network at both ends within 50 m and 30 m of height. Built as two short connections.",
    "link": "A gap closed by a `links` entry in the decisions file, built as a short connection.",
    "link_proposed": "A lift cut off from the network by a gap wider than `link_tolerance_m`. Left unjoined; the entry to join it by hand is given.",
    "lift_reversed": "A chair or surface lift mapped running downhill; the build turned it around. Fix the way direction in OSM.",
    "self_loop": "A piece that returns to its own start was left out.",
    "run_drawn": "A run on the resort's list and trail map with no mapped line, drawn by an `add_runs` entry along the terrain's fall line between the two nodes it names. Its edges and group are marked `approximate` in the bundle. Check the line on the preview against the trail map.",
}
LISTED_IN_FULL = 60


def markdown(document: dict, bundle_id: str, size_bytes: int, manifest: dict,
             evaluation: dict, constraint_errors: list[str], decisions: dict) -> str:
    edges = document["edges"]
    kinds = defaultdict(int)
    for edge in edges:
        kinds[edge["kind"]] += 1
    review = manifest["review"]
    blocking = [f for f in review["flagged"] if f["blocking"]]
    informational = [f for f in review["flagged"] if not f["blocking"]]
    lines = [
        f"# {document['name']}: bundle report",
        "",
        f"- Bundle: `{bundle_id}` ({size_bytes:,} bytes stored)",
        f"- Extract: `{document['source']['extract_id']}`; manifest v{document['source']['manifest_version']}; "
        f"pipeline {document['pipeline_version']}; built {document['built_at']}",
        f"- Result: **{'publishable' if evaluation['publishable'] and not constraint_errors else 'not publishable'}**, "
        f"status mode `{document['status_mode']}`",
        "- Decisions file: " + (
            f"yes, {decisions['review_minutes']} review minutes recorded" if decisions.get("present")
            else "none; built unattended from the sources"),
        "",
        "## Integrity",
        "",
        "| Metric | Value | Threshold | Needed for | Result |",
        "|---|---|---|---|---|",
    ]
    for row in evaluation["rows"]:
        lines.append(
            f"| `{row['metric']}` | {row['value']} | {row['comparison']} {row['threshold']} | "
            f"{'publishing' if row['required'] else 'live status'} | {'pass' if row['passed'] else 'FAIL'} |"
        )
    lines += [
        "",
        "Client constraints (`BundleIntegrity.validate`): "
        + ("all pass." if not constraint_errors else f"{len(constraint_errors)} FAIL."),
    ]
    lines += [f"- {error}" for error in constraint_errors[:LISTED_IN_FULL]]
    lines += [
        "",
        "## Contents",
        "",
        f"- {len(document['nodes'])} nodes; {len(edges)} edges "
        f"({kinds['run']} run, {kinds['lift']} lift, {kinds['connection']} connection)",
        f"- {sum(1 for g in document['groups'] if g['kind'] == 'trail')} trail groups, "
        f"{sum(1 for g in document['groups'] if g['kind'] == 'lift')} lift groups",
        f"- {len(document['rendezvous'])} rendezvous: " + ", ".join(
            f"{count} {kind}" for kind, count in sorted(_count(document["rendezvous"], "kind").items())),
        "",
        "## Reconciliation",
        "",
        "- Sources: " + ", ".join(f"{name} {count}" for name, count in review["sources"].items())
        + (f". Official list unavailable: {review['official_error']}" if review.get("official_error") else "")
        + (f". {review['official_matched_ignoring_punctuation']} official names matched ignoring punctuation"
           if review.get("official_matched_ignoring_punctuation") else "")
        + (f". {review['official_lifts_matched_by_name_key']} official lift names matched to a mapped lift "
           "of another name (listed under Other notes)"
           if review.get("official_lifts_matched_by_name_key") else ""),
        f"- {review['identities']} identities: {review['auto_accepted']} confirmed by two sources and one "
        f"piece, {review['accepted_by_decision']} accepted by decision, {review['needs_review']} not fully "
        f"supported, {review['rejected']} rejected",
        f"- {review['unnamed_runs']} unnamed run ways and {review['unnamed_lifts']} unnamed lift ways kept",
        "",
        f"### Identities the sources do not fully support ({len(blocking)})",
        "",
        "These are built as described; none of them holds up publishing.",
        "",
    ]
    lines += _review_table(blocking) if blocking else ["None."]
    lines += ["", f"### Other notes ({len(informational)})", ""]
    lines += _review_table(informational) if informational else ["None."]

    lines += ["", "## Graph flags", ""]
    by_code = defaultdict(list)
    for flag in document["integrity"]["flags"]:
        by_code[flag["code"]].append(flag)
    if not by_code:
        lines.append("None.")
    for code in sorted(by_code):
        items = by_code[code]
        lines += [f"### `{code}` ({len(items)})", "", FLAG_HELP.get(code, ""), ""]
        for flag in items[:LISTED_IN_FULL]:
            where = f"`{flag['edge_id']}` " if flag.get("edge_id") else ""
            lines.append(f"- {where}{flag['lat']:.5f}, {flag['lon']:.5f}: {flag['note']}")
        if len(items) > LISTED_IN_FULL:
            lines.append(f"- and {len(items) - LISTED_IN_FULL} more, all in the GeoJSON preview")
        lines.append("")

    fixes = _fixes(evaluation, constraint_errors)
    lines += ["## What would change the result", ""]
    lines += [f"- {fix}" for fix in fixes] if fixes else ["Nothing: every threshold passes."]
    return "\n".join(lines).rstrip() + "\n"


def geojson(document: dict) -> str:
    flag_of: dict[str, str] = {}
    features = []
    for flag in document["integrity"]["flags"]:
        if flag.get("edge_id"):
            flag_of.setdefault(flag["edge_id"], flag["code"])
        features.append({
            "type": "Feature",
            "geometry": {"type": "Point", "coordinates": [flag["lon"], flag["lat"]]},
            "properties": {
                "layer": "flag", "code": flag["code"], "edge_id": flag.get("edge_id"),
                "note": flag["note"], "marker-color": FLAG_COLORS.get(flag["code"], "#d81b60"),
            },
        })
    for edge in document["edges"]:
        code = flag_of.get(edge["id"])
        if code:
            color = FLAG_COLORS.get(code, "#d81b60")
        elif edge["kind"] == "lift":
            color = "#c62828"
        elif edge["kind"] == "connection":
            color = "#6d4c41"
        else:
            color = DIFFICULTY_COLORS.get(edge.get("difficulty", "unknown"), "#757575")
        features.append({
            "type": "Feature",
            "geometry": {
                "type": "LineString",
                "coordinates": [[round(p[0], 6), round(p[1], 6)] for p in edge["geometry"]],
            },
            "properties": {
                "layer": "edge", "id": edge["id"], "kind": edge["kind"], "name": edge.get("name"),
                "group": edge.get("group"), "difficulty": edge.get("difficulty"),
                "vertical_m": edge["vertical_m"], "flag": code, "stroke": color,
                "stroke-width": 3 if code else 2,
            },
        })
    nodes = {n["id"]: n for n in document["nodes"]}
    for rendezvous in document["rendezvous"]:
        node = nodes[rendezvous["node_id"]]
        features.append({
            "type": "Feature",
            "geometry": {"type": "Point", "coordinates": [node["lon"], node["lat"]]},
            "properties": {
                "layer": "rendezvous", "id": rendezvous["id"], "name": rendezvous["name"],
                "kind": rendezvous["kind"], "confidence": rendezvous["confidence"],
                "marker-color": "#00897b",
            },
        })
    return json.dumps({"type": "FeatureCollection", "features": features},
                      separators=(",", ":"), ensure_ascii=False)


def _review_table(flags: list[dict]) -> list[str]:
    rows = ["| Code | Identity | Detail | What the build does |", "|---|---|---|---|"]
    for flag in flags:
        identity = f"`{flag['group_id']}`" if flag["group_id"] else f"{flag['kind']} \"{flag['name']}\""
        rows.append(f"| `{flag['code']}` | {identity} | {_cell(flag['detail'])} | {_cell(flag['proposed'])} |")
    return rows


def _fixes(evaluation: dict, constraint_errors: list[str]) -> list[str]:
    needed = {row["metric"]: row["threshold"] for row in evaluation["rows"]}
    advice = {
        "lift_tops_reaching_base": f"At least {needed['lift_tops_reaching_base'] * 100:g} % of lift tops must be part of the connected network. Close the gaps listed under `lift_exit_dead_end`, `lift_cut_off` and `link_proposed` (in OSM, or with `links`), or `reject` lifts that are not part of the skiing.",
        "rendezvous_reachable_from_all_lift_tops": "No meeting point is left in the connected network; connect the lifts first.",
        "orphan_edge_share": "Exclude or connect the pieces listed under `orphan_edge`.",
        "unnamed_run_share": "Name the unnamed runs in OSM, or exclude the ones that are not real runs.",
        "lift_exit_dead_end": "Resolve every `lift_exit_dead_end`; until then the resort publishes as `scheduled_only`.",
        "run_uphill": "Check each `run_uphill` piece; it is built as a connection until the elevation or the way direction is fixed.",
        "status_alias_coverage": "Map at least 80 % of lift groups to their provider names (official list or `status_aliases` in the decisions file); until then the resort publishes as `scheduled_only`.",
    }
    fixes = [advice[row["metric"]] for row in evaluation["rows"] if not row["passed"]]
    if constraint_errors:
        fixes.insert(0, "Fix the client constraint failures above; the app would refuse this bundle.")
    return fixes


def _count(items: list[dict], key: str) -> dict:
    counts: dict = defaultdict(int)
    for item in items:
        counts[item[key]] += 1
    return counts


def _cell(text: str) -> str:
    return str(text).replace("|", "\\|").replace("\n", " ")
