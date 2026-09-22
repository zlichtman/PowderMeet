"""Stage a confirmed `DraftManifest`, then explicitly publish its built graph.

Idempotent strategy:
  1. Compute a content hash of the draft.
  2. Fetch the latest staged or published manifest for resort_id.
  3. If the prior validator_notes contains the same content_hash tag,
     no-op (return existing manifest_version).
  4. Else call the apply_canonical_manifest RPC with the full payload
     in one transaction. RPC bumps manifest_version internally.

Applying never changes the client-visible dataset. After a successful build,
publish() atomically moves the active pointer to one exact immutable graph
tuple. The same operation can point back to an older publication for rollback.
"""

from __future__ import annotations
import hashlib
import json
import math
import os
import re
from dataclasses import dataclass
from datetime import date
from typing import Optional, Dict, Any, List
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen

from canonical_ingest.models import DraftManifest, DraftRow


SUPABASE_URL = os.environ.get("SUPABASE_URL", "")
SUPABASE_SERVICE_KEY = os.environ.get("SUPABASE_SERVICE_ROLE_KEY", "")
REQUEST_TIMEOUT = 60
VALID_DIFFICULTIES = frozenset({
    "green", "blue", "black", "doubleBlack", "terrainPark",
})
VALID_LIFT_TYPES = frozenset({
    "chair_lift", "gondola", "cable_car", "drag_lift", "t-bar",
    "j-bar", "platter", "rope_tow", "magic_carpet", "funicular",
    "zip_line", "station", "unknown",
})
VALID_RESORT_ID = re.compile(r"[A-Za-z0-9][A-Za-z0-9_-]{0,99}")


def apply(
    manifest: DraftManifest,
    *,
    dry_run: bool = False,
) -> "ApplyResult":
    _validate_manifest(manifest)
    if not (SUPABASE_URL and SUPABASE_SERVICE_KEY) and not dry_run:
        raise RuntimeError(
            "SUPABASE_URL + SUPABASE_SERVICE_ROLE_KEY env vars required "
            "to write canonical_* tables (dry-run does not require them)"
        )
    if not dry_run and not _publication_safety_available():
        raise RuntimeError(
            "canonical publication-safety migration is not applied; "
            "refusing to create an immediately-visible manifest"
        )

    new_hash = _content_hash(manifest)
    existing = _fetch_latest(manifest.resort_id) if not dry_run else None

    if existing and _hash_matches(existing.get("validator_notes"), new_hash):
        return ApplyResult(
            resort_id=manifest.resort_id,
            manifest_version=existing["manifest_version"],
            written=False,
            note="no content change vs latest staged/published manifest",
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

    notes = _validator_notes_with_evidence(manifest)
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
        note=f"staged v{new_version}; build and publish an exact graph blob next",
    )


