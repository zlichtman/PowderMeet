"""`way_names`: one OSM way renamed in both sources, so two same-named lifts or runs
in different areas become two identities (Boston Mills' and Brandywine's Lift 1)."""

import pytest

from powdermeet_pipeline.reconcile import decisions as decisions_mod
from synthetic import Mountain


def test_a_renamed_way_becomes_its_own_identity_confirmed_by_both_sources():
    mountain = Mountain()
    mountain.decisions = {"way_names": {201: "Lower Alpha"}}
    manifest = mountain.manifest()
    trails = {t["name"]: t for t in manifest["trails"]}
    assert trails["Alpha"]["way_ids"] == [200]
    assert trails["Lower Alpha"]["way_ids"] == [201]
    assert sorted(trails["Lower Alpha"]["sources"]) == ["openskimap", "osm"]
    assert manifest["way_names"] == {"201": "Lower Alpha"}
    document = mountain.bundle().document
    assert {e["name"] for e in document["edges"] if e["id"].startswith("w201:")} == {"Lower Alpha"}


def test_a_way_name_for_a_way_not_in_the_extract_fails():
    mountain = Mountain()
    mountain.decisions = {"way_names": {999: "Nowhere"}}
    with pytest.raises(decisions_mod.DecisionError, match="not in the extract"):
        mountain.manifest()
