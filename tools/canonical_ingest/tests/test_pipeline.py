from __future__ import annotations

import hashlib
import json
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch
from urllib.parse import parse_qs

from canonical_ingest import apply as apply_mod
from canonical_ingest import cli, identity_decisions, reconcile, review_report
from canonical_ingest.models import (
    DraftManifest, DraftRow, SourceItem, SourceResult,
)
from canonical_ingest.sources import official, official_map, openskimap, overpass
from canonical_ingest.sources.common import merge_duplicate_items, normalize_grooming


def replace_source_difficulty(
    source: SourceResult, difficulty: str
) -> SourceResult:
    item = source.items[0]
    return SourceResult(
        source=source.source,
        resort_id=source.resort_id,
        role=source.role,
        items=(SourceItem(
            kind=item.kind,
            name=item.name,
            confidence=item.confidence,
            geometry=item.geometry,
            osm_way_ids=item.osm_way_ids,
            extra={**item.extra, "difficulty": difficulty},
        ),),
        fetched_at=source.fetched_at,
    )


class CanonicalIngestSafetyTests(unittest.TestCase):
    def test_private_lift_is_not_a_public_canonical_candidate(self):
        way = {"type": "way", "id": 10, "nodes": [1, 2],
               "tags": {"aerialway": "gondola", "name": "Private Lift", "access": "private"}}
        self.assertEqual(overpass._extract_items({"elements": [way]}), [])
        way["tags"]["ski"] = "yes"
        self.assertEqual(len(overpass._extract_items({"elements": [way]})), 1)

    def test_piste_area_does_not_claim_a_centerline_identity(self):
        nodes = [{"type": "node", "id": i, "lat": 40 + i/1000, "lon": -106} for i in (1, 2, 3)]
        ways = [{"type": "way", "id": 10, "nodes": [1, 2, 3, 1],
                 "tags": {"piste:type": "downhill", "name": "Alpine", "area": "yes"}},
                {"type": "way", "id": 20, "nodes": [1, 2, 3],
                 "tags": {"piste:type": "downhill", "name": "Alpine", "area": "no"}}]
        items = overpass._extract_items({"elements": nodes + ways})
        self.assertEqual(len(items), 1)
        self.assertEqual(items[0].osm_way_ids, ("20",))

    def test_publish_cli_defaults_to_elevation_preserving_graph_version(self) -> None:
        with tempfile.TemporaryDirectory() as folder, \
                patch.object(cli, "DRAFTS_DIR", Path(folder)), \
                patch.object(cli, "_cmd_publish", return_value=0) as publish:
            self.assertEqual(cli.main([
                "publish", "vail", "--manifest-version", "1",
                "--snapshot-date", "2026-09-03", "--content-sha256", "a" * 64,
            ]), 0)
            self.assertEqual(publish.call_args.args[0].graph_version, "v15")

    @staticmethod
    def _empty_reviewed_manifest() -> DraftManifest:
        return DraftManifest(
            resort_id="vail",
            expected_trail_count=0,
            expected_lift_count=0,
            canonical_counts_reviewed=True,
        )

    def test_reconcile_rejects_all_empty_sources_even_with_expected_counts(self) -> None:
        results = [
            SourceResult(source="official", resort_id="vail"),
            SourceResult(source="overpass", resort_id="vail"),
        ]
        with self.assertRaises(reconcile.SourceDataUnavailableError):
            reconcile.reconcile(
                results,
                expected_trail_count=195,
                expected_lift_count=32,
            )

    def test_apply_requires_human_acceptance_and_exact_expected_counts(self) -> None:
        row = DraftRow(
            name="Born Free",
            kind="trail",
            sources_seen=("official",),
            confidence=1,
            accepted=False,
        )
        manifest = DraftManifest(
            resort_id="vail",
            expected_trail_count=1,
            expected_lift_count=0,
            trail_rows=[row],
            canonical_counts_reviewed=True,
        )
        with self.assertRaisesRegex(
            apply_mod.ManifestValidationError,
            "accepted trail count 0",
        ):
            apply_mod.apply(manifest, dry_run=True)

        row.accepted = True
        result = apply_mod.apply(manifest, dry_run=True)
        self.assertFalse(result.written)
        self.assertIn("1 trails, 0 lifts", result.note)

    def test_apply_rejects_duplicate_accepted_names(self) -> None:
        rows = [
            DraftRow(name="Riva Ridge", kind="trail", accepted=True),
            DraftRow(name=" riva ridge ", kind="trail", accepted=True),
        ]
        manifest = DraftManifest(
            resort_id="vail",
            expected_trail_count=2,
            expected_lift_count=0,
            trail_rows=rows,
            canonical_counts_reviewed=True,
        )
        with self.assertRaisesRegex(
            apply_mod.ManifestValidationError,
            "names must be unique",
        ):
            apply_mod.apply(manifest, dry_run=True)

    def test_network_apply_refuses_backend_without_publication_safety(self) -> None:
        manifest = self._empty_reviewed_manifest()
        with patch.multiple(
            apply_mod,
            SUPABASE_URL="https://example.supabase.co",
            SUPABASE_SERVICE_KEY="service-key",
        ), patch.object(
            apply_mod, "_publication_safety_available", return_value=False,
        ), patch.object(apply_mod, "_rpc") as rpc:
            with self.assertRaisesRegex(RuntimeError, "publication-safety"):
                apply_mod.apply(manifest)
        rpc.assert_not_called()

    def test_latest_manifest_lookup_uses_staging_table_not_active_view(self) -> None:
        response = json.dumps([{
            "resort_id": "vail",
            "manifest_version": 9,
            "validator_notes": "#content_hash:abc",
        }]).encode()
        with patch.object(
            apply_mod, "SUPABASE_URL", "https://example.supabase.co",
        ), patch.object(apply_mod, "_http_get", return_value=response) as get:
            latest = apply_mod._fetch_latest("vail")
        self.assertEqual(latest["manifest_version"], 9)
        url = get.call_args.args[0]
        self.assertIn("/rest/v1/resort_canonical_manifest?", url)
        self.assertNotIn("current_resort_canonical_manifest", url)
        self.assertIn("order=manifest_version.desc", url)

    def test_publish_rejects_incomplete_or_malformed_exact_identity(self) -> None:
        sha = "a" * 64
        invalid = [
            ("", 1, "v11", "2026-08-09", sha, "resort_id"),
            ("../vail", 1, "v11", "2026-08-09", sha, "resort_id"),
            ("vail", True, "v11", "2026-08-09", sha, "manifest_version"),
            ("vail", "1", "v11", "2026-08-09", sha, "manifest_version"),
            ("vail", 0, "v11", "2026-08-09", sha, "manifest_version"),
            ("vail", 1, None, "2026-08-09", sha, "graph_version"),
            ("vail", 1, "latest", "2026-08-09", sha, "graph_version"),
            ("vail", 1, "v11", "2026-02-30", sha, "snapshot_date"),
            ("vail", 1, "v11", "2026-08-09", sha.upper(), "content_sha256"),
            ("vail", 1, "v11", "2026-08-09", None, "content_sha256"),
        ]
        with patch.multiple(
            apply_mod,
            SUPABASE_URL="https://example.supabase.co",
            SUPABASE_SERVICE_KEY="service-key",
        ), patch.object(
            apply_mod, "_publication_safety_available", return_value=True,
        ), patch.object(apply_mod, "_rpc") as rpc:
            for resort, version, graph, snapshot, content_sha, message in invalid:
                with self.subTest(message=message), self.assertRaisesRegex(
                    ValueError, message,
                ):
                    apply_mod.publish(
                        resort, version, graph, snapshot, content_sha,
                    )
        rpc.assert_not_called()

    def test_publish_calls_atomic_rpc_with_full_exact_identity(self) -> None:
        sha = "b" * 64
        rpc_result = {
            "resort_id": "vail",
            "manifest_version": 4,
            "graph_version": "v11",
            "snapshot_date": "2026-08-09",
            "content_sha256": sha,
            "blob_storage_path": "vail/4-2026-08-09-v11.json.gz",
        }
        with patch.multiple(
            apply_mod,
            SUPABASE_URL="https://example.supabase.co",
            SUPABASE_SERVICE_KEY="service-key",
        ), patch.object(
            apply_mod, "_publication_safety_available", return_value=True,
        ), patch.object(
            apply_mod, "_rpc", return_value=rpc_result,
        ) as rpc:
            result = apply_mod.publish(
                "vail", 4, "v11", "2026-08-09", sha,
            )
        rpc.assert_called_once_with("publish_canonical_manifest", {
            "p_resort_id": "vail",
            "p_manifest_version": 4,
            "p_graph_version": "v11",
            "p_snapshot_date": "2026-08-09",
            "p_content_sha256": sha,
        })
        self.assertEqual(result.blob_storage_path, rpc_result["blob_storage_path"])

    def test_publish_rejects_mismatched_rpc_identity(self) -> None:
        sha = "d" * 64
        with patch.multiple(
            apply_mod,
            SUPABASE_URL="https://example.supabase.co",
            SUPABASE_SERVICE_KEY="service-key",
        ), patch.object(
            apply_mod, "_publication_safety_available", return_value=True,
        ), patch.object(apply_mod, "_rpc", return_value={
            "resort_id": "vail",
            "manifest_version": 5,
            "graph_version": "v11",
            "snapshot_date": "2026-08-09",
            "content_sha256": sha,
            "blob_storage_path": "vail/wrong.json.gz",
        }):
            with self.assertRaisesRegex(RuntimeError, "mismatched"):
                apply_mod.publish("vail", 4, "v11", "2026-08-09", sha)

    def test_publish_cli_reports_failure_without_mutating_a_draft(self) -> None:
        args = SimpleNamespace(
            resort_id="vail",
            manifest_version=4,
            graph_version="v11",
            snapshot_date="2026-08-09",
            content_sha256="c" * 64,
        )
        with patch.object(
            apply_mod, "publish", side_effect=RuntimeError("migration missing"),
        ):
            self.assertEqual(cli._cmd_publish(args), 10)

    def test_overpass_request_is_form_encoded(self) -> None:
        captured = {}

        class Response:
            def __enter__(self):
                return self

            def __exit__(self, *_args):
                return False

            def read(self):
                return json.dumps({"elements": []}).encode()

        def fake_urlopen(request, timeout):
            captured["request"] = request
            captured["timeout"] = timeout
            return Response()

        query = "[out:json];way[piste:type=downhill](1,2,3,4);out;"
        with patch.object(overpass, "urlopen", side_effect=fake_urlopen):
            self.assertEqual(overpass._post_overpass(query), {"elements": []})

        encoded = captured["request"].data.decode()
        self.assertEqual(parse_qs(encoded)["data"], [query])

    def test_overpass_query_quotes_colon_tag_keys(self) -> None:
        query = overpass._build_query(1, 2, 3, 4)
        self.assertIn('way["piste:type"="downhill"](1,2,3,4)', query)
        self.assertIn('way["piste:type"="connection"](1,2,3,4)', query)
        self.assertIn('way["aerialway"](1,2,3,4)', query)

    def test_overpass_excludes_station_and_non_transport_ways(self) -> None:
        data = {
            "elements": [
                {"type": "node", "id": 1, "lat": 1, "lon": 1},
                {"type": "node", "id": 2, "lat": 2, "lon": 2},
                {
                    "type": "way", "id": 10, "nodes": [1, 2],
                    "tags": {"aerialway": "station", "name": "Base Station"},
                },
                {
                    "type": "way", "id": 11, "nodes": [1, 2],
                    "tags": {"aerialway": "zip_line", "name": "Adventure Zip"},
                },
                {
                    "type": "way", "id": 12, "nodes": [1, 2],
                    "tags": {"aerialway": "chair_lift", "name": "Chair One"},
                },
            ]
        }
        items = overpass._extract_items(data)
        self.assertEqual([item.name for item in items], ["Chair One"])
        self.assertEqual(items[0].extra["lift_type"], "chair_lift")

    def test_duplicate_segments_retain_every_way_and_flag_attribute_conflicts(self) -> None:
        items = merge_duplicate_items([
            SourceItem(
                kind="trail", name="Born Free", osm_way_ids=("20",),
                geometry=[(1, 1), (2, 2)],
                extra={"difficulty": "blue"},
            ),
            SourceItem(
                kind="trail", name="born free", osm_way_ids=("10",),
                geometry=[(2, 2), (3, 3)],
                extra={"difficulty": "green"},
            ),
        ])
        self.assertEqual(len(items), 1)
        self.assertEqual(items[0].osm_way_ids, ("10", "20"))
        self.assertIsNone(items[0].geometry)
        self.assertEqual(items[0].extra["source_segment_count"], 2)
        self.assertEqual(items[0].extra["attribute_conflicts"], ("difficulty",))
        self.assertEqual(
            items[0].extra["attribute_observations"]["difficulty"],
            ('"blue"', '"green"'),
        )

    def test_missing_grooming_remains_unknown(self) -> None:
        self.assertIsNone(normalize_grooming(None))
        self.assertIsNone(normalize_grooming("unsupported-tag"))
        self.assertTrue(normalize_grooming("classic"))
        self.assertFalse(normalize_grooming("backcountry"))

    def test_official_json_preserves_typed_attributes_and_geometry(self) -> None:
        trail = official._item_from_dict("trail", {
            "name": "Riva Ridge",
            "difficulty": "black",
            "is_groomed": "false",
            "has_moguls": True,
            "length_m": "4200.5",
            "osm_way_ids": [10, 20],
            "canonical_geometry": {
                "type": "LineString",
                "coordinates": [[-106.4, 39.6], [-106.3, 39.7]],
            },
        })
        self.assertEqual(trail.osm_way_ids, ("10", "20"))
        self.assertEqual(trail.geometry, [(-106.4, 39.6), (-106.3, 39.7)])
        self.assertEqual(trail.extra["difficulty"], "black")
        self.assertFalse(trail.extra["is_groomed"])
        self.assertTrue(trail.extra["has_moguls"])
        self.assertEqual(trail.extra["length_m"], 4200.5)

        lift = official._item_from_dict("lift", {
            "name": "Gondola One",
            "lift_type": "gondola",
            "capacity": "10",
            "base_coord": [-106.4, 39.6],
            "top_coord": {"type": "Point", "coordinates": [-106.3, 39.7]},
        })
        self.assertEqual(lift.extra["capacity"], 10)
        self.assertEqual(lift.extra["base_coord"], (-106.4, 39.6))
        self.assertEqual(lift.extra["top_coord"], (-106.3, 39.7))

    def test_official_map_is_validated_incomplete_evidence_not_inventory(self) -> None:
        payload = {
            "schema_version": 1,
            "resort_id": "vail",
            "season": "2025-2026",
            "observed_at": "2026-08-09",
            "usage": "corroboration_only",
            "maps": [{
                "id": "front",
                "source_url": "https://example.test/front.jpg",
                "content_sha256": "a" * 64,
            }],
            "labels": [{
                "kind": "lift",
                "name": "Cascade Village Lift",
                "official_number": 20,
                "map_ids": ["front"],
            }],
        }
        with tempfile.TemporaryDirectory() as directory, patch.object(
            official_map, "OFFICIAL_MAP_DIR", Path(directory)
        ):
            (Path(directory) / "vail.json").write_text(json.dumps(payload))
            source = official_map.fetch("vail")
        self.assertEqual(source.role, "evidence")
        self.assertEqual(source.fetched_at, "2026-08-09")
        self.assertEqual([item.name for item in source.items], [
            "Cascade Village Lift"
        ])
        self.assertEqual(
            source.items[0].extra["official_map_evidence"]["official_number"],
            20,
        )
        self.assertEqual(
            source.items[0].extra["official_map_evidence"]["maps"][0][
                "content_sha256"
            ],
            "a" * 64,
        )

    def test_evidence_counts_do_not_claim_inventory_or_force_disagreement(self) -> None:
        evidence = SourceResult(
            source="official_map", resort_id="vail", role="evidence",
            items=(
                SourceItem(kind="trail", name="Born Free"),
                SourceItem(kind="lift", name="Cascade Village Lift"),
            ),
        )
        source = SourceResult(
            source="overpass", resort_id="vail", items=(
                SourceItem(kind="trail", name="Born Free", osm_way_ids=("10",)),
            ),
        )
        manifest = reconcile.reconcile([evidence, source])
        self.assertEqual(manifest.expected_trail_count, 1)
        self.assertEqual(manifest.expected_lift_count, 1)
        born_free = manifest.trail_rows[0]
        self.assertEqual(born_free.sources_seen, ("official_map", "overpass"))
        self.assertEqual(born_free.confidence, 0.75)

    def test_approximate_names_are_suggestions_and_never_auto_merged(self) -> None:
        results = [
            SourceResult(
                source="official_map", resort_id="vail", role="evidence",
                items=(SourceItem(kind="trail", name="Wild Card"),),
            ),
            SourceResult(
                source="overpass", resort_id="vail",
                items=(SourceItem(
                    kind="trail", name="Wildcard", osm_way_ids=("10",)
                ),),
            ),
        ]
        manifest = reconcile.reconcile(
            results, expected_trail_count=2, expected_lift_count=0
        )
        self.assertEqual(
            [row.name for row in manifest.trail_rows], ["Wild Card", "Wildcard"]
        )
        report = review_report.build_report(cli._serialize_draft(manifest))
        self.assertEqual(len(report["near_name_suggestions"]), 1)
        self.assertEqual(
            report["near_name_suggestions"][0]["reason"], "compact_equivalent"
        )

    def test_positional_segments_are_reviewed_as_a_family_not_auto_merged(self) -> None:
        source = SourceResult(
            source="overpass", resort_id="vail", items=(
                SourceItem(kind="trail", name="Avanti - Lower", osm_way_ids=("10",)),
                SourceItem(kind="trail", name="Avanti - Upper", osm_way_ids=("20",)),
            ),
        )
        manifest = reconcile.reconcile(
            [source], expected_trail_count=2, expected_lift_count=0
        )
        report = review_report.build_report(cli._serialize_draft(manifest))
        family = report["segment_family_suggestions"][0]
        self.assertEqual(family["base_name"], "Avanti")
        self.assertEqual(family["members"], ["Avanti - Lower", "Avanti - Upper"])
        self.assertFalse(family["official_map_label_present"])

    def test_evidence_pinned_identity_decision_merges_exact_members_only(self) -> None:
        results = [
            SourceResult(
                source="official_map", resort_id="vail", role="evidence",
                items=(SourceItem(
                    kind="trail", name="Avanti",
                    extra={"official_map_evidence": {"map": "front"}},
                ),),
            ),
            SourceResult(
                source="overpass", resort_id="vail", items=(
                    SourceItem(
                        kind="trail", name="Avanti - Lower",
                        osm_way_ids=("10",), extra={"difficulty": "blue"},
                    ),
                    SourceItem(
                        kind="trail", name="Avanti - Upper",
                        osm_way_ids=("20",), extra={"difficulty": "blue"},
                    ),
                ),
            ),
        ]
        with tempfile.TemporaryDirectory() as directory:
            package = Path(directory)
            decisions_dir = package / "decisions"
            decisions_dir.mkdir()
            artifact = package / "fixture.json"
            artifact.write_text('{"source":"fixed"}')
            artifact_hash = hashlib.sha256(artifact.read_bytes()).hexdigest()
            raw = {
                "schema_version": 1,
                "resort_id": "vail",
                "artifacts": [{
                    "path": "fixture.json", "sha256": artifact_hash,
                }],
                "merges": [{
                    "id": "trail:avanti",
                    "kind": "trail",
                    "canonical_name": "Avanti",
                    "members": [
                        {"source": "official_map", "name": "Avanti"},
                        {"source": "overpass", "name": "Avanti - Lower"},
                        {"source": "overpass", "name": "Avanti - Upper"},
                    ],
                }],
            }
            with patch.object(
                identity_decisions, "PACKAGE_DIR", package
            ), patch.object(
                identity_decisions, "DECISIONS_DIR", decisions_dir
            ):
                fingerprint = identity_decisions.expected_fingerprints(
                    raw, results
                )["trail:avanti"]
                raw["merges"][0]["evidence_fingerprint"] = fingerprint
                (decisions_dir / "vail.json").write_text(json.dumps(raw))
                transformed, count = identity_decisions.load_and_apply(
                    "vail", results
                )

        self.assertEqual(count, 1)
        manifest = reconcile.reconcile(
            transformed, expected_trail_count=1, expected_lift_count=0
        )
        self.assertEqual(len(manifest.trail_rows), 1)
        row = manifest.trail_rows[0]
        self.assertEqual(row.name, "Avanti")
        self.assertEqual(row.osm_way_ids, ("10", "20"))
        self.assertEqual(
            row.source_name_variants,
            ("Avanti", "Avanti - Lower", "Avanti - Upper"),
        )
        self.assertEqual(row.unresolved_conflicts, ())
        self.assertEqual(row.identity_decision_ids, ("trail:avanti",))
        self.assertEqual(row.difficulty, "blue")
        self.assertEqual(
            row.source_segment_counts, {"official_map": 1, "overpass": 2}
        )

    def test_identity_decision_rejects_stale_artifact_and_changed_source(self) -> None:
        results = [
            SourceResult(
                source="official_map", resort_id="vail", role="evidence",
                items=(SourceItem(kind="trail", name="Avanti"),),
            ),
            SourceResult(
                source="overpass", resort_id="vail", items=(SourceItem(
                    kind="trail", name="Avanti - Lower", osm_way_ids=("10",),
                    extra={"difficulty": "blue"},
                ),),
            ),
        ]
        with tempfile.TemporaryDirectory() as directory:
            package = Path(directory)
            decisions_dir = package / "decisions"
            decisions_dir.mkdir()
            artifact = package / "fixture.json"
            artifact.write_text("fixed")
            raw = {
                "schema_version": 1,
                "resort_id": "vail",
                "artifacts": [{
                    "path": "fixture.json",
                    "sha256": hashlib.sha256(artifact.read_bytes()).hexdigest(),
                }],
                "merges": [{
                    "id": "trail:avanti",
                    "kind": "trail",
                    "canonical_name": "Avanti",
                    "members": [
                        {"source": "official_map", "name": "Avanti"},
                        {"source": "overpass", "name": "Avanti - Lower"},
                    ],
                }],
            }
            with patch.object(
                identity_decisions, "PACKAGE_DIR", package
            ), patch.object(
                identity_decisions, "DECISIONS_DIR", decisions_dir
            ):
                raw["merges"][0]["evidence_fingerprint"] = (
                    identity_decisions.expected_fingerprints(raw, results)[
                        "trail:avanti"
                    ]
                )
                (decisions_dir / "vail.json").write_text(json.dumps(raw))

                changed_results = [results[0], replace_source_difficulty(
                    results[1], "black"
                )]
                with self.assertRaisesRegex(
                    identity_decisions.IdentityDecisionError,
                    "evidence changed",
                ):
                    identity_decisions.load_and_apply("vail", changed_results)

                artifact.write_text("changed")
                with self.assertRaisesRegex(
                    identity_decisions.IdentityDecisionError,
                    "artifact changed",
                ):
                    identity_decisions.load_and_apply("vail", results)

    def test_identity_decision_rejects_overlapping_members(self) -> None:
        results = [SourceResult(
            source="overpass", resort_id="vail", items=(
                SourceItem(kind="trail", name="A"),
                SourceItem(kind="trail", name="B"),
                SourceItem(kind="trail", name="C"),
            ),
        )]
        raw = {
            "schema_version": 1,
            "resort_id": "vail",
            "artifacts": [{"path": "fixture.json", "sha256": "a" * 64}],
            "merges": [
                {
                    "id": "first", "kind": "trail", "canonical_name": "A",
                    "members": [
                        {"source": "overpass", "name": "A"},
                        {"source": "overpass", "name": "B"},
                    ],
                },
                {
                    "id": "second", "kind": "trail", "canonical_name": "B",
                    "members": [
                        {"source": "overpass", "name": "B"},
                        {"source": "overpass", "name": "C"},
                    ],
                },
            ],
        }
        with self.assertRaisesRegex(
            identity_decisions.IdentityDecisionError,
            "claimed by multiple",
        ):
            identity_decisions.expected_fingerprints(raw, results)

    def test_openskimap_excludes_explicit_non_transport_aerialways(self) -> None:
        payload = {"features": [
            {
                "properties": {"name": "Base", "aerialway": "station"},
                "geometry": {"type": "LineString", "coordinates": [[1, 1], [2, 2]]},
            },
            {
                "properties": {"name": "Chair One", "aerialway": "chair_lift"},
                "geometry": {"type": "LineString", "coordinates": [[1, 1], [2, 2]]},
            },
        ]}
        items = openskimap._extract_features(payload, kind="lift")
        self.assertEqual([item.name for item in items], ["Chair One"])

    def test_reconcile_merges_ids_and_attributes_without_hiding_conflicts(self) -> None:
        results = [
            SourceResult(
                source="official", resort_id="vail", items=(SourceItem(
                    kind="trail", name="Born Free",
                    extra={"difficulty": "blue", "is_groomed": True},
                ),),
            ),
            SourceResult(
                source="overpass", resort_id="vail", items=(SourceItem(
                    kind="trail", name="Born Free", osm_way_ids=("10", "20"),
                    extra={
                        "difficulty": "black", "is_groomed": True,
                        "source_segment_count": 2,
                    },
                ),),
            ),
        ]
        manifest = reconcile.reconcile(
            results, expected_trail_count=1, expected_lift_count=0,
        )
        row = manifest.trail_rows[0]
        self.assertEqual(row.difficulty, "blue")
        self.assertTrue(row.is_groomed)
        self.assertEqual(row.osm_way_ids, ("10", "20"))
        self.assertEqual(row.source_segment_counts, {"official": 1, "overpass": 2})
        self.assertEqual(row.unresolved_conflicts, ("difficulty",))
        self.assertEqual(
            row.source_attribute_observations["official"]["difficulty"],
            ('"blue"',),
        )
        self.assertEqual(
            row.source_attribute_observations["overpass"]["difficulty"],
            ('"black"',),
        )
        self.assertEqual(len(row.source_evidence_fingerprint or ""), 64)

    def test_apply_rejects_unresolved_attributes_and_hashes_resolved_values(self) -> None:
        row = DraftRow(
            name="Born Free", kind="trail", accepted=True,
            difficulty="blue", is_groomed=True, osm_way_ids=("10", "20"),
            unresolved_conflicts=("difficulty",),
        )
        manifest = DraftManifest(
            resort_id="vail", expected_trail_count=1, expected_lift_count=0,
            trail_rows=[row], canonical_counts_reviewed=True,
        )
        with self.assertRaisesRegex(
            apply_mod.ManifestValidationError, "unresolved source conflicts",
        ):
            apply_mod.apply(manifest, dry_run=True)

        row.unresolved_conflicts = ()
        blue_hash = apply_mod._content_hash(manifest)
        payload = apply_mod._trail_payload(row)
        self.assertEqual(payload["difficulty"], "blue")
        self.assertEqual(payload["osm_way_ids"], ["10", "20"])
        row.difficulty = "black"
        self.assertNotEqual(apply_mod._content_hash(manifest), blue_hash)

    def test_way_id_order_and_duplicates_do_not_change_canonical_content(self) -> None:
        row = DraftRow(
            name="Born Free", kind="trail", accepted=True,
            osm_way_ids=("20", "10", "20"),
        )
        manifest = DraftManifest(
            resort_id="vail", expected_trail_count=1, expected_lift_count=0,
            trail_rows=[row], canonical_counts_reviewed=True,
        )
        first_hash = apply_mod._content_hash(manifest)
        self.assertEqual(apply_mod._trail_payload(row)["osm_way_ids"], ["10", "20"])
        row.osm_way_ids = ("10", "20")
        self.assertEqual(apply_mod._content_hash(manifest), first_hash)

    def test_apply_validates_typed_canonical_attributes(self) -> None:
        trail = DraftRow(
            name="Born Free", kind="trail", accepted=True,
            difficulty="purple",
        )
        manifest = DraftManifest(
            resort_id="vail", expected_trail_count=1, expected_lift_count=0,
            trail_rows=[trail], canonical_counts_reviewed=True,
        )
        with self.assertRaisesRegex(
            apply_mod.ManifestValidationError, "invalid difficulty",
        ):
            apply_mod.apply(manifest, dry_run=True)

    def test_vail_fixture_matches_the_review_only_inventory(self) -> None:
        fixture_path = (
            Path(__file__).resolve().parents[1]
            / "fixtures" / "overpass" / "vail.json"
        )
        review_path = (
            Path(__file__).resolve().parents[1]
            / "reviews" / "vail-2025-26.json"
        )
        items = overpass._extract_items(json.loads(fixture_path.read_text()))
        reversed_payload = json.loads(fixture_path.read_text())
        reversed_payload["elements"].reverse()
        self.assertEqual(items, overpass._extract_items(reversed_payload))
        review = json.loads(review_path.read_text())
        inventory = review["overpass_candidate_inventory"]

        trails = [item for item in items if item.kind == "trail"]
        lifts = [item for item in items if item.kind == "lift"]
        self.assertEqual(len(trails), inventory["unique_normalized_trail_name_count"])
        self.assertEqual(len(lifts), inventory["unique_routable_lift_name_count"])
        self.assertNotIn("Gondola One Lower Station", {item.name for item in lifts})
        born_free = next(item for item in trails if item.name == "Born Free")
        self.assertEqual(len(born_free.osm_way_ids), 5)
        self.assertEqual(born_free.extra["attribute_conflicts"], ("difficulty",))
        self.assertFalse(review["production_apply_allowed"])
        self.assertFalse(review["review_state"]["canonical_counts_reviewed"])
        self.assertEqual(
            review["review_state"]["raw_review_union_trail_count"], 230
        )
        self.assertEqual(
            review["review_state"]["raw_review_union_lift_count"], 33
        )
        self.assertEqual(
            review["overpass_topology_crosscheck"]["disconnected_candidate_count"],
            6,
        )
        map_only = {
            row["name"]
            for row in review["official_map_manual_crosscheck"][
                "confirmed_routable_lifts_present_on_official_map_but_absent_from_overpass"
            ]
        }
        self.assertEqual(
            map_only, {"Cascade Village Lift", "Earl's Express Lift"}
        )
        map_source = official_map.fetch("vail")
        label_evidence = review["official_map_label_evidence"]
        self.assertEqual(
            sum(item.kind == "trail" for item in map_source.items),
            label_evidence["reviewed_trail_label_count"],
        )
        self.assertEqual(
            sum(item.kind == "lift" for item in map_source.items),
            label_evidence["reviewed_lift_label_count"],
        )
        self.assertEqual(
            review["positional_segment_family_crosscheck"]["family_count"], 17
        )
        union = reconcile.reconcile([
            map_source,
            SourceResult(
                source="overpass", resort_id="vail", items=tuple(items)
            ),
        ])
        self.assertEqual(
            len(union.trail_rows),
            review["review_state"]["raw_review_union_trail_count"],
        )
        self.assertEqual(
            len(union.lift_rows),
            review["review_state"]["raw_review_union_lift_count"],
        )
        self.assertEqual(
            sum(
                {"official_map", "overpass"}.issubset(row.sources_seen)
                for row in union.trail_rows
            ),
            label_evidence["overpass_trail_candidates_exactly_corroborated"],
        )
        self.assertEqual(
            sum(
                {"official_map", "overpass"}.issubset(row.sources_seen)
                for row in union.lift_rows
            ),
            label_evidence["overpass_lift_candidates_exactly_corroborated"],
        )
        union_report = review_report.build_report(
            cli._serialize_draft(union), json.loads(fixture_path.read_text())
        )
        family_gate = review["positional_segment_family_crosscheck"]
        families = union_report["segment_family_suggestions"]
        self.assertEqual(len(families), family_gate["family_count"])
        self.assertEqual(
            sum(
                family["combined_topology"]["classification"] == "connected_chain"
                for family in families
            ),
            family_gate["connected_chain_family_count"],
        )
        self.assertEqual(
            sum(len(family["members"]) - 1 for family in families),
            family_gate["candidate_row_reduction_if_every_family_were_approved"],
        )
        observed_pairs = {
            frozenset((pair["left"], pair["right"]))
            for pair in union_report["near_name_suggestions"]
        }
        expected_pairs = {
            frozenset(pair)
            for pair in review["near_name_crosscheck"]["raw_pairs"]
        }
        self.assertEqual(observed_pairs, expected_pairs)

        source_results = [
            map_source,
            SourceResult(
                source="overpass", resort_id="vail", items=tuple(items)
            ),
        ]
        decision_path = (
            Path(__file__).resolve().parents[1] / "decisions" / "vail.json"
        )
        decision_raw = json.loads(decision_path.read_text())
        expected_fingerprints = identity_decisions.expected_fingerprints(
            decision_raw, source_results
        )
        self.assertEqual(
            expected_fingerprints,
            {
                merge["id"]: merge["evidence_fingerprint"]
                for merge in decision_raw["merges"]
            },
        )
        transformed, decision_count = identity_decisions.load_and_apply(
            "vail", source_results
        )
        current = reconcile.reconcile(transformed)
        current_report = review_report.build_report(
            cli._serialize_draft(current), json.loads(fixture_path.read_text())
        )
        state = review["review_state"]
        self.assertEqual(len(current.trail_rows), state[
            "current_offline_candidate_trail_count"
        ])
        self.assertEqual(len(current.lift_rows), state[
            "current_offline_candidate_lift_count"
        ])
        self.assertEqual(
            decision_count,
            review["identity_decision_application"]["applied_decision_count"],
        )
        self.assertEqual(
            current_report["applied_identity_decisions"],
            sorted(expected_fingerprints),
        )
        self.assertEqual(
            current_report["unresolved_conflict_count"],
            state["unresolved_attribute_conflict_count"],
        )
        expected_conflicts = review["decision_applied_attribute_conflicts"]
        observed_conflicts = {
            row["name"]: row["source_attribute_observations"]["overpass"][
                expected_conflicts["attribute"]
            ]
            for row in current_report["rows"]
            if expected_conflicts["attribute"] in row["unresolved_conflicts"]
        }
        self.assertEqual(observed_conflicts, expected_conflicts["trails"])
        current_topology = review["decision_applied_topology_crosscheck"]
        self.assertEqual(
            current_report["multi_way_topology_counts"],
            {
                "connected_branch": current_topology["connected_branch_count"],
                "connected_chain": current_topology["connected_chain_count"],
                "disconnected": current_topology["disconnected_count"],
            },
        )
        self.assertEqual(
            len(current_report["segment_family_suggestions"]),
            current_topology["remaining_positional_family_count"],
        )
        self.assertEqual(
            {
                frozenset((pair["left"], pair["right"]))
                for pair in current_report["near_name_suggestions"]
            },
            {
                frozenset(pair)
                for pair in review["near_name_crosscheck"]["remaining_pairs"]
            },
        )

    def test_headline_statistics_never_satisfy_canonical_identity_counts(self) -> None:
        row = DraftRow(name="Born Free", kind="trail", accepted=True)
        manifest = DraftManifest(
            resort_id="vail",
            expected_trail_count=1,
            expected_lift_count=0,
            trail_rows=[row],
            canonical_counts_reviewed=True,
            headline_trail_count=278,
            headline_lift_count=32,
        )
        result = apply_mod.apply(manifest, dry_run=True)
        self.assertIn("1 trails, 0 lifts", result.note)

        manifest.expected_trail_count = 278
        with self.assertRaisesRegex(
            apply_mod.ManifestValidationError,
            "expected canonical trail identity count 278",
        ):
            apply_mod.apply(manifest, dry_run=True)

    def test_apply_requires_explicit_canonical_count_review_gate(self) -> None:
        manifest = DraftManifest(
            resort_id="vail",
            expected_trail_count=1,
            expected_lift_count=0,
            trail_rows=[DraftRow(name="Born Free", kind="trail", accepted=True)],
        )
        with self.assertRaisesRegex(
            apply_mod.ManifestValidationError,
            "canonical identity counts have not been reviewed",
        ):
            apply_mod.apply(manifest, dry_run=True)

    def test_review_evidence_round_trips_without_becoming_validation_input(self) -> None:
        original = DraftManifest(
            resort_id="vail",
            expected_trail_count=1,
            expected_lift_count=0,
            canonical_counts_reviewed=True,
            headline_trail_count=278,
            headline_lift_count=32,
            evidence_observed_at="2026-08-02",
            source_references=("https://example.test/info",),
            lift_rows=[DraftRow(
                name="Gondola One", kind="lift", lift_type="gondola",
                capacity=10, ride_time_s=420.0,
                base_coord=(-106.4, 39.6), top_coord=(-106.3, 39.7),
                geometry=[(-106.4, 39.6), (-106.3, 39.7)],
                osm_way_ids=("10",),
                source_name_variants=("Gondola One",),
                source_segment_counts={"official": 1},
                source_attribute_observations={
                    "official": {"capacity": ("10",)}
                },
                source_evidence_fingerprint="a" * 64,
            )],
        )
        decoded = cli._deserialize_draft(cli._serialize_draft(original))
        self.assertEqual(decoded, original)

    def test_unchanged_source_evidence_preserves_operator_review_only(self) -> None:
        source = SourceResult(
            source="overpass", resort_id="vail", items=(SourceItem(
                kind="trail", name="Born Free", osm_way_ids=("10",),
                extra={"difficulty": "blue"},
            ),),
        )
        old = reconcile.reconcile(
            [source], expected_trail_count=1, expected_lift_count=0
        )
        old.trail_rows[0].name = "Born Free (official)"
        old.trail_rows[0].accepted = True
        old.trail_rows[0].difficulty = "green"
        old.trail_rows[0].unresolved_conflicts = ()
        old.trail_rows[0].notes = "Verified on winter map"

        unchanged = reconcile.reconcile(
            [source], expected_trail_count=1, expected_lift_count=0
        )
        preserved = cli._preserve_review_decisions(
            unchanged, cli._serialize_draft(old)
        )
        self.assertEqual(preserved, 1)
        self.assertEqual(unchanged.trail_rows[0].name, "Born Free (official)")
        self.assertTrue(unchanged.trail_rows[0].accepted)
        self.assertEqual(unchanged.trail_rows[0].difficulty, "green")

        changed_source = SourceResult(
            source="overpass", resort_id="vail", items=(SourceItem(
                kind="trail", name="Born Free", osm_way_ids=("10",),
                extra={"difficulty": "black"},
            ),),
        )
        changed = reconcile.reconcile(
            [changed_source], expected_trail_count=1, expected_lift_count=0
        )
        self.assertEqual(
            cli._preserve_review_decisions(changed, cli._serialize_draft(old)), 0
        )
        self.assertFalse(changed.trail_rows[0].accepted)
        self.assertEqual(changed.trail_rows[0].difficulty, "black")

    def test_offline_vail_ingest_uses_frozen_fixture_without_legacy_stations(self) -> None:
        args = SimpleNamespace(
            resort_id="vail",
            bbox="39.572,-106.394,39.658,-106.298",
            lat_lon="39.605,-106.355",
            expected_canonical_trails=None,
            expected_canonical_lifts=None,
            canonical_counts_reviewed=False,
            headline_trails=278,
            headline_lifts=32,
            evidence_url=["https://www.vail.com/trail-map"],
            evidence_observed_at="2026-08-09",
            offline_fixtures=True,
        )
        with tempfile.TemporaryDirectory() as directory, patch.object(
            cli, "DRAFTS_DIR", Path(directory)
        ):
            self.assertEqual(cli._cmd_ingest(args), 0)
            raw = json.loads((Path(directory) / "vail.json").read_text())
        self.assertEqual(len(raw["trail_rows"]), 206)
        self.assertEqual(len(raw["lift_rows"]), 31)
        self.assertFalse(raw["canonical_counts_reviewed"])
        lift_names = {row["name"] for row in raw["lift_rows"]}
        self.assertNotIn("Gondola One Lower Station", lift_names)
        self.assertIn("Cascade Village Lift", lift_names)
        self.assertIn("Earl's Express Lift", lift_names)
        mountain_top = next(
            row for row in raw["lift_rows"]
            if row["name"] == "Mountain Top Express Lift"
        )
        self.assertEqual(
            mountain_top["source_name_variants"],
            ["Mountain Top Express Lift", "Mountain Top Express Lift (4)"],
        )
        self.assertEqual(
            mountain_top["identity_decision_ids"],
            ["lift:mountain-top-express"],
        )
        born_free = next(
            row for row in raw["trail_rows"] if row["name"] == "Born Free"
        )
        self.assertEqual(len(born_free["osm_way_ids"]), 5)
        self.assertEqual(born_free["unresolved_conflicts"], ["difficulty"])
        self.assertEqual(
            born_free["source_attribute_observations"]["overpass"]["difficulty"],
            ["blue", "green"],
        )

    def test_offline_ingest_fails_if_frozen_source_cannot_be_loaded(self) -> None:
        args = SimpleNamespace(
            resort_id="vail", bbox="1,2,3,4", lat_lon=None,
            expected_canonical_trails=None, expected_canonical_lifts=None,
            canonical_counts_reviewed=False, headline_trails=None,
            headline_lifts=None, evidence_url=[], evidence_observed_at=None,
            offline_fixtures=True,
        )
        with tempfile.TemporaryDirectory() as directory, patch.object(
            cli, "DRAFTS_DIR", Path(directory)
        ), patch.object(
            overpass, "fetch", side_effect=RuntimeError("fixture missing")
        ):
            self.assertEqual(cli._cmd_ingest(args), 9)
            self.assertFalse((Path(directory) / "vail.json").exists())

    def test_stale_identity_decision_cannot_overwrite_existing_draft(self) -> None:
        args = SimpleNamespace(
            resort_id="vail", bbox=None, lat_lon=None,
            expected_canonical_trails=None, expected_canonical_lifts=None,
            canonical_counts_reviewed=False, headline_trails=None,
            headline_lifts=None, evidence_url=[], evidence_observed_at=None,
            offline_fixtures=False,
        )
        sources = {
            "overpass": lambda *_args: SourceResult(
                source="overpass", resort_id="vail", items=(
                    SourceItem(kind="trail", name="Born Free"),
                ),
            ),
        }
        with tempfile.TemporaryDirectory() as directory:
            draft_path = Path(directory) / "vail.json"
            draft_path.write_text("existing reviewed work")
            with patch.object(cli, "SOURCES", sources), patch.object(
                cli, "DRAFTS_DIR", Path(directory)
            ), patch.object(
                identity_decisions,
                "load_and_apply",
                side_effect=identity_decisions.IdentityDecisionError(
                    "artifact changed"
                ),
            ):
                self.assertEqual(cli._cmd_ingest(args), 10)
            self.assertEqual(draft_path.read_text(), "existing reviewed work")

    def test_review_report_classifies_vail_multi_way_topology(self) -> None:
        fixture_path = (
            Path(__file__).resolve().parents[1]
            / "fixtures" / "overpass" / "vail.json"
        )
        payload = json.loads(fixture_path.read_text())
        source = SourceResult(
            source="overpass", resort_id="vail",
            items=tuple(overpass._extract_items(payload)),
        )
        manifest = reconcile.reconcile(
            [source], expected_trail_count=215, expected_lift_count=29
        )
        report = review_report.build_report(
            cli._serialize_draft(manifest), payload
        )
        topology = report["multi_way_topology_counts"]
        self.assertEqual(sum(topology.values()), 25)
        self.assertEqual(topology["disconnected"], 6)
        self.assertEqual(report["unresolved_conflict_count"], 5)
        self.assertFalse(report["apply_ready"])
        summary = review_report.summary_text(report)
        self.assertIn("Born Free: difficulty", summary)
        self.assertIn("Bwana: 2 components", summary)

    def test_empty_ingest_does_not_write_a_draft(self) -> None:
        args = SimpleNamespace(
            resort_id="vail",
            bbox=None,
            lat_lon=None,
            expected_canonical_trails=195,
            expected_canonical_lifts=32,
            canonical_counts_reviewed=False,
            headline_trails=None,
            headline_lifts=None,
            evidence_url=[],
            evidence_observed_at=None,
        )
        empty_sources = {
            "official": lambda *_args: SourceResult(
                source="official", resort_id="vail"
            ),
            "other": lambda *_args: SourceResult(source="other", resort_id="vail"),
        }
        with tempfile.TemporaryDirectory() as directory:
            with patch.object(cli, "SOURCES", empty_sources), patch.object(
                cli, "DRAFTS_DIR", Path(directory)
            ):
                self.assertEqual(cli._cmd_ingest(args), 6)
                self.assertFalse((Path(directory) / "vail.json").exists())

    def test_review_gate_requires_both_explicit_canonical_counts(self) -> None:
        args = SimpleNamespace(
            resort_id="vail",
            expected_canonical_trails=None,
            expected_canonical_lifts=None,
            canonical_counts_reviewed=True,
        )
        with patch.object(cli, "SOURCES", {}):
            self.assertEqual(cli._cmd_ingest(args), 8)

    def test_geometry_command_routes_to_authoring_tool(self) -> None:
        with patch("canonical_ingest.geometry_tool.main", return_value=9) as main:
            result = cli._cmd_geometry(SimpleNamespace(resort_id="vail"))
        self.assertEqual(result, 9)
        main.assert_called_once_with("vail")


if __name__ == "__main__":
    unittest.main()
