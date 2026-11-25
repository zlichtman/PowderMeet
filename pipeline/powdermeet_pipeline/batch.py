"""build-all: every resort through extract, reconcile, build and validate, with no
one watching. A resort that fails is recorded with its reason and the batch moves
on. The product is one summary: per resort, pass or fail, the validation numbers
and what blocks it.
"""

from __future__ import annotations

import json
import time
import traceback
from collections import Counter
from pathlib import Path

from . import build, catalog, drawn, extract, reconcile, report, validate
from .reconcile import decisions as decisions_mod
from .sources import openskimap

COUNTED_FLAGS = (
    "auto_link", "snap", "line_join", "orphan_link", "link_proposed", "lift_cut_off", "lift_exit_dead_end",
    "run_uphill", "rendezvous_dropped",
)
OVERPASS_PAUSE_S = 2.0


def run(resort_ids: list[str], *, reuse_extracts: bool = False, log=print) -> list[dict]:
    frozen: dict[str, Path] = {}
    if reuse_extracts:
        for resort_id in resort_ids:
            found = extract.newest(resort_id)
            if found:
                frozen[resort_id] = found[-1]
        # An extract whose OpenSkiMap features stop short of its OSM box is frozen
        # again with the features of the whole box, all of them in one pass.
        short = {
            resort_id: document["bbox"] for resort_id, path in frozen.items()
            if not extract.openskimap_covers(document := json.loads(path.read_text()))
        }
        for resort_id, ski_map in (openskimap.fetch_many(short, catalog.cache_dir()) if short else {}).items():
            frozen[resort_id] = extract.refresh_openskimap(resort_id, ski_map=ski_map)[1]
            log(f"{resort_id}: OpenSkiMap read again for the whole map box")
    # One pass over the OpenSkiMap world files serves every resort still to extract.
    boxes = {r: catalog.resort(r)["bbox"] for r in resort_ids if r not in frozen}
    slices = openskimap.fetch_many(boxes, catalog.cache_dir()) if boxes else {}

    rows = []
    for position, resort_id in enumerate(resort_ids, 1):
        started = time.monotonic()
        resort = catalog.resort(resort_id)
        row = {
            "resort_id": resort_id, "name": resort["name"], "country": resort.get("country"),
            "pass_products": resort.get("pass_products") or [], "result": "fail", "reason": None,
        }
        try:
            if resort_id in frozen:
                source = json.loads(frozen[resort_id].read_text())
            else:
                extract_id, path = extract.run(resort_id, ski_map=slices[resort_id])
                source = json.loads(path.read_text())
                time.sleep(OVERPASS_PAUSE_S)
            row["extract_seconds"] = round(time.monotonic() - started, 1)
            row.update(_one(resort, source))
        except Exception as error:  # the batch must outlive any one resort
            row["reason"] = f"{type(error).__name__}: {error}"[:400]
            if not isinstance(error, (catalog.PipelineError, RuntimeError, ValueError)):
                row["traceback"] = traceback.format_exc()[-1500:]
        row["seconds"] = round(time.monotonic() - started, 1)
        rows.append(row)
        log(f"[{position}/{len(resort_ids)}] {resort_id}: {row['result']}"
            + (f" ({row['reason']})" if row["reason"] else "") + f" in {row['seconds']} s")
    return rows


