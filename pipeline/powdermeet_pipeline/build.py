"""build: a frozen extract plus a manifest become one resort bundle.

The graph comes from source topology: ways are cut where they share an OSM node,
and nothing is joined merely because two coordinates are close (invariant I-16).
The only other joins are the ones `specs/05-PIPELINE.md` lists under Gaps (`snap`,
`auto_link`, `line_join`, `orphan_link`, and `link` from a decisions file), each
within its tolerance and each recorded as a flag.
The output is a pure function of the two input files and the pipeline version.
"""

from __future__ import annotations

import math
from dataclasses import dataclass

from . import __version__, canonical, drawn, topology, validate
from .catalog import PipelineError
from .geo import bearing_deg, haversine_m, length_m
from .reconcile import DIFFICULTY_ORDER
from .reconcile.common import is_mogul_run, normalize_grooming
from .reconcile.decisions import apply_way_names
from .reconcile.items import duration_seconds

RISE_TOLERANCE_M = 5.0
"""DEM noise allowance. A run way that climbs more than this end to end is drawn
uphill and gets reversed; a run edge that still climbs more than this is flagged
`run_uphill` and built as a connection."""

LIFT_DESCENT_M = topology.LIFT_DESCENT_M

GRADE_WINDOW_M = 30.0
BASE_BAND = 0.15
"""A lift bottom is a base when it sits in the lowest 15 % of the lift network's
elevation range."""

# Typical line speeds in m/s, used when a lift has no `aerialway:duration`.
LIFT_SPEED_MS = {
    "chair": 2.5, "gondola": 5.0, "cable_car": 8.0, "tbar": 3.0,
    "magic_carpet": 0.7, "rope_tow": 2.0,
}
DETACHABLE_CHAIR_SPEED_MS = 5.0
LIFT_CAPACITY_PPH = {
    "chair": 1800, "gondola": 2400, "cable_car": 1000, "tbar": 900,
    "magic_carpet": 800, "rope_tow": 500,
}


@dataclass
class Bundle:
    document: dict
    stored: bytes
    bundle_id: str


def build(resort: dict, extract: dict, manifest: dict) -> Bundle:
    document = assemble(resort, extract, manifest)
    stored, bundle_id = canonical.encode_bundle(canonical.typed(document))
    return Bundle(document, stored, bundle_id)


