#!/usr/bin/env python3
"""
scrape_topsheets.py — Build ski topsheet PNGs from operator-supplied URLs.

Two modes:

    --from-urls   Read tools/topsheet_urls.tsv (slug<TAB>url) and
                  download each. NO image-search step. URLs are operator-
                  curated (browser → right-click → copy image address).
                  Recommended path; bypasses search-engine rate limits.

    (default)     DuckDuckGo image-search per slug. Heavily rate-limited
                  in practice; works for a handful of slugs at a time.

Either mode runs the same processing pipeline on whatever bytes come back:
    1. Cache raw to ~/topsheet-source/raw/<slug>.<ext>
    2. rembg → alpha-cut
    3. Auto-rotate so long-axis is horizontal
    4. De-pair: detect "two skis stacked" via row groups, keep the largest
    5. Crop tight to bbox of opaque pixels
    6. Resize-to-fit-height (200px); center-crop or pad to 1280x200
    7. Save ~/topsheet-source/processed/<slug>.png

Then run `python3 tools/import_topsheets.py ~/topsheet-source/processed`
to fold the PNGs into the asset catalog and emit topsheet_keys.sql.

Usage:
    python3 tools/scrape_topsheets.py --init-urls       # scaffold TSV
    python3 tools/scrape_topsheets.py --from-urls       # download from TSV
    python3 tools/scrape_topsheets.py --reprocess       # redo rembg+crop
                                                        # from raw cache
    python3 tools/scrape_topsheets.py --slug atomic-bent-110 --from-urls
                                                        # single slug
    python3 tools/scrape_topsheets.py --limit 3         # DDG smoke test

Rerun-safe: skips slugs whose processed PNG already exists.

Source images come from operator-curated public URLs (or web image search
in DDG mode). Review each output before bundling. Distribution rights are
the operator's responsibility.
"""
from __future__ import annotations

import argparse
import sys
import time
from io import BytesIO
from pathlib import Path

try:
    import requests
    from PIL import Image, ImageOps
    from rembg import remove
except ImportError as exc:
    print(f"missing dep: {exc}. install via:")
    print("  pip install requests pillow rembg onnxruntime")
    sys.exit(1)

try:
    from duckduckgo_search import DDGS  # type: ignore
except ImportError:
    DDGS = None  # type: ignore  # only needed in DDG mode


