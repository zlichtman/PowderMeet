"""The search aliases in resorts.yaml are the ones migration 0020 seeds, so a
resort that has never been published searches the same as one that has."""

import re

from powdermeet_pipeline import catalog

MIGRATION = catalog.ROOT.parent / "backend" / "supabase" / "migrations" / "0020_resort_aliases_presence_clear.sql"


def test_yaml_aliases_match_the_migration_seed():
    seeded = {
        resort_id: re.findall(r"'((?:[^']|'')*)'", values)
        for resort_id, values in re.findall(r"\('([a-z0-9-]+)', array\[([^\]]*)\]\)", MIGRATION.read_text())
    }
    in_yaml = {}
    for resort_id in catalog.resort_ids():
        aliases = catalog.resort(resort_id).get("aliases")
        if aliases:
            assert all(isinstance(a, str) and a.strip() for a in aliases), resort_id
            in_yaml[resort_id] = aliases
    assert len(in_yaml) == 24
    assert in_yaml == seeded