def assemble(resort: dict, extract: dict, manifest: dict) -> dict:
    added = manifest.get("add_runs") or []
    extract = drawn.extend(apply_way_names(extract, manifest.get("way_names") or {}), added)
    net = topology.network(extract, frozenset(manifest["exclude_ways"]))
    raw_ele = {int(node): float(ele) for node, ele in extract["elevation"]["samples"].items()}
    flags: list[dict] = []

    identity_of = _claims(net, manifest)
    for skipped in net.skipped:
        if skipped["reason"] != "excluded_by_decision":
            flags.append(_flag(
                "way_skipped", None, skipped["lon"], skipped["lat"],
                f"{skipped['kind']} way {skipped['way_id']} {skipped['name'] or '(unnamed)'} left out: {skipped['reason']}",
            ))

    # Travel order per way. Runs are drawn downhill by convention, not by rule.
    travel: dict[int, list[int]] = {}
    reversed_ways: set[int] = set()
    for way_id in sorted(net.ways):
        way = net.ways[way_id]
        missing = [n for n in way.nodes if n not in raw_ele]
        if missing:
            raise PipelineError(f"extract has no elevation for node {missing[0]} of way {way_id}")
        nodes = list(way.nodes)
        rise = raw_ele[nodes[-1]] - raw_ele[nodes[0]]
        if way.kind == "run" and rise > RISE_TOLERANCE_M:
            nodes.reverse()
            reversed_ways.add(way_id)
        elif way.kind == "lift" and rise < 0 and topology.two_way_lift(way):
            # A two-way lift has no travel direction; its edge runs bottom to top.
            nodes.reverse()
            reversed_ways.add(way_id)
        elif way.kind == "lift" and rise < -LIFT_DESCENT_M:
            # Chairs and surface lifts carry skiers up; one drawn running down is
            # mapped backwards (all ten chairs at Yongpyong).
            nodes.reverse()
            reversed_ways.add(way_id)
            lon, lat = net.coords[nodes[0]]
            flags.append(_flag(
                "lift_reversed", f"w{way_id}:0", lon, lat,
                f"{way.name or 'unnamed lift'} is mapped running {-rise:.0f} m downhill; built bottom to top",
            ))
        travel[way_id] = nodes

    # Vertices the build adds where a join splits a line: negative ids here,
    # `v<12 hex>` in the bundle.
    synthetic: dict[int, str] = {}
    # The inner points of a drawn run are vertices the pipeline adds: `v…` if a
    # join ever splits the run there, and their negative ids are taken.
    for node, lon, lat, height, drawn_way in drawn.inner_nodes(added):
        synthetic[node] = synthetic_node_name(lon, lat, height, drawn_way)
    for run in added:
        lon, lat, _ = run["geometry"][0]
        flags.append(_flag(
            "run_drawn", f"w{run['way_id']}:0", lon, lat,
            f"{run['name']} has no mapped line; drawn along the fall line from {run['from']} to "
            f"{run['to']} after {run['source']}, marked approximate",
        ))
    anchors = {int(str(n)[1:]) for n in manifest.get("areas") or ()}
    joins = _close_gaps(
        net, travel, raw_ele, float(manifest.get("snap_tolerance_m") or 0),
        float(manifest.get("link_tolerance_m") or 0), manifest.get("links") or [], flags,
        _join_setting(manifest, resort, "orphan_join_m"), anchors,
        _join_setting(manifest, resort, "line_join_m"), synthetic,
    )

    def label(node: int) -> str:
        return synthetic.get(node) or f"n{node}"

    # Cut ways into edges at vertices, numbering pieces along the source node order.
    # A lift is numbered bottom to top instead, so that consecutive pieces of one
    # ride are always k, k+1 in travel direction (the solver relies on that).
    source_order = {
        way_id: (nodes[::-1] if way_id in reversed_ways and net.ways[way_id].kind != "lift" else nodes)
        for way_id, nodes in travel.items()
    }
    verts = topology.vertices(net, source_order)
    verts.update(node for join in joins for node in join[1:3])
    # A join shorter than a metre is two OSM nodes at one place. A zero-length edge
    # is not a valid edge, so the dead end becomes the node it joins instead. Two
    # such joins from one node merge all three (Perisher: a snap and a join from
    # the end of Pretty Valley Run to two nodes mapped at the same point).
    alias: dict[int, int] = {}

    def resolve(node: int) -> int:
        while node in alias:
            node = alias[node]
        return node

    def merge(keep: int, drop: int) -> None:
        # A vertex the build added gives way to the OSM node, so OSM ids stay. A
        # decisions file's `areas` node keeps its id too, so `pm-pipeline
        # validate` finds the area from the manifest alone.
        if (keep in synthetic and drop not in synthetic) or (drop in anchors and keep not in anchors):
            keep, drop = drop, keep
        alias[drop] = keep

    for _, start, end, distance, _ in joins:
        if distance < MERGE_BELOW_M and resolve(start) != resolve(end):
            merge(resolve(end), resolve(start))

    # The same holds for consecutive nodes of one way mapped at one point.
    for way_id in sorted(net.ways):
        nodes = net.ways[way_id].nodes
        for a, b in zip(nodes, nodes[1:]):
            if haversine_m(net.coords[a], net.coords[b]) < 0.05 and resolve(a) != resolve(b):
                merge(resolve(a), resolve(b))
    stations = net.stations
    pieces: list[dict] = []
    for way_id in sorted(net.ways):
        way = net.ways[way_id]
        nodes = source_order[way_id]
        cuts = topology.split_points(way, nodes, verts, stations)
        for k in range(len(cuts) - 1):
            segment = nodes[cuts[k]:cuts[k + 1] + 1]
            if way_id in reversed_ways and way.kind != "lift":
                segment = segment[::-1]
            segment = [resolve(segment[0])] + segment[1:-1] + [resolve(segment[-1])]
            lon, lat = net.coords[segment[0]]
            if segment[0] == segment[-1]:
                if len(segment) > 2:
                    flags.append(_flag("self_loop", None, lon, lat, f"way {way_id} piece {k} returns to its start; left out"))
                continue
            pieces.append({
                "id": f"w{way_id}:{k}", "way": way, "nodes": segment, "kind": way.kind,
                "first": k == 0,
            })
        if way_id in reversed_ways and way.kind == "run":
            lon, lat = net.coords[travel[way_id][0]]
            flags.append(_flag(
                "run_reversed", f"w{way_id}:0", lon, lat,
                f"{way.name or 'unnamed run'} is mapped uphill; built in the downhill direction",
            ))

    # Each snap or link is one more piece on its host way: a short walk.
    ordinal = {
        way_id: len(topology.split_points(net.ways[way_id], source_order[way_id], verts, stations)) - 1
        for way_id in net.ways
    }
    for host, start, end, distance, flag in joins:
        if distance < MERGE_BELOW_M or resolve(start) == resolve(end):
            continue
        piece_id = f"w{host}:{ordinal[host]}"
        pieces.append({
            "id": piece_id, "way": net.ways[host],
            "nodes": [resolve(start), resolve(end)], "kind": "connection", "first": False, "join": True,
        })
        # The flag names the walk it built, so the report preview colours it.
        flag["edge_id"] = piece_id
        ordinal[host] += 1

    # A run piece that still climbs past the tolerance cannot be skied as a run.
    for piece in pieces:
        if piece["kind"] == "run":
            rise = raw_ele[piece["nodes"][-1]] - raw_ele[piece["nodes"][0]]
            if rise > RISE_TOLERANCE_M:
                piece["kind"] = "connection"
                piece["uphill"] = True
                lon, lat = net.coords[piece["nodes"][0]]
                flags.append(_flag(
                    "run_uphill", piece["id"], lon, lat,
                    f"{piece['way'].name or 'unnamed run'} climbs {rise:.1f} m here; built as a connection",
                ))

    ele = _monotone_elevations(raw_ele, [p for p in pieces if p["kind"] == "run"])

    default_hours = manifest.get("default_hours") or []
    edges: list[dict] = []
    group_edges: dict[str, list[str]] = {}
    unnamed_groups: dict[str, dict] = {}
    for piece in pieces:
        way = piece["way"]
        identity = identity_of.get(way.id)
        geometry = _geometry(net, piece, raw_ele, ele)
        horizontal = length_m(geometry)
        start, end = piece["nodes"][0], piece["nodes"][-1]
        vertical = round(ele[end], 1) - round(ele[start], 1)
        downhill = (geometry[0], geometry[-1]) if vertical <= 0 else (geometry[-1], geometry[0])
        edge = {
            "id": piece["id"],
            "from": label(start),
            "to": label(end),
            "kind": piece["kind"],
            "geometry": [[lon, lat, round(z, 1)] for lon, lat, z in geometry],
            "length_m": max(0.1, round(horizontal, 1)),
            "vertical_m": round(vertical, 1),
            "grade_max_deg": round(_grade_max(geometry), 1),
            "groomed_default": None,
            "aspect_deg": round(bearing_deg(*downhill), 1) % 360.0,
            "one_way": True,
        }
        if piece.get("join"):
            # A join extends the run (or named connection) it is built on, so
            # it carries that trail's name: a descent matched onto it reads as
            # the trail, not as an unnamed walk. A join on a lift stays unnamed.
            if way.kind != "lift":
                trail = (identity or {}).get("name") or way.name
                if trail:
                    edge["name"] = trail
            edges.append(edge)
            continue
        if way.kind == "connection":
            edge["one_way"] = way.tags.get("oneway") == "yes"
            tagged = _tagged_difficulty(way)
            if tagged:
                edge["difficulty"] = tagged
            if way.name:
                edge["name"] = way.name
        else:
            if identity:
                group_id = identity["group_id"]
                edge["name"] = identity["name"]
            else:
                kind = "trail" if way.kind == "run" else "lift"
                group_id = f"{kind}:unnamed-{way.id}"
                unnamed_groups[group_id] = {"kind": kind, "way": way}
                if piece["first"]:
                    untagged = way.kind == "run" and _tagged_difficulty(way) is None
                    flags.append(_flag(
                        f"unnamed_{way.kind}", piece["id"], geometry[0][0], geometry[0][1],
                        f"way {way.id} has no name; kept" + (" with difficulty unknown" if untagged else ""),
                    ))
            edge["group"] = group_id
            group_edges.setdefault(group_id, []).append(piece["id"])
        if way.kind == "run":
            edge["difficulty"] = _edge_difficulty(way, identity)
            edge["groomed_default"] = normalize_grooming(way.tags.get("piste:grooming"))
            if is_mogul_run(way.tags.get("piste:grooming")):
                edge["moguls"] = True
            if drawn.is_drawn(way):
                edge["approximate"] = True
        elif way.kind == "lift":
            two_way = topology.two_way_lift(way)
            edge["one_way"] = not two_way
            lift_type = topology.LIFT_TYPES[str(way.tags.get("aerialway")).lower()]
            edge["lift"] = {
                "type": lift_type,
                "ride_s": _ride_seconds(net, way, lift_type, horizontal),
                "capacity_pph": _capacity(way, lift_type),
                "operating_hours": (identity or {}).get("operating_hours") or default_hours,
                "queue_entry": "both" if two_way else "bottom",
            }
        edges.append(edge)

    edges.sort(key=lambda e: _edge_key(e["id"]))
    groups = _groups(manifest, group_edges, unnamed_groups)
    nodes = _nodes(net, edges, ele, raw_ele, manifest, synthetic)
    node_ids = {n["id"] for n in nodes}

    rendezvous = []
    for candidate in manifest["rendezvous"]:
        candidate = {**candidate, "node_id": label(resolve(int(candidate["node_id"][1:])))}
        if candidate["node_id"] not in node_ids:
            flags.append(_flag(
                "rendezvous_dropped", None, candidate["lon"], candidate["lat"],
                f"{candidate['id']}: anchor {candidate['node_id']} is not in the graph",
            ))
            continue
        rendezvous.append({
            "id": candidate["id"], "node_id": candidate["node_id"], "kind": candidate["kind"],
            "name": candidate["name"], "confidence": round(float(candidate["confidence"]), 2),
            "quality": round(float(candidate["quality"]), 2),
            "amenities": sorted(candidate["amenities"]),
        })
    rendezvous.sort(key=lambda r: r["id"])

    if not edges:
        raise PipelineError("no lifts or downhill runs found for this resort")
    bbox = _bounds(edges)
    center = [float(v) for v in resort["center"]]
    if not (bbox[0] <= center[0] <= bbox[2] and bbox[1] <= center[1] <= bbox[3]):
        center = [round((bbox[0] + bbox[2]) / 2, 5), round((bbox[1] + bbox[3]) / 2, 5)]
    document = {
        "schema_version": 1,
        "resort_id": resort["resort_id"],
        "name": resort["name"],
        "timezone": resort["timezone"],
        "bbox": bbox,
        "center": center,
        "status_mode": "scheduled_only",
        "status_aliases": _status_aliases(manifest, groups),
        "source": {
            "extract_id": extract["extract_id"],
            "osm_extract_at": extract["osm"]["fetched_at"],
            "openskimap_at": extract["openskimap"].get("published_at") or extract["openskimap"]["fetched_at"],
            "official": list(extract["official"]["urls"]) if extract["official"].get("fetched_at") else [],
            "manifest_version": manifest["manifest_version"],
        },
        # Derived from the inputs so that rebuilding them reproduces the bytes.
        "built_at": max(manifest["created_at"], extract["osm"]["fetched_at"]),
        "pipeline_version": __version__,
        "nodes": nodes,
        "edges": edges,
        "groups": groups,
        "rendezvous": rendezvous,
    }
    # The manifest's ids as written: the merges above keep them, and `pm-pipeline
    # validate` measures with the same list.
    _integrity(document, flags, manifest.get("areas") or ())
    return document


