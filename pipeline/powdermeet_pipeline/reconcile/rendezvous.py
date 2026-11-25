"""Rendezvous proposals: places two skiers can agree to meet.

Candidates are lift bases and tops, lodges and restaurants beside the network,
named junctions and peaks, and the bottom of each named run. Each is anchored to a graph vertex. The reviewer
confirms, renames or rejects them in the decisions file.
"""

from __future__ import annotations

import re
from typing import Dict, List

from ..geo import haversine_m
from ..topology import LIFT_TYPES, Network, lift_mapped_downhill, vertices
from .decisions import DecisionError
from .identities import slugify

FOOD = {"restaurant", "cafe", "fast_food", "bar", "pub"}
# Staffed huts serve food. An unstaffed wilderness hut is a shelter: somewhere
# to recognise and get indoors, not somewhere to eat.
HUTS = {"alpine_hut"}
SHELTERS = {"wilderness_hut"}
NOT_PUBLIC = {"private", "no"}
# "Harmony Snack Hut (closed)", "Lodge - closed": the name says it is shut.
CLOSED_NAME = re.compile(r"[(\[]\s*(?:permanently\s+|temporarily\s+)?(?:closed|disused|abandoned)\s*[)\]]|[-\u2013\u2014]\s*(?:permanently\s+|temporarily\s+)?closed\s*$", re.I)
LODGE_RADIUS_M = 75.0
LANDMARK_RADIUS_M = 120.0
LODGES_PER_ANCHOR = 2
# Carpets and tows serve learning areas; their ends are not useful meeting points.
RENDEZVOUS_LIFT_TYPES = {"chair", "gondola", "cable_car", "tbar"}
# A run's bottom is a meeting point when the run drops this far (a flat
# connector has no "bottom" to wait at) and nothing else is proposed this close
# (a run that ends at a lift is already met at the lift).
RUN_END_MIN_DROP_M = 30.0
RUN_END_CLEAR_M = 60.0


def is_closed(name: str, tags: dict) -> bool:
    """A place OSM or its own name says is shut is not somewhere to meet, so it is
    dropped rather than kept as a landmark."""
    if CLOSED_NAME.search(name):
        return True
    if tags.get("disused") == "yes" or tags.get("abandoned") == "yes":
        return True
    if str(tags.get("opening_hours") or "").strip().lower() in ("closed", "off"):
        return True
    return any(key.startswith(("disused:", "abandoned:")) for key in tags)


def propose(net: Network, extract: dict, lifts: List[dict], decisions: dict) -> List[dict]:
    """`net` is the network build sees, without the ways of rejected identities."""
    verts = sorted(vertices(net))
    elevation = {int(n): float(e) for n, e in (extract.get("elevation") or {}).get("samples", {}).items()}
    candidates: List[dict] = []
    candidates += _lift_ends(net, lifts, elevation)
    candidates += _points_of_interest(net, extract, verts)
    candidates += _named_junctions(net, verts)
    candidates += _run_ends(net, set(verts), elevation, candidates)

    rules = decisions["rendezvous"]
    out: List[dict] = []
    # A repeated slug is numbered in order of each place's own OSM id, so a place
    # mapped later (a higher id) takes the next number instead of renumbering the
    # others, and a number never takes a slug a place already has ("Summit 2").
    natural = {c["id"] for c in candidates}
    taken: set = set()
    used: Dict[str, int] = {}
    for candidate in sorted(candidates, key=_ordinal_key):
        slug = candidate["id"]
        if slug in taken:
            count = used.get(slug, 2)
            while f"{slug}-{count}" in natural or f"{slug}-{count}" in taken:
                count += 1
            used[slug] = count
            candidate["id"] = f"{slug}-{count}"
        taken.add(candidate["id"])
        if candidate["id"] in rules["reject"]:
            continue
        if candidate["id"] in rules["rename"]:
            candidate["name"] = rules["rename"][candidate["id"]]
        if candidate["id"] in rules["confidence"]:
            candidate["confidence"] = rules["confidence"][candidate["id"]]
        out.append(candidate)
    # After an OSM rename a reject would stop matching and the place come back.
    stale = sorted({*rules["reject"], *rules["rename"], *rules["confidence"]} - taken)
    if stale:
        raise DecisionError(f"decisions rendezvous names places that are not proposed: {', '.join(stale)}")
    return out


OSM_TYPES = {"node": 0, "way": 1, "relation": 2}


def _ordinal_key(candidate: dict):
    """Where a repeated slug falls among the others. The anchor is the nearest
    vertex, not the place, so a new place beside an old low-numbered node would
    take an existing place's number; the place's own OSM element does not move.
    A lift station or run bottom has no element of its own but sits on its own
    node, so that node stands in as a node id."""
    kind, _, number = candidate["source"].partition("/")
    anchor = int(candidate["node_id"][1:])
    if kind in OSM_TYPES and number.isdigit():
        return (candidate["id"], int(number), OSM_TYPES[kind], anchor, candidate["source"])
    return (candidate["id"], anchor, OSM_TYPES["node"], anchor, candidate["source"])


