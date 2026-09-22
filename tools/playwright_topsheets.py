#!/usr/bin/env python3
"""
playwright_topsheets.py — Headless-browser ski topsheet fetcher.

Counterpart to scrape_topsheets.py for sites that block plain-HTTP
fetching (Atomic, Salomon, evo, REI, Backcountry — all use PerimeterX
or Cloudflare bot detection that defeats curl/requests/WebFetch).

Playwright drives a real Chromium that looks like a regular Mac Chrome
session (real UA, viewport, locale, timezone, +stealth WebGL/Canvas
fingerprint patches). This defeats most ski-retail bot protection —
they target price-monitoring scrapers, not human browser sessions.

Setup (one-time, ~150MB Chromium download):
    ~/topsheet-source/.venv/bin/pip install playwright playwright-stealth
    ~/topsheet-source/.venv/bin/playwright install chromium

Two modes:

    --auto          For every SKIS slug not yet processed:
                    1. Open DuckDuckGo Lite search inside Chromium
                    2. Search "<brand> <model> ski"
                    3. First result from an approved brand/retailer host
                    4. Navigate there, extract og:image
                    5. Download via the same browser session
                    6. Run rembg + de-pair + crop pipeline
                    No TSV needed; one command end-to-end.

    (default)       Reads tools/topsheet_product_pages.tsv
                    (slug<TAB>product_url) — operator-curated URLs.
                    Use when --auto fails for specific slugs.

    --headed        Show the browser window (debug).
    --slug X        Process only this slug.

Recommended:
    ~/topsheet-source/.venv/bin/python tools/playwright_topsheets.py --auto

Re-runnable: skips slugs whose processed PNG already exists.
"""
from __future__ import annotations

import argparse
import sys
import time
from pathlib import Path

try:
    from playwright.sync_api import sync_playwright, TimeoutError as PWTimeout
except ImportError:
    print("Playwright not installed. Run:")
    print("  ~/topsheet-source/.venv/bin/pip install playwright playwright-stealth")
    print("  ~/topsheet-source/.venv/bin/playwright install chromium")
    sys.exit(1)

HAVE_STEALTH = False
_stealth_err: str | None = None
try:
    import playwright_stealth as _ps  # noqa: F401
except ImportError as exc:
    _stealth_err = f"package not installed: {exc}"

if _stealth_err is None:
    # Try v2.x API: Stealth().apply_stealth_sync(page) or .apply_sync(page)
    try:
        from playwright_stealth import Stealth as _Stealth  # type: ignore
        _stealth_inst = _Stealth()
        for _method_name in ("apply_stealth_sync", "apply_sync"):
            if hasattr(_stealth_inst, _method_name):
                _method = getattr(_stealth_inst, _method_name)
                def stealth_sync(page, _m=_method):
                    _m(page)
                HAVE_STEALTH = True
                break
        if not HAVE_STEALTH:
            _stealth_err = (
                f"v2.x: Stealth has no apply_stealth_sync/apply_sync; "
                f"attrs: {sorted(a for a in dir(_stealth_inst) if not a.startswith('_'))}"
            )
    except ImportError:
        # Try v1.x API: module-level stealth_sync
        try:
            from playwright_stealth import stealth_sync  # type: ignore
            HAVE_STEALTH = True
        except ImportError as exc:
            _stealth_err = f"no v1 or v2 API found: {exc}"

if not HAVE_STEALTH:
    def stealth_sync(_page):
        pass
    print(f"stealth disabled: {_stealth_err}")
    print("(some sites may still detect headless browsing)")

# Reuse the existing pipeline (rembg + de-pair + crop) from scrape_topsheets.
sys.path.insert(0, str(Path(__file__).resolve().parent))
from scrape_topsheets import (  # type: ignore
    process, RAW_DIR, PROCESSED_DIR, find_raw, SKIS,
)

PRODUCT_PAGES_TSV = Path(__file__).resolve().parent / "topsheet_product_pages.tsv"