def _join_setting(manifest: dict, resort: dict, key: str) -> float:
    """`orphan_join_m` or `line_join_m`, frozen into the manifest by reconcile so a
    later catalog change cannot alter a rebuild. A manifest reconciled before they
    were frozen falls back to the catalog, as its build did."""
    value = manifest[key] if key in manifest else resort.get(key)
    return float(value or 0)


def _claims(net: topology.Network, manifest: dict) -> dict[int, dict]:
    """Way id -> manifest identity. The manifest must describe this extract."""
    identity_of: dict[int, dict] = {}
    for kind, entries in (("run", manifest["trails"]), ("lift", manifest["lifts"])):
        for identity in entries:
            for way_id in identity["way_ids"]:
                way = net.ways.get(way_id)
                if way is None or way.kind != kind or way_id in identity_of:
                    raise PipelineError(
                        f"manifest v{manifest['manifest_version']} does not match this extract "
                        f"(way {way_id} of {identity['group_id']}); run reconcile on the extract first"
                    )
                identity_of[way_id] = identity
    unclaimed = [w.id for w in net.ways.values() if w.name and w.kind != "connection" and w.id not in identity_of]
    if unclaimed:
        raise PipelineError(
            f"manifest v{manifest['manifest_version']} does not claim named way {unclaimed[0]}; "
            "run reconcile on the extract first"
        )
    return identity_of


MAX_LINK_M = 250.0
MAX_LINK_RISE_M = 30.0
MERGE_BELOW_M = 1.0
"""A join is a short walk: never further than this, never this much up or down."""
STUCK_AREA_LIMIT = 500


class _Index:
    """Network nodes on a grid whose cells are at least `radius_m` wide, so every
    node within the radius of a point is in the 3 x 3 cells around it."""

    def __init__(self, coords: dict, nodes, radius_m: float):
        self.coords = coords
        self.dlat = radius_m / 111_000.0
        widest = max((abs(coords[n][1]) for n in nodes), default=0.0)
        self.dlon = self.dlat / max(math.cos(math.radians(min(widest, 85.0))), 0.01)
        self.cells: dict[tuple[int, int], list[int]] = {}
        for node in sorted(nodes):
            self.cells.setdefault(self._cell(node), []).append(node)

    def _cell(self, node: int) -> tuple[int, int]:
        lon, lat = self.coords[node]
        return math.floor(lon / self.dlon), math.floor(lat / self.dlat)

    def around(self, node: int):
        cx, cy = self._cell(node)
        for x in (cx - 1, cx, cx + 1):
            for y in (cy - 1, cy, cy + 1):
                yield from self.cells.get((x, y), ())


