#!/usr/bin/env python3
"""
import_topsheets.py — One-shot importer for licensed ski topsheet PNGs.

Usage:
    python3 Tools/import_topsheets.py <source-dir>

Source-dir layout:
    Each PNG is named <brand-slug>-<model-slug>.png and matches an entry
    in `skis_catalog` by brand + model. Slugs are produced by lowercasing
    and replacing whitespace + punctuation with hyphens. Examples:
        atomic-bent-110.png         -> Atomic Bent 110
        black-crows-atris.png       -> Black Crows Atris
        volkl-m6-mantra.png         -> Volkl M6 Mantra
        k2-mindbender-99ti.png      -> K2 Mindbender 99Ti

Outputs:
    - PowderMeet/Resources/SkisTopsheets.xcassets/<slug>.imageset/<slug>.png
      (one image set per source PNG, normalized to 1280x200 PNG with alpha)
    - PowderMeet/Resources/SkisTopsheets.xcassets/<slug>.imageset/Contents.json
    - Tools/topsheet_keys.sql
      (SQL upsert script — paste into Supabase SQL editor or pipe to
       `supabase db push --include-seeds` to populate topsheet_asset_key
       on the matching catalog rows)

Requirements:
    pip install Pillow
"""
from __future__ import annotations

import json
import os
import re
import sys
from pathlib import Path

try:
    from PIL import Image
except ImportError:
    print("Pillow not installed. Run: pip install Pillow")
    sys.exit(1)


