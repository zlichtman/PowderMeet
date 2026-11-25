"""extract: fetch every source once and freeze it in one file.

The frozen file holds the OSM features, the OpenSkiMap features, the official
lists and the elevation of every node the network references. Reconcile and build
read only this file, so both are pure functions of it and never touch the network.
"""

from __future__ import annotations

import hashlib
import json
import sys
from datetime import datetime, timezone
from pathlib import Path

from . import catalog
from .dem import TerrariumDEM
from .sources import official_epic, official_mtnpowder, openskimap, overpass


def run(
    resort_id: str,
    *,
    date: str | None = None,
    pbf: Path | None = None,
    official_html: Path | None = None,
    now: datetime | None = None,
    ski_map: dict | None = None,
) -> tuple[str, Path]:
    resort = catalog.resort(resort_id)
    now = now or datetime.now(timezone.utc)
    fetched_at = now.strftime("%Y-%m-%dT%H:%M:%SZ")

    # OpenSkiMap first: it says which ski area sits in the catalog box and how far
    # that area really extends, which is the box OSM is then read for.
    ski_map = dict(ski_map or openskimap.fetch(resort["bbox"], catalog.cache_dir()))
    ski_map["fetched_at"] = fetched_at
    areas = choose_ski_areas(resort, ski_map)
    bbox = search_bbox(resort, ski_map, areas)
    # The ski area often reaches past the catalog box, and so does the OSM read.
    # OpenSkiMap is read again for that whole box, or a way out there would have
    # no ski area to its name and a neighbouring resort's lifts would be built.
    if not _within(bbox, _read_box(resort["bbox"])):
        ski_map = {**openskimap.fetch(bbox, catalog.cache_dir()), "fetched_at": fetched_at}
    ski_map["bbox"] = bbox

    if pbf:
        from .sources import pbf as pbf_source

        osm = pbf_source.fetch(pbf, bbox)
    else:
        osm = overpass.fetch(bbox, date)
    osm["fetched_at"] = f"{date}T00:00:00Z" if date else fetched_at

    document = {
        "schema": 1,
        "resort_id": resort_id,
        "bbox": bbox,
        "catalog_bbox": resort["bbox"],
        "ski_areas": areas,
        "osm": osm,
        "openskimap": ski_map,
        "official": _official(resort, official_html, fetched_at),
        "elevation": _elevation(resort, osm["elements"]),
    }
    return freeze(document)


_NAME_NOISE = frozenset({
    "ski", "resort", "mountain", "mountains", "mt", "mount", "area", "the", "and", "at",
    "of", "snow", "valley", "peak", "park", "basin", "alpine", "lake",
})
MAX_REACH_DEG = 0.25


