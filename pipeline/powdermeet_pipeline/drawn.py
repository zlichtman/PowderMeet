"""Runs no one has mapped, drawn from a decisions file's `add_runs`.

A run on the resort's list and its trail map with no mapped line is drawn from a
node of the graph to another along the terrain's fall line: the cheapest path over
a grid of DEM samples between the two, where climbing costs heavily and crossing
the slope costs more than following it. The line is traced once, before reconcile,
and frozen into the manifest with its elevations, so reconcile and build stay pure
and a rebuild gives the same bytes. Both then see it as one more downhill way in
the extract, so it is named, matched to the official list and joined like any
mapped run; its edges and group carry `approximate: true` in the bundle.
"""

from __future__ import annotations

import hashlib
import heapq
import math

from . import catalog, topology
from .dem import TerrariumDEM
from .geo import haversine_m

EARTH_RADIUS_M = 6_371_000.0
MAX_STRAIGHT_M = 4000.0
"""The two ends of a drawn run may be at most this far apart."""
MAX_LENGTH_M = 6000.0
"""A traced line longer than this is a mistake in the ends, not a run."""
MIN_DROP_M = 5.0
"""The end must lie this much below the start (the build's DEM noise allowance)."""
MAX_CLIMB_M = 10.0
"""The largest single climb a traced line may keep, DEM noise included."""
CELL_M = 10.0
MAX_CELLS_ALONG = 400
CLIMB_COST = 30.0
"""Metres of path one metre of climbing is worth."""
TRAVERSE_COST = 1.5
"""Extra cost per metre for a step across the slope instead of down it."""
FLAT_SLOPE = 0.03
SIMPLIFY_M = 4.0

DRAWN_WAY_BASE = 9 * 10**15
"""Drawn runs get way ids from here up, far above any OSM way id, so their edge ids
keep the `w<way>:<k>` shape. Ten hex digits of hash keep them under 2^53, so a
reader that parses them as doubles still reads them exactly."""
DRAWN_TAG = "powdermeet:drawn"
TAGGED_DIFFICULTY = {"green": "easy", "blue": "intermediate", "black": "advanced", "double_black": "expert"}


class DrawError(catalog.PipelineError):
    pass


def prepare(resort: dict, extract: dict, decisions: dict) -> dict:
    """The decisions with every `add_runs` entry traced on the resort's DEM."""
    if not decisions.get("add_runs"):
        return decisions
    config = resort.get("dem") or {}
    dem = TerrariumDEM(catalog.cache_dir() / "dem", zoom=int(config.get("zoom", 14)))
    return {**decisions, "add_runs": trace_all(extract, decisions["add_runs"], dem.sample)}


def way_id(entry: dict) -> int:
    key = f"{entry['name']}|{entry['from']}|{entry['to']}".encode()
    return DRAWN_WAY_BASE + int(hashlib.sha256(key).hexdigest()[:10], 16)


