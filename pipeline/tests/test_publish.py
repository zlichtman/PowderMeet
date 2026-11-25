"""The manifest number publish records: a fresh work directory numbers manifests from 1
again, and the server row must still go above every bundle published before."""

import pytest

from powdermeet_pipeline.publish import recorded_manifest_version


class FakeClient:
    def __init__(self, rows):
        self.rows = list(rows)

    def select(self, table, query):
        assert table == "resort_bundles"
        rows = [r for r in self.rows if f"eq.{r['resort_id']}" == query["resort_id"]]
        if "bundle_id" in query:
            rows = [r for r in rows if f"eq.{r['bundle_id']}" == query["bundle_id"]]
        rows.sort(key=lambda r: r["manifest_version"], reverse=True)
        return [{"manifest_version": r["manifest_version"]} for r in rows[: int(query.get("limit", len(rows)))]]


def row(bundle_id, manifest_version, resort_id="vail"):
    return {"bundle_id": bundle_id, "resort_id": resort_id, "manifest_version": manifest_version}


@pytest.mark.parametrize("rows, document_version, expected", [
    ([row("a", 5), row("b", 3)], 1, 6),   # fresh work directory behind the server
    ([row("a", 5)], 5, 6),                # same number, different bundle
    ([row("a", 5)], 7, 7),                # local numbering already ahead
    ([], 2, 2),                           # first publish of the resort
    ([row("a", 9, "stowe")], 1, 1),       # another resort's numbers do not count
    ([row("a", 5), row("new", 6)], 1, 6), # a re-run keeps the number it recorded
])
def test_recorded_manifest_version_is_above_older_bundles(rows, document_version, expected):
    assert recorded_manifest_version(FakeClient(rows), "vail", "new", document_version) == expected

