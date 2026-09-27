"""Command-line entry point for canonical_ingest.

Usage:
  python -m canonical_ingest ingest <resort_id>      — fetch + reconcile, write draft.json
  python -m canonical_ingest review <resort_id>      — open draft.json for human review (prints summary)
  python -m canonical_ingest apply <resort_id>       — stage reviewed draft in Postgres
  python -m canonical_ingest publish <resort_id>     — activate one exact built graph
  python -m canonical_ingest geometry <resort_id>    — open the override authoring tool (Phase 11)

Drafts live under `tools/canonical_ingest/drafts/{resort_id}.json` so
review state survives between invocations.
"""

from __future__ import annotations
import argparse
import json
import sys
from dataclasses import asdict
from pathlib import Path
from typing import Dict, Tuple

from canonical_ingest import apply as apply_mod
from canonical_ingest import identity_decisions
from canonical_ingest import reconcile as reconcile_mod
from canonical_ingest import review_report
from canonical_ingest.models import DraftManifest, DraftRow
from canonical_ingest.sources import (
    official,
    official_map,
    openskimap,
    overpass,
    skimap,
)


SOURCES = {
    "skimap": skimap.fetch,
    "openskimap": openskimap.fetch,
    "overpass": overpass.fetch,
    "official": official.fetch,
    "official_map": official_map.fetch,
}

DRAFTS_DIR = Path(__file__).resolve().parent / "drafts"


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(prog="canonical_ingest")
    sub = p.add_subparsers(dest="cmd", required=True)

    ing = sub.add_parser("ingest", help="fetch + reconcile sources, write draft")
    ing.add_argument("resort_id")
    ing.add_argument(
        "--expected-canonical-trails", "--expected-trails",
        dest="expected_canonical_trails", type=int, default=None,
        help=(
            "reviewed unique routable trail-identity count; "
            "--expected-trails is a deprecated alias"
        ),
    )
    ing.add_argument(
        "--expected-canonical-lifts", "--expected-lifts",
        dest="expected_canonical_lifts", type=int, default=None,
        help=(
            "reviewed unique routable lift-identity count; "
            "--expected-lifts is a deprecated alias"
        ),
    )
    ing.add_argument(
        "--canonical-counts-reviewed", action="store_true",
        help=(
            "assert that both canonical counts came from a reviewed identity "
            "inventory, not headline resort statistics"
        ),
    )
    ing.add_argument(
        "--headline-trails", type=int, default=None,
        help="optional resort-published trail/run statistic (evidence only)",
    )
    ing.add_argument(
        "--headline-lifts", type=int, default=None,
        help="optional resort-published lift statistic (evidence only)",
    )
    ing.add_argument(
        "--evidence-url", action="append", default=[],
        help="review source URL; repeat for multiple sources",
    )
    ing.add_argument(
        "--evidence-observed-at", default=None,
        help="date/time the cited evidence was observed",
    )
    ing.add_argument("--bbox", type=str, default=None,
                     help="south,west,north,east (decimal degrees)")
    ing.add_argument("--lat-lon", type=str, default=None,
                     help="lat,lon (decimal degrees) for proximity-based lookups")
    ing.add_argument(
        "--offline-fixtures", action="store_true",
        help=(
            "use only committed/local official evidence and the cached "
            "Overpass fixture; never access network sources"
        ),
    )

    rev = sub.add_parser("review", help="show draft summary")
    rev.add_argument("resort_id")
    rev.add_argument(
        "--report-json", type=Path, default=None,
        help="write the full deterministic row/topology checklist as JSON",
    )

    app = sub.add_parser("apply", help="stage reviewed draft in Postgres")
    app.add_argument("resort_id")
    app.add_argument("--dry-run", action="store_true")

    pub = sub.add_parser(
        "publish",
        help="atomically activate one exact, already-built graph blob",
    )
    pub.add_argument("resort_id")
    pub.add_argument("--manifest-version", type=int, required=True)
    pub.add_argument("--graph-version", default="v15")
    pub.add_argument("--snapshot-date", required=True)
    pub.add_argument("--content-sha256", required=True)

    geo = sub.add_parser("geometry", help="open override authoring tool")
    geo.add_argument("resort_id")

    args = p.parse_args(argv)
    DRAFTS_DIR.mkdir(parents=True, exist_ok=True)

    if args.cmd == "ingest":
        return _cmd_ingest(args)
    if args.cmd == "review":
        return _cmd_review(args)
    if args.cmd == "apply":
        return _cmd_apply(args)
    if args.cmd == "publish":
        return _cmd_publish(args)
    if args.cmd == "geometry":
        return _cmd_geometry(args)
    p.print_help()
    return 2


def _draft_path(resort_id: str) -> Path:
    return DRAFTS_DIR / f"{resort_id}.json"