def _one(resort: dict, source: dict) -> dict:
    resort_id = resort["resort_id"]
    decisions = decisions_mod.load(resort_id, catalog.DECISIONS_DIR)
    traced = drawn.prepare(resort, source, decisions)
    manifest, _ = reconcile.write(reconcile.run(resort, source, traced), source["extract_id"])
    bundle = build.build(resort, source, manifest)
    document = bundle.document
    evaluation = validate.evaluate(document)
    errors = validate.check_constraints(document)

    path = catalog.bundle_path(resort_id, bundle.bundle_id)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(bundle.stored)
    directory = catalog.report_dir(resort_id)
    directory.mkdir(parents=True, exist_ok=True)
    (directory / f"{bundle.bundle_id}.md").write_text(report.markdown(
        document, bundle.bundle_id, len(bundle.stored), manifest, evaluation, errors, decisions,
    ))
    (directory / f"{bundle.bundle_id}.geojson").write_text(report.geojson(document))

    publishable = evaluation["publishable"] and not errors
    blockers = validate.reasons(evaluation, errors)
    review = manifest["review"]
    kinds = Counter(edge["kind"] for edge in document["edges"])
    flags = evaluation["flag_counts"]
    return {
        "result": document["status_mode"] if publishable else "fail",
        "reason": "; ".join(blockers) or None,
        "bundle_id": bundle.bundle_id,
        "size_bytes": len(bundle.stored),
        "extract_id": source["extract_id"],
        "ski_areas": source.get("ski_areas") or [],
        "metrics": {row["metric"]: row["value"] for row in evaluation["rows"]},
        "lifts": sum(1 for g in document["groups"] if g["kind"] == "lift"),
        "trails": sum(1 for g in document["groups"] if g["kind"] == "trail"),
        "edges": dict(kinds),
        "rendezvous": len(document["rendezvous"]),
        "identities": review["identities"],
        "confirmed_identities": review["auto_accepted"],
        "flags": {code: flags.get(code, 0) for code in COUNTED_FLAGS},
        "skipped_other_ski_area": sum(
            1 for f in document["integrity"]["flags"]
            if f["code"] == "way_skipped" and f["note"].endswith("other_ski_area")),
        "official_list": review.get("official_error") is None,
    }


def headline(rows: list[dict]) -> str:
    passed = [row for row in rows if row["result"] != "fail"]
    live = sum(1 for row in passed if row["result"] == "live")
    return (f"{len(passed)} of {len(rows)} resorts publishable "
            f"({live} live, {len(passed) - live} scheduled_only), {len(rows) - len(passed)} failed")


def write_summary(rows: list[dict], name: str) -> tuple[Path, Path]:
    directory = catalog.workdir() / "report"
    directory.mkdir(parents=True, exist_ok=True)
    json_path = directory / f"{name}.json"
    json_path.write_text(json.dumps({"resorts": rows}, indent=1, ensure_ascii=False) + "\n")
    markdown_path = directory / f"{name}.md"
    markdown_path.write_text(summary_markdown(rows))
    return json_path, markdown_path


def summary_markdown(rows: list[dict]) -> str:
    lines = [
        "# Resort build summary", "", headline(rows) + ".", "",
        "| Resort | Result | Lift tops connected | Orphan edges | Unnamed runs | Lifts | Trails | "
        "Meeting points | Auto links | Still cut off | Why it fails |",
        "|---|---|---|---|---|---|---|---|---|---|---|",
    ]
    for row in rows:
        metrics = row.get("metrics") or {}
        flags = row.get("flags") or {}
        cut_off = flags.get("lift_cut_off", 0) + flags.get("lift_exit_dead_end", 0)
        lines.append(
            f"| {row['name']} (`{row['resort_id']}`) | {row['result']} | "
            f"{metrics.get('lift_tops_reaching_base', '')} | {metrics.get('orphan_edge_share', '')} | "
            f"{metrics.get('unnamed_run_share', '')} | {row.get('lifts', '')} | {row.get('trails', '')} | "
            f"{row.get('rendezvous', '')} | {flags.get('auto_link', '')} | {cut_off if metrics else ''} | "
            f"{(row['reason'] or '') if row['result'] == 'fail' else ''} |"
        )
    failures = Counter(_failure_kind(row) for row in rows if row["result"] == "fail")
    if failures:
        lines += ["", "## Why resorts fail", ""]
        lines += [f"- {count} × {kind}" for kind, count in failures.most_common()]
    seconds = [row["seconds"] for row in rows if "seconds" in row]
    if seconds:
        lines += ["", f"Time: {sum(seconds) / 60:.1f} minutes in all, "
                      f"{sum(seconds) / len(seconds):.0f} s per resort on average."]
    return "\n".join(lines) + "\n"


def _failure_kind(row: dict) -> str:
    reason = row.get("reason") or "unknown"
    if "metrics" not in row:
        return reason.split(":")[0] + ": " + reason.split(":", 1)[-1].strip()[:80]
    return "; ".join(part.split(" is ")[0] for part in reason.split("; "))
