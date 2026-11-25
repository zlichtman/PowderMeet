"""Status aliases for lifts whose official name is not the mapped name.

The status feeds and the map name the same chair differently: Epic says
"Stella Express" where OSM says "Stella", MtnPowder "Powderhorn II" where OSM
says "Powderhorn 2", Epic "Chateau Carpet - Blackcomb" where OSM says "Chateau
Carpet", OSM "Apollo #27" for Epic's "Apollo". A resort can only show live lift
status when every lift group has its provider's name, so these are matched here.

Nothing is merged: the mapped identity keeps its name and group id, and the
official name is only added to the provider's `status_aliases`, verbatim, because
the status worker looks names up exactly. A wrong alias would show a closed lift
as open, so a match must be unambiguous on both sides: the key it is made on
belongs to exactly one lift group and exactly one official name, and no other
official name lands on the same group.
"""

from __future__ import annotations

import re
import unicodedata
from typing import Dict, Iterable, List, Tuple

# Words that say what kind of lift it is, not which one. Feeds and maps add or
# drop them freely ("Red Dog" / "Red Dog Express", "Rendezvous" / "Rendezvous Triple").
LIFT_TYPE_WORDS = frozenset({
    "express", "xpress", "lift", "chair", "chairlift", "chairlifts", "quad", "triple",
    "double", "six", "sixpack", "pack", "eight", "detachable", "platter", "poma",
    "gondola", "telecabine", "cabriolet", "tram", "tramway", "aerial", "funitel",
    "funicular", "carpet", "conveyor", "tow", "rope", "surface", "magic", "tapis",
    "magique", "telesiege", "teleski", "telemix", "sesselbahn", "sessellift",
    "schlepplift", "gondelbahn", "kabinenbahn", "seilbahn", "bahn", "tbar", "jbar",
})
ARTICLES = frozenset({"the", "le", "la", "les", "l", "der", "die", "das"})
ROMAN = {"i": "1", "ii": "2", "iii": "3", "iv": "4", "v": "5", "vi": "6"}
# Spellings feeds and maps swap: "High 5" / "High Five", "BC Mtn" / "Mountain",
# "Hi-Lonesome" / "High Lonesome".
SPELLINGS = {
    # "six" and "eight" stay lift-type words (a six-pack, an eight-seat gondola).
    "one": "1", "two": "2", "three": "3", "four": "4", "five": "5",
    "seven": "7", "nine": "9", "ten": "10",
    "mtn": "mountain", "mt": "mount", "hi": "high",
}
MIN_LETTERS = 3
"""A key with fewer letters than this ("1", "t2") says too little to match on."""


def _tokens(name: str) -> List[str]:
    folded = unicodedata.normalize("NFKD", name).encode("ascii", "ignore").decode("ascii").lower()
    folded = folded.replace("&", " and ")
    # "Apollo #27", "Lift No. 5": a number the map or the feed adds as a label.
    folded = re.sub(r"(#|\bno\.)\s*\d+", " ", folded)
    folded = re.sub(r"\b([tj])[\s-]*bar\b", r"\1bar", folded)  # "T-Bar", "T Bar"
    words = [SPELLINGS.get(w, w) for w in re.findall(r"[a-z0-9]+", folded)]
    if len(words) > 1 and words[-1] in ROMAN:
        words[-1] = ROMAN[words[-1]]
    # "High Speed Quad" as a whole; "High Lonesome" keeps its "high".
    out: List[str] = []
    for index, word in enumerate(words):
        if word == "high" and index + 1 < len(words) and words[index + 1] == "speed":
            continue
        if word == "speed" and index > 0 and words[index - 1] == "high":
            continue
        out.append(word)
    while out and out[0] in ARTICLES:
        out = out[1:]
    return out


def _key(words: Iterable[str]) -> str | None:
    key = "".join(words)
    return key if sum(ch.isalpha() for ch in key) >= MIN_LETTERS else None


def keys(name: str, resort_words: frozenset) -> List[str]:
    """Match keys from the most to the least specific: without the resort's own
    name ("Heavenly Gondola" -> "gondola"), then also without lift-type words."""
    tokens = _tokens(name)
    words = [w for w in tokens if w not in resort_words] or tokens
    typeless = [w for w in words if w not in LIFT_TYPE_WORDS]
    # Then without a trailing lift number ("Broadway Express 1" at Mammoth);
    # when two lifts differ only by it, the key names both and matches neither.
    unnumbered = typeless[:-1] if len(typeless) > 1 and typeless[-1].isdigit() else typeless
    # "Wildcat Express" at Wildcat: without the resort's name only a lift-type
    # word is left, so last comes the whole name without lift-type words.
    whole = [w for w in tokens if w not in LIFT_TYPE_WORDS] if not typeless else []
    found = []
    for key in (_key(words), _key(typeless), _key(unnumbered), _key(whole)):
        if key and key not in found:
            found.append(key)
    return found


def variants(name: str) -> List[str]:
    """The name, then without each trailing " - qualifier" Epic appends
    ("Creekside Carpet - Whistler - Whistler Kids Only")."""
    parts = re.split(r"\s+[-–]\s*", name.strip())
    return [" - ".join(parts[:end]) for end in range(len(parts), 0, -1)]


def resort_words(resort_name: str) -> frozenset:
    words = [w for w in _tokens(resort_name) if len(w) >= 3 and w not in LIFT_TYPE_WORDS]
    # Feeds abbreviate the resort to its initials: "Lower BC Mtn Express".
    initials = "".join(w[0] for w in words) if len(words) >= 2 else ""
    return frozenset(words + ([initials] if initials else []))


def match_lifts(
    official_names: List[str], groups: Dict[str, List[str]], aliased: Dict[str, str],
    resort_name: str,
) -> List[Tuple[str, str, str]]:
    """(official name, group id, key) for each official lift name that is not yet
    an alias and matches exactly one lift group without one.

    `groups` is group id -> the names the map uses for it; `aliased` is the
    provider's aliases so far (official name -> group id).
    """
    own = resort_words(resort_name)
    by_key: Dict[str, set] = {}
    for group_id, names in groups.items():
        for name in names:
            for key in keys(name, own):
                by_key.setdefault(key, set()).add(group_id)
    official_by_key: Dict[str, set] = {}
    for official in official_names:
        for variant in variants(official):
            for key in keys(variant, own):
                official_by_key.setdefault(key, set()).add(official)

    taken = set(aliased.values())
    chosen: Dict[str, Tuple[str, str]] = {}
    for official in sorted(set(official_names)):
        if official in aliased:
            continue
        for variant in variants(official):
            hit = None
            for key in keys(variant, own):
                owners = by_key.get(key, set())
                if len(owners) == 1 and official_by_key.get(key) == {official}:
                    hit = (next(iter(owners)), key)
                    break
                if owners:
                    break  # the key names several lifts: a looser one would guess
            if hit:
                if hit[0] not in taken:
                    chosen[official] = hit
                break
    claims: Dict[str, int] = {}
    for group_id, _ in chosen.values():
        claims[group_id] = claims.get(group_id, 0) + 1
    return sorted(
        (official, group_id, key) for official, (group_id, key) in chosen.items() if claims[group_id] == 1
    )