def trace_all(extract: dict, entries: list[dict], sample) -> list[dict]:
    """Each entry with its traced `geometry` and `way_id`. `sample(lon, lat)` is
    the DEM the extract's elevations came from."""
    if not entries:
        return []
    net = topology.network(extract)
    samples = extract["elevation"]["samples"]
    ends = _usable_nodes(net)
    traced = []
    for entry in entries:
        points = []
        for field in ("from", "to"):
            node = int(entry[field][1:])
            if node not in ends:
                raise DrawError(
                    f"add_runs {entry['name']!r}: {entry[field]} is not a node of the built graph "
                    "(a lift end or station, or a node of a run or connection)")
            lon, lat = net.coords[node]
            points.append((lon, lat, float(samples[str(node)])))
        start, end = points
        straight = haversine_m(start, end)
        if straight > MAX_STRAIGHT_M:
            raise DrawError(f"add_runs {entry['name']!r}: its ends are {straight:.0f} m apart; "
                            f"{MAX_STRAIGHT_M:.0f} m at most")
        if end[2] > start[2] - MIN_DROP_M:
            raise DrawError(f"add_runs {entry['name']!r}: {entry['to']} ({end[2]:.0f} m) is not below "
                            f"{entry['from']} ({start[2]:.0f} m); a run goes downhill")
        line = trace(start, end, sample)
        length = sum(haversine_m(a, b) for a, b in zip(line, line[1:]))
        if length > MAX_LENGTH_M:
            raise DrawError(f"add_runs {entry['name']!r}: the traced line is {length:.0f} m; "
                            f"{MAX_LENGTH_M:.0f} m at most")
        climb = largest_climb(line)
        if climb > MAX_CLIMB_M:
            raise DrawError(f"add_runs {entry['name']!r}: no line between its ends descends; the best "
                            f"one still climbs {climb:.0f} m. Check the two nodes")
        traced.append({
            **entry, "way_id": way_id(entry),
            "geometry": [[round(lon, 7), round(lat, 7), round(z, 1)] for lon, lat, z in line],
        })
    ids = [t["way_id"] for t in traced]
    if len(set(ids)) != len(ids):
        raise DrawError("add_runs has two entries with the same name and ends")
    return traced


def extend(extract: dict, traced: list[dict]) -> dict:
    """The extract with each drawn run as a downhill way. Its inner points get
    negative node ids, numbered in file order; the build names them `v…`."""
    if not traced:
        return extract
    elements = list(extract["osm"]["elements"])
    samples = dict(extract["elevation"]["samples"])
    next_id = -1
    for run in traced:
        nodes = [int(run["from"][1:])]
        for lon, lat, z in run["geometry"][1:-1]:
            elements.append({"type": "node", "id": next_id, "lon": lon, "lat": lat})
            samples[str(next_id)] = z
            nodes.append(next_id)
            next_id -= 1
        nodes.append(int(run["to"][1:]))
        elements.append({"type": "way", "id": run["way_id"], "nodes": nodes, "tags": {
            "piste:type": "downhill", "name": run["name"],
            "piste:difficulty": TAGGED_DIFFICULTY[run["difficulty"]], DRAWN_TAG: "yes",
        }})
    return {
        **extract,
        "osm": {**extract["osm"], "elements": elements},
        "elevation": {**extract["elevation"], "samples": samples},
    }


def is_drawn(way: topology.Way) -> bool:
    return way.tags.get(DRAWN_TAG) == "yes"


def inner_nodes(traced: list[dict]) -> list[tuple[int, float, float, float, int]]:
    """(node id, lon, lat, ele, way id) of every inner point `extend` adds."""
    out, next_id = [], -1
    for run in traced:
        for lon, lat, z in run["geometry"][1:-1]:
            out.append((next_id, lon, lat, z, run["way_id"]))
            next_id -= 1
    return out


def largest_climb(line) -> float:
    worst, low = 0.0, line[0][2]
    for _, _, z in line:
        low = min(low, z)
        worst = max(worst, z - low)
    return worst


