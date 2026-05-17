"""Command-line entry point for canonical_ingest.

Usage:
  python -m canonical_ingest ingest <resort_id>      — fetch + reconcile, write draft.json
  python -m canonical_ingest review <resort_id>      — open draft.json for human review (prints summary)
  python -m canonical_ingest apply <resort_id>       — push reviewed draft to Postgres
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
from canonical_ingest import reconcile as reconcile_mod
from canonical_ingest.models import DraftManifest, DraftRow
from canonical_ingest.sources import skimap, openskimap, overpass, official


SOURCES = {
    "skimap": skimap.fetch,
    "openskimap": openskimap.fetch,
    "overpass": overpass.fetch,
    "official": official.fetch,
}

DRAFTS_DIR = Path(__file__).resolve().parent / "drafts"


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(prog="canonical_ingest")
    sub = p.add_subparsers(dest="cmd", required=True)

    ing = sub.add_parser("ingest", help="fetch + reconcile sources, write draft")
    ing.add_argument("resort_id")
    ing.add_argument("--expected-trails", type=int, default=None,
                     help="official trail count from the resort's site")
    ing.add_argument("--expected-lifts", type=int, default=None,
                     help="official lift count from the resort's site")
    ing.add_argument("--bbox", type=str, default=None,
                     help="south,west,north,east (decimal degrees)")
    ing.add_argument("--lat-lon", type=str, default=None,
                     help="lat,lon (decimal degrees) for proximity-based lookups")

    rev = sub.add_parser("review", help="show draft summary")
    rev.add_argument("resort_id")

    app = sub.add_parser("apply", help="push reviewed draft to Postgres")
    app.add_argument("resort_id")
    app.add_argument("--dry-run", action="store_true")

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
    if args.cmd == "geometry":
        return _cmd_geometry(args)
    p.print_help()
    return 2


def _draft_path(resort_id: str) -> Path:
    return DRAFTS_DIR / f"{resort_id}.json"


def _cmd_ingest(args) -> int:
    hints: Dict[str, object] = {}
    if args.bbox:
        hints["bbox"] = _parse_bbox(args.bbox)
    if args.lat_lon:
        hints["lat_lon"] = _parse_lat_lon(args.lat_lon)

    results = []
    for name, fn in SOURCES.items():
        try:
            results.append(fn(args.resort_id, hints))
        except Exception as exc:
            print(f"[{name}] fetch failed: {exc}", file=sys.stderr)

    try:
        manifest = reconcile_mod.reconcile(
            results,
            expected_trail_count=args.expected_trails,
            expected_lift_count=args.expected_lifts,
        )
    except reconcile_mod.CountDisagreementError as err:
        print(f"COUNT DISAGREEMENT for {err.resort_id}:", file=sys.stderr)
        for source, counts in err.per_source.items():
            print(f"  {source}: {counts['trails']} trails, {counts['lifts']} lifts",
                  file=sys.stderr)
        print(f"\n  resolve via: --expected-trails N --expected-lifts N "
              f"(from the resort's official site)", file=sys.stderr)
        return 3

    path = _draft_path(args.resort_id)
    path.write_text(json.dumps(_serialize_draft(manifest), indent=2))
    print(f"draft written → {path}")
    print(f"  {len(manifest.trail_rows)} trails / {len(manifest.lift_rows)} lifts")
    return 0


def _cmd_review(args) -> int:
    path = _draft_path(args.resort_id)
    if not path.exists():
        print(f"no draft for {args.resort_id} — run `ingest` first", file=sys.stderr)
        return 4
    raw = json.loads(path.read_text())
    print(f"resort_id: {raw['resort_id']}")
    print(f"expected: {raw['expected_trail_count']} trails / "
          f"{raw['expected_lift_count']} lifts")
    print(f"draft has: {len(raw.get('trail_rows', []))} trails / "
          f"{len(raw.get('lift_rows', []))} lifts")
    needs_review = [r for r in raw.get("trail_rows", []) + raw.get("lift_rows", [])
                    if r.get("confidence", 0) < 0.7]
    if needs_review:
        print(f"\n{len(needs_review)} rows below confidence 0.7 — review:")
        for row in needs_review[:20]:
            print(f"  [{row['kind']}] {row['name']} "
                  f"(conf {row['confidence']:.2f}, sources: {row['sources_seen']})")
    return 0


def _cmd_apply(args) -> int:
    path = _draft_path(args.resort_id)
    if not path.exists():
        print(f"no draft for {args.resort_id}", file=sys.stderr)
        return 4
    raw = json.loads(path.read_text())
    manifest = _deserialize_draft(raw)
    result = apply_mod.apply(manifest, dry_run=args.dry_run)
    print(f"{result.resort_id}: v{result.manifest_version} — {result.note}")
    return 0 if result.written or args.dry_run else 0


def _cmd_geometry(args) -> int:
    print(f"geometry tool not yet implemented — see canonical-pipeline #11",
          file=sys.stderr)
    return 5


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
        "geometry": row.geometry,
        "osm_way_ids": list(row.osm_way_ids),
        "notes": row.notes,
    }


def _deserialize_draft(raw: dict) -> DraftManifest:
    return DraftManifest(
        resort_id=raw["resort_id"],
        expected_trail_count=raw["expected_trail_count"],
        expected_lift_count=raw["expected_lift_count"],
        validator_notes=raw.get("validator_notes"),
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
        geometry=raw.get("geometry"),
        osm_way_ids=tuple(raw.get("osm_way_ids", [])),
        notes=raw.get("notes"),
    )


if __name__ == "__main__":
    sys.exit(main())