USER_AGENT = (
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
    "AppleWebKit/537.36 (KHTML, like Gecko) "
    "Chrome/124.0.0.0 Safari/537.36"
)

# Slug → brand search hint. We trust the brand's own site first, then
# fall back to a curated list of US ski retailers known to host clean
# product imagery. Order matters: first match wins.
APPROVED_HOSTS = (
    # Manufacturer sites (highest preference for accurate topsheet)
    "atomic.com", "salomon.com", "k2skis.com", "rossignol.com",
    "volkl.com", "blackcrows.com", "factionskis.com", "nordica.com",
    "head.com", "blizzard-tecnica.com", "blizzardskis.com",
    "dpsskis.com", "armadaskis.com", "lineskis.com",
    "stoeckli.com", "stockli.com", "on3pskis.com",
    "dynastar.com", "fischer-sports.com", "elanskis.com",
    "momentskis.com", "jskis.com", "icelantic.com",
    "voile.com", "blackdiamondequipment.com",
    # Retailer fallbacks (clean white-bg product shots, often)
    "evo.com", "rei.com", "backcountry.com",
    "skis.com", "christysports.com",
    "skiessentials.com", "powder7.com", "level9sports.com",
    "utahskigear.com", "snowcountry.com", "ellis-brigham.com",
)


def host_priority(url: str) -> int:
    """Lower is better. Returns len(APPROVED_HOSTS) for unmatched."""
    from urllib.parse import urlparse
    host = urlparse(url).netloc.lower()
    for i, h in enumerate(APPROVED_HOSTS):
        if h in host:
            return i
    return len(APPROVED_HOSTS)


def unwrap_bing_redirect(url: str) -> str:
    """Bing wraps results in /ck/a?...&u=a1<base64-of-target>...
    Decode the target so host_priority sees the real destination."""
    import base64
    from urllib.parse import urlparse, parse_qs
    parsed = urlparse(url)
    if "bing.com" not in parsed.netloc or "/ck/a" not in parsed.path:
        return url
    qs = parse_qs(parsed.query)
    u_vals = qs.get("u")
    if not u_vals:
        return url
    encoded = u_vals[0]
    if encoded.startswith("a1"):
        encoded = encoded[2:]
    encoded += "=" * (-len(encoded) % 4)
    try:
        decoded = base64.b64decode(encoded).decode("utf-8")
    except Exception:
        return url
    return decoded if decoded.startswith(("http://", "https://")) else url


def brand_for_slug(slug: str) -> str:
    """Best human-readable brand name for the slug (drives search query)."""
    # SKIS values are descriptive search hints; pluck "<brand> <model>".
    hint = SKIS.get(slug, slug)
    # Trim trailing keywords used to bias DDG results
    for trail in (" ski topsheet 2024", " ski topsheet"):
        if hint.endswith(trail):
            return hint[:-len(trail)]
    return hint


def read_product_pages_tsv() -> dict[str, str]:
    if not PRODUCT_PAGES_TSV.exists():
        return {}
    out: dict[str, str] = {}
    for line in PRODUCT_PAGES_TSV.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        parts = line.split(None, 1)
        if len(parts) == 2 and parts[1].startswith(("http://", "https://")):
            out[parts[0]] = parts[1]
    return out


def write_product_pages_scaffold() -> None:
    lines = [
        "# topsheet_product_pages.tsv — operator-curated product page URLs.",
        "# Format: <slug><TAB><product_page_url>",
        "# The Playwright runner visits each URL with stealth patches and",
        "# extracts og:image / the largest product image.",
        "",
    ]
    for slug in SKIS:
        lines.append(f"{slug}\t")
    PRODUCT_PAGES_TSV.write_text("\n".join(lines) + "\n")


