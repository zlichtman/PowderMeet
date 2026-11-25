"""validate: the integrity block, the publication thresholds and the constraints
the client enforces (`BundleIntegrity.validate`, specs/02-DOMAIN.md section 2).

Everything here reads a plain bundle document, so `build` runs it before the bytes
exist and `pm-pipeline validate` runs it again on the stored bundle.
"""

from __future__ import annotations

import math
from collections import defaultdict, deque

from .geo import haversine_m, length_m

# Metric -> (comparison, threshold). The first three decide whether a resort can
# publish at all; the rest only decide whether it can publish as `live`.
MIN_LIVE_ALIAS_COVERAGE = 0.80

LIVE_CHECKS = ("status_alias_coverage", "lift_exit_dead_end")

THRESHOLDS = (
    ("lift_tops_reaching_base", ">=", 0.90, True),
    ("rendezvous_reachable_from_all_lift_tops", "==", 1.0, True),
    ("orphan_edge_share", "<=", 0.10, True),
    ("unnamed_run_share", "<=", 0.10, False),
    ("lift_exit_dead_end", "==", 0, False),
    ("run_uphill", "==", 0, False),
    # The status worker writes a row once its feed maps this share of lift
    # groups (MIN_LIFT_COVERAGE in status.ts); the app checks the same.
    ("status_alias_coverage", ">=", MIN_LIVE_ALIAS_COVERAGE, False),
)


class Graph:
    def __init__(self, document: dict):
        self.nodes = {n["id"]: n for n in document["nodes"]}
        self.edges = document["edges"]
        self.downhill: dict[str, list[str]] = defaultdict(list)  # runs and connections
        self.full: dict[str, list[str]] = defaultdict(list)
        self.full_reverse: dict[str, list[str]] = defaultdict(list)
        self.downhill_reverse: dict[str, list[str]] = defaultdict(list)
        self.lift_tops: dict[str, list[dict]] = defaultdict(list)  # node -> lift edges arriving
        self.lift_out: dict[str, list[dict]] = defaultdict(list)
        for edge in self.edges:
            pairs = [(edge["from"], edge["to"])]
            if not edge.get("one_way", True):
                pairs.append((edge["to"], edge["from"]))
            for start, end in pairs:
                self.full[start].append(end)
                self.full_reverse[end].append(start)
                if edge["kind"] == "lift":
                    self.lift_out[start].append(edge)
                else:
                    self.downhill[start].append(end)
                    self.downhill_reverse[end].append(start)
        # Lift edges run bottom to top. A lift top is where a lift group ends: not
        # the lower terminal of a two-way lift, and not a mid-station the same
        # lift carries on from.
        lifts = [edge for edge in self.edges if edge["kind"] == "lift"]
        carries_on = {(edge.get("group"), edge["from"]) for edge in lifts}
        for edge in lifts:
            if (edge.get("group"), edge["to"]) not in carries_on:
                self.lift_tops[edge["to"]].append(edge)
        self.bases = {n["id"] for n in document["nodes"] if n["kind"] == "base"}
        self.lift_bottoms = sorted({edge["from"] for edge in lifts})

    def core(self) -> set[str]:
        """The largest set of nodes that can all reach each other, found from the
        lift bottoms (a part of the mountain with no lift is never the network)."""
        best: set[str] = set()
        seen: set[str] = set()
        for anchor in self.lift_bottoms:
            if anchor in seen:
                continue
            component = reach(self.full, [anchor]) & reach(self.full_reverse, [anchor])
            seen |= component
            if len(component) > len(best):
                best = component
        return best


BASE_BAND = 0.15
"""A lift bottom is a base when it sits in the lowest 15 % of the lift network's
elevation range."""
AREA_SEPARATION_M = 250.0
"""A part of the map nearer the main network than this is a gap to join, never a
separate ski area (the longest join the build or a decisions file makes)."""


