"""The same frozen extract gives the same bundle bytes (specs/05-PIPELINE.md,
invariant I-17)."""

import hashlib
import json
import zlib
from pathlib import Path

import pytest

from powdermeet_pipeline import build, canonical, catalog, reconcile, validate
from powdermeet_pipeline.reconcile import decisions
from synthetic import RESORT, Mountain

FIXTURE = Path(__file__).resolve().parents[1] / "fixtures" / "whistler-blackcomb"


def test_same_inputs_give_the_same_bytes():
    first, second = Mountain().bundle(), Mountain().bundle()
    assert first.stored == second.stored
    assert first.bundle_id == hashlib.sha256(first.stored).hexdigest()


def test_element_order_does_not_change_the_bundle():
    mountain = Mountain()
    extract = mountain.extract()
    shuffled = json.loads(json.dumps(extract))
    shuffled["osm"]["elements"].reverse()
    shuffled["openskimap"]["runs"].reverse()
    manifest = mountain.manifest()
    assert build.build(RESORT, shuffled, manifest).bundle_id == build.build(RESORT, extract, manifest).bundle_id


def test_container_is_gzip_with_no_name_and_no_time():
    stored = Mountain().bundle().stored
    assert stored[:4] == b"\x1f\x8b\x08\x00"      # gzip, deflate, no optional fields
    assert stored[4:8] == b"\x00\x00\x00\x00"      # mtime 0
    text = zlib.decompress(stored, 31).decode("utf-8")
    document = json.loads(text)
    assert text == canonical.dumps(canonical.typed(document))  # already canonical
    assert '"lon":-120.0000000' in text and '"ele_m":1000.0' in text


def test_whistler_fixture_reproduces_the_recorded_bundle():
    extracts = sorted(FIXTURE.glob("extract-*.json"))
    if not extracts:
        pytest.skip("Whistler fixture not present")
    resort = catalog.resort("whistler-blackcomb")
    extract = json.loads(extracts[-1].read_text())
    manifest = json.loads((FIXTURE / "manifest-v1.json").read_text())

    # Reconcile is a pure function of the extract and the decisions file.
    content = reconcile.run(resort, extract, decisions.load("whistler-blackcomb", catalog.DECISIONS_DIR))
    assert reconcile.content_hash(content) == reconcile.content_hash(manifest)

    first = build.build(resort, extract, manifest)
    second = build.build(resort, extract, manifest)
    assert first.stored == second.stored
    assert validate.check_constraints(first.document) == []

    content_sha = hashlib.sha256(canonical.gunzip_bytes(first.stored)).hexdigest()
    assert content_sha == (FIXTURE / "expected-content.sha").read_text().strip()
    if first.bundle_id != (FIXTURE / "expected-bundle.sha").read_text().strip():
        # The JSON is identical; only the deflate stream differs between zlib builds.
        pytest.skip(f"same content, different deflate implementation (zlib {zlib.ZLIB_RUNTIME_VERSION})")