def _lift_ends(net: Network, lifts: List[dict], elevation: Dict[int, float]) -> List[dict]:
    """The base, top and mid stations of every chair, gondola, cable car and T-bar,
    named or not. A lift with no name has no identity; build still makes it the
    group `lift:unnamed-<way>`, and its stops are named for its type and the
    nearest named run."""
    claimed = {w for lift in lifts for w in lift["way_ids"]}
    entries = [
        (lift["group_id"].split(":", 1)[1], lift["name"], lift["lift_type"], lift["way_ids"],
         0.9 if lift["accepted"] else 0.7, lift["group_id"])
        for lift in lifts
    ]
    for way_id in sorted(net.ways):
        way = net.ways[way_id]
        if way.kind != "lift" or way_id in claimed:
            continue
        lift_type = LIFT_TYPES.get(str(way.tags.get("aerialway") or "").lower())
        entries.append((f"unnamed-{way_id}", None, lift_type, [way_id], 0.6, f"way/{way_id}"))

    stations = net.stations
    out = []
    for slug, name, lift_type, way_ids, confidence, source in entries:
        if lift_type not in RENDEZVOUS_LIFT_TYPES:
            continue
        # Ends in travel order: build turns a lift drawn top first around.
        ends = []
        for w in way_ids:
            nodes = net.ways[w].nodes
            ends.append((nodes[-1], nodes[0]) if lift_mapped_downhill(net.ways[w], elevation) else (nodes[0], nodes[-1]))
        firsts = {first for first, _ in ends}
        lasts = {last for _, last in ends}
        middles = (firsts & lasts) | {
            n for w in way_ids for n in net.ways[w].nodes[1:-1] if n in stations
        }
        for suffix, kind, label, nodes, quality in (
            ("base", "lift_base", "base", firsts - lasts, 0.6),
            ("top", "lift_top", "top", lasts - firsts, 0.5),
            ("mid", "lift_top", "mid station", middles, 0.5),
        ):
            for node in sorted(nodes):
                lon, lat = net.coords[node]
                title = f"{name} {label}" if name else _unnamed_title(net, lift_type, label, lon, lat)
                out.append({
                    "id": f"{slug}-{suffix}", "kind": kind, "name": title,
                    "node_id": f"n{node}", "confidence": confidence, "quality": quality,
                    "amenities": [], "lon": lon, "lat": lat, "distance_m": 0.0,
                    "source": source,
                })
    return out


LIFT_WORDS = {"chair": "Chairlift", "gondola": "Gondola", "cable_car": "Cable car", "tbar": "T-bar"}
NEAR_RUN_M = 150.0


def _unnamed_title(net: Network, lift_type: str, label: str, lon: float, lat: float) -> str:
    """"Chairlift base by Big Riskey": the lift's type and the named run with a
    point nearest the station, so two unnamed lifts read apart."""
    best, best_distance = None, NEAR_RUN_M
    window = NEAR_RUN_M / 60000.0
    for way_id in sorted(net.ways):
        way = net.ways[way_id]
        if way.kind != "run" or not way.name:
            continue
        for node in way.nodes:
            node_lon, node_lat = net.coords[node]
            if abs(node_lat - lat) > window or abs(node_lon - lon) > 2.5 * window:
                continue
            distance = haversine_m((lon, lat), (node_lon, node_lat))
            if distance < best_distance:
                best, best_distance = way.name, distance
    title = f"{LIFT_WORDS[lift_type]} {label}"
    if best and best.isdigit():
        best = f"run {best}"
    return f"{title} by {best}" if best else title