def separate_areas(parts, core, coord, height, bottoms, stations, has_lift, has_run, anchors=()):
    """The parts of the map, besides the main network, that are ski areas of their
    own: each a strongly connected part with at least one lift and one run inside,
    farther than AREA_SEPARATION_M from the main network, and with its own base (a
    lift bottom in the lowest BASE_BAND of the whole lift network's elevation
    range: Ahorn at Mayrhofen, Dollar Mountain at Sun Valley, Kitzbühel's Horn).
    A part holding one of `anchors` (a decisions file's `areas`) needs no base in
    the band: Silver Creek sits halfway up Snowshoe's upside-down mountain.

    `parts` are node sets; `coord` and `height` look a node up; `has_lift` and
    `has_run` say whether a part holds a whole lift and a whole run."""
    if not bottoms or not core:
        return []
    lowest = min(height(n) for n in bottoms)
    highest = max(height(n) for n in stations)
    ceiling = lowest + BASE_BAND * (highest - lowest)
    cell = AREA_SEPARATION_M / 111_000.0
    # One longitude scale for the whole grid, taken where a degree is narrowest:
    # with each node's own latitude, two nodes 250 m apart north to south can key
    # cells apart and the 3 x 3 lookup misses them.
    widest = max(abs(coord(n)[1]) for part in [core, *parts] for n in part)
    scale = max(math.cos(math.radians(min(widest, 85.0))), 0.01)
    grid: dict[tuple[int, int], list] = defaultdict(list)
    for node in core:
        lon, lat = coord(node)
        grid[(math.floor(lon / cell * scale), math.floor(lat / cell))].append(node)

    def near_core(node) -> bool:
        lon, lat = coord(node)
        cx, cy = math.floor(lon / cell * scale), math.floor(lat / cell)
        return any(
            haversine_m((lon, lat), coord(other)) <= AREA_SEPARATION_M
            for x in (cx - 1, cx, cx + 1) for y in (cy - 1, cy, cy + 1) for other in grid.get((x, y), ())
        )

    anchors = set(anchors)
    found = []
    for part in parts:
        if part is core or part & core or not has_lift(part) or not has_run(part):
            continue
        if not part & anchors:
            own = [height(n) for n in part if n in bottoms]
            if not own or min(own) > ceiling:
                continue
        if any(near_core(n) for n in part):
            continue
        found.append(part)
    return found


def strong_parts(full, full_reverse, starts) -> list[set]:
    """The strongly connected parts that hold each of `starts`, largest first."""
    parts, seen = [], set()
    for start in sorted(starts):
        if start in seen:
            continue
        part = reach(full, [start]) & reach(full_reverse, [start])
        seen |= part
        parts.append(part)
    return sorted(parts, key=lambda p: (-len(p), min(p)))


def reach(adjacency: dict[str, list[str]], starts) -> set[str]:
    seen = set(starts)
    queue = deque(seen)
    while queue:
        for neighbor in adjacency.get(queue.popleft(), ()):
            if neighbor not in seen:
                seen.add(neighbor)
                queue.append(neighbor)
    return seen


