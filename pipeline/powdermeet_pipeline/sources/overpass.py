"""OSM features for a resort bbox through Overpass.

Network ways (pistes and aerialways) come back with every node they reference, tags
included, so station and name tags on shared vertices survive. Points of interest
come back as tagged nodes or as way and relation centers, without geometry.
"""

from __future__ import annotations

import http.client
import json
import os
import time
from urllib.error import HTTPError, URLError
from urllib.parse import urlencode
from urllib.request import Request, urlopen

OVERPASS_URL = "https://overpass-api.de/api/interpreter"
# PM_OVERPASS_URL replaces it with one or more comma-separated instances, tried
# in turn. The public mirrors did not answer when tried, so none is tried by
# default.
USER_AGENT = "powdermeet-pipeline/1.0 (+https://powdermeet.app)"
REQUEST_TIMEOUT = 240
RETRY_WAITS_S = (30, 60, 120, 240, 300)
"""Pause before each further attempt; a busy instance needs minutes, not seconds."""

POI_AMENITIES = "restaurant|cafe|fast_food|bar|pub|toilets|shelter|first_aid|ski_school"
POI_TOURISM = "alpine_hut|wilderness_hut|viewpoint|information"


def build_query(bbox, date: str | None = None) -> str:
    """`bbox` is [minLon, minLat, maxLon, maxLat]; Overpass wants (south, west, north, east)."""
    min_lon, min_lat, max_lon, max_lat = bbox
    box = f"({min_lat},{min_lon},{max_lat},{max_lon})"
    header = "[out:json][timeout:180]"
    if date:
        header += f'[date:"{date}T00:00:00Z"]'
    return f"""{header};
(
  way["piste:type"]{box};
  way["aerialway"]{box};
)->.network;
.network out body qt;
.network >;
out body qt;
(
  node["aerialway"]{box};
  node["natural"="peak"]{box};
  node["amenity"~"^({POI_AMENITIES})$"]{box};
  node["tourism"~"^({POI_TOURISM})$"]{box};
)->.points;
.points out body qt;
(
  way["amenity"~"^({POI_AMENITIES})$"]{box};
  relation["amenity"~"^({POI_AMENITIES})$"]{box};
  way["tourism"~"^({POI_TOURISM})$"]{box};
  way["building"]["name"]{box};
  way["landuse"="winter_sports"]{box};
  relation["landuse"="winter_sports"]{box};
)->.areas;
.areas out tags center qt;
"""


def fetch(bbox, date: str | None = None) -> dict:
    data = _post(build_query(bbox, date))
    return {
        "source": "overpass",
        "osm_base_at": (data.get("osm3s") or {}).get("timestamp_osm_base"),
        "elements": normalize_elements(data.get("elements") or []),
    }


def normalize_elements(elements: list[dict]) -> list[dict]:
    """One entry per (type, id), in a fixed order, so the freeze does not depend on
    the order Overpass happened to answer in."""
    by_key: dict[tuple[str, int], dict] = {}
    for element in elements:
        kind, identifier = element.get("type"), element.get("id")
        if kind not in ("node", "way", "relation") or identifier is None:
            continue
        key = (kind, int(identifier))
        kept = by_key.setdefault(key, {"type": kind, "id": int(identifier)})
        for field in ("lat", "lon", "nodes", "center"):
            if field in element and field not in kept:
                kept[field] = element[field]
        if element.get("tags"):
            kept["tags"] = dict(sorted(element["tags"].items()))
    return [by_key[key] for key in sorted(by_key)]


def endpoints() -> list[str]:
    configured = [u.strip() for u in os.environ.get("PM_OVERPASS_URL", "").split(",") if u.strip()]
    return configured or [OVERPASS_URL]


def _post(query: str, waits=RETRY_WAITS_S, sleep=time.sleep, opener=urlopen) -> dict:
    """POST the query, retrying transient failures with growing pauses and
    alternating between the instances. A 400 is a bad query and is not retried."""
    body = urlencode({"data": query}).encode()
    urls = endpoints()
    errors: list[str] = []
    for attempt in range(len(waits) + 1):
        url = urls[attempt % len(urls)]
        request = Request(
            url,
            data=body,
            headers={
                "User-Agent": USER_AGENT,
                "Content-Type": "application/x-www-form-urlencoded",
            },
        )
        try:
            with opener(request, timeout=REQUEST_TIMEOUT) as response:
                data = json.loads(response.read())
        except HTTPError as error:
            if error.code == 400:
                raise RuntimeError(f"Overpass refused the query: HTTP 400 from {url}") from error
            errors.append(f"HTTP {error.code}")
        # A dropped connection (RemoteDisconnected) is an HTTPException, a reset
        # an OSError; both are the server being busy, not the query being wrong.
        except (URLError, OSError, http.client.HTTPException, ValueError) as error:
            errors.append(f"{type(error).__name__}: {error}")
        else:
            # A query that timed out or ran out of memory still answers 200, with
            # only some of the elements; frozen, it would be reused as complete.
            remark = str(data.get("remark") or "")
            if "runtime error" not in remark.lower():
                return data
            errors.append(f"incomplete answer: {remark}")
        if attempt < len(waits):
            sleep(waits[attempt])
    raise RuntimeError(f"Overpass failed {len(errors)} times: " + "; ".join(errors))
