"""pm-pipeline command line. Stages are specified in specs/05-PIPELINE.md."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

from . import __version__, batch, build, canonical, catalog, drawn, extract, publish, reconcile, report, validate
from .reconcile import decisions as decisions_mod


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="pm-pipeline")
    parser.add_argument("--version", action="version", version=f"pm-pipeline {__version__}")
    commands = parser.add_subparsers(dest="command")

    p = commands.add_parser("extract", help="fetch every source once and freeze it")
    p.add_argument("resort_id")
    p.add_argument("--date", help="YYYY-MM-DD: read OSM as of this date")
    p.add_argument("--pbf", type=Path, help="regional PBF to read OSM from instead of Overpass")
    p.add_argument("--official-html", type=Path, help="saved copy of the resort's official status page")
    p.add_argument("--official-only", action="store_true",
                   help="fetch only the official lists again, keeping the latest extract's OSM data")

    p.add_argument("--openskimap-only", action="store_true",
                   help="read only OpenSkiMap again, for the latest extract's whole box, keeping its OSM data")

    p = commands.add_parser("reconcile", help="merge the sources into a manifest")
    p.add_argument("resort_id")
    p.add_argument("--extract", required=True, help="extract id or file")

    p = commands.add_parser("build", help="build the bundle")
    p.add_argument("resort_id")
    p.add_argument("--manifest", required=True, help="v<N> or file")
    p.add_argument("--extract", required=True, help="extract id or file")

    p = commands.add_parser("validate", help="check a bundle against the thresholds and write its report")
    p.add_argument("bundle_id")

    p = commands.add_parser("publish", help="publish a validated bundle")
    p.add_argument("resort_id")
    p.add_argument("--bundle", required=True)
    p.add_argument("--rollback", action="store_true", help="point the resort back at this earlier bundle")

    p = commands.add_parser(
        "fixture", help="rebuild a resort's committed test fixture from its frozen extract")
    p.add_argument("resort_id")

    p = commands.add_parser(
        "build-all", help="run every resort through all stages, past failures, into one summary")
    p.add_argument("--only", help="comma-separated resort ids instead of the whole catalog")
    p.add_argument("--shard", help="I/N: only the resorts whose position in the catalog is I modulo N")
    p.add_argument("--reuse-extracts", action="store_true",
                   help="build from the newest frozen extract of a resort when there is one")

    p = commands.add_parser("summary", help="merge the summaries of several build-all runs")
    p.add_argument("files", nargs="+", type=Path)

    args = parser.parse_args(argv)
    if not args.command:
        parser.print_help()
        return 0
    try:
        return _COMMANDS[args.command](args)
    except (catalog.PipelineError, decisions_mod.DecisionError,
            reconcile.identities.SourceDataUnavailableError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 1


def _extract(args) -> int:
    if args.official_only:
        extract_id, path = extract.refresh_official(args.resort_id, official_html=args.official_html)
    elif args.openskimap_only:
        extract_id, path = extract.refresh_openskimap(args.resort_id)
    else:
        extract_id, path = extract.run(
            args.resort_id, date=args.date, pbf=args.pbf, official_html=args.official_html,
        )
    print(f"extract_id={extract_id}")
    print(f"path={path}")
    return 0


def _reconcile(args) -> int:
    resort = catalog.resort(args.resort_id)
    frozen = extract.load(args.resort_id, args.extract)
    decisions = decisions_mod.load(args.resort_id, catalog.DECISIONS_DIR)
    traced = drawn.prepare(resort, frozen, decisions)
    manifest, path = reconcile.write(reconcile.run(resort, frozen, traced), frozen["extract_id"])
    review = manifest["review"]
    print(f"manifest=v{manifest['manifest_version']}")
    print(f"path={path}")
    print(
        f"{review['identities']} identities: {review['auto_accepted']} confirmed by two sources, "
        f"{review['accepted_by_decision']} by decision, {review['needs_review']} not fully supported; "
        f"{len(manifest['rendezvous'])} rendezvous proposed"
    )
    return 0


def _build(args) -> int:
    resort = catalog.resort(args.resort_id)
    frozen = extract.load(args.resort_id, args.extract)
    manifest = reconcile.load(args.resort_id, args.manifest)
    bundle = build.build(resort, frozen, manifest)
    path = catalog.bundle_path(args.resort_id, bundle.bundle_id)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(bundle.stored)
    print(f"bundle_id={bundle.bundle_id}")
    print(f"path={path}")
    print(f"size_bytes={len(bundle.stored)}")
    return 0


def _validate(args) -> int:
    path = catalog.find_bundle(args.bundle_id)
    stored = path.read_bytes()
    if canonical.sha256_hex(stored) != args.bundle_id:
        raise catalog.PipelineError("bundle bytes do not hash to the bundle_id")
    document = json.loads(canonical.gunzip_bytes(stored))
    resort_id = document["resort_id"]

    errors = validate.check_constraints(document)
    manifest = reconcile.load(resort_id, f"v{document['source']['manifest_version']}")
    errors += validate.recheck(document, manifest.get("areas") or ())
    evaluation = validate.evaluate(document)

    decisions = decisions_mod.load(resort_id, catalog.DECISIONS_DIR)
    directory = catalog.report_dir(resort_id)
    directory.mkdir(parents=True, exist_ok=True)
    markdown_path = directory / f"{args.bundle_id}.md"
    markdown_path.write_text(report.markdown(
        document, args.bundle_id, len(stored), manifest, evaluation, errors, decisions,
    ))
    geojson_path = directory / f"{args.bundle_id}.geojson"
    geojson_path.write_text(report.geojson(document))

    for row in evaluation["rows"]:
        print(f"{'pass' if row['passed'] else 'FAIL'}  {row['metric']} = {row['value']} "
              f"({row['comparison']} {row['threshold']})")
    print(f"client_constraint_failures={len(errors)}")
    print(f"status_mode={document['status_mode']}")
    print(f"report={markdown_path}")
    print(f"preview={geojson_path}")
    publishable = evaluation["publishable"] and not errors
    print(f"publishable={'true' if publishable else 'false'}")
    return 0 if publishable else 2


def _publish(args) -> int:
    if args.rollback:
        publish.rollback(args.resort_id, args.bundle)
        print(f"rolled back {args.resort_id} to {args.bundle}")
        return 0
    decisions = decisions_mod.load(args.resort_id, catalog.DECISIONS_DIR)
    result = publish.publish(
        args.resort_id, args.bundle, decisions["review_minutes"] if decisions["present"] else None)
    print(f"published {args.resort_id} {args.bundle} status_mode={result['status_mode']}")
    return 0


def _fixture(args) -> int:
    """Refresh fixtures/<resort_id>/ after the decisions file or the pipeline
    changes: manifest, expected SHAs, report, and the bundle MountainCore tests read."""
    resort_id = args.resort_id
    directory = catalog.FIXTURES_DIR / resort_id
    extracts = sorted(directory.glob("extract-*.json"))
    if not extracts:
        raise catalog.PipelineError(f"no frozen extract in {directory}")
    resort = catalog.resort(resort_id)
    frozen = json.loads(extracts[-1].read_text())
    decisions = decisions_mod.load(resort_id, catalog.DECISIONS_DIR)
    content = reconcile.run(resort, frozen, drawn.prepare(resort, frozen, decisions))

    manifest_path = directory / "manifest-v1.json"
    previous = json.loads(manifest_path.read_text()) if manifest_path.exists() else None
    if previous and reconcile.content_hash(previous) == reconcile.content_hash(content):
        manifest = previous
    else:
        from datetime import datetime, timezone

        stamp = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
        manifest = {"manifest_version": 1, "created_at": stamp, "extract_id": frozen["extract_id"], **content}
        manifest_path.write_text(json.dumps(manifest, indent=1, sort_keys=True, ensure_ascii=False) + "\n")

    bundle = build.build(resort, frozen, manifest)
    evaluation = validate.evaluate(bundle.document)
    errors = validate.check_constraints(bundle.document)
    (directory / "expected-bundle.sha").write_text(bundle.bundle_id + "\n")
    (directory / "expected-content.sha").write_text(
        canonical.sha256_hex(canonical.gunzip_bytes(bundle.stored)) + "\n")
    (directory / "report.md").write_text(report.markdown(
        bundle.document, bundle.bundle_id, len(bundle.stored), manifest, evaluation, errors, decisions,
    ))
    preview = catalog.report_dir(resort_id) / f"{bundle.bundle_id}.geojson"
    preview.parent.mkdir(parents=True, exist_ok=True)
    preview.write_text(report.geojson(bundle.document))

    swift_fixtures = catalog.ROOT.parent / "packages" / "MountainCore" / "Tests" / "Fixtures"
    swift_fixtures.mkdir(parents=True, exist_ok=True)
    for stale in swift_fixtures.glob(f"{resort_id}.*.json.gz"):
        stale.unlink()
    (swift_fixtures / f"{resort_id}.{bundle.bundle_id}.json.gz").write_bytes(bundle.stored)

    print(f"bundle_id={bundle.bundle_id}")
    print(f"size_bytes={len(bundle.stored)}")
    print(f"publishable={'true' if evaluation['publishable'] and not errors else 'false'}")
    print(f"status_mode={bundle.document['status_mode']}")
    print(f"preview={preview}")
    return 0


def _build_all(args) -> int:
    ids = catalog.resort_ids()
    name = "summary"
    if args.only:
        # A partial run must not replace the whole-catalog summary.
        name = "summary-only"
        wanted = [part.strip() for part in args.only.split(",") if part.strip()]
        unknown = sorted(set(wanted) - set(ids))
        if unknown:
            raise catalog.PipelineError(f"unknown resort ids: {', '.join(unknown)}")
        ids = wanted
    if args.shard:
        index, _, count = args.shard.partition("/")
        if not (index.isdigit() and count.isdigit() and int(index) < int(count)):
            raise catalog.PipelineError("--shard must be I/N with I < N")
        ids = [resort_id for position, resort_id in enumerate(ids) if position % int(count) == int(index)]
        name = f"summary-{index}-of-{count}"
    rows = batch.run(ids, reuse_extracts=args.reuse_extracts)
    json_path, markdown_path = batch.write_summary(rows, name)
    print(batch.headline(rows))
    print(f"summary={markdown_path}")
    print(f"summary_json={json_path}")
    return 0


def _summary(args) -> int:
    rows = []
    for path in args.files:
        rows += json.loads(path.read_text())["resorts"]
    rows.sort(key=lambda row: row["resort_id"])
    json_path, markdown_path = batch.write_summary(rows, "summary")
    print(batch.headline(rows))
    print(f"summary={markdown_path}")
    print(f"summary_json={json_path}")
    return 0


_COMMANDS = {
    "build-all": _build_all,
    "summary": _summary,
    "fixture": _fixture,
    "extract": _extract, "reconcile": _reconcile, "build": _build,
    "validate": _validate, "publish": _publish,
}

if __name__ == "__main__":
    raise SystemExit(main())
