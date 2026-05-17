#!/usr/bin/env python3
"""
prewarm_snapshots.py — one-time pre-bake of pinned resort snapshots.

For every ResortEntry in PowderMeet/Models/ResortCatalog.swift, POSTs to the
snapshot-resort Edge Function with the resort's bbox and the catalog-wide
pinned date. The Edge Function builds the OSM + elevation snapshot once and
stores it at the immutable filename `<resort_id>/osm-<date>.json` /
`elev-<date>.json`. From then on, every device requesting the same pin gets
the same blob — variance gone, cold-load-fast forever (until the pin gets
bumped).

Run after deploying the snapshot-resort Edge Function changes:

    SUPABASE_URL=https://<proj>.supabase.co \\
    SUPABASE_ANON_KEY=<anon-key> \\
    python3 tools/prewarm_snapshots.py

Reads the pinned date from the catalog source so this script always agrees
with what the app sends. Skips resorts whose pinned snapshot already exists
(idempotent — safe to re-run).

Pacing: 2-second sleep between resorts so we don't pound Open-Meteo elevation
or Overpass; ~3 minutes total for the 159-resort catalog. Exits with status
1 if any resort fails (network / 5xx) so you notice in CI.
"""

import json
import os
import re
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

CATALOG_PATH = Path(__file__).resolve().parent.parent / "PowderMeet" / "Models" / "ResortCatalog.swift"

# Tolerates the Swift `box(centerLat, centerLon, latSpan: X, lonSpan: Y)` shape
# used by ResortEntry. latSpan/lonSpan default to 0.05 / 0.07 in the Swift
# helper, so missing args fall back to that.
ENTRY_RE = re.compile(
    r'ResortEntry\(\s*'
    r'id:\s*"(?P<id>[^"]+)"\s*,\s*'
    r'name:\s*"(?P<name>[^"]+)"\s*,\s*'
    r'bounds:\s*box\(\s*'
    r'(?P<lat>-?\d+(?:\.\d+)?)\s*,\s*'
    r'(?P<lon>-?\d+(?:\.\d+)?)'
    r'(?:\s*,\s*latSpan:\s*(?P<latSpan>-?\d+(?:\.\d+)?))?'
    r'(?:\s*,\s*lonSpan:\s*(?P<lonSpan>-?\d+(?:\.\d+)?))?'
    r'\s*\)'
)

DEFAULT_PIN_RE = re.compile(
    r'static\s+let\s+defaultPinnedSnapshotDate\s*=\s*"(?P<date>\d{4}-\d{2}-\d{2})"'
)

PER_RESORT_PIN_RE = re.compile(
    r'pinnedSnapshotDate:\s*"(?P<date>\d{4}-\d{2}-\d{2})"'
)


def parse_catalog(text: str):
    """Yield (id, name, south, west, north, east, pin_date) per ResortEntry."""
    default_pin_match = DEFAULT_PIN_RE.search(text)
    if not default_pin_match:
        sys.exit("error: could not find ResortEntry.defaultPinnedSnapshotDate in catalog")
    default_pin = default_pin_match.group("date")

    for match in ENTRY_RE.finditer(text):
        rid = match.group("id")
        name = match.group("name")
        lat = float(match.group("lat"))
        lon = float(match.group("lon"))
        lat_span = float(match.group("latSpan") or 0.05)
        lon_span = float(match.group("lonSpan") or 0.07)
        south = lat - lat_span / 2
        north = lat + lat_span / 2
        west = lon - lon_span / 2
        east = lon + lon_span / 2

        # Per-resort override pin (look in the same ResortEntry call).
        # Find the closing paren of THIS ResortEntry then scan its body.
        start = match.start()
        # Walk to the matching closing paren counting depth.
        depth = 0
        end = start
        for i, ch in enumerate(text[start:], start=start):
            if ch == '(':
                depth += 1
            elif ch == ')':
                depth -= 1
                if depth == 0:
                    end = i
                    break
        body = text[start:end]
        per_resort = PER_RESORT_PIN_RE.search(body)
        pin = per_resort.group("date") if per_resort else default_pin

        yield rid, name, south, west, north, east, pin