SKIS: dict[str, str] = {
    # Atomic
    "atomic-bent-110":            "Atomic Bent 110 ski topsheet 2024",
    "atomic-bent-100":            "Atomic Bent 100 ski topsheet 2024",
    "atomic-bent-90":             "Atomic Bent 90 ski topsheet 2024",
    "atomic-maverick-95-ti":      "Atomic Maverick 95 Ti ski topsheet",
    "atomic-redster-g9-rvsk-s":   "Atomic Redster G9 RVSK ski topsheet",
    # Black Crows
    "black-crows-atris":          "Black Crows Atris ski topsheet",
    "black-crows-camox":          "Black Crows Camox ski topsheet",
    "black-crows-daemon":         "Black Crows Daemon ski topsheet",
    "black-crows-anima":          "Black Crows Anima ski topsheet",
    # Faction
    "faction-prodigy-3":          "Faction Prodigy 3 ski topsheet",
    "faction-mana-4":             "Faction Mana 4 ski topsheet",
    "faction-dancer-3":           "Faction Dancer 3 ski topsheet",
    # Rossignol
    "rossignol-soul-7-hd":        "Rossignol Soul 7 HD ski topsheet",
    "rossignol-sender-104-ti":    "Rossignol Sender 104 Ti ski topsheet",
    "rossignol-experience-86-ti": "Rossignol Experience 86 Ti ski topsheet",
    "rossignol-black-ops-sender": "Rossignol Black Ops Sender ski topsheet",
    # K2
    "k2-mindbender-99ti":         "K2 Mindbender 99Ti ski topsheet",
    "k2-mindbender-108ti":        "K2 Mindbender 108Ti ski topsheet",
    "k2-disruption-82ti":         "K2 Disruption 82Ti ski topsheet",
    # Salomon
    "salomon-qst-106":            "Salomon QST 106 ski topsheet",
    "salomon-qst-98":             "Salomon QST 98 ski topsheet",
    "salomon-stance-96":          "Salomon Stance 96 ski topsheet",
    "salomon-s-force-bold":       "Salomon S/Force Bold ski topsheet",
    # Volkl
    "volkl-m6-mantra":            "Volkl M6 Mantra ski topsheet",
    "volkl-blaze-106":            "Volkl Blaze 106 ski topsheet",
    "volkl-kendo-88":             "Volkl Kendo 88 ski topsheet",
    "volkl-revolt-95":            "Volkl Revolt 95 ski topsheet",
    # Nordica
    "nordica-enforcer-100":       "Nordica Enforcer 100 ski topsheet",
    "nordica-enforcer-110":       "Nordica Enforcer 110 ski topsheet",
    "nordica-santa-ana-98":       "Nordica Santa Ana 98 ski topsheet",
    # Head
    "head-kore-99":               "Head Kore 99 ski topsheet",
    "head-kore-105":              "Head Kore 105 ski topsheet",
    "head-supershape-e-magnum":   "Head Supershape e-Magnum ski topsheet",
    # Blizzard
    "blizzard-bonafide-97":       "Blizzard Bonafide 97 ski topsheet",
    "blizzard-rustler-10":        "Blizzard Rustler 10 ski topsheet",
    "blizzard-hustle-10":         "Blizzard Hustle 10 ski topsheet",
    "blizzard-black-pearl-88":    "Blizzard Black Pearl 88 ski topsheet",
    # DPS
    "dps-pagoda-100-rp":          "DPS Pagoda 100 RP ski topsheet",
    "dps-pagoda-tour-112":        "DPS Pagoda Tour 112 ski topsheet",
    "dps-wailer-a112":            "DPS Wailer A112 ski topsheet",
    # Armada
    "armada-arv-100":             "Armada ARV 100 ski topsheet",
    "armada-arv-116-jj":          "Armada ARV 116 JJ ski topsheet",
    "armada-declivity-102-ti":    "Armada Declivity 102 Ti ski topsheet",
    # Line
    "line-sakana":                "Line Sakana ski topsheet",
    "line-blade-optic-96":        "Line Blade Optic 96 ski topsheet",
    "line-pandora-99":            "Line Pandora 99 ski topsheet",
    # Stockli
    "stockli-stormrider-102":     "Stockli Stormrider 102 ski topsheet",
    "stockli-stormrider-88":      "Stockli Stormrider 88 ski topsheet",
    "stockli-laser-ax":           "Stockli Laser AX ski topsheet",
    # ON3P
    "on3p-wrenegade-108":         "ON3P Wrenegade 108 ski topsheet",
    "on3p-woodsman-108":          "ON3P Woodsman 108 ski topsheet",
    # Dynastar
    "dynastar-m-pro-99":          "Dynastar M-Pro 99 ski topsheet",
    "dynastar-m-free-108":        "Dynastar M-Free 108 ski topsheet",
    # Fischer
    "fischer-ranger-102":         "Fischer Ranger 102 ski topsheet",
    "fischer-rc4":                "Fischer RC4 ski topsheet",
    # Elan
    "elan-ripstick-96":           "Elan Ripstick 96 ski topsheet",
    "elan-ripstick-106":          "Elan Ripstick 106 ski topsheet",
    # Moment
    "moment-wildcat":             "Moment Wildcat ski topsheet",
    "moment-deathwish":           "Moment Deathwish ski topsheet",
    # J Skis
    "j-skis-masterblaster":       "J Skis Masterblaster ski topsheet",
    "j-skis-friend":              "J Skis Friend ski topsheet",
    # Icelantic
    "icelantic-nomad-105":        "Icelantic Nomad 105 ski topsheet",
    "icelantic-pioneer-109":      "Icelantic Pioneer 109 ski topsheet",
    # Touring / niche
    "voile-hypervector-bc":           "Voile HyperVector BC ski topsheet",
    "black-diamond-helio-carbon-95":  "Black Diamond Helio Carbon 95 ski topsheet",
    # House — will not be scraped; placeholder slug only
    # "powdermeet-house": designed in-house; do not attempt to scrape
}


ROOT = Path("~/topsheet-source").expanduser()
RAW_DIR = ROOT / "raw"
PROCESSED_DIR = ROOT / "processed"
RAW_DIR.mkdir(parents=True, exist_ok=True)
PROCESSED_DIR.mkdir(parents=True, exist_ok=True)