def extract_image_url(page) -> str | None:
    """Find the best topsheet image URL on the loaded page. Strategy:
    1. og:image meta tag (most reliable — brands set this for shares)
    2. JSON-LD product image
    3. Largest image in the product gallery
    """
    # Wait for og:image to populate (some Shopify sites set it via JS)
    try:
        page.wait_for_selector('meta[property="og:image"]', timeout=8000)
    except PWTimeout:
        pass

    og = page.locator('meta[property="og:image"]').first
    if og.count() > 0:
        url = og.get_attribute("content")
        if url and url.startswith(("http://", "https://")):
            return url

    # JSON-LD: look for "image" field in any application/ld+json block
    try:
        jsonld_scripts = page.locator('script[type="application/ld+json"]').all()
        import json as _json
        for s in jsonld_scripts:
            text = s.text_content() or ""
            try:
                data = _json.loads(text)
            except Exception:
                continue
            if isinstance(data, list):
                data = data[0] if data else {}
            img = data.get("image") if isinstance(data, dict) else None
            if isinstance(img, list) and img:
                img = img[0]
            if isinstance(img, str) and img.startswith("http"):
                return img
            if isinstance(img, dict) and isinstance(img.get("url"), str):
                return img["url"]
    except Exception:
        pass

    # Fallback: largest <img> on the page
    try:
        imgs = page.evaluate("""
            () => Array.from(document.images)
                .filter(i => i.naturalWidth >= 600 && i.src.startsWith('http'))
                .sort((a, b) => b.naturalWidth - a.naturalWidth)
                .map(i => i.src)
        """)
        if imgs:
            return imgs[0]
    except Exception:
        pass

    return None


SEARCH_ENGINES = (
    # name, URL template, link selector
    ("ddg-html", "https://html.duckduckgo.com/html/?q={q}",
     "a.result__a, a.result__url"),
    ("ddg-lite", "https://lite.duckduckgo.com/lite/?q={q}",
     "a[href]"),
    ("bing",     "https://www.bing.com/search?q={q}",
     "li.b_algo h2 a, .b_algo a[h]"),
)


def search_for_product_url(context, slug: str, *, debug: bool = False) -> str | None:
    """Try multiple search engines in order. For each, navigate inside the
    stealthed Chromium and extract organic-result hrefs. Return the first
    URL whose host is in APPROVED_HOSTS."""
    from urllib.parse import quote_plus

    query = brand_for_slug(slug) + " ski"

    for engine_name, url_tmpl, selector in SEARCH_ENGINES:
        page = context.new_page()
        if HAVE_STEALTH:
            stealth_sync(page)
        try:
            page.goto(
                url_tmpl.format(q=quote_plus(query)),
                wait_until="domcontentloaded", timeout=30000,
            )
            page.wait_for_timeout(800)  # let any JS hydrate
        except PWTimeout:
            page.close()
            continue

        try:
            urls: list[str] = page.evaluate(f"""
                () => Array.from(document.querySelectorAll({selector!r}))
                    .map(a => a.href)
                    .filter(h =>
                        h && h.startsWith('http')
                        && !h.includes('duckduckgo.com')
                        && !h.includes('bing.com/aclick')
                        && !h.includes('bing.com/search')
                        && !h.includes('/y.js?')
                    )
            """) or []
        except Exception:
            urls = []
        page.close()

        # Unwrap Bing redirects so host_priority sees actual targets
        urls = [unwrap_bing_redirect(u) for u in urls]
        # Drop dupes (Bing duplicates result + caption + thumbnail per item)
        seen, deduped = set(), []
        for u in urls:
            if u not in seen:
                seen.add(u)
                deduped.append(u)
        urls = deduped

        if debug:
            print(f"   [{engine_name}] {len(urls)} urls; "
                  f"top: {urls[0] if urls else '(none)'}")

        if not urls:
            continue
        ranked = sorted(urls, key=host_priority)
        if host_priority(ranked[0]) < len(APPROVED_HOSTS):
            if debug:
                print(f"   [{engine_name}] picked: {ranked[0]}")
            return ranked[0]
        elif debug:
            print(f"   [{engine_name}] no approved host; top 3: {ranked[:3]}")

    return None


