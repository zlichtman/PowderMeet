"""Official trail and lift names for resorts in the MtnPowder feed (Alterra and
others). One JSON feed carries every resort, so it is cached for an hour and a
batch of resorts costs one download.

The names are the ones the `mtnpowder` status provider reports, so they become
both the official inventory and the `mtnpowder` status aliases. Which feed entries
make up a resort is written in `resorts.yaml` (`official.names`): summer, forecast
and combined entries in the feed are never substitutes.
"""

from __future__ import annotations

import json
import time
from pathlib import Path
from urllib.request import Request, urlopen

FEED_URL = "https://mtnpowder.com/feed/"
USER_AGENT = "powdermeet-pipeline/1.0 (+https://powdermeet.app)"
FEED_MAX_AGE_S = 3600

# TrailIcon -> bundle difficulty. An icon missing here is not a winter run.
_ICONS = {
    "greencircle": "green",
    "bluesquare": "blue",
    "bluebluesquare": "blue",
    "blueblacksquare": "black",
    "blackdiamond": "black",
    "doubleblackdiamond": "double_black",
    "extremeterrain": "double_black",
    "park": "park",
    "halfpipe": "park",
    "glades": None,
}


def fetch(names: list[str], cache_dir: Path) -> dict:
    return parse(_feed(cache_dir), names)


def parse(feed: dict, names: list[str]) -> dict:
    resorts = feed.get("Resorts") if isinstance(feed, dict) else None
    if not isinstance(resorts, list):
        raise ValueError("malformed MtnPowder feed")
    # Keyed on name and difficulty: two runs called alike in different areas
    # keep both values, so reconcile sees the disagreement instead of the first.
    trails: dict[tuple[str, str], dict] = {}
    lifts: dict[str, dict] = {}
    for expected in names:
        matches = [r for r in resorts if isinstance(r, dict) and _text(r.get("Name")) == expected]
        if len(matches) != 1:
            raise ValueError(f"missing or ambiguous MtnPowder resort: {expected}")
        for area in matches[0].get("MountainAreas") or []:
            for trail in area.get("Trails") or []:
                icon = _text(trail.get("TrailIcon")).lower()
                name = _text(trail.get("Name"))
                if not name or icon not in _ICONS or _text(trail.get("Nordic")).lower() == "yes":
                    continue
                entry = {"name": name}
                if _ICONS[icon]:
                    entry["difficulty"] = _ICONS[icon]
                trails.setdefault((name, entry.get("difficulty", "")), entry)
            for lift in area.get("Lifts") or []:
                name = _text(lift.get("Name"))
                if name:
                    lifts.setdefault(name, {"name": name})
    if not trails or not lifts:
        raise ValueError("MtnPowder entry lists no winter trails or no lifts")
    return {
        "trails": [trails[key] for key in sorted(trails)],
        "lifts": [lifts[name] for name in sorted(lifts)],
    }


def _feed(cache_dir: Path) -> dict:
    path = Path(cache_dir) / "mtnpowder" / "feed.json"
    if not path.exists() or time.time() - path.stat().st_mtime > FEED_MAX_AGE_S:
        request = Request(FEED_URL, headers={"User-Agent": USER_AGENT, "Accept": "application/json"})
        with urlopen(request, timeout=60) as response:
            body = response.read()
        json.loads(body)  # refuse to cache something that is not JSON
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(body)
    return json.loads(path.read_text())


def _text(value) -> str:
    return value.strip() if isinstance(value, str) else ""
