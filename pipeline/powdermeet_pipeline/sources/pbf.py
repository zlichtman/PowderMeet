"""OSM features for a resort bbox from a regional PBF, the reproducible alternative
to Overpass. Needs the optional `osmium` package (`uv sync --extra pbf`).

Produces the elements `overpass.fetch` does for nodes and ways: network ways with
every node they reference, each with all its tags wherever it lies, tagged points,
and bounding-box centers for tagged areas. Relations are not read, so a restaurant
or ski area mapped only as a multipolygon relation is missing.
"""

from __future__ import annotations

import re
from pathlib import Path

from .overpass import POI_AMENITIES, POI_TOURISM, normalize_elements

_AMENITY = re.compile(f"^({POI_AMENITIES})$")
_TOURISM = re.compile(f"^({POI_TOURISM})$")


def fetch(path: Path, bbox) -> dict:
    try:
        import osmium
    except ImportError as error:  # pragma: no cover - optional dependency
        raise RuntimeError("--pbf needs the osmium package: uv sync --extra pbf") from error

    min_lon, min_lat, max_lon, max_lat = bbox

    def inside(lon: float, lat: float) -> bool:
        return min_lon <= lon <= max_lon and min_lat <= lat <= max_lat

    def point_of_interest(tags: dict) -> bool:
        return bool(
            "aerialway" in tags
            or tags.get("natural") == "peak"
            or _AMENITY.match(tags.get("amenity", ""))
            or _TOURISM.match(tags.get("tourism", ""))
        )

    elements: list[dict] = []
    network_refs: set[int] = set()

    # Ways need node locations to be placed in the bbox; the index keeps them in
    # memory for the region.
    for obj in osmium.FileProcessor(str(path)).with_locations():
        if not obj.is_way():
            continue
        tags = {tag.k: tag.v for tag in obj.tags}
        points = [(n.location.lon, n.location.lat) for n in obj.nodes if n.location.valid()]
        if not points or not any(inside(lon, lat) for lon, lat in points):
            continue
        if "piste:type" in tags or "aerialway" in tags:
            # Every reference is kept: a node with no location is then missing from
            # the extract, and topology leaves the way out as `missing_nodes`.
            refs = [n.ref for n in obj.nodes]
            elements.append({"type": "way", "id": obj.id, "nodes": refs, "tags": tags})
            network_refs.update(refs)
        elif (
            _AMENITY.match(tags.get("amenity", ""))
            or _TOURISM.match(tags.get("tourism", ""))
            or ("building" in tags and "name" in tags)
            or tags.get("landuse") == "winter_sports"
        ):
            # Overpass `out center` gives the middle of the bounding box.
            lons, lats = [p[0] for p in points], [p[1] for p in points]
            elements.append({
                "type": "way", "id": obj.id, "tags": tags,
                "center": {"lat": (min(lats) + max(lats)) / 2, "lon": (min(lons) + max(lons)) / 2},
            })

    # A second pass, once the network is known, for the nodes: a station at the bbox
    # edge or a junction tagged only with a name keeps its tags, as from Overpass.
    for obj in osmium.FileProcessor(str(path)):
        if not obj.is_node() or not obj.location.valid():
            continue
        tags = {tag.k: tag.v for tag in obj.tags}
        lon, lat = obj.location.lon, obj.location.lat
        if obj.id in network_refs or (tags and inside(lon, lat) and point_of_interest(tags)):
            element = {"type": "node", "id": obj.id, "lat": lat, "lon": lon}
            if tags:
                element["tags"] = tags
            elements.append(element)

    return {"source": "pbf", "osm_base_at": None, "elements": normalize_elements(elements)}
