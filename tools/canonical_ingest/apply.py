"""Push a confirmed `DraftManifest` into Postgres via the
`apply_canonical_manifest` RPC (atomic single-call insert).

Idempotent strategy:
  1. Compute a content hash of the draft.
  2. Fetch current_resort_canonical_manifest for resort_id.
  3. If the prior validator_notes contains the same content_hash tag,
     no-op (return existing manifest_version).
  4. Else call the apply_canonical_manifest RPC with the full payload
     in one transaction. RPC bumps manifest_version internally.

Bumping discipline: every successful apply() invalidates every cached
client graph for this resort on next foreground. Only invoke after
human review confirms the diff is real (new lift, new run, geometry
correction). Source-noise diffs MUST be filtered out before this point.
"""

from __future__ import annotations
import hashlib
import json
import os
from dataclasses import dataclass
from typing import Optional, Dict, Any, List
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen

from canonical_ingest.models import DraftManifest, DraftRow


SUPABASE_URL = os.environ.get("SUPABASE_URL", "")
SUPABASE_SERVICE_KEY = os.environ.get("SUPABASE_SERVICE_ROLE_KEY", "")
REQUEST_TIMEOUT = 60


def apply(
    manifest: DraftManifest,
    *,
    dry_run: bool = False,
) -> "ApplyResult":
    if not (SUPABASE_URL and SUPABASE_SERVICE_KEY) and not dry_run:
        raise RuntimeError(
            "SUPABASE_URL + SUPABASE_SERVICE_ROLE_KEY env vars required "
            "to write canonical_* tables (dry-run does not require them)"
        )

    new_hash = _content_hash(manifest)
    existing = _fetch_current(manifest.resort_id) if not dry_run else None

    if existing and _hash_matches(existing.get("validator_notes"), new_hash):
        return ApplyResult(
            resort_id=manifest.resort_id,
            manifest_version=existing["manifest_version"],
            written=False,
            note="no content change vs current manifest",
        )

    if dry_run:
        next_version = (existing.get("manifest_version", 0) if existing else 0) + 1
        return ApplyResult(
            resort_id=manifest.resort_id,
            manifest_version=next_version,
            written=False,
            note=(
                f"DRY RUN — would write v{next_version} with "
                f"{_accepted_count(manifest.trail_rows)} trails, "
                f"{_accepted_count(manifest.lift_rows)} lifts"
            ),
        )

    notes = (manifest.validator_notes or "").strip()
    notes_with_hash = (
        (notes + ("\n" if notes else "") + f"#content_hash:{new_hash}").strip()
    )

    payload = {
        "p_resort_id": manifest.resort_id,
        "p_expected_trail_count": manifest.expected_trail_count,
        "p_expected_lift_count": manifest.expected_lift_count,
        "p_validator_notes": notes_with_hash,
        "p_trails": [_trail_payload(r) for r in manifest.trail_rows if _is_accepted(r)],
        "p_lifts":  [_lift_payload(r)  for r in manifest.lift_rows  if _is_accepted(r)],
    }
    new_version = _rpc("apply_canonical_manifest", payload)

    return ApplyResult(
        resort_id=manifest.resort_id,
        manifest_version=int(new_version),
        written=True,
        note=f"applied v{new_version}",
    )


# ── Content hash + match check ───────────────────────────────────────


def _content_hash(manifest: DraftManifest) -> str:
    payload = {
        "resort_id": manifest.resort_id,
        "expected_trail_count": manifest.expected_trail_count,
        "expected_lift_count": manifest.expected_lift_count,
        "trails": sorted(
            [_row_to_hash(r) for r in manifest.trail_rows if _is_accepted(r)],
            key=lambda r: r["name"],
        ),
        "lifts": sorted(
            [_row_to_hash(r) for r in manifest.lift_rows if _is_accepted(r)],
            key=lambda r: r["name"],
        ),
    }
    return hashlib.sha256(json.dumps(payload, sort_keys=True).encode()).hexdigest()


def _row_to_hash(r: DraftRow) -> Dict[str, Any]:
    return {
        "name": r.name,
        "osm_way_ids": list(r.osm_way_ids),
        "geometry": r.geometry,
    }


def _hash_matches(notes: Optional[str], expected_hash: str) -> bool:
    if not notes:
        return False
    tag = f"#content_hash:{expected_hash}"
    return tag in notes


def _is_accepted(r: DraftRow) -> bool:
    if r.notes and r.notes.startswith("REJECT:"):
        return False
    return True


def _accepted_count(rows: List[DraftRow]) -> int:
    return sum(1 for r in rows if _is_accepted(r))


# ── Payload builders ─────────────────────────────────────────────────


def _trail_payload(r: DraftRow) -> Dict[str, Any]:
    return {
        "name": r.name,
        "osm_way_ids": list(r.osm_way_ids),
        "canonical_geometry": _line_geojson(r.geometry),
    }


def _lift_payload(r: DraftRow) -> Dict[str, Any]:
    return {
        "name": r.name,
        "osm_way_ids": list(r.osm_way_ids),
        "canonical_geometry": _line_geojson(r.geometry),
    }


def _line_geojson(line):
    if not line:
        return None
    return {
        "type": "LineString",
        "coordinates": [[float(c[0]), float(c[1])] for c in line],
    }


# ── HTTP plumbing ────────────────────────────────────────────────────


def _fetch_current(resort_id: str) -> Optional[Dict[str, Any]]:
    url = (
        f"{SUPABASE_URL}/rest/v1/current_resort_canonical_manifest"
        f"?resort_id=eq.{resort_id}"
        f"&select=resort_id,manifest_version,validator_notes"
    )
    body = _http_get(url)
    if not body:
        return None
    rows = json.loads(body)
    return rows[0] if rows else None


def _rpc(name: str, payload: Dict[str, Any]) -> Any:
    url = f"{SUPABASE_URL}/rest/v1/rpc/{name}"
    body = json.dumps(payload).encode()
    req = Request(url, data=body, headers=_auth_headers(
        accept="application/json",
        content_type="application/json",
    ))
    try:
        with urlopen(req, timeout=REQUEST_TIMEOUT) as resp:
            data = resp.read()
    except HTTPError as err:
        msg = err.read().decode("utf-8", errors="replace")
        raise RuntimeError(f"RPC {name} failed: HTTP {err.code} — {msg}") from err
    except URLError as err:
        raise RuntimeError(f"RPC {name} failed: {err}") from err
    if not data:
        return None
    return json.loads(data)


def _http_get(url: str) -> Optional[bytes]:
    req = Request(url, headers=_auth_headers(accept="application/json"))
    try:
        with urlopen(req, timeout=REQUEST_TIMEOUT) as resp:
            return resp.read()
    except (URLError, HTTPError):
        return None


def _auth_headers(
    *,
    accept: str = "application/json",
    content_type: Optional[str] = None,
) -> Dict[str, str]:
    h = {
        "Accept": accept,
        "apikey": SUPABASE_SERVICE_KEY,
        "Authorization": f"Bearer {SUPABASE_SERVICE_KEY}",
    }
    if content_type:
        h["Content-Type"] = content_type
    return h


@dataclass(frozen=True)
class ApplyResult:
    resort_id: str
    manifest_version: int
    written: bool
    note: str
