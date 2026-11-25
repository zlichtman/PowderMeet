"""publish: put a validated bundle on the PowderMeet Supabase project.

Uploads `resort-bundles/<resort_id>/<bundle_id>.json.gz` and its small
`.status.json` sidecar (skipped when present), writes the resort's catalog row,
inserts the `resort_bundles` row (its `manifest_version` above every other bundle the
server holds for the resort), calls `bundle_publish` with every rendezvous id in
the bundle, and marks the resort published with its status mode. Needs SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY in
the environment; the key is never written anywhere.
"""

from __future__ import annotations

import json
import os
import time
from urllib.error import HTTPError
from urllib.parse import quote
from urllib.request import Request, urlopen

from . import canonical, catalog, reconcile, validate
from .catalog import PipelineError

BUNDLE_BUCKET = "resort-bundles"
REPORT_BUCKET = "resort-reports"
ROW_UPDATE_WAITS_S = (5, 20)


def status_sidecar(document: dict, bundle_id: str) -> bytes:
    """What the status worker reads, so it need not download the whole bundle: the
    provider aliases and the group ids, under the same keys the bundle uses."""
    return json.dumps({
        "schema_version": document["schema_version"],
        "resort_id": document["resort_id"],
        "bundle_id": bundle_id,
        "status_mode": document["status_mode"],
        "status_aliases": document["status_aliases"],
        "groups": [{"id": group["id"], "kind": group["kind"]} for group in document["groups"]],
    }, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode("utf-8")


def publish(resort_id: str, bundle_id: str, review_minutes: int | None,
            published_by: str | None = None) -> dict:
    resort = catalog.resort(resort_id)
    client = _Client.from_environment()
    path = catalog.bundle_path(resort_id, bundle_id)
    if not path.is_file():
        raise PipelineError(f"bundle not found: {path}")
    stored = path.read_bytes()
    if canonical.sha256_hex(stored) != bundle_id:
        raise PipelineError("bundle bytes do not hash to the bundle_id")
    document = json.loads(canonical.gunzip_bytes(stored))
    if document["resort_id"] != resort_id:
        raise PipelineError(f"bundle is for {document['resort_id']}, not {resort_id}")
    evaluation = validate.evaluate(document)
    errors = validate.check_constraints(document)
    if not evaluation["publishable"] or errors:
        raise PipelineError("bundle is not publishable; run `pm-pipeline validate` for the report")
    # The same re-measurement `pm-pipeline validate` makes, before anything is
    # uploaded: a stored `live` or integrity block from an older pipeline with
    # looser rules must not publish on its own word.
    manifest = reconcile.load(resort_id, f"v{document['source']['manifest_version']}")
    stale = validate.recheck(document, manifest.get("areas") or ())
    if stale:
        raise PipelineError(f"bundle does not measure as stored ({stale[0]}); rebuild it")
    manifest_version = recorded_manifest_version(
        client, resort_id, bundle_id, document["source"]["manifest_version"])

    # Stored as an opaque gzip object. With `Content-Encoding: gzip` a CDN may
    # hand the client inflated bytes, and the client's SHA check would fail.
    client.upload(BUNDLE_BUCKET, f"{resort_id}/{bundle_id}.json.gz", stored, "application/gzip", replace=False)
    client.upload(BUNDLE_BUCKET, f"{resort_id}/{bundle_id}.status.json",
                  status_sidecar(document, bundle_id), "application/json", replace=False)
    report_url = None
    for suffix, content_type in ((".md", "text/markdown; charset=utf-8"), (".geojson", "application/geo+json")):
        report = catalog.report_dir(resort_id) / f"{bundle_id}{suffix}"
        if report.is_file():
            client.upload(REPORT_BUCKET, f"{resort_id}/{bundle_id}{suffix}", report.read_bytes(), content_type, replace=True)
            if suffix == ".md":
                report_url = f"{client.url}/storage/v1/object/public/{REPORT_BUCKET}/{resort_id}/{bundle_id}.md"

    # The catalog row the app reads. `resort_bundles` references it, so it is
    # written first; `published` and `status_mode` are set once the pointer moves.
    client.upsert("resorts", {
        "id": resort_id,
        "name": resort["name"],
        "timezone": resort["timezone"],
        "bbox": document["bbox"],
        "center": document["center"],
        "camera": resort.get("camera"),
        "pass_products": resort.get("pass_products") or [],
        # Other names the picker searches by (0020).
        "aliases": resort.get("aliases") or [],
        "status_provider": resort.get("status_provider"),
    })
    client.insert("resort_bundles", {
        "bundle_id": bundle_id,
        "resort_id": resort_id,
        "schema_version": document["schema_version"],
        "manifest_version": manifest_version,
        "extract_id": document["source"]["extract_id"],
        "built_at": document["built_at"],
        "pipeline_version": document["pipeline_version"],
        "size_bytes": len(stored),
        "integrity": document["integrity"],
        "report_url": report_url,
    })
    report = {
        "status_mode": document["status_mode"],
        "review_minutes": review_minutes,
        "report_url": report_url,
        "thresholds": evaluation["rows"],
        "flag_counts": evaluation["flag_counts"],
    }
    client.rpc("bundle_publish", {
        "p_resort_id": resort_id,
        "p_bundle_id": bundle_id,
        "p_rendezvous_ids": [r["id"] for r in document["rendezvous"]],
        "p_report": report,
        "p_published_by": published_by or os.environ.get("GITHUB_ACTOR") or "pm-pipeline",
    })
    # The pointer has moved, so a failure here leaves the new bundle active under
    # the old status_mode (or unpublished on a first publish) until this update
    # lands. It is idempotent, so a dropped request is tried again.
    for wait in (*ROW_UPDATE_WAITS_S, None):
        try:
            client.update("resorts", {"id": f"eq.{resort_id}"}, {
                "published": True,
                "status_mode": document["status_mode"],
                "review_minutes": review_minutes,
            })
            break
        except (PipelineError, OSError) as error:
            if wait is None:
                raise PipelineError(
                    f"bundle {bundle_id} is active, but the resorts row was not updated ({error}); "
                    "run publish again"
                ) from error
            time.sleep(wait)
    return report


def recorded_manifest_version(client: "_Client", resort_id: str, bundle_id: str, document_version: int) -> int:
    """The `manifest_version` for the bundle's `resort_bundles` row. Reconcile numbers
    manifests from the local work directory, so a fresh one starts again at 1 while
    the server holds higher numbers. The row has no manifest identity to tell a
    rebuild of the same manifest from a different one, so a new bundle always goes
    above every number the server holds, and the column orders bundles as published.
    The document keeps its own number: changing it would change the bundle id."""
    resort = f"eq.{resort_id}"
    recorded = client.select("resort_bundles", {
        "select": "manifest_version", "resort_id": resort, "bundle_id": f"eq.{bundle_id}"})
    if recorded:
        return recorded[0]["manifest_version"]
    highest = client.select("resort_bundles", {
        "select": "manifest_version", "resort_id": resort,
        "order": "manifest_version.desc", "limit": "1"})
    if not highest:
        return document_version
    return max(document_version, highest[0]["manifest_version"] + 1)


def rollback(resort_id: str, bundle_id: str) -> None:
    _Client.from_environment().rpc("bundle_rollback", {"p_resort_id": resort_id, "p_bundle_id": bundle_id})


class _Client:
    def __init__(self, url: str, key: str):
        self.url = url.rstrip("/")
        self._headers = {"Authorization": f"Bearer {key}", "apikey": key}

    @classmethod
    def from_environment(cls) -> "_Client":
        url, key = os.environ.get("SUPABASE_URL"), os.environ.get("SUPABASE_SERVICE_ROLE_KEY")
        if not url or not key:
            raise PipelineError("publish needs SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY in the environment")
        return cls(url, key)

    def upload(self, bucket: str, path: str, body: bytes, content_type: str, *, replace: bool) -> None:
        headers = {"Content-Type": content_type, "x-upsert": "true" if replace else "false"}
        try:
            self._send("POST", f"/storage/v1/object/{bucket}/{quote(path)}", body, headers)
        except HTTPError as error:
            detail = error.read().decode("utf-8", "replace")
            # An immutable bundle that is already there is the outcome we want.
            if not replace and (error.code == 409 or "exists" in detail.lower() or "duplicate" in detail.lower()):
                return
            raise PipelineError(f"upload of {bucket}/{path} failed: HTTP {error.code} {detail[:200]}") from error

    def insert(self, table: str, row: dict) -> None:
        self._json("POST", f"/rest/v1/{table}", row, {"Prefer": "resolution=ignore-duplicates,return=minimal"})

    def upsert(self, table: str, row: dict) -> None:
        self._json("POST", f"/rest/v1/{table}", row, {"Prefer": "resolution=merge-duplicates,return=minimal"})

    def update(self, table: str, where: dict, values: dict) -> None:
        query = "&".join(f"{quote(k)}={quote(v)}" for k, v in where.items())
        self._json("PATCH", f"/rest/v1/{table}?{query}", values, {"Prefer": "return=minimal"})

    def select(self, table: str, query: dict) -> list[dict]:
        path = f"/rest/v1/{table}?" + "&".join(f"{quote(k)}={quote(v)}" for k, v in query.items())
        try:
            return json.loads(self._send("GET", path, None, {"Accept": "application/json"}))
        except HTTPError as error:
            detail = error.read().decode("utf-8", "replace")
            raise PipelineError(f"GET /rest/v1/{table} failed: HTTP {error.code} {detail[:300]}") from error

    def rpc(self, name: str, arguments: dict) -> None:
        self._json("POST", f"/rest/v1/rpc/{name}", arguments, {})

    def _json(self, method: str, path: str, payload: dict, headers: dict) -> None:
        try:
            self._send(method, path, json.dumps(payload).encode(), {"Content-Type": "application/json", **headers})
        except HTTPError as error:
            detail = error.read().decode("utf-8", "replace")
            raise PipelineError(f"{method} {path.split('?')[0]} failed: HTTP {error.code} {detail[:300]}") from error

    def _send(self, method: str, path: str, body: bytes | None, headers: dict) -> bytes:
        request = Request(self.url + path, data=body, method=method, headers={**self._headers, **headers})
        with urlopen(request, timeout=120) as response:
            return response.read()