def _points_of_interest(net: Network, extract: dict, verts: List[int]) -> List[dict]:
    points = []
    for element in extract["osm"]["elements"]:
        tags = element.get("tags") or {}
        if "lon" in element:
            lon, lat = element["lon"], element["lat"]
        elif "center" in element:
            lon, lat = element["center"]["lon"], element["center"]["lat"]
        else:
            continue
        points.append((element, tags, float(lon), float(lat)))
    toilets = [(lon, lat) for _, tags, lon, lat in points if tags.get("amenity") == "toilets"]

    lodges: Dict[str, dict] = {}
    landmarks: List[dict] = []
    for element, tags, lon, lat in points:
        name = str(tags.get("name") or "").strip()
        if not name or "aerialway" in tags or "piste:type" in tags or tags.get("access") in NOT_PUBLIC:
            continue
        if is_closed(name, tags):
            continue
        is_food = tags.get("amenity") in FOOD or tags.get("tourism") in HUTS
        is_building = "building" in tags or tags.get("tourism") in SHELTERS
        is_landmark = tags.get("natural") == "peak" or tags.get("tourism") == "viewpoint"
        if not (is_food or is_building or is_landmark):
            continue
        radius = LANDMARK_RADIUS_M if is_landmark and not is_food else LODGE_RADIUS_M
        anchor, distance = _nearest(net, verts, lon, lat, radius)
        if anchor is None:
            continue
        entry = {
            "id": slugify(name), "name": name, "node_id": f"n{anchor}",
            "lon": lon, "lat": lat, "distance_m": round(distance, 1),
            "source": f"{element['type']}/{element['id']}",
        }
        if is_food:
            amenities = ["food", "indoor"]
            if tags.get("toilets") == "yes" or any(
                haversine_m((lon, lat), spot) <= 60.0 for spot in toilets
            ):
                amenities.append("restrooms")
            entry.update(
                kind="lodge", confidence=0.85 if distance <= 40.0 else 0.7, quality=0.9,
                amenities=sorted(amenities),
            )
        elif is_building:
            # A named building or shelter with no food service: recognisable, but not
            # somewhere two people would plan to wait.
            entry.update(kind="landmark", confidence=0.7, quality=0.5, amenities=["indoor"])
        else:
            entry.update(kind="landmark", confidence=0.7, quality=0.4, amenities=[])
            landmarks.append(entry)
            continue
        best = lodges.get(entry["id"])
        if best is None or _lodge_rank(entry) < _lodge_rank(best):
            lodges[entry["id"]] = entry

    # A base village has dozens of restaurants; keep the closest few per anchor.
    by_anchor: Dict[str, List[dict]] = {}
    for entry in lodges.values():
        by_anchor.setdefault(entry["node_id"], []).append(entry)
    kept = []
    for entries in by_anchor.values():
        kept += sorted(entries, key=_lodge_rank)[:LODGES_PER_ANCHOR]
    return kept + landmarks


def _lodge_rank(entry: dict):
    return ("food" not in entry["amenities"], entry["distance_m"], entry["source"])


def _named_junctions(net: Network, verts: List[int]) -> List[dict]:
    out = []
    for node in verts:
        tags = net.node_tags.get(node) or {}
        name = str(tags.get("name") or "").strip()
        if not name or "aerialway" in tags or tags.get("natural") == "peak" or is_closed(name, tags):
            continue
        lon, lat = net.coords[node]
        out.append({
            "id": slugify(name), "kind": "junction", "name": name, "node_id": f"n{node}",
            "confidence": 0.7, "quality": 0.5, "amenities": [], "lon": lon, "lat": lat,
            "distance_m": 0.0, "source": f"node/{node}",
        })
    return out


def _run_ends(net: Network, verts: set, elevation: Dict[int, float], others: List[dict]) -> List[dict]:
    """The bottom of each named run: where skiers regroup, and where two who
    came down different lines of the same run find each other. One entry per
    node, named for the longest run that ends there."""
    ends: Dict[str, List[int]] = {}
    length: Dict[str, int] = {}
    for way_id in sorted(net.ways):
        way = net.ways[way_id]
        if way.kind != "run" or not way.name:
            continue
        ends.setdefault(way.name, []).extend((way.nodes[0], way.nodes[-1]))
        length[way.name] = length.get(way.name, 0) + len(way.nodes)
    bottoms: Dict[int, str] = {}
    for name in sorted(ends):
        known = [n for n in ends[name] if n in elevation and n in verts]
        if not known:
            continue
        bottom = min(known, key=lambda n: (elevation[n], n))
        if max(elevation[n] for n in known) - elevation[bottom] < RUN_END_MIN_DROP_M:
            continue
        held = bottoms.get(bottom)
        if held is None or (length[name], name) > (length[held], held):
            bottoms[bottom] = name
    taken = [(c["lon"], c["lat"]) for c in others]
    out = []
    for node in sorted(bottoms):
        lon, lat = net.coords[node]
        if any(haversine_m((lon, lat), spot) < RUN_END_CLEAR_M for spot in taken):
            continue
        name = bottoms[node]
        title = f"run {name}" if name.isdigit() else name
        out.append({
            "id": f"{slugify(name)}-bottom", "kind": "junction", "name": f"Bottom of {title}",
            "node_id": f"n{node}", "confidence": 0.6, "quality": 0.4, "amenities": [],
            "lon": lon, "lat": lat, "distance_m": 0.0, "source": f"run/{name}",
        })
        taken.append((lon, lat))
    return out


def _nearest(net: Network, verts: List[int], lon: float, lat: float, radius: float):
    best, best_distance = None, radius
    window = radius / 60000.0  # generous degree window before the exact distance
    for node in verts:
        node_lon, node_lat = net.coords[node]
        if abs(node_lat - lat) > window or abs(node_lon - lon) > 2.5 * window:
            continue
        distance = haversine_m((lon, lat), (node_lon, node_lat))
        if distance < best_distance or (distance == best_distance and best is not None and node < best):
            best, best_distance = node, distance
    return best, best_distance