def post_snapshot(supabase_url: str, anon_key: str, payload: dict, timeout: float = 180.0) -> dict:
    req = urllib.request.Request(
        f"{supabase_url}/functions/v1/snapshot-resort",
        data=json.dumps(payload).encode("utf-8"),
        headers={
            "Content-Type": "application/json",
            "apikey": anon_key,
            "Authorization": f"Bearer {anon_key}",
        },
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return json.loads(resp.read().decode("utf-8"))


def drive_chunked_build(
    supabase_url: str,
    anon_key: str,
    initial_payload: dict,
    max_iterations: int = 12,
) -> dict:
    """Drives the chunked-elevation Edge Function to completion.

    The function returns either {status: "ready", ...} (final) or
    {status: "elevation_pending", elevation_progress: {processed, total}}
    (continue). On ready, returns the final body. On pending, re-posts
    with `continue: true` and updates the progress counter on stdout.
    Caps at max_iterations so a stuck resort doesn't loop forever.
    """
    payload = dict(initial_payload)
    last_progress = None
    for iteration in range(max_iterations):
        body = post_with_retry(supabase_url, anon_key, payload)
        status = body.get("status") or ("ready" if "osm_url" in body else None)
        if status == "ready" or "osm_url" in body:
            return body
        prog = body.get("elevation_progress") or {}
        processed = prog.get("processed", 0)
        total = prog.get("total", 0)
        if total > 0:
            pct = int(processed / total * 100)
            print(
                f"    elevation {processed}/{total} ({pct}%)",
                flush=True,
            )
            last_progress = (processed, total)
        # Continuation calls re-use the same body but flag continue=true.
        payload["continue"] = True
        time.sleep(0.5)
    # Didn't converge — surface a synthetic error body so the outer
    # caller can record the failure.
    raise RuntimeError(
        f"chunked build did not converge after {max_iterations} iterations"
        + (f" (last progress {last_progress[0]}/{last_progress[1]})" if last_progress else "")
    )


def post_with_retry(
    supabase_url: str,
    anon_key: str,
    payload: dict,
    *,
    max_attempts: int = 4,
    base_delay: float = 60.0,
) -> dict:
    """Calls the Edge Function. On 502/503/504 (typically Open-Meteo or
    Overpass rate limits propagating through), waits base_delay × attempt
    and retries — Open-Meteo per-IP recovery is ~60-120s, so a single
    minute usually clears the gate. Other HTTP errors raise immediately.
    """
    last_err: Exception | None = None
    for attempt in range(max_attempts):
        try:
            return post_snapshot(supabase_url, anon_key, payload)
        except urllib.error.HTTPError as e:
            last_err = e
            if e.code not in (429, 502, 503, 504) or attempt == max_attempts - 1:
                raise
            time.sleep(base_delay * (attempt + 1))
        except (urllib.error.URLError, TimeoutError) as e:
            last_err = e
            if attempt == max_attempts - 1:
                raise
            time.sleep(base_delay * (attempt + 1))
    if last_err:
        raise last_err
    raise RuntimeError("post_with_retry: unreachable")


def main() -> int:
    supabase_url = os.environ.get("SUPABASE_URL", "").rstrip("/")
    anon_key = os.environ.get("SUPABASE_ANON_KEY", "")
    if not supabase_url or not anon_key:
        sys.exit("error: set SUPABASE_URL and SUPABASE_ANON_KEY env vars")

    text = CATALOG_PATH.read_text()
    entries = list(parse_catalog(text))
    if not entries:
        sys.exit("error: no ResortEntry rows parsed from ResortCatalog.swift — regex out of date?")

    print(f"prewarm: {len(entries)} resorts, posting to {supabase_url}/functions/v1/snapshot-resort")

    failures = []
    cached_count = 0
    built_count = 0

    # Inter-request delay. Cached-hits return ~100ms (we want fast iteration
    # through them); fresh builds spend 4-10s in the function itself, plus
    # we want spacing for Open-Meteo to recover. The script bumps to 30s
    # AFTER a fresh build, otherwise stays at 1s for cache hits.
    PACE_AFTER_BUILD_S = 30
    PACE_AFTER_CACHE_S = 1

    for i, (rid, name, south, west, north, east, pin) in enumerate(entries, start=1):
        payload = {
            "resort_id": rid,
            "south": south,
            "west": west,
            "north": north,
            "east": east,
            "pinned_snapshot_date": pin,
        }
        prefix = f"[{i:3d}/{len(entries)}] {rid:<32} pin={pin}"
        is_build = False
        try:
            body = drive_chunked_build(supabase_url, anon_key, payload)
            if body.get("cached"):
                cached_count += 1
                print(f"{prefix}  cached", flush=True)
            else:
                built_count += 1
                is_build = True
                print(f"{prefix}  BUILT (snapshot_date={body.get('snapshot_date')})", flush=True)
        except urllib.error.HTTPError as e:
            failures.append((rid, f"HTTP {e.code}: {e.read().decode('utf-8', 'replace')[:200]}"))
            print(f"{prefix}  FAILED — HTTP {e.code}", flush=True)
        except urllib.error.URLError as e:
            failures.append((rid, f"URLError: {e}"))
            print(f"{prefix}  FAILED — {e}", flush=True)
        except Exception as e:
            failures.append((rid, f"{type(e).__name__}: {e}"))
            print(f"{prefix}  FAILED — {e}", flush=True)

        # Long pace after a fresh build, short pace after a cache hit.
        # Open-Meteo recovers in ~60-120s; back-to-back builds without a
        # pause hit the per-IP rate limit immediately.
        time.sleep(PACE_AFTER_BUILD_S if is_build else PACE_AFTER_CACHE_S)

    print(f"\nprewarm done. cached={cached_count} built={built_count} failed={len(failures)}")
    if failures:
        print("\nfailures:")
        for rid, msg in failures:
            print(f"  {rid}: {msg}")
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