def publish(
    resort_id: str,
    manifest_version: int,
    graph_version: str,
    snapshot_date: str,
    content_sha256: str,
) -> "PublishResult":
    if not (SUPABASE_URL and SUPABASE_SERVICE_KEY):
        raise RuntimeError(
            "SUPABASE_URL + SUPABASE_SERVICE_ROLE_KEY env vars required "
            "to publish a canonical graph"
        )
    normalized_resort_id = resort_id.strip() if isinstance(resort_id, str) else ""
    if not VALID_RESORT_ID.fullmatch(normalized_resort_id):
        raise ValueError("resort_id is invalid")
    if (
        isinstance(manifest_version, bool)
        or not isinstance(manifest_version, int)
        or manifest_version <= 0
    ):
        raise ValueError("manifest_version must be positive")
    if (
        not isinstance(graph_version, str)
        or not re.fullmatch(r"v[0-9]+(?:-s[0-9]+)?", graph_version)
    ):
        raise ValueError("invalid graph_version")
    try:
        date.fromisoformat(snapshot_date)
    except (TypeError, ValueError) as error:
        raise ValueError("snapshot_date must be YYYY-MM-DD") from error
    if (
        not isinstance(content_sha256, str)
        or not re.fullmatch(r"[0-9a-f]{64}", content_sha256)
    ):
        raise ValueError("content_sha256 must be a lowercase SHA-256")
    if not _publication_safety_available():
        raise RuntimeError(
            "canonical publication-safety migration is not applied"
        )

    result = _rpc("publish_canonical_manifest", {
        "p_resort_id": normalized_resort_id,
        "p_manifest_version": manifest_version,
        "p_graph_version": graph_version,
        "p_snapshot_date": snapshot_date,
        "p_content_sha256": content_sha256,
    })
    if not isinstance(result, dict):
        raise RuntimeError("publish_canonical_manifest returned an invalid result")
    expected = {
        "resort_id": normalized_resort_id,
        "manifest_version": manifest_version,
        "graph_version": graph_version,
        "snapshot_date": snapshot_date,
        "content_sha256": content_sha256,
    }
    if any(result.get(key) != value for key, value in expected.items()):
        raise RuntimeError(
            "publish_canonical_manifest returned a mismatched graph identity"
        )
    blob_storage_path = result.get("blob_storage_path")
    if not isinstance(blob_storage_path, str) or not blob_storage_path.strip():
        raise RuntimeError(
            "publish_canonical_manifest returned an invalid storage path"
        )
    return PublishResult(
        resort_id=normalized_resort_id,
        manifest_version=manifest_version,
        graph_version=graph_version,
        snapshot_date=snapshot_date,
        content_sha256=content_sha256,
        blob_storage_path=blob_storage_path,
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
    payload: Dict[str, Any] = {
        "name": r.name,
        "osm_way_ids": _canonical_way_ids(r),
        "geometry": r.geometry,
    }
    if r.kind == "trail":
        payload.update({
            "difficulty": r.difficulty,
            "is_groomed": r.is_groomed,
            "has_moguls": r.has_moguls,
            "is_gladed": r.is_gladed,
            "length_m": r.length_m,
            "vert_m": r.vert_m,
        })
    else:
        payload.update({
            "lift_type": r.lift_type,
            "capacity": r.capacity,
            "ride_time_s": r.ride_time_s,
            "vertical_rise_m": r.vertical_rise_m,
            "weekday_wait_min": r.weekday_wait_min,
            "weekend_wait_min": r.weekend_wait_min,
            "base_coord": r.base_coord,
            "top_coord": r.top_coord,
        })
    return payload


def _hash_matches(notes: Optional[str], expected_hash: str) -> bool:
    if not notes:
        return False
    tag = f"#content_hash:{expected_hash}"
    return tag in notes


def _is_accepted(r: DraftRow) -> bool:
    return r.accepted and not (r.notes and r.notes.startswith("REJECT:"))


def _accepted_count(rows: List[DraftRow]) -> int:
    return sum(1 for r in rows if _is_accepted(r))


def _validate_manifest(manifest: DraftManifest) -> None:
    if (
        not isinstance(manifest.resort_id, str)
        or not VALID_RESORT_ID.fullmatch(manifest.resort_id)
    ):
        raise ManifestValidationError("resort_id is invalid")
    if not manifest.canonical_counts_reviewed:
        raise ManifestValidationError(
            "canonical identity counts have not been reviewed; headline "
            "statistics and source candidate counts cannot authorize apply"
        )
    expected_counts = (manifest.expected_trail_count, manifest.expected_lift_count)
    if any(isinstance(count, bool) or not isinstance(count, int) for count in expected_counts):
        raise ManifestValidationError("expected canonical counts must be integers")
    if manifest.expected_trail_count < 0 or manifest.expected_lift_count < 0:
        raise ManifestValidationError("expected canonical counts must be non-negative")
    headline_counts = (manifest.headline_trail_count, manifest.headline_lift_count)
    if any(
        count is not None and (isinstance(count, bool) or not isinstance(count, int))
        for count in headline_counts
    ):
        raise ManifestValidationError("headline evidence counts must be integers")
    if any(count is not None and count < 0 for count in headline_counts):
        raise ManifestValidationError("headline evidence counts must be non-negative")

    accepted_trails = [row for row in manifest.trail_rows if _is_accepted(row)]
    accepted_lifts = [row for row in manifest.lift_rows if _is_accepted(row)]
    if len(accepted_trails) != manifest.expected_trail_count:
        raise ManifestValidationError(
            f"accepted trail count {len(accepted_trails)} does not match "
            f"expected canonical trail identity count {manifest.expected_trail_count}"
        )
    if len(accepted_lifts) != manifest.expected_lift_count:
        raise ManifestValidationError(
            f"accepted lift count {len(accepted_lifts)} does not match "
            f"expected canonical lift identity count {manifest.expected_lift_count}"
        )
    if any(row.kind != "trail" for row in accepted_trails):
        raise ManifestValidationError("trail_rows contains an accepted non-trail row")
    if any(row.kind != "lift" for row in accepted_lifts):
        raise ManifestValidationError("lift_rows contains an accepted non-lift row")

    for label, rows in (("trail", accepted_trails), ("lift", accepted_lifts)):
        names = [row.name.strip().casefold() for row in rows]
        if any(not name for name in names):
            raise ManifestValidationError(f"accepted {label} rows must have names")
        if len(names) != len(set(names)):
            raise ManifestValidationError(f"accepted {label} names must be unique")
        if any(row.name != row.name.strip() for row in rows):
            raise ManifestValidationError(
                f"accepted {label} names must not have leading/trailing whitespace"
            )
        for row in rows:
            if any(not isinstance(value, str) or not value.strip() for value in row.osm_way_ids):
                raise ManifestValidationError(
                    f"accepted {label} {row.name!r} has an invalid osm_way_id"
                )
        conflicted = [row.name for row in rows if row.unresolved_conflicts]
        if conflicted:
            raise ManifestValidationError(
                f"accepted {label} rows have unresolved source conflicts: "
                f"{', '.join(sorted(conflicted))}"
            )

    for row in accepted_trails:
        _validate_trail_attributes(row)
    for row in accepted_lifts:
        _validate_lift_attributes(row)


class ManifestValidationError(ValueError):
    pass


def _validator_notes_with_evidence(manifest: DraftManifest) -> str:
    """Persist provenance without letting it affect routing-data identity.

    The content hash intentionally excludes review evidence so changing a URL
    or observation date cannot mint a new graph version by itself.
    """
    lines = []
    if manifest.validator_notes and manifest.validator_notes.strip():
        lines.append(manifest.validator_notes.strip())
    if manifest.evidence_observed_at:
        lines.append(f"evidence_observed_at:{manifest.evidence_observed_at}")
    if manifest.headline_trail_count is not None or manifest.headline_lift_count is not None:
        trails = manifest.headline_trail_count
        lifts = manifest.headline_lift_count
        lines.append(
            "headline_statistics_only:"
            f"trails_or_runs={trails if trails is not None else 'unknown'},"
            f"lifts={lifts if lifts is not None else 'unknown'}"
        )
    lines.extend(f"evidence_url:{reference}" for reference in manifest.source_references)
    return "\n".join(lines)


# ── Payload builders ─────────────────────────────────────────────────


def _trail_payload(r: DraftRow) -> Dict[str, Any]:
    return {
        "name": r.name,
        "difficulty": r.difficulty,
        "is_groomed": r.is_groomed,
        "has_moguls": r.has_moguls,
        "is_gladed": r.is_gladed,
        "length_m": r.length_m,
        "vert_m": r.vert_m,
        "osm_way_ids": _canonical_way_ids(r),
        "canonical_geometry": _line_geojson(r.geometry),
    }


def _lift_payload(r: DraftRow) -> Dict[str, Any]:
    return {
        "name": r.name,
        "lift_type": r.lift_type,
        "capacity": r.capacity,
        "ride_time_s": r.ride_time_s,
        "vertical_rise_m": r.vertical_rise_m,
        "weekday_wait_min": r.weekday_wait_min,
        "weekend_wait_min": r.weekend_wait_min,
        "base_coord": _point_geojson(r.base_coord),
        "top_coord": _point_geojson(r.top_coord),
        "osm_way_ids": _canonical_way_ids(r),
        "canonical_geometry": _line_geojson(r.geometry),
    }


def _validate_trail_attributes(row: DraftRow) -> None:
    if row.difficulty is not None and row.difficulty not in VALID_DIFFICULTIES:
        raise ManifestValidationError(
            f"accepted trail {row.name!r} has invalid difficulty {row.difficulty!r}"
        )
    _optional_bool(row.is_groomed, f"trail {row.name!r} is_groomed")
    _required_bool(row.has_moguls, f"trail {row.name!r} has_moguls")
    _required_bool(row.is_gladed, f"trail {row.name!r} is_gladed")
    _optional_nonnegative_number(row.length_m, f"trail {row.name!r} length_m")
    _optional_nonnegative_number(row.vert_m, f"trail {row.name!r} vert_m")
    _optional_line(row.geometry, f"trail {row.name!r} geometry")


def _validate_lift_attributes(row: DraftRow) -> None:
    if row.lift_type is not None and row.lift_type not in VALID_LIFT_TYPES:
        raise ManifestValidationError(
            f"accepted lift {row.name!r} has invalid lift_type {row.lift_type!r}"
        )
    if row.capacity is not None:
        if isinstance(row.capacity, bool) or not isinstance(row.capacity, int):
            raise ManifestValidationError(
                f"lift {row.name!r} capacity must be an integer"
            )
        if row.capacity <= 0:
            raise ManifestValidationError(
                f"lift {row.name!r} capacity must be positive"
            )
    for field, value in (
        ("ride_time_s", row.ride_time_s),
        ("vertical_rise_m", row.vertical_rise_m),
        ("weekday_wait_min", row.weekday_wait_min),
        ("weekend_wait_min", row.weekend_wait_min),
    ):
        _optional_nonnegative_number(value, f"lift {row.name!r} {field}")
    _optional_coord(row.base_coord, f"lift {row.name!r} base_coord")
    _optional_coord(row.top_coord, f"lift {row.name!r} top_coord")
    _optional_line(row.geometry, f"lift {row.name!r} geometry")


def _required_bool(value: object, label: str) -> None:
    if not isinstance(value, bool):
        raise ManifestValidationError(f"{label} must be boolean")


def _optional_bool(value: object, label: str) -> None:
    if value is not None:
        _required_bool(value, label)


def _optional_nonnegative_number(value: object, label: str) -> None:
    if value is None:
        return
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise ManifestValidationError(f"{label} must be numeric")
    if not math.isfinite(float(value)) or float(value) < 0:
        raise ManifestValidationError(f"{label} must be finite and non-negative")


def _optional_coord(coord, label: str) -> None:
    if coord is None:
        return
    if not isinstance(coord, (list, tuple)) or len(coord) != 2:
        raise ManifestValidationError(f"{label} must be a (lon, lat) pair")
    lon, lat = coord
    _optional_nonnegative_or_signed_number(lon, f"{label} longitude")
    _optional_nonnegative_or_signed_number(lat, f"{label} latitude")
    if not -180 <= float(lon) <= 180 or not -90 <= float(lat) <= 90:
        raise ManifestValidationError(f"{label} is outside valid lon/lat bounds")


def _optional_nonnegative_or_signed_number(value: object, label: str) -> None:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise ManifestValidationError(f"{label} must be numeric")
    if not math.isfinite(float(value)):
        raise ManifestValidationError(f"{label} must be finite")


def _optional_line(line, label: str) -> None:
    if line is None:
        return
    if not isinstance(line, list) or len(line) < 2:
        raise ManifestValidationError(f"{label} must have at least two coordinates")
    for index, coord in enumerate(line):
        _optional_coord(coord, f"{label}[{index}]")


def _line_geojson(line):
    if not line:
        return None
    return {
        "type": "LineString",
        "coordinates": [[float(c[0]), float(c[1])] for c in line],
    }


def _point_geojson(coord):
    if not coord:
        return None
    return {
        "type": "Point",
        "coordinates": [float(coord[0]), float(coord[1])],
    }


def _canonical_way_ids(row: DraftRow) -> List[str]:
    return sorted(set(row.osm_way_ids), key=_way_id_sort_key)


def _way_id_sort_key(value: str):
    return (0, int(value)) if value.isdigit() else (1, value)


# ── HTTP plumbing ────────────────────────────────────────────────────


def _fetch_latest(resort_id: str) -> Optional[Dict[str, Any]]:
    url = (
        f"{SUPABASE_URL}/rest/v1/resort_canonical_manifest"
        f"?resort_id=eq.{resort_id}"
        f"&select=resort_id,manifest_version,validator_notes"
        "&order=manifest_version.desc&limit=1"
    )
    body = _http_get(url)
    if not body:
        return None
    rows = json.loads(body)
    return rows[0] if rows else None


def _publication_safety_available() -> bool:
    url = (
        f"{SUPABASE_URL}/rest/v1/resort_canonical_active"
        "?select=resort_id&limit=0"
    )
    return _http_get(url) is not None


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


@dataclass(frozen=True)
class PublishResult:
    resort_id: str
    manifest_version: int
    graph_version: str
    snapshot_date: str
    content_sha256: str
    blob_storage_path: str