# Hardcoded slug -> (brand, model) mapping for the 66 seeded catalog
# rows. Drives the SQL output: each successfully-imported PNG produces
# an UPDATE on the matching brand+model row. Single source of truth so
# we don\'t need DB credentials to wire up topsheet_asset_key values.
CATALOG: dict[str, tuple[str, str]] = {
    "atomic-bent-110":            ("Atomic",      "Bent 110"),
    "atomic-bent-100":            ("Atomic",      "Bent 100"),
    "atomic-bent-90":             ("Atomic",      "Bent 90"),
    "atomic-maverick-95-ti":      ("Atomic",      "Maverick 95 Ti"),
    "atomic-redster-g9-rvsk-s":   ("Atomic",      "Redster G9 RVSK S"),
    "black-crows-atris":          ("Black Crows", "Atris"),
    "black-crows-camox":          ("Black Crows", "Camox"),
    "black-crows-daemon":         ("Black Crows", "Daemon"),
    "black-crows-anima":          ("Black Crows", "Anima"),
    "faction-prodigy-3":          ("Faction",     "Prodigy 3"),
    "faction-mana-4":             ("Faction",     "Mana 4"),
    "faction-dancer-3":           ("Faction",     "Dancer 3"),
    "rossignol-soul-7-hd":        ("Rossignol",   "Soul 7 HD"),
    "rossignol-sender-104-ti":    ("Rossignol",   "Sender 104 Ti"),
    "rossignol-experience-86-ti": ("Rossignol",   "Experience 86 Ti"),
    "rossignol-black-ops-sender": ("Rossignol",   "Black Ops Sender"),
    "k2-mindbender-99ti":         ("K2",          "Mindbender 99Ti"),
    "k2-mindbender-108ti":        ("K2",          "Mindbender 108Ti"),
    "k2-disruption-82ti":         ("K2",          "Disruption 82Ti"),
    "salomon-qst-106":            ("Salomon",     "QST 106"),
    "salomon-qst-98":             ("Salomon",     "QST 98"),
    "salomon-stance-96":          ("Salomon",     "Stance 96"),
    "salomon-s-force-bold":       ("Salomon",     "S/Force Bold"),
    "volkl-m6-mantra":            ("Volkl",       "M6 Mantra"),
    "volkl-blaze-106":            ("Volkl",       "Blaze 106"),
    "volkl-kendo-88":             ("Volkl",       "Kendo 88"),
    "volkl-revolt-95":            ("Volkl",       "Revolt 95"),
    "nordica-enforcer-100":       ("Nordica",     "Enforcer 100"),
    "nordica-enforcer-110":       ("Nordica",     "Enforcer 110"),
    "nordica-santa-ana-98":       ("Nordica",     "Santa Ana 98"),
    "head-kore-99":               ("Head",        "Kore 99"),
    "head-kore-105":              ("Head",        "Kore 105"),
    "head-supershape-e-magnum":   ("Head",        "Supershape e-Magnum"),
    "blizzard-bonafide-97":       ("Blizzard",    "Bonafide 97"),
    "blizzard-rustler-10":        ("Blizzard",    "Rustler 10"),
    "blizzard-hustle-10":         ("Blizzard",    "Hustle 10"),
    "blizzard-black-pearl-88":    ("Blizzard",    "Black Pearl 88"),
    "dps-pagoda-100-rp":          ("DPS",         "Pagoda 100 RP"),
    "dps-pagoda-tour-112":        ("DPS",         "Pagoda Tour 112"),
    "dps-wailer-a112":            ("DPS",         "Wailer A112"),
    "armada-arv-100":             ("Armada",      "ARV 100"),
    "armada-arv-116-jj":          ("Armada",      "ARV 116 JJ"),
    "armada-declivity-102-ti":    ("Armada",      "Declivity 102 Ti"),
    "line-sakana":                ("Line",        "Sakana"),
    "line-blade-optic-96":        ("Line",        "Blade Optic 96"),
    "line-pandora-99":            ("Line",        "Pandora 99"),
    "stockli-stormrider-102":     ("Stockli",     "Stormrider 102"),
    "stockli-stormrider-88":      ("Stockli",     "Stormrider 88"),
    "stockli-laser-ax":           ("Stockli",     "Laser AX"),
    "on3p-wrenegade-108":         ("ON3P",        "Wrenegade 108"),
    "on3p-woodsman-108":          ("ON3P",        "Woodsman 108"),
    "dynastar-m-pro-99":          ("Dynastar",    "M-Pro 99"),
    "dynastar-m-free-108":        ("Dynastar",    "M-Free 108"),
    "fischer-ranger-102":         ("Fischer",     "Ranger 102"),
    "fischer-rc4":                ("Fischer",     "RC4"),
    "elan-ripstick-96":           ("Elan",        "Ripstick 96"),
    "elan-ripstick-106":          ("Elan",        "Ripstick 106"),
    "moment-wildcat":             ("Moment",      "Wildcat"),
    "moment-deathwish":           ("Moment",      "Deathwish"),
    "j-skis-masterblaster":       ("J Skis",      "Masterblaster"),
    "j-skis-friend":              ("J Skis",      "Friend"),
    "icelantic-nomad-105":        ("Icelantic",   "Nomad 105"),
    "icelantic-pioneer-109":      ("Icelantic",   "Pioneer 109"),
    "voile-hypervector-bc":       ("Voile",       "HyperVector BC"),
    "black-diamond-helio-carbon-95": ("Black Diamond", "Helio Carbon 95"),
    # 20260515 — variants pass: 30 commonly-owned widths added to skis_catalog.
    "atomic-bent-85":              ("Atomic",     "Bent 85"),
    "atomic-bent-120":             ("Atomic",     "Bent 120"),
    "atomic-maverick-88-ti":       ("Atomic",     "Maverick 88 Ti"),
    "atomic-maverick-100-ti":      ("Atomic",     "Maverick 100 Ti"),
    "salomon-qst-92":              ("Salomon",    "QST 92"),
    "salomon-qst-99":              ("Salomon",    "QST 99"),
    "salomon-stance-102":          ("Salomon",    "Stance 102"),
    "rossignol-sender-94-ti":      ("Rossignol",  "Sender 94 Ti"),
    "rossignol-sender-90-pro":     ("Rossignol",  "Sender 90 Pro"),
    "rossignol-experience-82-basalt": ("Rossignol", "Experience 82 Basalt"),
    "k2-mindbender-89ti":          ("K2",         "Mindbender 89Ti"),
    "k2-mindbender-96c":           ("K2",         "Mindbender 96C"),
    "volkl-blaze-94":              ("Volkl",      "Blaze 94"),
    "nordica-enforcer-94":         ("Nordica",    "Enforcer 94"),
    "nordica-enforcer-104":        ("Nordica",    "Enforcer 104"),
    "nordica-santa-ana-93":        ("Nordica",    "Santa Ana 93"),
    "head-kore-93":                ("Head",       "Kore 93"),
    "head-kore-87":                ("Head",       "Kore 87"),
    "blizzard-rustler-9":          ("Blizzard",   "Rustler 9"),
    "blizzard-hustle-9":           ("Blizzard",   "Hustle 9"),
    "blizzard-black-pearl-97":     ("Blizzard",   "Black Pearl 97"),
    "armada-arv-94":               ("Armada",     "ARV 94"),
    "armada-arv-88":               ("Armada",     "ARV 88"),
    "faction-prodigy-2":           ("Faction",    "Prodigy 2"),
    "faction-prodigy-4":           ("Faction",    "Prodigy 4"),
    "faction-dancer-2":            ("Faction",    "Dancer 2"),
    "elan-ripstick-88":            ("Elan",       "Ripstick 88"),
    "line-pandora-94":             ("Line",       "Pandora 94"),
    "fischer-ranger-96":           ("Fischer",    "Ranger 96"),
    "dynastar-m-free-99":          ("Dynastar",   "M-Free 99"),
}


