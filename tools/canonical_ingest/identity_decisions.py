"""Evidence-pinned canonical identity decisions.

Reconciliation is exact-only. When an operator concludes that differently
named source rows are one canonical identity, that judgment is recorded in a
committed decision file instead of being hidden in fuzzy matching code.

Each decision pins both its source items and the complete local evidence
artifacts used to review them. Any map, OSM fixture, name, geometry, way ID, or
attribute change fails the ingest before an existing draft is overwritten.
Decisions rename source items into one exact reconciliation bucket; they do not
accept a row, resolve attribute conflicts, or authorize publication.
"""

from __future__ import annotations

import hashlib
import json
import re
from dataclasses import replace
from pathlib import Path
from typing import Dict, Iterable, List, Tuple

from canonical_ingest.models import SourceItem, SourceResult


PACKAGE_DIR = Path(__file__).resolve().parent
DECISIONS_DIR = PACKAGE_DIR / "decisions"
_SHA256 = re.compile(r"^[0-9a-f]{64}$")


class IdentityDecisionError(ValueError):
    pass


def load_and_apply(
    resort_id: str,
    results: List[SourceResult],
) -> Tuple[List[SourceResult], int]:
    path = DECISIONS_DIR / f"{resort_id}.json"
    if not path.exists():
        return results, 0
    try:
        raw = json.loads(path.read_text())
    except (OSError, json.JSONDecodeError) as exc:
        raise IdentityDecisionError(
            f"identity decision file cannot be read: {path}: {exc}"
        ) from exc
    return apply(raw, results), len(raw.get("merges") or ())


def apply(raw: dict, results: List[SourceResult]) -> List[SourceResult]:
    resort_id, artifacts, merges = _validate_document(raw, results)
    artifact_evidence = _validate_artifacts(artifacts)
    item_index = _item_index(results)
    claimed = set()
    replacements: Dict[tuple[int, int], SourceItem] = {}

    for merge in merges:
        merge_id = merge["id"]
        member_items = []
        for member in merge["members"]:
            key = (member["source"], merge["kind"], member["name"])
            matches = item_index.get(key, ())
            if len(matches) != 1:
                raise IdentityDecisionError(
                    f"identity decision {merge_id!r} expected exactly one "
                    f"source item for {key}, found {len(matches)}"
                )
            location, item = matches[0]
            if location in claimed:
                raise IdentityDecisionError(
                    f"source item {key} is claimed by multiple identity decisions"
                )
            claimed.add(location)
            member_items.append((member["source"], location, item))

        expected = merge["evidence_fingerprint"].lower()
        actual = merge_evidence_fingerprint(
            merge,
            [(source, item) for source, _, item in member_items],
            artifact_evidence,
        )
        if actual != expected:
            raise IdentityDecisionError(
                f"identity decision {merge_id!r} evidence changed: "
                f"expected {expected}, computed {actual}"
            )

        for source, location, item in member_items:
            extra = dict(item.extra)
            extra["identity_decision"] = {
                "id": merge_id,
                "canonical_name": merge["canonical_name"],
                "observed_name": item.name,
                "evidence_fingerprint": expected,
                "source": source,
            }
            replacements[location] = replace(
                item,
                name=merge["canonical_name"],
                extra=extra,
            )

    transformed = []
    for result_index, result in enumerate(results):
        items = tuple(
            replacements.get((result_index, item_index_value), item)
            for item_index_value, item in enumerate(result.items)
        )
        transformed.append(replace(result, items=items))
    if any(result.resort_id != resort_id for result in transformed):
        raise IdentityDecisionError("identity decision resort changed unexpectedly")
    return transformed


def merge_evidence_fingerprint(
    merge: dict,
    member_items: Iterable[Tuple[str, SourceItem]],
    artifact_evidence: Iterable[dict],
) -> str:
    payload = {
        "id": merge["id"],
        "kind": merge["kind"],
        "canonical_name": merge["canonical_name"],
        "members": [
            {
                "source": source,
                "kind": item.kind,
                "name": item.name,
                "confidence": item.confidence,
                "geometry": item.geometry,
                "osm_way_ids": list(item.osm_way_ids),
                "extra": item.extra,
            }
            for source, item in sorted(
                member_items,
                key=lambda pair: (
                    pair[0], pair[1].kind, pair[1].name.casefold(), pair[1].name
                ),
            )
        ],
        "artifacts": sorted(
            artifact_evidence, key=lambda artifact: artifact["path"]
        ),
    }
    encoded = json.dumps(
        payload, sort_keys=True, separators=(",", ":"), default=str
    ).encode()
    return hashlib.sha256(encoded).hexdigest()


def expected_fingerprints(raw: dict, results: List[SourceResult]) -> Dict[str, str]:
    """Return calculated fingerprints for authoring/review tooling.

    This does not apply decisions and deliberately ignores the stored
    fingerprint values. Normal ingest always uses `load_and_apply`, which
    compares them fail-closed.
    """
    _, artifacts, merges = _validate_document(
        raw, results, validate_fingerprints=False
    )
    artifact_evidence = _validate_artifacts(artifacts)
    item_index = _item_index(results)
    output = {}
    for merge in merges:
        selected = []
        for member in merge["members"]:
            key = (member["source"], merge["kind"], member["name"])
            matches = item_index.get(key, ())
            if len(matches) != 1:
                raise IdentityDecisionError(
                    f"identity decision {merge['id']!r} expected exactly one "
                    f"source item for {key}, found {len(matches)}"
                )
            selected.append((member["source"], matches[0][1]))
        output[merge["id"]] = merge_evidence_fingerprint(
            merge, selected, artifact_evidence
        )
    return output


