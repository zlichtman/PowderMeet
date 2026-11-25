"""The routable network in a frozen extract: which OSM ways are lifts, runs and
connections, and which of their nodes are graph vertices.

Reconcile and build both read the network through this module so they agree on
way ids and vertex ids. Here connectivity comes only from shared OSM node ids;
the listed, flagged joins of invariant I-16 are added by build, and nothing here
compares coordinates.
"""

from __future__ import annotations

import re
from collections import Counter
from dataclasses import dataclass, field

ROUTABLE_AERIALWAYS = frozenset({
    "chair_lift", "gondola", "cable_car", "drag_lift", "t-bar", "j-bar",
    "platter", "rope_tow", "magic_carpet", "funicular", "mixed_lift",
})

# Lifts that serve a tubing hill carry no skiers.
_NOT_SKI_LIFT = re.compile(r"\btubing\b|\btube ?park\b", re.IGNORECASE)

# OSM aerialway value -> bundle lift type.
LIFT_TYPES = {
    "chair_lift": "chair",
    "gondola": "gondola",
    "mixed_lift": "gondola",
    "cable_car": "cable_car",
    "funicular": "cable_car",
    "t-bar": "tbar",
    "j-bar": "tbar",
    "platter": "tbar",
    "drag_lift": "tbar",
    "magic_carpet": "magic_carpet",
    "rope_tow": "rope_tow",
}

# OSM piste:difficulty -> bundle difficulty.
DIFFICULTIES = {
    "novice": "green",
    "easy": "green",
    "intermediate": "blue",
    "advanced": "black",
    "expert": "double_black",
    "freeride": "double_black",
    "extreme": "double_black",
}


@dataclass
class Way:
    id: int
    kind: str  # "lift" | "run" | "connection"
    nodes: list[int]
    tags: dict

    @property
    def name(self) -> str:
        return str(self.tags.get("name") or self.tags.get("piste:name") or "").strip()


# Cabins carry people both ways unless the map says otherwise; chairs and surface
# lifts carry them up only unless the map says otherwise (the OSM convention).
TWO_WAY_BY_DEFAULT = frozenset({"gondola", "cable_car", "mixed_lift", "funicular"})


def two_way_lift(way: "Way") -> bool:
    oneway = str(way.tags.get("oneway") or "").lower()
    if oneway == "no":
        return True
    return str(way.tags.get("aerialway") or "").lower() in TWO_WAY_BY_DEFAULT and oneway not in ("yes", "true", "1")


LIFT_DESCENT_M = 20.0
"""A one-way lift that descends more than this in its mapped direction is drawn
backwards and gets reversed (flag `lift_reversed`)."""


def lift_mapped_downhill(way: "Way", elevation: dict) -> bool:
    """Whether `build` reverses this lift way so that it runs bottom to top: a
    two-way lift drawn top first, or a one-way lift drawn running down.
    `elevation` maps node id to metres; without both ends the way is kept."""
    start, end = elevation.get(way.nodes[0]), elevation.get(way.nodes[-1])
    if start is None or end is None:
        return False
    rise = end - start
    return rise < 0 if two_way_lift(way) else rise < -LIFT_DESCENT_M


@dataclass
class Network:
    ways: dict[int, Way] = field(default_factory=dict)
    coords: dict[int, tuple[float, float]] = field(default_factory=dict)  # node id -> (lon, lat)
    node_tags: dict[int, dict] = field(default_factory=dict)
    skipped: list[dict] = field(default_factory=list)

    @property
    def stations(self) -> set[int]:
        return {n for n, tags in self.node_tags.items() if tags.get("aerialway") == "station"}