TARGET_W = 1280
TARGET_H = 200


def slugify(brand: str, model: str) -> str:
    """Match the slug produced by the CATALOG keys above."""
    raw = f"{brand} {model}".lower()
    raw = re.sub(r"[^a-z0-9]+", "-", raw)
    return raw.strip("-")


def assets_dir() -> Path:
    here = Path(__file__).resolve().parent.parent
    return here / "PowderMeet" / "Resources" / "SkisTopsheets.xcassets"


def normalize(src: Path, dst_imageset: Path, slug: str) -> None:
    """Letterbox-fit the source PNG into the TARGET_W x TARGET_H canvas.
    Earlier versions cropped to fill, which sliced the distinguishing
    tip rocker / tail kick off whenever the source aspect didn't match
    6.4:1 exactly. Now we fit whichever dimension is the binding
    constraint and transparent-pad the other so the full ski profile
    is preserved end-to-end."""
    img = Image.open(src).convert("RGBA")
    w, h = img.size
    target_aspect = TARGET_W / TARGET_H  # 6.4
    src_aspect = w / max(h, 1)
    if src_aspect >= target_aspect:
        new_w = TARGET_W
        new_h = max(1, round(TARGET_W / src_aspect))
    else:
        new_h = TARGET_H
        new_w = max(1, round(TARGET_H * src_aspect))
    img = img.resize((new_w, new_h), Image.LANCZOS)
    canvas = Image.new("RGBA", (TARGET_W, TARGET_H), (0, 0, 0, 0))
    cx = (TARGET_W - new_w) // 2
    cy = (TARGET_H - new_h) // 2
    canvas.paste(img, (cx, cy), img)
    dst_imageset.mkdir(parents=True, exist_ok=True)
    out_png = dst_imageset / f"{slug}.png"
    canvas.save(out_png, format="PNG", optimize=True)

    contents = {
        "images": [
            {"idiom": "universal", "filename": f"{slug}.png", "scale": "1x"},
        ],
        "info": {"author": "xcode", "version": 1},
    }
    (dst_imageset / "Contents.json").write_text(
        json.dumps(contents, indent=2) + "\n"
    )


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        print(__doc__)
        return 1
    source_dir = Path(argv[1]).expanduser().resolve()
    if not source_dir.is_dir():
        print(f"source-dir not a directory: {source_dir}")
        return 1

    out_assets = assets_dir()
    out_assets.mkdir(parents=True, exist_ok=True)

    sql_lines = [
        "-- Generated by Tools/import_topsheets.py.",
        "-- Apply via Supabase SQL editor or `supabase db push`.",
        "",
    ]
    imported = 0
    skipped: list[str] = []

    for png in sorted(source_dir.glob("*.png")):
        slug = png.stem.lower()
        if slug not in CATALOG:
            skipped.append(png.name)
            continue
        brand, model = CATALOG[slug]
        imageset = out_assets / f"{slug}.imageset"
        normalize(png, imageset, slug)
        # Single-quote-escape brand and model for SQL safety.
        sb = brand.replace("\'", "\'\'")
        sm = model.replace("\'", "\'\'")
        sql_lines.append(
            f"update public.skis_catalog set topsheet_asset_key = \'{slug}\' "
            f"where brand = \'{sb}\' and model = \'{sm}\';"
        )
        imported += 1

    sql_path = Path(__file__).resolve().parent / "topsheet_keys.sql"
    sql_path.write_text("\n".join(sql_lines) + "\n")

    print(f"Imported {imported} topsheet(s) into {out_assets}")
    if skipped:
        print(f"Skipped {len(skipped)} unrecognized file(s):")
        for name in skipped:
            print(f"  {name}")
        print("(Filename must match a catalog slug — see CATALOG in this script.)")
    print(f"SQL upsert script: {sql_path}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