def measure(document: dict, anchors=()) -> dict:
    """Metrics and the structural flags they produce.

    Everything is judged against the connected network: the largest part of the
    graph in which every node can reach every other by runs, connections and
    lifts, together with any separate ski area with its own base
    (`separate_areas`). A lift with an end outside them is one nobody can ski to,
    or one whose runs never lead back. A rendezvous outside them cannot be a
    meeting point; `build` drops it. The one exception is a lift bottom that
    skiers can ski to from them: both can reach it even if the lift is cut off.
    """
    graph = Graph(document)
    core = graph.core()
    # One entry per lift, at the edge that reaches its top.
    lifts = sorted(
        (edge for arriving in graph.lift_tops.values() for edge in arriving), key=lambda e: e["id"]
    )
    lift_edges = [e for e in graph.edges if e["kind"] == "lift"]
    run_edges = [e for e in graph.edges if e["kind"] == "run"]
    bottoms = {e["from"] for e in lift_edges}
    areas = separate_areas(
        strong_parts(graph.full, graph.full_reverse, bottoms - core), core,
        lambda n: (graph.nodes[n]["lon"], graph.nodes[n]["lat"]), lambda n: graph.nodes[n]["ele_m"],
        bottoms, bottoms | {e["to"] for e in lift_edges},
        lambda part: any(e["from"] in part and e["to"] in part for e in lift_edges),
        lambda part: any(e["from"] in part and e["to"] in part for e in run_edges),
        anchors,
    )
    networks = [core] + areas
    counted = set().union(*networks)

    def inside(edge) -> bool:
        return any(edge["from"] in part and edge["to"] in part for part in networks)

    connected = [edge for edge in lifts if inside(edge)]

    flags: list[dict] = []
    for part in areas:
        low = min((n for n in part if n in bottoms), key=lambda n: (graph.nodes[n]["ele_m"], n))
        names = sorted({e.get("name") or "unnamed lift" for e in lifts if e["from"] in part and e["to"] in part})
        node = graph.nodes[low]
        flags.append({
            "code": "separate_area", "lon": node["lon"], "lat": node["lat"],
            "note": f"{len(names)} lift(s) with their own base, apart from the main network: {', '.join(names)}",
        })
    for edge in lifts:
        if inside(edge):
            continue
        top = edge["to"]
        name = edge.get("name") or "unnamed lift"
        node = graph.nodes[top]
        onward_lift = any(other["id"] != edge["id"] for other in graph.lift_out.get(top, ()))
        if top in counted or reach(graph.full, [top]) & counted:
            code, note = "lift_cut_off", f"nothing in the rest of the network leads to {name}"
            node = graph.nodes[edge["from"]]
        elif not graph.downhill.get(top) and not onward_lift:
            # Nothing leaves the top but the lift that arrived there.
            code, note = "lift_exit_dead_end", f"{name} unloads at {top} with no run or connection leaving"
        else:
            code, note = "lift_cut_off", f"the runs from the top of {name} never lead back to the rest of the network"
        flags.append({
            "code": code, "edge_id": edge["id"], "lon": node["lon"], "lat": node["lat"], "note": note,
        })

    for edge in graph.edges:
        end = edge["to"]
        if edge["kind"] == "run" and not graph.full.get(end) and end not in graph.bases:
            node = graph.nodes[end]
            flags.append({
                "code": "run_dead_end", "edge_id": edge["id"], "lon": node["lon"], "lat": node["lat"],
                "note": f"{edge.get('name') or 'unnamed run'} ends at {end} with nothing leaving",
            })

    # A lift bottom that skiers can ski to from the network is somewhere they can
    # both reach, even when the lift itself is cut off because no run is mapped
    # from its top (Bärenbadkogel I at Kitzbühel). Any other stop outside the
    # network is dropped.
    downhill_of = reach(graph.full, counted)
    unreachable = sorted(
        r["id"] for r in document["rendezvous"]
        if r["node_id"] not in counted and not (r.get("kind") == "lift_base" and r["node_id"] in downhill_of)
    )

    parent = {node: node for node in graph.nodes}

    def find(node: str) -> str:
        while parent[node] != node:
            parent[node] = parent[parent[node]]
            node = parent[node]
        return node

    for edge in graph.edges:
        parent[find(edge["from"])] = find(edge["to"])
    with_lift = {find(edge["from"]) for edge in graph.edges if edge["kind"] == "lift"}
    orphans = [edge for edge in graph.edges if find(edge["from"]) not in with_lift]

    runs = [edge for edge in graph.edges if edge["kind"] == "run"]
    unnamed = [edge for edge in runs if not edge.get("name")]
    return {
        "lift_tops_reaching_base": _ratio(len(connected), len(lifts)),
        "rendezvous_reachable_from_all_lift_tops": _ratio(
            len(document["rendezvous"]) - len(unreachable), len(document["rendezvous"])
        ),
        "orphan_edge_share": _ratio(len(orphans), len(graph.edges), empty=1.0),
        "unnamed_run_share": _ratio(len(unnamed), len(runs), empty=0.0),
        "flags": flags,
        "unreachable_rendezvous": unreachable,
        "orphan_edge_ids": [edge["id"] for edge in orphans],
        "lift_count": len(lifts),
        "connected_lift_count": len(connected),
    }


MEASURED_METRICS = (
    "lift_tops_reaching_base", "rendezvous_reachable_from_all_lift_tops",
    "orphan_edge_share", "unnamed_run_share",
)