def _close_gaps(net, travel, raw_ele, tolerance: float, link_tolerance: float,
                links: list[dict], flags: list[dict], orphan_join: float = 0.0,
                anchors: set[int] = frozenset(), line_join: float = 0.0,
                synthetic: dict[int, str] | None = None):
    """Join places the map leaves a few metres apart. Returns (host way, from, to)
    for each join; the caller builds each as a short connection piece.

    `links` from a decisions file are applied as written. Then these gaps are
    looked for: a run end that leads nowhere (joined within `tolerance`), a lift
    station no run touches, a run start or end near a lift station that touches
    no other way, a lift top whose runs never reach another lift, and a lift cut
    off from the rest of the network because nobody can ski to it or its runs
    never connect back (all joined within `link_tolerance`). A wider gap, up to MAX_LINK_M, only
    gets a `link_proposed` flag. Every join is flagged; with both tolerances 0 and
    no links nothing is joined. Only these named gaps are closed: two ways are
    never joined merely because they pass close to each other.
    """
    forward: dict[int, list[int]] = {}
    containing: dict[int, list[int]] = {}
    boarding: set[int] = set()
    lift_ends: list[tuple[int, int]] = []  # (way id, top node)
    lift_starts: list[tuple[int, int]] = []  # (boarding node, way id)
    # Where riders get off and on. A two-way lift carries people down as well,
    # so each of its stations is both; without that a gondola joining two
    # valleys never joins them (Palisades Tahoe's Base to Base Gondola).
    alight: list[tuple[int, int]] = []  # (way id, node)
    board: list[tuple[int, int]] = []  # (node, way id)
    lift_hops: list[tuple[int, int]] = []
    for way_id in sorted(travel):
        way, nodes = net.ways[way_id], travel[way_id]
        for node in nodes:
            containing.setdefault(node, []).append(way_id)
        if way.kind == "lift":
            middle = [n for n in nodes[1:-1] if n in net.stations]
            boarding.update([nodes[0]] + middle)
            lift_ends.append((way_id, nodes[-1]))
            stops = [nodes[0]] + middle + [nodes[-1]]
            lift_starts.extend((stop, way_id) for stop in stops[:-1])
            two_way = topology.two_way_lift(way)
            alight.extend((way_id, stop) for stop in (stops if two_way else stops[-1:]))
            board.extend((stop, way_id) for stop in (stops if two_way else stops[:-1]))
            for a, b in zip(stops, stops[1:]):
                lift_hops.append((a, b))
                if two_way:
                    lift_hops.append((b, a))
            continue
        two_way = way.kind == "connection" and way.tags.get("oneway") != "yes"
        for a, b in zip(nodes, nodes[1:]):
            forward.setdefault(a, []).append(b)
            if two_way:
                forward.setdefault(b, []).append(a)
    def good_nodes() -> set[int]:
        backward: dict[int, list[int]] = {}
        for a, targets in forward.items():
            for b in targets:
                backward.setdefault(b, []).append(a)
        return validate.reach(backward, boarding)

    cell = 0.0005
    grid: dict[tuple[int, int], list[int]] = {}
    for node in containing:
        lon, lat = net.coords[node]
        grid.setdefault((math.floor(lon / cell), math.floor(lat / cell)), []).append(node)

    def nearest(node: int, allowed, exclude, limit: float):
        lon, lat = net.coords[node]
        height = raw_ele[node]
        span = math.ceil(limit / 30.0)
        # A cell is narrower east to west the further from the equator; at
        # Alyeska's 61 degrees seven cells cover less than 200 m.
        span_x = max(span, math.ceil(limit / (cell * 111_000.0 * max(math.cos(math.radians(lat)), 0.01))))
        best, best_distance = None, limit
        cx, cy = math.floor(lon / cell), math.floor(lat / cell)
        for x in range(cx - span_x, cx + span_x + 1):
            for y in range(cy - span, cy + span + 1):
                for other in grid.get((x, y), ()):
                    if other == node or other not in allowed or other in exclude:
                        continue
                    if abs(raw_ele[other] - height) > MAX_LINK_RISE_M:
                        continue
                    distance = haversine_m((lon, lat), net.coords[other])
                    if distance < best_distance or (distance == best_distance and best is not None and other < best):
                        best, best_distance = other, distance
        return best, best_distance

    joins: list[tuple[int, int, int, float, dict]] = []
    if synthetic is None:
        synthetic = {}

    def label(node: int) -> str:
        return synthetic.get(node) or f"n{node}"

    def join(code: str, host: int, start: int, end: int, distance: float, why: str) -> None:
        lon, lat = net.coords[start]
        flag = _flag(
            code, None, lon, lat,
            f"{why}: {label(start)} joined to {label(end)}, {distance:.1f} m, on way {host} {net.ways[host].name or '(unnamed)'}",
        )
        flags.append(flag)
        joins.append((host, start, end, distance, flag))
        forward.setdefault(start, []).append(end)

    def host_of(node: int) -> int:
        ways = containing[node]
        ending = [w for w in ways if travel[w][-1] == node]
        return (ending or ways)[0]

    for link in links:
        start, end = int(str(link["from"])[1:]), int(str(link["to"])[1:])
        if start not in containing or end not in containing:
            raise PipelineError(f"link {link['from']} -> {link['to']} names a node that is not in the network")
        distance = haversine_m(net.coords[start], net.coords[end])
        if distance > MAX_LINK_M:
            raise PipelineError(f"link {link['from']} -> {link['to']} spans {distance:.0f} m; the limit is {MAX_LINK_M:.0f} m")
        join("link", host_of(start), start, end, distance, "link from the decisions file")

    # Stations the map never ties to a run: nothing leaves the top, or nothing
    # arrives at the bottom. Many resorts are mapped this way throughout.
    if link_tolerance > 0:
        departures = {node for node, targets in forward.items() if targets}
        for way_id, top in sorted(lift_ends):
            if forward.get(top):
                continue
            target, distance = nearest(top, departures, set(travel[way_id]), link_tolerance)
            if target is not None:
                join("auto_link", way_id, top, target, distance,
                     f"no run leaves the top of {net.ways[way_id].name or 'unnamed lift'}")
        for bottom, way_id in sorted(lift_starts):
            arrivals = {b for targets in forward.values() for b in targets}
            if bottom in arrivals:
                continue
            source, distance = nearest(bottom, set(forward) | arrivals, set(travel[way_id]), link_tolerance)
            if source is not None:
                join("auto_link", host_of(source), source, bottom, distance,
                     f"no run arrives at the bottom of {net.ways[way_id].name or 'unnamed lift'}")

    if tolerance > 0:
        good = good_nodes()
        for way_id in sorted(travel):
            way, end = net.ways[way_id], travel[way_id][-1]
            if way.kind != "run" or forward.get(end) or end in boarding:
                continue
            target, distance = nearest(end, good | boarding, set(travel[way_id]), tolerance)
            if target is not None:
                join("snap", way_id, end, target, distance, "run end with no continuation")

    # Run ends drawn a few metres short of another run's line (a T-junction the
    # map leaves open), or a run start just below a ridge or traverse: joined
    # to the nearest point on that line, which splits it there. A station the
    # next rule would join is preferred when it is nearer.
    if line_join > 0:
        _join_run_lines(net, travel, forward, containing, grid, cell, raw_ele, boarding, alight, board,
                        nearest, join, min(line_join, MAX_LINE_JOIN_M), link_tolerance, synthetic)

    # Runs drawn from near a lift's top, or down to near its bottom, without a
    # shared node: nothing reaches the run's start, or nothing leaves its end.
    # Each is tied to the nearest station, under the same limits as a lift
    # station is.
    if link_tolerance > 0:
        lift_nodes = {n for w in travel if net.ways[w].kind == "lift" for n in travel[w]}
        unload = {node: way_id for way_id, node in alight}
        load = {node: way_id for node, way_id in board}
        arrivals = {b for targets in forward.values() for b in targets}

        def lift_name(way_id: int) -> str:
            return net.ways[way_id].name or "unnamed lift"

        for way_id in sorted(travel):
            way, nodes = net.ways[way_id], travel[way_id]
            if way.kind != "run":
                continue
            start, end = nodes[0], nodes[-1]
            if start not in arrivals and start not in lift_nodes:
                source, distance = nearest(start, unload, set(nodes), link_tolerance)
                if source is not None:
                    join("auto_link", unload[source], source, start, distance,
                         f"nothing reaches the start of {way.name or 'unnamed run'} "
                         f"near {lift_name(unload[source])}")
                    arrivals.add(start)
            if not forward.get(end) and end not in lift_nodes:
                target, distance = nearest(end, load, set(nodes), link_tolerance)
                if target is not None:
                    join("auto_link", way_id, end, target, distance,
                         f"{way.name or 'unnamed run'} ends near {lift_name(load[target])} with nothing leaving")
                    arrivals.add(target)

    def settle(code_reason: str, host: int, start: int, end: int, distance: float) -> None:
        """Join a gap inside the link tolerance; otherwise only propose it, and carry
        on as if it were accepted so later proposals do not repeat it."""
        if 0 < link_tolerance and distance <= link_tolerance:
            join("auto_link", host, start, end, distance, code_reason)
        else:
            assumed.setdefault(start, []).append(end)
            lon, lat = net.coords[start]
            flags.append(_flag(
                "link_proposed", None, lon, lat,
                f"{code_reason}: the nearest way on is {distance:.1f} m away, beyond the automatic "
                f"limit; to join it anyway add `- {{from: {label(start)}, to: {label(end)}}}` under links",
            ))

    def graph(with_lifts: bool) -> dict[int, list[int]]:
        merged = {node: list(targets) for node, targets in forward.items()}
        for node, targets in assumed.items():
            merged.setdefault(node, []).extend(targets)
        if with_lifts:
            for a, b in lift_hops:
                merged.setdefault(a, []).append(b)
        return merged

    def inverse(adjacency: dict[int, list[int]]) -> dict[int, list[int]]:
        backward: dict[int, list[int]] = {}
        for a, targets in adjacency.items():
            for b in targets:
                backward.setdefault(b, []).append(a)
        return backward

    def name(way_id: int) -> str:
        return net.ways[way_id].name or "unnamed lift"

    assumed: dict[int, list[int]] = {}

    # Lift tops with no run-only way down to any lift.
    for way_id, top in sorted(lift_ends):
        downhill = graph(with_lifts=False)
        good = validate.reach(inverse(downhill), boarding)
        if top in good:
            continue
        stuck = validate.reach(downhill, [top])
        if len(stuck) > STUCK_AREA_LIMIT:
            continue
        pairs = [
            (distance, node, target)
            for node in sorted(stuck)
            for target, distance in (nearest(node, good, stuck, MAX_LINK_M),)
            if target is not None
        ]
        if pairs:
            distance, node, target = min(pairs)
            settle(f"no way down from the top of {name(way_id)}",
                   way_id if node == top else host_of(node), node, target, distance)

    # Parts of the lift network cut off from the rest: a lift nobody can ski to,
    # or a lift top whose runs lead nowhere that connects back.
    def core_of(adjacency, backward) -> set[int]:
        best: set[int] = set()
        seen: set[int] = set()
        for start in sorted(boarding):
            if start in seen:
                continue
            both = validate.reach(adjacency, [start]) & validate.reach(backward, [start])
            seen |= both
            if len(both) > len(best):
                best = both
        return best

    index = _Index(net.coords, containing, MAX_LINK_M)

    def closest(near: set[int], far: set[int], near_first: bool):
        """The shortest gap (distance, from, to) between a node of `near` (the
        small side, searched around) and a node of `far`, within MAX_LINK_M and
        MAX_LINK_RISE_M of height. `near_first` says which side the join leaves."""
        best = None
        for node in sorted(near):
            point, height = net.coords[node], raw_ele[node]
            for other in index.around(node):
                if other not in far or abs(raw_ele[other] - height) > MAX_LINK_RISE_M:
                    continue
                distance = haversine_m(point, net.coords[other])
                if distance > MAX_LINK_M:
                    continue
                candidate = (distance, node, other) if near_first else (distance, other, node)
                if best is None or candidate < best:
                    best = candidate
        return best

    # One join per round, the shortest gap first, then the network is measured
    # again: a join that ties a pod in can bring others within reach, so nothing
    # is given up until a round finds no gap at all. A gap past the tolerance is
    # proposed only once no shorter one is left, so a proposal never stands in
    # for a join the build could have made.
    def tie_in(pick, apart) -> None:
        """Join cut-off lifts to the network `pick` returns, round by round.
        `apart(adjacency, backward)` gives nodes whose lifts are left alone."""
        for _ in range(4 * len(alight) + 20):
            adjacency = graph(with_lifts=True)
            backward = inverse(adjacency)
            core = pick(adjacency, backward)
            if not core:
                return
            if not _tie_in_round(adjacency, backward, core, apart(adjacency, backward)):
                return

    def _tie_in_round(adjacency, backward, core, left_alone) -> bool:
        from_core = validate.reach(adjacency, core)
        to_core = validate.reach(backward, core)
        tried: dict[frozenset, tuple | None] = {}
        candidates = []
        # A lift whose riders cannot get back: join anywhere they can reach
        # from its top to anywhere that leads back.
        for way_id, top in sorted(alight):
            if top in to_core or top in left_alone:
                continue
            stuck = frozenset(validate.reach(adjacency, [top]))
            if stuck not in tried:
                tried[stuck] = closest(stuck, to_core, near_first=True)
            if tried[stuck]:
                where = "the top" if top == travel[way_id][-1] else "a station"
                candidates.append((tried[stuck], f"no way on from {where} of {name(way_id)}"))
        # A lift nobody can get to: join anywhere reachable to anything that
        # leads to its boarding station, not only to the station itself.
        for bottom, way_id in sorted(board):
            if bottom in from_core or bottom in left_alone:
                continue
            feeders = frozenset(validate.reach(backward, [bottom]))
            if feeders not in tried:
                tried[feeders] = closest(feeders, from_core, near_first=False)
            if tried[feeders]:
                candidates.append((tried[feeders], f"no way in to {name(way_id)}"))
        if not candidates:
            return False
        (distance, start, end), why = min(candidates)
        settle(why, host_of(start), start, end, distance)
        return True

    tie_in(core_of, lambda adjacency, backward: set())

    # A separate ski area with its own base (validate.separate_areas) gets the
    # same treatment: pieces of it the map leaves apart are joined to it, so it
    # is one network rather than several fragments. Lifts that touch the main
    # network were settled above and are left alone.
    run_pairs = [
        (a, b) for w in travel if net.ways[w].kind == "run" for a, b in zip(travel[w], travel[w][1:])
    ]
    tops = {node for _, node in lift_ends}
    bottoms = {node for node, _ in lift_starts}

    def touching_main(adjacency, backward) -> set[int]:
        main = core_of(adjacency, backward)
        return validate.reach(adjacency, main) | validate.reach(backward, main)

    def areas_now() -> list[set[int]]:
        adjacency = graph(with_lifts=True)
        backward = inverse(adjacency)
        main = core_of(adjacency, backward)
        return validate.separate_areas(
            validate.strong_parts(adjacency, backward, boarding - main), main,
            lambda n: net.coords[n], lambda n: raw_ele[n], bottoms, bottoms | tops,
            lambda part: any(a in part and b in part for a, b in lift_hops),
            lambda part: any(a in part and b in part for a, b in run_pairs),
            anchors,
        )

    for anchor in sorted(min(part) for part in areas_now()):
        def pick(adjacency, backward, anchor=anchor):
            return validate.reach(adjacency, [anchor]) & validate.reach(backward, [anchor])
        tie_in(pick, touching_main)

    # The station joins and tie-ins above reach lines the first pass could not
    # use, so T-junctions are looked for once more, with no station preferred:
    # any station join a dead end could have had is made by now.
    if line_join > 0:
        _join_run_lines(net, travel, forward, containing, grid, cell, raw_ele, boarding, alight, board,
                        nearest, join, min(line_join, MAX_LINE_JOIN_M), 0.0, synthetic)

    # Last, runs that touch nothing with a lift: drawn as a line that starts just
    # below one run and ends just above another (Jiminy Peak, Crystal Mountain).
    # Such a run is tied in at both ends or not at all, each within
    # `orphan_join_m` and MAX_LINK_RISE_M of height, so it is never left as a dead
    # end. Coming after every other join, it changes none of them.
    if orphan_join > 0:
        _join_orphan_runs(net, travel, forward, lift_hops, containing, nearest, join, host_of,
                          min(orphan_join, MAX_ORPHAN_JOIN_M))
    return joins