def trace(start, end, sample) -> list[tuple[float, float, float]]:
    """The fall line from `start` to `end`, both (lon, lat, ele), as points with
    DEM elevations between the two exact ends."""
    lon0, lat0 = start[0], start[1]
    kx = math.radians(1) * EARTH_RADIUS_M * math.cos(math.radians(lat0))
    ky = math.radians(1) * EARTH_RADIUS_M
    ex, ey = (end[0] - lon0) * kx, (end[1] - lat0) * ky
    distance = math.hypot(ex, ey)
    ux, uy = ex / distance, ey / distance
    vx, vy = -uy, ux
    cell = max(CELL_M, (distance * 1.5) / MAX_CELLS_ALONG)
    margin = max(100.0, 0.25 * distance)
    half = max(100.0, 0.5 * distance)
    nu = int(math.ceil((distance + 2 * margin) / cell)) + 1
    nv = 2 * int(math.ceil(half / cell)) + 1
    mid = nv // 2

    def lonlat(i: int, j: int) -> tuple[float, float]:
        u, v = -margin + i * cell, (j - mid) * cell
        return lon0 + (u * ux + v * vx) / kx, lat0 + (u * uy + v * vy) / ky

    z = [[sample(*lonlat(i, j)) for j in range(nv)] for i in range(nu)]
    slope = [[0.0] * nv for _ in range(nu)]
    for i in range(nu):
        for j in range(nv):
            gu = (z[min(i + 1, nu - 1)][j] - z[max(i - 1, 0)][j]) / ((min(i + 1, nu - 1) - max(i - 1, 0)) * cell)
            gv = (z[i][min(j + 1, nv - 1)] - z[i][max(j - 1, 0)]) / ((min(j + 1, nv - 1) - max(j - 1, 0)) * cell)
            slope[i][j] = math.hypot(gu, gv)

    source = (int(round(margin / cell)), mid)
    target = (int(round((margin + distance) / cell)), mid)
    steps = [(di, dj, cell * math.hypot(di, dj)) for di in (-1, 0, 1) for dj in (-1, 0, 1) if di or dj]
    best = {source: 0.0}
    previous: dict[tuple[int, int], tuple[int, int]] = {}
    queue = [(0.0, source)]
    while queue:
        cost, here = heapq.heappop(queue)
        if here == target:
            break
        if cost > best[here]:
            continue
        i, j = here
        for di, dj, length in steps:
            a, b = i + di, j + dj
            if not (0 <= a < nu and 0 <= b < nv):
                continue
            drop = z[i][j] - z[a][b]
            if drop < 0:
                step = length - CLIMB_COST * drop
            else:
                steep = (slope[i][j] + slope[a][b]) / 2
                along = 1.0 if steep < FLAT_SLOPE else min(1.0, drop / (length * steep))
                step = length * (1 + TRAVERSE_COST * (1 - along))
            total = cost + step
            if total < best.get((a, b), math.inf):
                best[(a, b)] = total
                previous[(a, b)] = here
                heapq.heappush(queue, (total, (a, b)))
    cells = [target]
    while cells[-1] != source:
        cells.append(previous[cells[-1]])
    cells.reverse()
    plane = [((i * cell), (j - mid) * cell) for i, j in cells]
    kept = _simplify(plane, SIMPLIFY_M)
    inner = [lonlat(*cells[k]) for k in kept[1:-1]]
    return [start] + [(lon, lat, sample(lon, lat)) for lon, lat in inner] + [end]


def _simplify(points: list[tuple[float, float]], tolerance: float) -> list[int]:
    """Douglas-Peucker: indexes of the points kept, ends included."""
    keep = {0, len(points) - 1}
    stack = [(0, len(points) - 1)]
    while stack:
        a, b = stack.pop()
        (x1, y1), (x2, y2) = points[a], points[b]
        span = math.hypot(x2 - x1, y2 - y1) or 1e-9
        worst, at = 0.0, None
        for k in range(a + 1, b):
            x, y = points[k]
            offset = abs((x2 - x1) * (y1 - y) - (x1 - x) * (y2 - y1)) / span
            if offset > worst:
                worst, at = offset, k
        if at is not None and worst > tolerance:
            keep.add(at)
            stack += [(a, at), (at, b)]
    return sorted(keep)


def _usable_nodes(net: topology.Network) -> set[int]:
    """Nodes a run can start or end at: any node of a run or connection, and a
    lift's ends and stations (where riders get on and off)."""
    stations = net.stations
    usable: set[int] = set()
    for way in net.ways.values():
        if way.kind == "lift":
            usable.update((way.nodes[0], way.nodes[-1]))
            usable.update(n for n in way.nodes if n in stations)
        else:
            usable.update(way.nodes)
    return usable