def network(extract: dict, exclude_ways: frozenset[int] = frozenset()) -> Network:
    """Classify the extract's ways. A way that cannot be routed is recorded in
    `skipped` with the reason instead of being repaired."""
    net = Network()
    # Ways that OpenSkiMap puts only in some other ski area belong to a neighbour.
    ours = set(extract.get("ski_areas") or ())
    cited: dict[int, set[str]] = {}
    # Ways every OpenSkiMap feature citing them calls proposed, planned, under
    # construction, disused or abandoned: nobody can ride or ski them yet.
    operating: dict[int, bool] = {}
    ski_map = extract.get("openskimap") or {}
    for feature in (ski_map.get("runs") or []) + (ski_map.get("lifts") or []):
        for source in feature.get("sources") or []:
            way_id = str(source.get("id") or "")
            if source.get("type") == "openstreetmap" and way_id.startswith("way/") and way_id[4:].isdigit():
                works = feature.get("status") in (None, "operating")
                operating[int(way_id[4:])] = operating.get(int(way_id[4:]), False) or works
                if ours:
                    cited.setdefault(int(way_id[4:]), set()).update(feature.get("ski_areas") or ())
    raw_ways = []
    for element in extract["osm"]["elements"]:
        if element["type"] == "node" and "lon" in element:
            net.coords[element["id"]] = (float(element["lon"]), float(element["lat"]))
            if element.get("tags"):
                net.node_tags[element["id"]] = element["tags"]
        elif element["type"] == "way" and element.get("nodes"):
            raw_ways.append(element)

    for element in raw_ways:
        tags = element.get("tags") or {}
        aerialway = str(tags.get("aerialway") or "").lower()
        piste = tags.get("piste:type")
        if aerialway in ROUTABLE_AERIALWAYS:
            kind = "lift"
        elif piste == "downhill":
            kind = "run"
        elif piste == "connection":
            kind = "connection"
        else:
            continue
        # A piste area is a footprint, not a centerline.
        if tags.get("area") == "yes":
            continue
        nodes = [n for i, n in enumerate(element["nodes"]) if i == 0 or n != element["nodes"][i - 1]]

        def skip(reason: str) -> None:
            known = [net.coords[n] for n in nodes if n in net.coords]
            lon, lat = known[0] if known else (0.0, 0.0)
            net.skipped.append({
                "way_id": element["id"], "kind": kind, "reason": reason,
                "name": str(tags.get("name") or ""), "lon": lon, "lat": lat,
            })

        if element["id"] in exclude_ways:
            skip("excluded_by_decision")
        elif tags.get("ski", tags.get("access")) in ("private", "no"):
            skip("private")
        elif any(tags.get(key) == "yes" for key in ("abandoned", "disused", "piste:abandoned")):
            skip("disused")
        elif operating.get(element["id"]) is False:
            skip("not_operating")
        elif len(nodes) < 2:
            skip("too_short")
        elif any(n not in net.coords for n in nodes):
            skip("missing_nodes")
        elif kind != "lift" and nodes[0] == nodes[-1]:
            skip("closed_way")
        elif cited.get(element["id"]) and not cited[element["id"]] & ours:
            skip("other_ski_area")
        elif kind == "lift" and ours and element["id"] in cited and not cited[element["id"]]:
            # OpenSkiMap puts every lift it knows in the ski areas it serves; one
            # in none is a village cable car or a summer lift (Riddes - Isérables).
            skip("no_ski_area")
        elif kind == "lift" and _NOT_SKI_LIFT.search(str(tags.get("name") or "")):
            skip("not_a_ski_lift")
        else:
            net.ways[element["id"]] = Way(element["id"], kind, nodes, tags)
    return net


def vertices(net: Network, way_nodes: dict[int, list[int]] | None = None) -> set[int]:
    """Graph vertices: way ends, lift stations, and nodes shared between ways.

    A lift can only be boarded or left at its ends and stations, so its other
    nodes never join it to a run that happens to share one.
    """
    stations = net.stations
    usage: Counter[int] = Counter()
    found: set[int] = set()
    for way_id in sorted(net.ways):
        way = net.ways[way_id]
        nodes = way_nodes[way_id] if way_nodes else way.nodes
        found.update((nodes[0], nodes[-1]))
        if way.kind == "lift":
            usable = [nodes[0], nodes[-1]] + [n for n in nodes[1:-1] if n in stations]
            found.update(usable)
        else:
            usable = nodes
        usage.update(usable)
    found.update(n for n, count in usage.items() if count >= 2)
    return found


def split_points(way: Way, nodes: list[int], verts: set[int], stations: set[int]) -> list[int]:
    """Indexes into `nodes` where the way is cut into edges, ends included."""
    allowed = stations if way.kind == "lift" else verts
    cuts = [0] + [i for i in range(1, len(nodes) - 1) if nodes[i] in allowed] + [len(nodes) - 1]
    return cuts


def way_clusters(net: Network, way_ids) -> list[list[int]]:
    """Group ways that touch through shared nodes."""
    ids = sorted(w for w in way_ids if w in net.ways)
    parent = {w: w for w in ids}

    def find(w: int) -> int:
        while parent[w] != w:
            parent[w] = parent[parent[w]]
            w = parent[w]
        return w

    first_seen: dict[int, int] = {}
    for w in ids:
        for node in net.ways[w].nodes:
            other = first_seen.setdefault(node, w)
            if other != w:
                parent[find(w)] = find(other)
    clusters: dict[int, list[int]] = {}
    for w in ids:
        clusters.setdefault(find(w), []).append(w)
    return sorted(clusters.values())