MAX_ORPHAN_JOIN_M = 50.0
"""The furthest a run that touches nothing with a lift may be tied to the network
at each end (`orphan_join_m`)."""

MAX_LINE_JOIN_M = 50.0
"""The furthest a run end may be joined to another run's line (`line_join_m`)."""
LINE_VERTEX_M = 3.0
"""A junction this close to an existing vertex of the line uses that vertex
instead of a new one."""


def _local(origin: tuple[float, float]):
    """Planar metres around `origin`; good to a few centimetres over 100 m."""
    lon0, lat0 = origin
    kx = 111_320.0 * math.cos(math.radians(lat0))
    return lambda p: ((p[0] - lon0) * kx, (p[1] - lat0) * 110_574.0)


def _crosses(p1, p2, q1, q2) -> bool:
    def side(a, b, c) -> float:
        return (b[0] - a[0]) * (c[1] - a[1]) - (b[1] - a[1]) * (c[0] - a[0])
    d1, d2 = side(q1, q2, p1), side(q1, q2, p2)
    d3, d4 = side(p1, p2, q1), side(p1, p2, q2)
    return d1 * d2 < 0 and d3 * d4 < 0


def synthetic_node_name(lon: float, lat: float, ele: float, way_id: int) -> str:
    """`v<12 hex>` for a vertex the pipeline adds (specs/02-DOMAIN.md section 1)."""
    import hashlib

    key = f"{lon:.7f},{lat:.7f},{ele:.1f},w{way_id}".encode()
    return "v" + hashlib.sha256(key).hexdigest()[:12]


