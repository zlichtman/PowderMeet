import json

import pytest

from powdermeet_pipeline import __version__, extract
from powdermeet_pipeline.cli import main


def test_version_flag(capsys):
    with pytest.raises(SystemExit) as exit_info:
        main(["--version"])
    assert exit_info.value.code == 0
    assert __version__ in capsys.readouterr().out


def test_an_extract_with_refreshed_official_lists_is_the_newest(tmp_path, monkeypatch):
    # A refresh keeps the OSM time, so the file names differ only in their hash
    # and the refreshed one can sort first by name.
    monkeypatch.setenv("PM_PIPELINE_WORKDIR", str(tmp_path))
    directory = tmp_path / "extract" / "okemo"
    directory.mkdir(parents=True)
    osm = {"fetched_at": "2026-11-20T10:49:00Z"}
    (directory / "osm-2026-11-20T1049Z-okemo-111111.json").write_text(json.dumps(
        {"osm": osm, "official": {"fetched_at": "2026-11-21T08:00:00Z", "checked_at": "2026-11-21T08:00:00Z"}}))
    (directory / "osm-2026-11-20T1049Z-okemo-999999.json").write_text(json.dumps(
        {"osm": osm, "official": {"fetched_at": None, "checked_at": "2026-11-20T10:49:00Z"}}))
    assert extract.newest("okemo")[-1].name == "osm-2026-11-20T1049Z-okemo-111111.json"