def _cmd_ingest(args) -> int:
    reviewed = bool(getattr(args, "canonical_counts_reviewed", False))
    expected_trails = getattr(args, "expected_canonical_trails", None)
    expected_lifts = getattr(args, "expected_canonical_lifts", None)
    if reviewed and (expected_trails is None or expected_lifts is None):
        print(
            "--canonical-counts-reviewed requires both "
            "--expected-canonical-trails and --expected-canonical-lifts",
            file=sys.stderr,
        )
        return 8

    hints: Dict[str, object] = {}
    if args.bbox:
        hints["bbox"] = _parse_bbox(args.bbox)
    if args.lat_lon:
        hints["lat_lon"] = _parse_lat_lon(args.lat_lon)
    offline_fixtures = bool(getattr(args, "offline_fixtures", False))
    if offline_fixtures:
        hints["offline_fixtures"] = True

    results = []
    active_sources = (
        {
            "official": official.fetch,
            "official_map": official_map.fetch,
            "overpass": overpass.fetch,
        }
        if offline_fixtures else SOURCES
    )
    for name, fn in active_sources.items():
        try:
            results.append(fn(args.resort_id, hints))
        except Exception as exc:
            print(f"[{name}] fetch failed: {exc}", file=sys.stderr)
            if offline_fixtures:
                return 9

    for result in results:
        trail_count = sum(1 for item in result.items if item.kind == "trail")
        lift_count = sum(1 for item in result.items if item.kind == "lift")
        print(f"[{result.source}] {trail_count} trails / {lift_count} lifts")

    applied_decisions = 0
    if any(result.items for result in results):
        try:
            results, applied_decisions = identity_decisions.load_and_apply(
                args.resort_id, results
            )
        except identity_decisions.IdentityDecisionError as err:
            print(f"IDENTITY DECISION INVALID: {err}", file=sys.stderr)
            return 10
    if applied_decisions:
        print(f"[identity_decisions] applied {applied_decisions} merge(s)")

    try:
        manifest = reconcile_mod.reconcile(
            results,
            expected_trail_count=expected_trails,
            expected_lift_count=expected_lifts,
        )
    except reconcile_mod.CountDisagreementError as err:
        print(f"COUNT DISAGREEMENT for {err.resort_id}:", file=sys.stderr)
        for source, counts in err.per_source.items():
            print(f"  {source}: {counts['trails']} trails, {counts['lifts']} lifts",
                  file=sys.stderr)
        print(
            "\n  resolve only after identity review via: "
            "--expected-canonical-trails N --expected-canonical-lifts N "
            "--canonical-counts-reviewed",
            file=sys.stderr,
        )
        return 3
    except reconcile_mod.SourceDataUnavailableError as err:
        print(str(err), file=sys.stderr)
        for source, counts in err.per_source.items():
            print(
                f"  {source}: {counts['trails']} trails, {counts['lifts']} lifts",
                file=sys.stderr,
            )
        return 6

    manifest.canonical_counts_reviewed = reviewed
    manifest.headline_trail_count = getattr(args, "headline_trails", None)
    manifest.headline_lift_count = getattr(args, "headline_lifts", None)
    manifest.evidence_observed_at = getattr(args, "evidence_observed_at", None)
    manifest.source_references = tuple(getattr(args, "evidence_url", ()) or ())

    path = _draft_path(args.resort_id)
    preserved = 0
    if path.exists():
        try:
            existing = json.loads(path.read_text())
            preserved = _preserve_review_decisions(manifest, existing)
        except (OSError, ValueError, KeyError, TypeError):
            preserved = 0
    path.write_text(json.dumps(_serialize_draft(manifest), indent=2))
    print(f"draft written → {path}")
    print(f"  {len(manifest.trail_rows)} trails / {len(manifest.lift_rows)} lifts")
    if preserved:
        print(f"  preserved {preserved} unchanged operator decision(s)")
    return 0


def _cmd_review(args) -> int:
    path = _draft_path(args.resort_id)
    if not path.exists():
        print(f"no draft for {args.resort_id} — run `ingest` first", file=sys.stderr)
        return 4
    raw = json.loads(path.read_text())
    fixture_path = (
        Path(__file__).resolve().parent
        / "fixtures" / "overpass" / f"{args.resort_id}.json"
    )
    fixture = json.loads(fixture_path.read_text()) if fixture_path.exists() else None
    validation_error = None
    try:
        apply_mod._validate_manifest(_deserialize_draft(raw))
    except apply_mod.ManifestValidationError as error:
        validation_error = str(error)
    report = review_report.build_report(
        raw, fixture,
        apply_validation_checked=True,
        apply_validation_error=validation_error,
    )
    print(review_report.summary_text(report))
    report_path = getattr(args, "report_json", None)
    if report_path is not None:
        report_path.parent.mkdir(parents=True, exist_ok=True)
        report_path.write_text(json.dumps(report, indent=2) + "\n")
        print(f"full review report written → {report_path}")
    return 0