def _join_run_lines(net, travel, forward, containing, grid, cell, raw_ele, boarding, alight, board,
                    nearest, join, limit: float, link_tolerance: float, synthetic: dict) -> None:
    """T-junctions the map leaves open, joined round by round (flag `line_join`).

    A run end nothing leaves is joined to the nearest point on another run or
    connection that leads on to a lift; a run start nothing reaches is joined
    from the nearest point on one that skiers reach from a lift. The point is
    within `limit`, the join climbs no more than RISE_TOLERANCE_M and drops no
    more than MAX_LINK_RISE_M, and it never crosses a lift's cable. The line is
    split there: at its vertex when one is within LINE_VERTEX_M, else at a new
    vertex. Each round can make more lines reachable, so rounds repeat until
    none joins (a chain of two cut-off runs is tied in from both ends).
    """
    lift_nodes = {n for w in travel if net.ways[w].kind == "lift" for n in travel[w]}
    unload = {node: way_id for way_id, node in alight}
    load = {node: way_id for node, way_id in board}
    lift_segments = [
        (net.coords[a], net.coords[b])
        for w in sorted(travel) if net.ways[w].kind == "lift" for a, b in zip(travel[w], travel[w][1:])
    ]
    # Line segments on a grid of `limit`-wide cells: (way id, upper node, lower node).
    dlat = limit / 110_574.0
    widest = max((abs(net.coords[n][1]) for n in containing), default=0.0)
    dlon = dlat / max(math.cos(math.radians(min(widest, 85.0))), 0.01)
    segments: dict[tuple[int, int], list[tuple[int, int, int]]] = {}

    def index(way_id: int, a: int, b: int) -> None:
        (x1, y1), (x2, y2) = net.coords[a], net.coords[b]
        for x in range(math.floor(min(x1, x2) / dlon), math.floor(max(x1, x2) / dlon) + 1):
            for y in range(math.floor(min(y1, y2) / dlat), math.floor(max(y1, y2) / dlat) + 1):
                segments.setdefault((x, y), []).append((way_id, a, b))

    hosts = sorted(w for w in travel if net.ways[w].kind in ("run", "connection"))
    for way_id in hosts:
        for a, b in zip(travel[way_id], travel[way_id][1:]):
            index(way_id, a, b)

    def two_way(way_id: int) -> bool:
        way = net.ways[way_id]
        return way.kind == "connection" and way.tags.get("oneway") != "yes"

    def closest_on_lines(node: int, own: int, usable):
        """(distance, way, a, b, t, point, height) of the nearest usable point."""
        point = net.coords[node]
        plane = _local(point)
        best = None
        seen: set[tuple[int, int, int]] = set()
        cx, cy = math.floor(point[0] / dlon), math.floor(point[1] / dlat)
        for x in (cx - 1, cx, cx + 1):
            for y in (cy - 1, cy, cy + 1):
                for segment in segments.get((x, y), ()):
                    way_id, a, b = segment
                    if segment in seen or way_id == own or node in (a, b):
                        continue
                    seen.add(segment)
                    pa, pb = plane(net.coords[a]), plane(net.coords[b])
                    dx, dy = pb[0] - pa[0], pb[1] - pa[1]
                    span = dx * dx + dy * dy
                    t = 0.0 if span == 0 else max(0.0, min(1.0, (-pa[0] * dx - pa[1] * dy) / span))
                    distance = math.hypot(pa[0] + t * dx, pa[1] + t * dy)
                    if distance > limit or (best is not None and (distance, way_id, a, b) >= best[:4]):
                        continue
                    height = raw_ele[a] + t * (raw_ele[b] - raw_ele[a])
                    if not usable(way_id, a, b, height):
                        continue
                    lon = net.coords[a][0] + t * (net.coords[b][0] - net.coords[a][0])
                    lat = net.coords[a][1] + t * (net.coords[b][1] - net.coords[a][1])
                    best = (distance, way_id, a, b, t, (lon, lat), height)
        return best

    def crosses_a_lift(p, q) -> bool:
        plane = _local(p)
        p1, p2 = plane(p), plane(q)
        for a, b in lift_segments:
            q1, q2 = plane(a), plane(b)
            if max(q1[0], q2[0]) < min(p1[0], p2[0]) or min(q1[0], q2[0]) > max(p1[0], p2[0]):
                continue
            if max(q1[1], q2[1]) < min(p1[1], p2[1]) or min(q1[1], q2[1]) > max(p1[1], p2[1]):
                continue
            if _crosses(p1, p2, q1, q2):
                return True
        return False

    def vertex_on(found) -> int:
        """The line's vertex at the junction, splitting the segment if needed."""
        _, way_id, a, b, t, (lon, lat), height = found
        length = haversine_m(net.coords[a], net.coords[b])
        if t * length <= LINE_VERTEX_M:
            return a
        if (1 - t) * length <= LINE_VERTEX_M:
            return b
        new = -(len(synthetic) + 1)
        synthetic[new] = synthetic_node_name(lon, lat, height, way_id)
        net.coords[new] = (lon, lat)
        raw_ele[new] = height
        nodes = travel[way_id]
        at = next(i for i in range(len(nodes) - 1) if nodes[i] == a and nodes[i + 1] == b)
        nodes.insert(at + 1, new)
        containing[new] = [way_id]
        grid.setdefault((math.floor(lon / cell), math.floor(lat / cell)), []).append(new)
        targets = forward[a]
        targets[targets.index(b)] = new
        forward[new] = [b]
        if two_way(way_id):
            back = forward[b]
            back[back.index(a)] = new
            forward[new].append(a)
        for key, entries in segments.items():
            if (way_id, a, b) in entries:
                entries.remove((way_id, a, b))
        index(way_id, a, new)
        index(way_id, new, b)
        return new

    def reach(adjacency, starts) -> set[int]:
        return validate.reach(adjacency, starts)

    for _ in range(len(travel) + 1):
        backward: dict[int, list[int]] = {}
        for a, targets in forward.items():
            for b in targets:
                backward.setdefault(b, []).append(a)
        leads_on = reach(backward, boarding)  # skiing from here reaches a lift
        reached = reach(forward, sorted(unload))  # skiers get here from a lift
        arrivals = {b for targets in forward.values() for b in targets}
        joined = 0
        for way_id in sorted(travel):
            way, nodes = net.ways[way_id], travel[way_id]
            if way.kind != "run":
                continue
            name = way.name or "unnamed run"
            end = nodes[-1]
            if not forward.get(end) and end not in boarding and end not in lift_nodes:
                height = raw_ele[end]

                def below(host, a, b, h, height=height) -> bool:
                    on = b in leads_on or (two_way(host) and a in leads_on)
                    return on and height - MAX_LINK_RISE_M <= h <= height + RISE_TOLERANCE_M

                found = closest_on_lines(end, way_id, below)
                if found and not crosses_a_lift(net.coords[end], found[5]):
                    station, gap = nearest(end, load, set(nodes), link_tolerance) if link_tolerance > 0 else (None, 0)
                    if station is None or gap > found[0]:
                        target = vertex_on(found)
                        join("line_join", way_id, end, target, haversine_m(net.coords[end], net.coords[target]),
                             f"{name} ends {found[0]:.1f} m from {net.ways[found[1]].name or 'an unnamed way'}")
                        arrivals.update((target, *forward.get(target, ())))
                        joined += 1
            start = nodes[0]
            if start not in arrivals and start not in lift_nodes:
                height = raw_ele[start]

                def above(host, a, b, h, height=height) -> bool:
                    on = a in reached or (two_way(host) and b in reached)
                    return on and height - RISE_TOLERANCE_M <= h <= height + MAX_LINK_RISE_M

                found = closest_on_lines(start, way_id, above)
                if found and not crosses_a_lift(found[5], net.coords[start]):
                    station, gap = nearest(start, unload, set(nodes), link_tolerance) if link_tolerance > 0 else (None, 0)
                    if station is None or gap > found[0]:
                        source = vertex_on(found)
                        host = found[1]
                        join("line_join", host, source, start, haversine_m(net.coords[source], net.coords[start]),
                             f"{name} starts {found[0]:.1f} m from {net.ways[host].name or 'an unnamed way'}")
                        arrivals.update((source, *forward.get(source, ())))
                        joined += 1
        if not joined:
            return