def choose_ski_areas(resort: dict, ski_map: dict) -> list[str]:
    """The OpenSkiMap ski areas this catalog entry stands for: those in the catalog
    box whose name shares a distinctive word with the resort's, else the largest.
    Ways that belong only to other ski areas are then left out of the graph.
    A catalog entry may name its areas under `ski_areas` instead (two linked
    areas OpenSkiMap keeps apart, like Hakuba Goryu and Hakuba 47)."""
    if resort.get("ski_areas"):
        return sorted(str(area) for area in resort["ski_areas"])
    box = resort["bbox"]
    counts: dict[str, int] = {}
    for kind in ("runs", "lifts"):
        for feature in ski_map.get(kind) or []:
            extent = feature.get("extent")
            if feature.get("status") not in (None, "operating") or not extent:
                continue
            if kind == "runs" and "downhill" not in (feature.get("uses") or ["downhill"]):
                continue
            if extent[0] > box[2] or extent[2] < box[0] or extent[1] > box[3] or extent[3] < box[1]:
                continue
            for area in feature.get("ski_areas") or []:
                counts[area] = counts.get(area, 0) + 1
    if not counts:
        return []
    wanted = _name_words(resort["name"])
    largest = max(counts.values())
    shared = {
        area: wanted & _name_words(area) for area, count in counts.items()
        if wanted & _name_words(area) and count >= max(3, largest // 10)
    }
    # A word every Hakuba area carries ("hakuba") says nothing about which one
    # this is. When some area shares a word no other area does, only areas that
    # share such a word are kept.
    seen: dict[str, int] = {}
    for words in shared.values():
        for word in words:
            seen[word] = seen.get(word, 0) + 1
    distinctive = {area for area, words in shared.items() if any(seen[w] == 1 for w in words)}
    named = sorted(distinctive or shared)
    return named or [min(counts, key=lambda area: (-counts[area], area))]


def search_bbox(resort: dict, ski_map: dict, areas: list[str]) -> list[float]:
    """The extent of the chosen ski areas, a little padded; the catalog box when
    OpenSkiMap knows nothing here. Never more than MAX_REACH_DEG past the catalog box."""
    box = list(resort["bbox"])
    extents = [
        feature["extent"]
        for kind in ("runs", "lifts")
        for feature in ski_map.get(kind) or []
        if feature.get("extent") and set(feature.get("ski_areas") or ()) & set(areas)
    ]
    if not extents:
        return box
    pad = 0.003
    found = [
        min(e[0] for e in extents) - pad, min(e[1] for e in extents) - pad,
        max(e[2] for e in extents) + pad, max(e[3] for e in extents) + pad,
    ]
    return [
        round(max(found[0], box[0] - MAX_REACH_DEG), 5), round(max(found[1], box[1] - MAX_REACH_DEG), 5),
        round(min(found[2], box[2] + MAX_REACH_DEG), 5), round(min(found[3], box[3] + MAX_REACH_DEG), 5),
    ]


def _name_words(name: str) -> set[str]:
    import re
    import unicodedata

    folded = unicodedata.normalize("NFKD", name).encode("ascii", "ignore").decode("ascii").lower()
    # Letters and digits are separate words, so "Hakuba47" meets "Hakuba 47".
    return {word for word in re.findall(r"[a-z]+|[0-9]+", folded) if word not in _NAME_NOISE and len(word) > 1}


def _within(inner: list[float], outer: list[float]) -> bool:
    return inner[0] >= outer[0] and inner[1] >= outer[1] and inner[2] <= outer[2] and inner[3] <= outer[3]


def _read_box(box: list[float]) -> list[float]:
    """What an OpenSkiMap read for `box` covers: the box and the margin around it."""
    margin = openskimap.MARGIN_DEG
    return [box[0] - margin, box[1] - margin, box[2] + margin, box[3] + margin]


def freeze(document: dict) -> tuple[str, Path]:
    """Name the extract by its content and write it."""
    content = json.dumps(document, sort_keys=True, separators=(",", ":"), ensure_ascii=False)
    sha6 = hashlib.sha256(content.encode("utf-8")).hexdigest()[:6]
    stamp = document["osm"]["fetched_at"][:16] + "Z"
    extract_id = f"osm-{stamp}-{document['resort_id']}-{sha6}"
    path = catalog.extract_path(document["resort_id"], extract_id)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(
        json.dumps({"extract_id": extract_id, **document}, sort_keys=True,
                   separators=(",", ":"), ensure_ascii=False)
    )
    return extract_id, path


def load(resort_id: str, reference: str) -> dict:
    """`reference` is an extract id or a path to a frozen extract file."""
    path = Path(reference)
    if not path.is_file():
        path = catalog.extract_path(resort_id, reference)
    if not path.is_file():
        raise catalog.PipelineError(f"extract not found: {reference}")
    extract = json.loads(path.read_text())
    if extract.get("resort_id") != resort_id:
        raise catalog.PipelineError(
            f"extract {extract.get('extract_id')} is for {extract.get('resort_id')}, not {resort_id}"
        )
    return extract


def newest(resort_id: str) -> list[Path]:
    """The resort's frozen extracts, oldest first: by OSM time, then by when the
    official lists were fetched (a refreshed extract keeps its OSM time)."""
    def order(path: Path):
        try:
            frozen = json.loads(path.read_text())
        except (OSError, ValueError):
            return ("", "", path.name)
        official = frozen.get("official") or {}
        checked = official.get("checked_at") or official.get("fetched_at") or ""
        reread = (frozen.get("openskimap") or {}).get("fetched_at") or ""
        return (frozen.get("osm", {}).get("fetched_at") or "", max(checked, reread), path.name)

    return sorted((catalog.workdir() / "extract" / resort_id).glob("*.json"), key=order)


def refresh_official(resort_id: str, *, official_html: Path | None = None,
                     now: datetime | None = None) -> tuple[str, Path]:
    """Fetch only the official lists again and freeze them with the OSM,
    OpenSkiMap and elevation of the resort's latest extract. Epic pages fill in
    their lifts as each resort opens; this picks them up without Overpass."""
    found = newest(resort_id)
    if not found:
        raise catalog.PipelineError(f"no extract of {resort_id} to refresh; run extract first")
    previous = json.loads(found[-1].read_text())
    now = now or datetime.now(timezone.utc)
    document = {key: value for key, value in previous.items() if key != "extract_id"}
    document["official"] = _official(
        catalog.resort(resort_id), official_html, now.strftime("%Y-%m-%dT%H:%M:%SZ"))
    return freeze(document)


def openskimap_covers(frozen: dict) -> bool:
    """Whether the extract's OpenSkiMap features were read for its whole OSM box.
    Extracts frozen before 1.4.0 read them for the catalog box only."""
    read_for = (frozen.get("openskimap") or {}).get("bbox") or frozen.get("catalog_bbox")
    return bool(read_for) and _within(frozen["bbox"], _read_box(read_for))


def refresh_openskimap(resort_id: str, *, ski_map: dict | None = None,
                       now: datetime | None = None) -> tuple[str, Path]:
    """Read OpenSkiMap again for the whole box of the resort's latest extract and
    freeze it with that extract's OSM, official lists and elevation. This is how
    an extract whose OpenSkiMap features stop at the catalog box learns which ski
    area the ways beyond it belong to, without another Overpass request."""
    found = newest(resort_id)
    if not found:
        raise catalog.PipelineError(f"no extract of {resort_id} to refresh; run extract first")
    previous = json.loads(found[-1].read_text())
    now = now or datetime.now(timezone.utc)
    document = {key: value for key, value in previous.items() if key != "extract_id"}
    document["openskimap"] = {
        **(ski_map or openskimap.fetch(previous["bbox"], catalog.cache_dir())),
        "fetched_at": now.strftime("%Y-%m-%dT%H:%M:%SZ"), "bbox": previous["bbox"],
    }
    return freeze(document)


def _official(resort: dict, official_html: Path | None, fetched_at: str) -> dict:
    config = resort.get("official") or {}
    result = {
        "adapter": config.get("adapter"),
        "urls": list(config.get("urls") or []),
        "fetched_at": None,
        "error": None,
        "trails": [],
        "lifts": [],
    }
    if config.get("adapter") not in ("epic", "mtnpowder"):
        result["error"] = "no official adapter for this resort"
        return result
    # When the lists were last asked for, fetched or not: it orders an extract
    # whose lists were refreshed after a later one with the same OSM time.
    result["checked_at"] = fetched_at
    try:
        if config["adapter"] == "mtnpowder":
            lists = official_mtnpowder.fetch(list(config["names"]), catalog.cache_dir())
        elif official_html:
            lists = official_epic.parse(Path(official_html).read_text(errors="replace"))
        else:
            lists = official_epic.fetch(result["urls"][0])
    except Exception as error:  # the extract is still useful without the official list
        result["error"] = f"{type(error).__name__}: {error}"
        print(f"warning: official list unavailable ({result['error']})", file=sys.stderr)
        carried = _last_official(resort["resort_id"])
        if carried:
            print(f"warning: using the official list fetched {carried['fetched_at']} instead", file=sys.stderr)
            return {**carried, "fetch_error": result["error"], "checked_at": fetched_at}
        return result
    result.update(lists)
    result["fetched_at"] = fetched_at
    return result


def _last_official(resort_id: str) -> dict | None:
    """The newest official list an earlier extract of this resort holds, so that
    a page that is down or between seasons does not take the status aliases with
    it. Lifts and trails keep the time they were really fetched."""
    for path in reversed(newest(resort_id)):
        try:
            official = json.loads(path.read_text()).get("official") or {}
        except (OSError, ValueError):
            continue
        if official.get("fetched_at") and (official.get("lifts") or official.get("trails")):
            kept = {key: value for key, value in official.items() if key not in ("fetch_error", "checked_at")}
            return {**kept, "carried_from": kept.get("carried_from") or path.stem}
    return None


def _elevation(resort: dict, elements: list[dict]) -> dict:
    """Sample the DEM at every node a way references."""
    config = resort.get("dem") or {}
    if config.get("provider", "terrarium") != "terrarium":
        raise catalog.PipelineError("only the terrarium DEM provider is implemented")
    dem = TerrariumDEM(catalog.cache_dir() / "dem", zoom=int(config.get("zoom", 14)))
    referenced = {n for e in elements if e["type"] == "way" for n in e.get("nodes") or []}
    samples = {}
    for element in elements:
        if element["type"] == "node" and element["id"] in referenced and "lon" in element:
            samples[str(element["id"])] = round(dem.sample(element["lon"], element["lat"]), 1)
    return {"provider": "terrarium", "zoom": dem.zoom, "tiles": dem.tile_count, "samples": samples}
