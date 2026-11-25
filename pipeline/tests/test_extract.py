"""Which OpenSkiMap ski areas a catalog entry stands for, and the DEM tile cache."""

import pytest

from powdermeet_pipeline import dem, extract

BOX = [137.80, 36.65, 137.87, 36.74]


def _ski_map(counts: dict[str, int]) -> dict:
    lifts = [
        {"extent": [137.83, 36.70, 137.84, 36.71], "ski_areas": [area], "status": "operating"}
        for area, count in counts.items() for _ in range(count)
    ]
    return {"runs": [], "lifts": lifts}


def test_a_word_every_area_shares_does_not_pick_the_neighbours():
    ski_map = _ski_map({
        "白馬八方尾根, Hakuba Happo One": 66, "白馬白馬岩岳, Hakuba Iwatake, 白馬岩岳": 42,
        "白馬47, Hakuba 47": 19, "白馬五竜, Hakuba Goryu": 26,
    })
    def choose(name):
        return extract.choose_ski_areas({"name": name, "bbox": BOX}, ski_map)
    assert choose("Hakuba Happo-One") == ["白馬八方尾根, Hakuba Happo One"]
    assert choose("Hakuba Iwatake") == ["白馬白馬岩岳, Hakuba Iwatake, 白馬岩岳"]
    # "Hakuba47" is the words hakuba and 47.
    assert choose("Hakuba47 Winter Sports Park") == ["白馬47, Hakuba 47"]
    # A catalog entry can name linked areas itself.
    assert extract.choose_ski_areas(
        {"name": "Hakuba Goryu", "bbox": BOX, "ski_areas": ["白馬五竜, Hakuba Goryu", "白馬47, Hakuba 47"]}, ski_map,
    ) == ["白馬47, Hakuba 47", "白馬五竜, Hakuba Goryu"]


def test_two_named_areas_are_both_kept():
    ski_map = _ski_map({"Boston Mills": 20, "Brandywine": 20, "Other Hill": 30})
    assert extract.choose_ski_areas(
        {"name": "Boston Mills & Brandywine", "bbox": BOX}, ski_map) == ["Boston Mills", "Brandywine"]


def test_openskimap_read_for_the_catalog_box_does_not_cover_a_wider_map_box():
    # Megève: the map box reached Les Contamines, the OpenSkiMap read did not, and
    # its gondolas were built as Megève's.
    old = {"catalog_bbox": [6.55, 45.80, 6.68, 45.90], "bbox": [6.55, 45.78, 6.75, 45.90], "openskimap": {}}
    assert not extract.openskimap_covers(old)
    assert extract.openskimap_covers({**old, "openskimap": {"bbox": old["bbox"]}})
    # The read takes in a margin, so a map box a little past the catalog box is covered.
    assert extract.openskimap_covers({**old, "bbox": [6.52, 45.78, 6.70, 45.92]})


def test_a_truncated_dem_tile_is_not_cached(tmp_path):
    model = dem.TerrariumDEM(tmp_path, fetch=lambda url: b"\x89PNG\r\n\x1a\n truncated")
    with pytest.raises(OSError):
        model.sample(-120.0, 50.0)
    assert [p for p in tmp_path.rglob("*") if p.is_file()] == []