def recheck(document: dict, anchors=()) -> list[str]:
    """Where a stored bundle's integrity block or `status_mode` disagrees with
    measuring it again under the current rules, one line each. A bundle built by
    an older pipeline under looser rules is not trusted on its own word.
    `anchors` are the manifest's `areas`, as build used them."""
    measured = measure(document, anchors)
    errors = [
        f"integrity.{metric} is {document['integrity'][metric]} but measures {measured[metric]}"
        for metric in MEASURED_METRICS if measured[metric] != document["integrity"][metric]
    ]
    status_mode = evaluate(document)["status_mode"]
    if status_mode != document["status_mode"]:
        errors.append(f"status_mode is {document['status_mode']} but the thresholds give {status_mode}")
    return errors


def reasons(evaluation: dict, constraint_errors: list[str]) -> list[str]:
    """Why a bundle cannot publish, one short line each."""
    found = [
        f"{row['metric']} is {row['value']}, needs {row['comparison']} {row['threshold']}"
        for row in evaluation["rows"] if row["required"] and not row["passed"]
    ]
    if constraint_errors:
        found.append(f"{len(constraint_errors)} client constraint failures, first: {constraint_errors[0]}")
    return found


def evaluate(document: dict) -> dict:
    """Compare the stored integrity block with the thresholds."""
    integrity = document["integrity"]
    codes = defaultdict(int)
    for flag in integrity["flags"]:
        codes[flag["code"]] += 1
    lift_groups = [g["id"] for g in document["groups"] if g["kind"] == "lift"]
    mapped = {
        group for names in document["status_aliases"].values() for group in names.values()
    }
    values = {
        "lift_tops_reaching_base": integrity["lift_tops_reaching_base"],
        "rendezvous_reachable_from_all_lift_tops": integrity["rendezvous_reachable_from_all_lift_tops"],
        "orphan_edge_share": integrity["orphan_edge_share"],
        "unnamed_run_share": integrity["unnamed_run_share"],
        "lift_exit_dead_end": codes["lift_exit_dead_end"],
        "run_uphill": codes["run_uphill"],
        "status_alias_coverage": _ratio(sum(1 for g in lift_groups if g in mapped), len(lift_groups)),
    }
    rows = []
    for metric, comparison, threshold, required in THRESHOLDS:
        value = values[metric]
        passed = {
            ">=": value >= threshold, "<=": value <= threshold, "==": value == threshold,
        }[comparison]
        rows.append({
            "metric": metric, "value": value, "comparison": comparison,
            "threshold": threshold, "required": required, "passed": passed,
        })
    publishable = all(row["passed"] for row in rows if row["required"])
    # Live status needs the feed to name enough lifts and every lift exit to
    # lead somewhere; unnamed and climbing run pieces are map warnings that say
    # nothing about whether a lift is open.
    live = publishable and bool(lift_groups) and all(
        row["passed"] for row in rows if row["metric"] in LIVE_CHECKS
    )
    return {
        "rows": rows,
        "publishable": publishable,
        "status_mode": "live" if live else "scheduled_only",
        "flag_counts": dict(sorted(codes.items())),
    }