def _cmd_apply(args) -> int:
    path = _draft_path(args.resort_id)
    if not path.exists():
        print(f"no draft for {args.resort_id}", file=sys.stderr)
        return 4
    raw = json.loads(path.read_text())
    manifest = _deserialize_draft(raw)
    try:
        result = apply_mod.apply(manifest, dry_run=args.dry_run)
    except apply_mod.ManifestValidationError as err:
        print(f"manifest validation failed: {err}", file=sys.stderr)
        return 7
    except RuntimeError as err:
        print(f"apply failed: {err}", file=sys.stderr)
        return 10
    print(f"{result.resort_id}: v{result.manifest_version} — {result.note}")
    return 0 if result.written or args.dry_run else 0


def _cmd_publish(args) -> int:
    try:
        result = apply_mod.publish(
            args.resort_id,
            args.manifest_version,
            args.graph_version,
            args.snapshot_date,
            args.content_sha256,
        )
    except (ValueError, RuntimeError) as error:
        print(f"publication failed: {error}", file=sys.stderr)
        return 10
    print(
        f"{result.resort_id}: activated manifest v{result.manifest_version} "
        f"{result.graph_version} {result.snapshot_date} "
        f"sha256={result.content_sha256}"
    )
    return 0


def _cmd_geometry(args) -> int:
    from canonical_ingest import geometry_tool
    return geometry_tool.main(args.resort_id)


def _parse_bbox(s: str) -> Tuple[float, float, float, float]:
    parts = [float(x.strip()) for x in s.split(",")]
    if len(parts) != 4:
        raise ValueError("--bbox must be south,west,north,east")
    return (parts[0], parts[1], parts[2], parts[3])


def _parse_lat_lon(s: str) -> Tuple[float, float]:
    parts = [float(x.strip()) for x in s.split(",")]
    if len(parts) != 2:
        raise ValueError("--lat-lon must be lat,lon")
    return (parts[0], parts[1])


def _serialize_draft(manifest: DraftManifest) -> dict:
    return {
        "resort_id": manifest.resort_id,
        "expected_trail_count": manifest.expected_trail_count,
        "expected_lift_count": manifest.expected_lift_count,
        "validator_notes": manifest.validator_notes,
        "canonical_counts_reviewed": manifest.canonical_counts_reviewed,
        "headline_trail_count": manifest.headline_trail_count,
        "headline_lift_count": manifest.headline_lift_count,
        "evidence_observed_at": manifest.evidence_observed_at,
        "source_references": list(manifest.source_references),
        "trail_rows": [_serialize_row(r) for r in manifest.trail_rows],
        "lift_rows": [_serialize_row(r) for r in manifest.lift_rows],
    }


def _serialize_row(row: DraftRow) -> dict:
    return {
        "name": row.name,
        "kind": row.kind,
        "sources_seen": list(row.sources_seen),
        "confidence": row.confidence,
        "accepted": row.accepted,
        "difficulty": row.difficulty,
        "is_groomed": row.is_groomed,
        "has_moguls": row.has_moguls,
        "is_gladed": row.is_gladed,
        "length_m": row.length_m,
        "vert_m": row.vert_m,
        "lift_type": row.lift_type,
        "capacity": row.capacity,
        "ride_time_s": row.ride_time_s,
        "vertical_rise_m": row.vertical_rise_m,
        "weekday_wait_min": row.weekday_wait_min,
        "weekend_wait_min": row.weekend_wait_min,
        "base_coord": row.base_coord,
        "top_coord": row.top_coord,
        "geometry": row.geometry,
        "osm_way_ids": list(row.osm_way_ids),
        "source_name_variants": list(row.source_name_variants),
        "source_segment_counts": row.source_segment_counts,
        "source_attribute_observations": {
            source: {
                attribute: [json.loads(value) for value in values]
                for attribute, values in sorted(attributes.items())
            }
            for source, attributes in row.source_attribute_observations.items()
        },
        "source_evidence_fingerprint": row.source_evidence_fingerprint,
        "identity_decision_ids": list(row.identity_decision_ids),
        "unresolved_conflicts": list(row.unresolved_conflicts),
        "notes": row.notes,
    }


def _deserialize_draft(raw: dict) -> DraftManifest:
    return DraftManifest(
        resort_id=raw["resort_id"],
        expected_trail_count=raw["expected_trail_count"],
        expected_lift_count=raw["expected_lift_count"],
        validator_notes=raw.get("validator_notes"),
        canonical_counts_reviewed=raw.get("canonical_counts_reviewed", False),
        headline_trail_count=raw.get("headline_trail_count"),
        headline_lift_count=raw.get("headline_lift_count"),
        evidence_observed_at=raw.get("evidence_observed_at"),
        source_references=tuple(raw.get("source_references", [])),
        trail_rows=[_deserialize_row(r) for r in raw.get("trail_rows", [])],
        lift_rows=[_deserialize_row(r) for r in raw.get("lift_rows", [])],
    )