def fetch_one(context, slug: str, url: str | None, *, debug: bool = False) -> str:
    out_path = PROCESSED_DIR / f"{slug}.png"
    if out_path.exists():
        return "skip-exists"

    raw = find_raw(slug)
    if raw is None:
        if not url:
            url = search_for_product_url(context, slug, debug=debug)
            if not url:
                return "search-no-result"
        if debug:
            print(f"   navigating: {url}")

        page = context.new_page()
        if HAVE_STEALTH:
            stealth_sync(page)
        try:
            page.goto(url, wait_until="domcontentloaded", timeout=30000)
        except PWTimeout:
            page.close()
            return "page-timeout"
        # Give JS a moment to populate og:image
        page.wait_for_timeout(2500)
        img_url = extract_image_url(page)
        page.close()
        if not img_url:
            return "no-image-found"

        # Download via the browser's request context (carries cookies + UA)
        try:
            response = context.request.get(img_url, timeout=30000)
            if response.status >= 400:
                return f"download-{response.status}"
            ext = img_url.rsplit(".", 1)[-1].split("?")[0].split("#")[0].lower()
            if ext not in {"png", "jpg", "jpeg", "webp"}:
                ext = "jpg"
            raw = RAW_DIR / f"{slug}.{ext}"
            raw.write_bytes(response.body())
        except Exception as exc:
            return f"download-error: {exc}"

    return "ok" if process(raw, out_path) else "process-failed"


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--auto", action="store_true",
                    help="Search-then-fetch every slug; no TSV required")
    ap.add_argument("--init-pages", action="store_true",
                    help="Scaffold topsheet_product_pages.tsv and exit")
    ap.add_argument("--slug", default="", help="Process only this slug")
    ap.add_argument("--headed", action="store_true",
                    help="Show the browser window (default headless)")
    ap.add_argument("--debug", action="store_true",
                    help="Print which search engine fired and what URLs it returned")
    ap.add_argument("--sleep", type=float, default=1.5,
                    help="Seconds between pages (politeness cushion)")
    args = ap.parse_args(argv[1:])

    if args.init_pages:
        if PRODUCT_PAGES_TSV.exists():
            print(f"refusing to overwrite {PRODUCT_PAGES_TSV}")
            return 1
        write_product_pages_scaffold()
        print(f"wrote {PRODUCT_PAGES_TSV}")
        return 0

    if args.auto:
        # Auto mode — no TSV; each slug gets DDG-Lite search inside the
        # browser. URL is None; fetch_one will search.
        if args.slug:
            items = [(args.slug, None)]
        else:
            items = [(s, None) for s in SKIS]
    else:
        pages_map = read_product_pages_tsv()
        if not pages_map:
            print(f"no URLs in {PRODUCT_PAGES_TSV}")
            print("either:")
            print("  1) run with --auto to search-then-fetch automatically, or")
            print("  2) run --init-pages and paste product URLs into the TSV")
            return 1
        items = ([(args.slug, pages_map[args.slug])]
                 if args.slug and args.slug in pages_map
                 else list(pages_map.items()))

    counts: dict[str, int] = {}
    with sync_playwright() as p:
        browser = p.chromium.launch(headless=not args.headed)
        context = browser.new_context(
            user_agent=USER_AGENT,
            viewport={"width": 1440, "height": 900},
            locale="en-US",
            timezone_id="America/Denver",
        )

        for i, (slug, url) in enumerate(items, 1):
            print(f"[{i}/{len(items)}] {slug}")
            try:
                result = fetch_one(context, slug, url, debug=args.debug)
            except Exception as exc:
                result = f"crash: {exc}"
            counts[result] = counts.get(result, 0) + 1
            print(f"   -> {result}")
            if i < len(items):
                time.sleep(args.sleep)

        browser.close()

    print("\nsummary:")
    for k, v in sorted(counts.items()):
        print(f"  {k}: {v}")
    print(f"raw dir:       {RAW_DIR}")
    print(f"processed dir: {PROCESSED_DIR}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
