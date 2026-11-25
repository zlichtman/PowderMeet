"""Official trail and lift names for Epic resorts.

Epic's terrain page embeds `FR.TerrainStatusFeed = {...}` with every lift and trail
the resort publishes. Those names are the ones the status provider reports, so they
become both the official inventory and the `epic` status aliases.

The page is behind bot protection that refuses some networks. When the request is
refused the caller freezes the extract without an official list, or the reviewer
saves the page from a browser and passes it with `--official-html`.
"""

from __future__ import annotations

import json
from urllib.error import HTTPError
from urllib.request import Request, urlopen

USER_AGENT = "powdermeet-pipeline/1.0 (+https://powdermeet.app)"
MARKER = "FR.TerrainStatusFeed"
# Epic sites name the page either way round, and some answer only to one of
# them (aftonalps.com, okemo.com and others 404 on the first).
PAGE_SPELLINGS = ("terrain-and-lift-status.aspx", "lift-and-terrain-status.aspx")

_DIFFICULTY = {
    "green": "green", "easiest": "green", "beginner": "green",
    "blue": "blue", "moredifficult": "blue", "intermediate": "blue",
    "black": "black", "mostdifficult": "black", "advanced": "black",
    "doubleblack": "double_black", "expert": "double_black", "extreme": "double_black",
    "terrainpark": "park", "park": "park",
}


def candidate_urls(url: str) -> list[str]:
    """The catalog URL, then the same page under the other spelling."""
    urls = [url]
    for spelling, other in (PAGE_SPELLINGS, PAGE_SPELLINGS[::-1]):
        if url.endswith(spelling):
            urls.append(url[: -len(spelling)] + other)
    return urls


def fetch(url: str, opener=urlopen) -> dict:
    last: HTTPError | None = None
    for candidate in candidate_urls(url):
        request = Request(candidate, headers={"User-Agent": USER_AGENT, "Accept": "text/html"})
        try:
            with opener(request, timeout=30) as response:
                html = response.read().decode("utf-8", "replace")
        except HTTPError as error:
            if error.code != 404:
                raise
            last = error
            continue
        return parse(html)
    raise last  # type: ignore[misc]


def parse(html: str) -> dict:
    feeds = _assigned_objects(html, MARKER)
    if not feeds:
        raise ValueError("Epic terrain feed assignment was not found")
    feed = feeds[-1]
    areas = feed.get("GroomingAreas")
    if not isinstance(areas, list):
        raise ValueError("Epic terrain feed has no GroomingAreas array")
    # Keyed on name and difficulty: two runs called alike in different areas
    # keep both values, so reconcile sees the disagreement instead of the first.
    trails: dict[tuple[str, str], dict] = {}
    lifts: dict[str, dict] = {}
    for area in areas:
        if not isinstance(area, dict):
            continue
        for trail in area.get("Trails") or []:
            name = _text(trail.get("Name"))
            if name and _is_winter(trail.get("TrailType")):
                entry = {"name": name}
                difficulty = _DIFFICULTY.get(_key(trail.get("Difficulty")))
                if difficulty:
                    entry["difficulty"] = difficulty
                trails.setdefault((name, entry.get("difficulty", "")), entry)
        for lift in area.get("Lifts") or []:
            name = _text(lift.get("Name"))
            if name:
                lifts.setdefault(name, {"name": name})
    # Before opening day a page often lists the lifts but no winter trails. The
    # lift names are the ones the status feed will report, so they are kept.
    if not trails and not lifts:
        raise ValueError("Epic terrain feed lists no winter trails or lifts (off-season page)")
    return {
        "trails": [trails[key] for key in sorted(trails)],
        "lifts": [lifts[name] for name in sorted(lifts)],
    }


def _assigned_objects(html: str, marker: str) -> list[dict]:
    found = []
    index = 0
    while True:
        index = html.find(marker, index)
        if index < 0:
            return found
        start = html.find("{", index)
        equals = html.find("=", index)
        index += len(marker)
        if start < 0 or equals < 0 or equals > start:
            continue
        end = _object_end(html, start)
        if end < 0:
            continue
        try:
            value = json.loads(html[start:end])
        except ValueError:
            continue
        if isinstance(value, dict):
            found.append(value)


def _object_end(text: str, start: int) -> int:
    depth, in_string, escaped = 0, False, False
    for position in range(start, len(text)):
        character = text[position]
        if in_string:
            if escaped:
                escaped = False
            elif character == "\\":
                escaped = True
            elif character == '"':
                in_string = False
        elif character == '"':
            in_string = True
        elif character == "{":
            depth += 1
        elif character == "}":
            depth -= 1
            if depth == 0:
                return position + 1
    return -1


def _is_winter(value) -> bool:
    return value == 1 or (isinstance(value, str) and value.strip().lower() in ("skiing", "ski"))


def _text(value) -> str:
    return value.strip() if isinstance(value, str) else ""


def _key(value) -> str:
    return "".join(ch for ch in str(value or "").lower() if ch.isalnum())
