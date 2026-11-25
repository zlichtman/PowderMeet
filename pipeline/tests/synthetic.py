"""A small hand-built mountain for tests: one chair, three named runs and a lodge.

Grid units are 0.001 degrees (about 111 m north-south). Tests add ways to this
baseline to trip one threshold at a time.
"""

from __future__ import annotations

import copy

from powdermeet_pipeline import build, drawn, reconcile
from powdermeet_pipeline.reconcile import decisions as decisions_mod

RESORT = {
    "resort_id": "test-mountain",
    "name": "Test Mountain",
    "timezone": "America/Vancouver",
    "bbox": [-120.1, 49.9, -119.9, 50.1],
    "center": [-120.0, 50.0],
    "status_provider": "epic",
    "default_hours": [{"days": [1, 2, 3, 4, 5, 6, 7], "open": "08:30", "close": "15:30"}],
}

# id: (x, y, elevation)
NODES = {
    1: (0, 0, 1000.0),    # base
    2: (0, 10, 1500.0),   # summit
    3: (2, 5, 1250.0),    # mid-mountain junction
    4: (3, 8, 1400.0),
    5: (-2, 6, 1300.0),
}
WAYS = {
    100: ([1, 2], {"aerialway": "chair_lift", "name": "Summit Express"}),
    200: ([2, 3], {"piste:type": "downhill", "name": "Alpha", "piste:difficulty": "easy"}),
    201: ([3, 1], {"piste:type": "downhill", "name": "Alpha", "piste:difficulty": "easy"}),
    202: ([2, 4, 3], {"piste:type": "downhill", "name": "Beta", "piste:difficulty": "advanced"}),
    203: ([2, 5, 1], {"piste:type": "downhill", "name": "Gamma", "piste:difficulty": "intermediate"}),
}
POINTS = {
    900: (0.1, 10.1, {"amenity": "restaurant", "name": "Summit Lodge"}),
}
OFFICIAL = {
    "trails": [{"name": "Alpha"}, {"name": "Beta"}, {"name": "Gamma"}],
    "lifts": [{"name": "Summit Express"}],
}


class Mountain:
    def __init__(self):
        self.nodes = dict(NODES)
        self.ways = copy.deepcopy(WAYS)
        self.points = copy.deepcopy(POINTS)
        self.official = copy.deepcopy(OFFICIAL)
        self.unmapped: set[int] = set()  # ways OpenSkiMap does not know
        self.decisions: dict = {}

    def node(self, node_id: int, x: float, y: float, ele: float) -> "Mountain":
        self.nodes[node_id] = (x, y, ele)
        return self

    def way(self, way_id: int, nodes: list[int], tags: dict, openskimap: bool = True) -> "Mountain":
        self.ways[way_id] = (nodes, tags)
        if not openskimap:
            self.unmapped.add(way_id)
        return self

    def extract(self) -> dict:
        elements = []
        for node_id, (x, y, _) in self.nodes.items():
            elements.append({"type": "node", "id": node_id, "lon": -120.0 + x / 1000, "lat": 50.0 + y / 1000})
        for node_id, (x, y, tags) in self.points.items():
            elements.append({
                "type": "node", "id": node_id, "lon": -120.0 + x / 1000, "lat": 50.0 + y / 1000, "tags": tags,
            })
        for way_id, (nodes, tags) in self.ways.items():
            elements.append({"type": "way", "id": way_id, "nodes": nodes, "tags": tags})
        runs, lifts = [], []
        for way_id, (_, tags) in self.ways.items():
            if way_id in self.unmapped or not tags.get("name"):
                continue
            feature = {
                "id": f"osm-{way_id}", "name": tags["name"], "status": "operating",
                "sources": [{"type": "openstreetmap", "id": f"way/{way_id}"}],
            }
            if "aerialway" in tags:
                lifts.append({**feature, "liftType": tags["aerialway"]})
            else:
                runs.append({**feature, "uses": ["downhill"], "difficulty": tags.get("piste:difficulty")})
        return {
            "extract_id": "osm-2026-11-01T06:00Z-test-mountain-000000",
            "schema": 1,
            "resort_id": RESORT["resort_id"],
            "bbox": RESORT["bbox"],
            "osm": {"source": "overpass", "fetched_at": "2026-11-01T06:00:00Z", "elements": elements},
            "openskimap": {
                "fetched_at": "2026-11-01T06:00:00Z", "published_at": "2026-10-28T00:00:00Z",
                "runs": runs, "lifts": lifts,
            },
            "official": {
                "adapter": "epic", "urls": ["https://example.com/status"],
                "fetched_at": "2026-11-01T06:00:00Z" if self.official else None, "error": None,
                "trails": (self.official or {}).get("trails", []),
                "lifts": (self.official or {}).get("lifts", []),
            },
            "elevation": {
                "provider": "terrarium", "zoom": 14,
                "samples": {str(node_id): ele for node_id, (_, _, ele) in self.nodes.items()},
            },
        }

    @staticmethod
    def dem(lon: float, lat: float) -> float:
        """A plane through the baseline nodes: 50 m per grid unit northward."""
        return 1000.0 + 50.0 * (lat - 50.0) * 1000

    def manifest(self) -> dict:
        decisions = decisions_mod.normalize(RESORT["resort_id"], self.decisions)
        extract = self.extract()
        decisions["add_runs"] = drawn.trace_all(extract, decisions["add_runs"], self.dem)
        content = reconcile.run(RESORT, extract, decisions)
        return {"manifest_version": 1, "created_at": "2026-11-02T10:11:12Z", **content}

    def bundle(self) -> build.Bundle:
        return build.build(RESORT, self.extract(), self.manifest())