def _deserialize_row(raw: dict) -> DraftRow:
    return DraftRow(
        name=raw["name"],
        kind=raw["kind"],
        sources_seen=tuple(raw.get("sources_seen", [])),
        confidence=raw.get("confidence", 0.0),
        accepted=raw.get("accepted", False),
        difficulty=raw.get("difficulty"),
        is_groomed=raw.get("is_groomed"),
        has_moguls=raw.get("has_moguls", False),
        is_gladed=raw.get("is_gladed", False),
        length_m=raw.get("length_m"),
        vert_m=raw.get("vert_m"),
        lift_type=raw.get("lift_type"),
        capacity=raw.get("capacity"),
        ride_time_s=raw.get("ride_time_s"),
        vertical_rise_m=raw.get("vertical_rise_m"),
        weekday_wait_min=raw.get("weekday_wait_min"),
        weekend_wait_min=raw.get("weekend_wait_min"),
        base_coord=_deserialize_coord(raw.get("base_coord")),
        top_coord=_deserialize_coord(raw.get("top_coord")),
        geometry=_deserialize_geometry(raw.get("geometry")),
        osm_way_ids=tuple(raw.get("osm_way_ids", [])),
        source_name_variants=tuple(raw.get("source_name_variants", [])),
        source_segment_counts=dict(raw.get("source_segment_counts", {})),
        source_attribute_observations={
            str(source): {
                str(attribute): tuple(_canonical_json(value) for value in values)
                for attribute, values in (attributes or {}).items()
            }
            for source, attributes in (
                raw.get("source_attribute_observations") or {}
            ).items()
        },
        source_evidence_fingerprint=raw.get("source_evidence_fingerprint"),
        identity_decision_ids=tuple(raw.get("identity_decision_ids", [])),
        unresolved_conflicts=tuple(raw.get("unresolved_conflicts", [])),
        notes=raw.get("notes"),
    )


def _deserialize_coord(raw):
    if not isinstance(raw, (list, tuple)) or len(raw) < 2:
        return None
    return (float(raw[0]), float(raw[1]))


def _deserialize_geometry(raw):
    if not isinstance(raw, list):
        return None
    coordinates = [_deserialize_coord(coord) for coord in raw]
    return [coord for coord in coordinates if coord is not None] or None


def _canonical_json(value: object) -> str:
    return json.dumps(value, sort_keys=True, separators=(",", ":"), default=str)


def _preserve_review_decisions(manifest: DraftManifest, raw: dict) -> int:
    """Carry operator edits only across byte-equivalent source evidence.

    A source geometry, attribute, name, or way-ID change invalidates the old
    decision. This prevents a routine refresh from silently accepting new
    evidence while still protecting hours of unchanged manual review.
    """
    existing = _deserialize_draft(raw)
    old_rows = existing.trail_rows + existing.lift_rows
    new_rows = manifest.trail_rows + manifest.lift_rows
    by_key: Dict[tuple, list[DraftRow]] = {}
    for row in old_rows:
        if not (row.accepted or row.notes):
            continue
        by_key.setdefault(_source_identity_key(row), []).append(row)
    preserved = 0
    for row in new_rows:
        candidates = by_key.get(_source_identity_key(row), [])
        if len(candidates) != 1:
            continue
        prior = candidates[0]
        if not row.source_evidence_fingerprint or (
            row.source_evidence_fingerprint != prior.source_evidence_fingerprint
        ):
            continue
        _copy_operator_fields(prior, row)
        preserved += 1
    return preserved


def _source_identity_key(row: DraftRow) -> tuple:
    variants = row.source_name_variants or (row.name,)
    return (
        row.kind,
        tuple(sorted({reconcile_mod.normalize_name(value) for value in variants})),
        tuple(sorted(set(row.osm_way_ids), key=_identifier_key)),
    )


def _copy_operator_fields(source: DraftRow, target: DraftRow) -> None:
    for field in (
        "name", "accepted", "difficulty", "is_groomed", "has_moguls",
        "is_gladed", "length_m", "vert_m", "lift_type", "capacity",
        "ride_time_s", "vertical_rise_m", "weekday_wait_min",
        "weekend_wait_min", "base_coord", "top_coord", "geometry",
        "unresolved_conflicts", "notes",
    ):
        setattr(target, field, getattr(source, field))


def _identifier_key(value: str):
    return (0, int(value)) if value.isdigit() else (1, value)


if __name__ == "__main__":
    sys.exit(main())