TARGET_W, TARGET_H = 1280, 200
USER_AGENT = (
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
    "AppleWebKit/537.36 (KHTML, like Gecko) "
    "Chrome/124.0.0.0 Safari/537.36"
)


def find_image_url(query: str, attempt: int = 0) -> str | None:
    """First plausible large image URL from DDG. Retries with backoff
    on rate-limit; returns None if nothing usable."""
    if DDGS is None:
        print("   duckduckgo_search not installed; --from-urls is the supported path")
        return None
    try:
        with DDGS() as ddgs:
            results = list(ddgs.images(query, max_results=15))
    except Exception as exc:
        if attempt < 2:
            sleep_s = 5 * (attempt + 1)
            print(f"   ddg error '{exc}' — backoff {sleep_s}s")
            time.sleep(sleep_s)
            return find_image_url(query, attempt + 1)
        print(f"   ddg failed after retries: {exc}")
        return None

    # Prefer images with both dimensions reported and at least one side
    # >= 800px. White-background product shots are usually wider than tall;
    # photos of the ski being held are taller than wide. We accept either
    # because rotation comes after.
    plausible: list[tuple[int, str]] = []
    for r in results:
        w, h = r.get("width") or 0, r.get("height") or 0
        url = r.get("image")
        if not url:
            continue
        long_side = max(w, h)
        if long_side < 600:
            continue
        plausible.append((long_side, url))

    if not plausible:
        return None
    plausible.sort(key=lambda x: -x[0])
    return plausible[0][1]


def download(url: str, dst: Path) -> bool:
    try:
        r = requests.get(url, timeout=15, headers={"User-Agent": USER_AGENT})
        r.raise_for_status()
        dst.write_bytes(r.content)
        return True
    except Exception as exc:
        print(f"   download failed: {exc}")
        return False


def _column_groups(img: "Image.Image", *, alpha_threshold: int = 64,
                   min_pixels_per_col: int = 6,
                   gap_threshold: int = 12) -> list[tuple[int, int]]:
    """Cluster columns of opaque pixels into horizontal groups
    separated by gap_threshold or more empty columns. Used to split
    portrait catalog photos that show N ski profiles side-by-side."""
    alpha = img.getchannel("A")
    w, h = alpha.size
    has_content: list[bool] = []
    for x in range(w):
        col = alpha.crop((x, 0, x + 1, h))
        opaque = sum(1 for v in col.getdata() if v >= alpha_threshold)
        has_content.append(opaque >= min_pixels_per_col)

    groups: list[tuple[int, int]] = []
    in_group, start, gap_count = False, 0, 0
    for x, h_ in enumerate(has_content):
        if h_:
            if not in_group:
                in_group, start = True, x
            gap_count = 0
        else:
            if in_group:
                gap_count += 1
                if gap_count >= gap_threshold:
                    groups.append((start, x - gap_count))
                    in_group = False
    if in_group:
        groups.append((start, len(has_content) - 1))
    return groups


def _row_groups(img: "Image.Image", *, alpha_threshold: int = 64,
                min_pixels_per_row: int = 6,
                gap_threshold: int = 8) -> list[tuple[int, int]]:
    """Cluster rows of opaque pixels into vertical groups separated by
    gap_threshold or more empty rows. Used to detect pair-shots: a pair
    of skis shows as 2 groups; a single ski as 1."""
    alpha = img.getchannel("A")
    w, h = alpha.size
    has_content: list[bool] = []
    for y in range(h):
        row = alpha.crop((0, y, w, y + 1))
        opaque = sum(1 for v in row.getdata() if v >= alpha_threshold)
        has_content.append(opaque >= min_pixels_per_row)

    groups: list[tuple[int, int]] = []
    in_group, start, gap_count = False, 0, 0
    for y, h_ in enumerate(has_content):
        if h_:
            if not in_group:
                in_group, start = True, y
            gap_count = 0
        else:
            if in_group:
                gap_count += 1
                if gap_count >= gap_threshold:
                    groups.append((start, y - gap_count))
                    in_group = False
    if in_group:
        groups.append((start, len(has_content) - 1))
    return groups