def _join_orphan_runs(net, travel, forward, lift_hops, containing, nearest, join, host_of,
                      limit: float) -> None:
    """Tie in runs whose whole piece of the map has no lift, one round at a time:
    a run joined in one round brings its neighbours within reach in the next."""
    lift_nodes = {n for w in travel if net.ways[w].kind == "lift" for n in travel[w]}
    for _ in range(len(travel) + 1):
        parent = {node: node for node in containing}

        def find(node: int) -> int:
            while parent[node] != node:
                parent[node] = parent[parent[node]]
                node = parent[node]
            return node

        for a, targets in forward.items():
            for b in targets:
                parent[find(a)] = find(b)
        for a, b in lift_hops:
            parent[find(a)] = find(b)
        # Only a lift's stations connect; the nodes between them are on the
        # cable, so a run is never tied to one.
        lifted = {find(n) for hop in lift_hops for n in hop}
        network_nodes = {n for n in containing if find(n) in lifted and n not in lift_nodes}
        # A run is tied in from a place skiers reach and into a place that leads
        # on to a lift, so the join never extends a dead end.
        onward: dict[int, list[int]] = {a: list(b) for a, b in forward.items()}
        for a, b in lift_hops:
            onward.setdefault(a, []).append(b)
        back: dict[int, list[int]] = {}
        for a, targets in onward.items():
            for b in targets:
                back.setdefault(b, []).append(a)
        stops = {n for hop in lift_hops for n in hop}
        reached = validate.reach(onward, stops) & network_nodes
        leading = validate.reach(back, stops) & network_nodes
        done: set[int] = set()
        for way_id in sorted(travel):
            way, nodes = net.ways[way_id], travel[way_id]
            root = find(nodes[0])
            if way.kind != "run" or root in lifted or root in done:
                continue
            exclude = set(nodes)
            source, d_in = nearest(nodes[0], reached, exclude, limit)
            target, d_out = nearest(nodes[-1], leading, exclude, limit)
            if source is None or target is None:
                continue
            name = way.name or "unnamed run"
            join("orphan_link", host_of(source), source, nodes[0], d_in,
                 f"{name} touches nothing with a lift; its start")
            join("orphan_link", way_id, nodes[-1], target, d_out,
                 f"{name} touches nothing with a lift; its end")
            done.add(root)
        if not done:
            return


def _bounds(edges: list[dict]) -> list[float]:
    """The box that holds the whole graph, padded about 200 m. The catalog box only
    says where to look; this is what the bundle declares."""
    lons = [p[0] for e in edges for p in e["geometry"]]
    lats = [p[1] for e in edges for p in e["geometry"]]
    pad, step = 0.002, 1e4
    return [
        math.floor((min(lons) - pad) * step) / step, math.floor((min(lats) - pad) * step) / step,
        math.ceil((max(lons) + pad) * step) / step, math.ceil((max(lats) + pad) * step) / step,
    ]


def _bases(bottoms: set, tops: set, height: dict) -> set:
    """Lift bottoms in the lowest BASE_BAND of the lift network's elevation range."""
    if not bottoms:
        return set()
    lowest = min(height[n] for n in bottoms)
    highest = max(height[n] for n in bottoms | tops)
    ceiling = lowest + BASE_BAND * (highest - lowest)
    return {n for n in bottoms if height[n] <= ceiling}


def _monotone_elevations(raw: dict[int, float], runs: list[dict]) -> dict[int, float]:
    """Vertex elevations under which no run edge climbs.

    DEM noise makes flat traverses rise a little. Each vertex moves to the midpoint
    of the lowest elevation upstream of it and the highest downstream of it, which
    is the raw value wherever the raw data already descends.
    """
    constraints = [(p["nodes"][0], p["nodes"][-1]) for p in runs]
    low = dict(raw)
    high = dict(raw)
    changed = True
    while changed:
        changed = False
        for upper, lower in constraints:
            if low[lower] > low[upper]:
                low[lower] = low[upper]
                changed = True
            if high[upper] < high[lower]:
                high[upper] = high[lower]
                changed = True
    return {node: (low[node] + high[node]) / 2.0 for node in raw}


def _geometry(net: topology.Network, piece: dict, raw: dict, ele: dict) -> list[tuple]:
    nodes = piece["nodes"]
    top, bottom = ele[nodes[0]], ele[nodes[-1]]
    points = []
    previous = top
    for index, node in enumerate(nodes):
        lon, lat = net.coords[node]
        if index == 0:
            z = top
        elif index == len(nodes) - 1:
            z = bottom
        elif piece["kind"] == "run":
            z = min(previous, max(raw[node], bottom))
        else:
            z = raw[node]
        previous = z
        points.append((round(lon, 7), round(lat, 7), z))
    return points


def _grade_max(geometry: list[tuple]) -> float:
    """Steepest slope over any stretch of at least GRADE_WINDOW_M, in degrees; an
    edge shorter than that takes its mean slope. A few metres at the end of an edge
    would otherwise turn DEM noise into a pitch that gates a skier off a gentle run."""
    distance = [0.0]
    for i in range(1, len(geometry)):
        distance.append(distance[-1] + haversine_m(geometry[i - 1], geometry[i]))
    if distance[-1] <= 0:
        return 0.0
    if distance[-1] < GRADE_WINDOW_M:
        return math.degrees(math.atan(abs(geometry[-1][2] - geometry[0][2]) / distance[-1]))
    steepest = 0.0
    j = 0
    for i in range(len(geometry) - 1):
        j = max(j, i + 1)
        while j < len(geometry) - 1 and distance[j] - distance[i] < GRADE_WINDOW_M:
            j += 1
        run = distance[j] - distance[i]
        if run < GRADE_WINDOW_M:
            break
        steepest = max(steepest, abs(geometry[j][2] - geometry[i][2]) / run)
    return math.degrees(math.atan(steepest))