def check_constraints(document: dict) -> list[str]:
    """The checks the client runs before it will use a bundle. An empty list means
    the bundle will load."""
    errors: list[str] = []
    nodes = {n["id"]: n for n in document["nodes"]}
    if len(nodes) != len(document["nodes"]):
        errors.append("duplicate node ids")
    min_lon, min_lat, max_lon, max_lat = document["bbox"]
    edges = {}
    for edge in document["edges"]:
        if edge["id"] in edges:
            errors.append(f"duplicate edge id {edge['id']}")
        edges[edge["id"]] = edge
        start, end = nodes.get(edge["from"]), nodes.get(edge["to"])
        if start is None or end is None:
            errors.append(f"{edge['id']}: endpoint node missing")
            continue
        geometry = edge["geometry"]
        if len(geometry) < 2:
            errors.append(f"{edge['id']}: geometry has fewer than two points")
            continue
        if any(not math.isfinite(v) for point in geometry for v in point):
            errors.append(f"{edge['id']}: non-finite coordinate")
            continue
        if haversine_m(geometry[0], (start["lon"], start["lat"])) > 1.0:
            errors.append(f"{edge['id']}: geometry does not start at {edge['from']}")
        if haversine_m(geometry[-1], (end["lon"], end["lat"])) > 1.0:
            errors.append(f"{edge['id']}: geometry does not end at {edge['to']}")
        if any(
            not (min_lon <= p[0] <= max_lon and min_lat <= p[1] <= max_lat) for p in geometry
        ):
            errors.append(f"{edge['id']}: coordinate outside bbox")
        measured = length_m(geometry)
        if edge["length_m"] <= 0:
            errors.append(f"{edge['id']}: length_m must be greater than 0")
        elif abs(edge["length_m"] - measured) > 0.05 * max(measured, 1.0):
            errors.append(f"{edge['id']}: length_m {edge['length_m']} vs geometry {measured:.1f}")
        if edge["kind"] == "run" and not edge.get("one_way", True):
            errors.append(f"{edge['id']}: a run cannot be two-way")
        lift = edge.get("lift")
        if lift:
            if lift["ride_s"] <= 0:
                errors.append(f"{edge['id']}: lift.ride_s must be greater than 0")
            if (lift["queue_entry"] == "both") != (not edge.get("one_way", True)):
                errors.append(f"{edge['id']}: queue_entry is both exactly when the lift is two-way")
            for hours in lift["operating_hours"]:
                if not hours["days"] or any(d not in range(1, 8) for d in hours["days"]) \
                        or hours["open"] >= hours["close"]:
                    errors.append(f"{edge['id']}: invalid operating_hours {hours}")
        if edge["kind"] == "lift" and "lift" not in edge:
            errors.append(f"{edge['id']}: lift edge without lift block")
        if edge["kind"] != "lift" and "lift" in edge:
            errors.append(f"{edge['id']}: lift block on a {edge['kind']} edge")
        if edge["kind"] == "run" and edge["vertical_m"] > 0:
            errors.append(f"{edge['id']}: run climbs {edge['vertical_m']} m")
        if edge["kind"] in ("run", "lift") and not edge.get("group"):
            errors.append(f"{edge['id']}: {edge['kind']} edge without a group")

    group_ids = set()
    for group in document["groups"]:
        if group["id"] in group_ids:
            errors.append(f"duplicate group id {group['id']}")
        group_ids.add(group["id"])
        for edge_id in group["edge_ids"]:
            if edge_id not in edges:
                errors.append(f"{group['id']}: edge {edge_id} missing")
            elif edges[edge_id].get("group") != group["id"]:
                errors.append(f"{group['id']}: edge {edge_id} belongs to {edges[edge_id].get('group')}")
    for edge in document["edges"]:
        if edge.get("group") and edge["group"] not in group_ids:
            errors.append(f"{edge['id']}: group {edge['group']} missing")

    touched = {e["from"] for e in document["edges"]} | {e["to"] for e in document["edges"]}
    center = document["center"]
    if not (min_lon <= center[0] <= max_lon and min_lat <= center[1] <= max_lat):
        errors.append("center is outside bbox")
    seen = set()
    for rendezvous in document["rendezvous"]:
        if rendezvous["id"] in seen:
            errors.append(f"duplicate rendezvous id {rendezvous['id']}")
        seen.add(rendezvous["id"])
        if rendezvous["node_id"] not in nodes or rendezvous["node_id"] not in touched:
            errors.append(f"rendezvous {rendezvous['id']}: node {rendezvous['node_id']} missing or untouched")

    if document["status_mode"] == "live":
        mapped = {g for names in document["status_aliases"].values() for g in names.values()}
        lifts = [group["id"] for group in document["groups"] if group["kind"] == "lift"]
        covered = sum(1 for group in lifts if group in mapped)
        if not lifts or covered < MIN_LIVE_ALIAS_COVERAGE * len(lifts):
            errors.append(f"live bundle maps {covered} of {len(lifts)} lift groups to status names")
    for metric in (
        "lift_tops_reaching_base", "rendezvous_reachable_from_all_lift_tops",
        "orphan_edge_share", "unnamed_run_share", "flags",
    ):
        if metric not in document.get("integrity", {}):
            errors.append(f"integrity.{metric} missing")
    return errors


def _ratio(numerator: int, denominator: int, empty: float = 0.0) -> float:
    return round(numerator / denominator, 4) if denominator else empty