def process(raw_path: Path, out_path: Path) -> bool:
    """rembg → auto-rotate → de-pair → crop-to-content → resize-to-fit-height."""
    raw_bytes = raw_path.read_bytes()

    try:
        cut = remove(raw_bytes)
    except Exception as exc:
        print(f"   rembg failed: {exc}")
        return False

    img = Image.open(BytesIO(cut)).convert("RGBA")
    img = ImageOps.exif_transpose(img)

    bbox = img.getchannel("A").getbbox()
    if not bbox:
        print("   alpha empty after rembg")
        return False
    img = img.crop(bbox)

    # PORTRAIT MULTI-COLUMN SPLIT — for catalog photos that show N
    # vertical ski profiles side-by-side (topsheet, base, side, etc).
    # A single ski has h/w ≈ 22:1; portrait input with h/w < 18 is
    # almost certainly multiple skis in columns. Find the column-
    # groups (columns of opaque pixels separated by transparent gaps)
    # and keep the WIDEST one — for catalog shots that's reliably
    # the topsheet view (side-profiles + base material discs are
    # narrower than the topsheet's full waist). Falls back to the
    # old left/right pixel-count split when no clean column-gaps
    # exist (e.g., two skis touching at tips).
    if img.height > img.width and img.height / max(img.width, 1) < 18:
        cols = _column_groups(img)
        if len(cols) >= 2:
            widest = max(cols, key=lambda g: g[1] - g[0])
            img = img.crop((widest[0], 0, widest[1] + 1, img.height))
            print(f"   split portrait pair: kept column "
                  f"{widest[0]}..{widest[1]} of {len(cols)} columns")
        else:
            left = img.crop((0, 0, img.width // 2, img.height))
            right = img.crop((img.width // 2, 0, img.width, img.height))

            def _opaque_count(im):
                return sum(1 for v in im.getchannel("A").getdata() if v >= 64)
            if _opaque_count(left) >= _opaque_count(right):
                img = left
                print("   split portrait pair: kept left half (no column gaps)")
            else:
                img = right
                print("   split portrait pair: kept right half (no column gaps)")

    if img.height > img.width:
        img = img.rotate(90, expand=True)

    # Horizontal-pair de-pair (for sources like Faction CDN where two
    # skis are stacked one above the other in a wide image).
    groups = _row_groups(img)
    if len(groups) >= 2:
        biggest = max(groups, key=lambda g: g[1] - g[0])
        img = img.crop((0, biggest[0], img.width, biggest[1] + 1))
        print(f"   de-paired horizontal: kept rows {biggest[0]}..{biggest[1]} "
              f"of {len(groups)} groups")

    # Letterbox-fit into the canvas, preserve aspect, transparent pad.
    # Earlier versions fit-to-height then center-cropped horizontally,
    # which sliced ~30% of tip-to-tail off skis whose product photos
    # were tighter than the 6.4:1 canvas. The distinctive tip rocker
    # and tail kick — what visually distinguishes one ski model from
    # another — landed in the cropped region. Fit width OR height
    # whichever is the binding constraint, pad the other dimension.
    src_aspect = img.width / max(img.height, 1)
    canvas_aspect = TARGET_W / TARGET_H
    if src_aspect >= canvas_aspect:
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
    canvas.save(out_path, format="PNG", optimize=True)
    return True


def find_raw(slug: str) -> Path | None:
    for ext in ("png", "jpg", "jpeg", "webp"):
        p = RAW_DIR / f"{slug}.{ext}"
        if p.exists():
            return p
    return None


URLS_TSV_PATH = Path(__file__).resolve().parent / "topsheet_urls.tsv"


def write_urls_scaffold() -> None:
    """Write a scaffold TSV with one row per slug, URL column blank."""
    lines = [
        "# topsheet_urls.tsv — operator-curated source URLs.",
        "# Format: <slug><TAB><url>",
        "# Lines starting with # are ignored. Blank URL → slug is skipped.",
        "# Workflow:",
        "#   1. For each slug, search the brand site / retailer / image search.",
        "#   2. Right-click the topsheet image → 'Copy Image Address'.",
        "#   3. Paste the URL after the TAB. Save.",
        "#   4. Run: python3 tools/scrape_topsheets.py --from-urls",
        "# Re-runnable: rows whose processed PNG already exists are skipped.",
        "# Empty URLs are silently skipped, so you can drip-fill over time.",
        "",
    ]
    for slug in SKIS:
        lines.append(f"{slug}\t")
    URLS_TSV_PATH.write_text("\n".join(lines) + "\n")


def read_urls_tsv() -> dict[str, str]:
    """Return {slug: url} from the TSV, ignoring comments and blank URLs.
    Tolerates tab OR whitespace separation between slug and URL."""
    if not URLS_TSV_PATH.exists():
        return {}
    out: dict[str, str] = {}
    for raw_line in URLS_TSV_PATH.read_text().splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        # Split on first whitespace run (tab or spaces both work)
        parts = line.split(None, 1)
        if len(parts) != 2:
            continue  # slug-only row → no URL yet; skip
        slug, url = parts[0].strip(), parts[1].strip()
        if slug and url:
            out[slug] = url
    return out


def handle(slug: str, query: str, *,
           reprocess: bool,
           url_override: str | None = None,
           require_url: bool = False) -> str:
    out_path = PROCESSED_DIR / f"{slug}.png"
    if out_path.exists() and not reprocess:
        return "skip-exists"

    raw = find_raw(slug)

    if reprocess and raw is not None:
        # Skip download, just redo the rembg+crop step on cached bytes
        return "ok" if process(raw, out_path) else "process-failed"

    if raw is None:
        if url_override:
            url = url_override
        elif require_url:
            return "no-url-in-tsv"
        else:
            url = find_image_url(query)
            if not url:
                return "no-search-result"
        ext = url.rsplit(".", 1)[-1].split("?")[0].split("#")[0].lower()
        if ext not in {"png", "jpg", "jpeg", "webp"}:
            ext = "jpg"
        raw = RAW_DIR / f"{slug}.{ext}"
        if not download(url, raw):
            return "download-failed"

    return "ok" if process(raw, out_path) else "process-failed"


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--limit", type=int, default=0,
                    help="Stop after N slugs (0 = all)")
    ap.add_argument("--slug", default="",
                    help="Process only this slug")
    ap.add_argument("--reprocess", action="store_true",
                    help="Skip download; redo rembg+crop+pad from cached raw")
    ap.add_argument("--sleep", type=float, default=2.0,
                    help="Seconds between DDG searches (rate-limit cushion)")
    ap.add_argument("--init-urls", action="store_true",
                    help=f"Scaffold {URLS_TSV_PATH.name} with all slugs and exit")
    ap.add_argument("--from-urls", action="store_true",
                    help="Skip search; read URLs from topsheet_urls.tsv instead")
    args = ap.parse_args(argv[1:])

    if args.init_urls:
        if URLS_TSV_PATH.exists():
            print(f"refusing to overwrite existing {URLS_TSV_PATH}")
            print("   delete it first if you want a fresh scaffold")
            return 1
        write_urls_scaffold()
        print(f"wrote {URLS_TSV_PATH}")
        print("Edit it: paste a URL after each slug<TAB>, then run:")
        print("  python3 tools/scrape_topsheets.py --from-urls")
        return 0

    url_map: dict[str, str] = read_urls_tsv() if args.from_urls else {}
    if args.from_urls and not url_map and not args.reprocess:
        print(f"no URLs found in {URLS_TSV_PATH}")
        print(f"  run --init-urls to scaffold, or paste URLs into the TSV")
        return 1

    if args.slug:
        items = [(args.slug, SKIS.get(args.slug, args.slug))]
    else:
        items = list(SKIS.items())
        if args.limit > 0:
            items = items[:args.limit]

    counts: dict[str, int] = {}
    for i, (slug, query) in enumerate(items, 1):
        print(f"[{i}/{len(items)}] {slug}")
        url_override = url_map.get(slug) if args.from_urls else None
        result = handle(
            slug, query,
            reprocess=args.reprocess,
            url_override=url_override,
            require_url=args.from_urls,
        )
        counts[result] = counts.get(result, 0) + 1
        print(f"   -> {result}")
        # Rate-limit cushion only for DDG mode (URL mode hits product CDNs)
        if (not args.from_urls and not args.reprocess
                and result not in {"skip-exists", "no-url-in-tsv"}
                and i < len(items)):
            time.sleep(args.sleep)

    print("\nsummary:")
    for k, v in sorted(counts.items()):
        print(f"  {k}: {v}")
    print(f"output dir: {PROCESSED_DIR}")
    if args.from_urls:
        ok = counts.get("ok", 0)
        missing = counts.get("no-url-in-tsv", 0)
        if missing:
            print(f"  {missing} slug(s) have no URL in {URLS_TSV_PATH.name} yet")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