def _validate_document(
    raw: dict,
    results: List[SourceResult],
    *,
    validate_fingerprints: bool = True,
) -> Tuple[str, list[dict], list[dict]]:
    if not isinstance(raw, dict) or raw.get("schema_version") != 1:
        raise IdentityDecisionError("identity decisions require schema_version 1")
    resort_id = _required_text(raw.get("resort_id"), "resort_id")
    if not results or any(result.resort_id != resort_id for result in results):
        raise IdentityDecisionError(
            "identity decision resort_id does not match all source results"
        )
    artifacts = raw.get("artifacts")
    if not isinstance(artifacts, list) or not artifacts:
        raise IdentityDecisionError("identity decisions require evidence artifacts")
    merges = raw.get("merges")
    if not isinstance(merges, list):
        raise IdentityDecisionError("identity decision merges must be a list")

    merge_ids = set()
    canonical_targets = set()
    claimed_members = set()
    for merge in merges:
        if not isinstance(merge, dict):
            raise IdentityDecisionError("identity decision merges must be objects")
        merge_id = _required_text(merge.get("id"), "merge id")
        if merge_id in merge_ids:
            raise IdentityDecisionError(f"duplicate identity decision id: {merge_id}")
        merge_ids.add(merge_id)
        kind = _required_text(merge.get("kind"), "merge kind")
        if kind not in ("trail", "lift"):
            raise IdentityDecisionError(f"invalid identity decision kind: {kind}")
        canonical_name = _required_text(
            merge.get("canonical_name"), "canonical_name"
        )
        target = (kind, canonical_name.casefold())
        if target in canonical_targets:
            raise IdentityDecisionError(
                f"multiple identity decisions target {kind} {canonical_name!r}"
            )
        canonical_targets.add(target)
        members = merge.get("members")
        if not isinstance(members, list) or len(members) < 2:
            raise IdentityDecisionError(
                f"identity decision {merge_id!r} requires at least two members"
            )
        local_members = set()
        for member in members:
            if not isinstance(member, dict):
                raise IdentityDecisionError("identity decision members must be objects")
            member_key = (
                _required_text(member.get("source"), "member source"),
                kind,
                _required_text(member.get("name"), "member name"),
            )
            if member_key in local_members:
                raise IdentityDecisionError(
                    f"duplicate member in identity decision {merge_id!r}: {member_key}"
                )
            if member_key in claimed_members:
                raise IdentityDecisionError(
                    f"member is claimed by multiple identity decisions: {member_key}"
                )
            local_members.add(member_key)
            claimed_members.add(member_key)
        fingerprint = merge.get("evidence_fingerprint")
        if validate_fingerprints and (
            not isinstance(fingerprint, str)
            or not _SHA256.fullmatch(fingerprint.lower())
        ):
            raise IdentityDecisionError(
                f"identity decision {merge_id!r} has invalid evidence_fingerprint"
            )
    return resort_id, artifacts, merges


def _validate_artifacts(artifacts: list[dict]) -> list[dict]:
    validated = []
    seen = set()
    package_root = PACKAGE_DIR.resolve()
    for artifact in artifacts:
        if not isinstance(artifact, dict):
            raise IdentityDecisionError("identity decision artifacts must be objects")
        relative = _required_text(artifact.get("path"), "artifact path")
        relative_path = Path(relative)
        if relative_path.is_absolute() or ".." in relative_path.parts:
            raise IdentityDecisionError(f"unsafe identity artifact path: {relative}")
        resolved = (package_root / relative_path).resolve()
        try:
            resolved.relative_to(package_root)
        except ValueError as exc:
            raise IdentityDecisionError(
                f"identity artifact escapes package: {relative}"
            ) from exc
        if relative in seen:
            raise IdentityDecisionError(f"duplicate identity artifact: {relative}")
        seen.add(relative)
        expected = _required_text(artifact.get("sha256"), "artifact sha256").lower()
        if not _SHA256.fullmatch(expected):
            raise IdentityDecisionError(f"invalid identity artifact sha256: {relative}")
        if not resolved.is_file():
            raise IdentityDecisionError(f"identity artifact is missing: {relative}")
        try:
            actual = hashlib.sha256(resolved.read_bytes()).hexdigest()
        except OSError as exc:
            raise IdentityDecisionError(
                f"identity artifact cannot be read: {relative}: {exc}"
            ) from exc
        if actual != expected:
            raise IdentityDecisionError(
                f"identity artifact changed: {relative}; expected {expected}, "
                f"computed {actual}"
            )
        validated.append({"path": relative, "sha256": actual})
    return validated


def _item_index(
    results: List[SourceResult],
) -> Dict[tuple[str, str, str], list[tuple[tuple[int, int], SourceItem]]]:
    index: Dict[
        tuple[str, str, str], list[tuple[tuple[int, int], SourceItem]]
    ] = {}
    for result_index, result in enumerate(results):
        for item_index, item in enumerate(result.items):
            key = (result.source, item.kind, item.name)
            index.setdefault(key, []).append(((result_index, item_index), item))
    return index


def _required_text(value: object, field: str) -> str:
    if not isinstance(value, str) or not value.strip():
        raise IdentityDecisionError(f"identity decision {field} must be nonempty text")
    return value.strip()