def _edge_difficulty(way: topology.Way, identity: dict | None) -> str:
    """Each section is paced and gated by its own difficulty: the harder of its
    way's tag and the feed's value for the trail, so neither makes it easier."""
    tagged = _tagged_difficulty(way)
    if identity is None:
        return tagged or "unknown"
    if identity.get("difficulty_source") == "decision":
        return identity["difficulty"]
    official = identity.get("official_difficulty")
    if official is None and identity.get("difficulty_source") == "official":
        # A manifest reconciled before `official_difficulty` was stored.
        official = identity["difficulty"]
    if official:
        if tagged is None:
            return official
        return max(tagged, official, key=DIFFICULTY_ORDER.index)
    return tagged or identity.get("difficulty") or "unknown"


def _tagged_difficulty(way: topology.Way) -> str | None:
    return topology.DIFFICULTIES.get(str(way.tags.get("piste:difficulty") or "").lower())


def _ride_seconds(net: topology.Network, way: topology.Way, lift_type: str, horizontal: float) -> int:
    whole = length_m([net.coords[n] for n in way.nodes])
    tagged = duration_seconds(way.tags.get("aerialway:duration"))
    if tagged and whole > 0:
        return max(1, round(tagged * horizontal / whole))
    speed = LIFT_SPEED_MS[lift_type]
    if lift_type == "chair" and (
        way.tags.get("aerialway:detachable") == "yes" or way.tags.get("aerialway:bubble") == "yes"
    ):
        speed = DETACHABLE_CHAIR_SPEED_MS
    return max(1, round(horizontal / speed))


def _capacity(way: topology.Way, lift_type: str) -> int:
    try:
        tagged = int(way.tags.get("aerialway:capacity"))
    except (TypeError, ValueError):
        tagged = 0
    return tagged if tagged > 0 else LIFT_CAPACITY_PPH[lift_type]


def _groups(manifest: dict, group_edges: dict, unnamed_groups: dict) -> list[dict]:
    groups = []
    for kind, entries in (("trail", manifest["trails"]), ("lift", manifest["lifts"])):
        for identity in entries:
            edge_ids = group_edges.get(identity["group_id"])
            if not edge_ids:
                continue
            group = {
                "id": identity["group_id"], "kind": kind, "name": identity["name"],
                "edge_ids": sorted(edge_ids, key=_edge_key), "official": bool(identity["official"]),
            }
            if kind == "trail":
                group["difficulty"] = identity["difficulty"]
            if identity.get("approximate"):
                group["approximate"] = True
            groups.append(group)
    for group_id, info in unnamed_groups.items():
        group = {
            "id": group_id, "kind": info["kind"], "name": "",
            "edge_ids": sorted(group_edges[group_id], key=_edge_key), "official": False,
        }
        if info["kind"] == "trail":
            # One way per unnamed group, so the group is exactly that way's tag.
            group["difficulty"] = _tagged_difficulty(info["way"]) or "unknown"
        groups.append(group)
    return sorted(groups, key=lambda g: g["id"])


def _nodes(net: topology.Network, edges: list[dict], ele: dict, raw_ele: dict, manifest: dict,
           synthetic: dict[int, str]) -> list[dict]:
    used = {e["from"] for e in edges} | {e["to"] for e in edges}
    lifts = [e for e in edges if e["kind"] == "lift"]
    bottoms = {int(e["from"][1:]) for e in lifts}
    arrivals = {int(e["to"][1:]) for e in lifts}
    bases = _bases(bottoms, arrivals, raw_ele)
    # A lift top is where a lift group ends, not a mid-station the same lift
    # carries on from (the same rule as validate.Graph). Keyed on the group: one
    # lift's mid-station can be another's real top.
    carries_on = {(e["group"], e["from"]) for e in lifts}
    tops = {int(e["to"][1:]) for e in lifts if (e["group"], e["to"]) not in carries_on}
    landmarks = {r["node_id"] for r in manifest["rendezvous"] if r["kind"] in ("lodge", "landmark")}
    added = {name: number for number, name in synthetic.items()}

    def order(node_id: str):
        # OSM nodes by number, then the vertices the build added by name.
        return (1, 0, node_id) if node_id in added else (0, int(node_id[1:]), "")

    nodes = []
    for node_id in sorted(used, key=order):
        number = added[node_id] if node_id in added else int(node_id[1:])
        lon, lat = net.coords[number]
        if number in bases:
            kind = "base"
        elif number in tops:
            kind = "lift_top"
        elif number in bottoms:
            kind = "lift_bottom"
        elif node_id in landmarks:
            kind = "landmark"
        else:
            kind = "junction"
        nodes.append({
            "id": node_id, "lon": round(lon, 7), "lat": round(lat, 7),
            "ele_m": round(ele[number], 1), "kind": kind,
        })
    return nodes


def _status_aliases(manifest: dict, groups: list[dict]) -> dict:
    built = {g["id"] for g in groups}
    return {
        provider: {name: group for name, group in sorted(names.items()) if group in built}
        for provider, names in sorted(manifest.get("status_aliases", {}).items())
    }


def _integrity(document: dict, flags: list[dict], anchors=()) -> None:
    """Attach the integrity block, drop rendezvous outside the connected network,
    and settle `status_mode`."""
    measured = validate.measure(document, anchors)
    by_id = {r["id"]: r for r in document["rendezvous"]}
    nodes = {n["id"]: n for n in document["nodes"]}
    for rendezvous_id in measured["unreachable_rendezvous"]:
        rendezvous = by_id[rendezvous_id]
        node = nodes[rendezvous["node_id"]]
        flags.append(_flag(
            "rendezvous_dropped", None, node["lon"], node["lat"],
            f"{rendezvous_id} ({rendezvous['name']}) is outside the connected network; dropped",
        ))
    dropped = set(measured["unreachable_rendezvous"])
    document["rendezvous"] = [r for r in document["rendezvous"] if r["id"] not in dropped]
    edge_start = {e["id"]: e["geometry"][0] for e in document["edges"]}
    for edge_id in measured["orphan_edge_ids"]:
        lon, lat = edge_start[edge_id][:2]
        flags.append(_flag("orphan_edge", edge_id, lon, lat, "in a part of the network with no lift"))
    flags += measured["flags"]
    document["integrity"] = {
        "lift_tops_reaching_base": measured["lift_tops_reaching_base"],
        # Every rendezvous that is kept is reachable; none kept means none usable.
        "rendezvous_reachable_from_all_lift_tops": 1.0 if document["rendezvous"] else 0.0,
        "orphan_edge_share": measured["orphan_edge_share"],
        "unnamed_run_share": measured["unnamed_run_share"],
        "flags": sorted(flags, key=lambda f: (f["code"], _edge_key(f.get("edge_id") or "w0:0"), f["note"])),
    }
    document["status_mode"] = validate.evaluate(document)["status_mode"]


def _flag(code: str, edge_id: str | None, lon: float, lat: float, note: str) -> dict:
    flag = {"code": code, "lon": round(float(lon), 7), "lat": round(float(lat), 7), "note": note}
    if edge_id:
        flag["edge_id"] = edge_id
    return flag


def _edge_key(edge_id: str):
    way, _, ordinal = edge_id[1:].partition(":")
    return (int(way), int(ordinal))
