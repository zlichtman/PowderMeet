"""Reference reconcile cases, plus the auto-accept rule from specs/05-PIPELINE.md."""

import http.client
from urllib.error import HTTPError

import pytest

from powdermeet_pipeline import build, topology
from powdermeet_pipeline.reconcile import aliases as alias_matching
from powdermeet_pipeline.reconcile import decisions, identities, items
from powdermeet_pipeline.reconcile.common import merge_duplicate_items, normalize_grooming
from powdermeet_pipeline.reconcile.models import SourceItem, SourceResult
from powdermeet_pipeline.sources import official_epic, overpass
from synthetic import RESORT, Mountain

BBOX = [-107.0, 39.0, -105.0, 41.0]


def network(elements):
    return topology.network({"bbox": BBOX, "osm": {"elements": elements}})


def nodes(*ids):
    return [{"type": "node", "id": i, "lat": 40 + i / 1000, "lon": -106} for i in ids]


def test_private_lift_is_not_a_public_candidate():
    way = {"type": "way", "id": 10, "nodes": [1, 2],
           "tags": {"aerialway": "gondola", "name": "Private Lift", "access": "private"}}
    assert items.osm_items(network(nodes(1, 2) + [way])) == []
    way["tags"]["ski"] = "yes"
    assert len(items.osm_items(network(nodes(1, 2) + [way]))) == 1


def test_lifts_that_carry_no_skiers_are_left_out():
    ways = [
        {"type": "way", "id": 10, "nodes": [1, 2], "tags": {"aerialway": "cable_car", "name": "Riddes - Isérables"}},
        {"type": "way", "id": 11, "nodes": [1, 2], "tags": {"aerialway": "magic_carpet", "name": "Tubing Carpet"}},
        {"type": "way", "id": 12, "nodes": [1, 2], "tags": {"aerialway": "chair_lift", "name": "Chair One"}},
        {"type": "way", "id": 13, "nodes": [1, 2], "tags": {"aerialway": "chair_lift", "name": "Next Year's Chair"}},
    ]
    cite = lambda way_id, areas: {"sources": [{"type": "openstreetmap", "id": f"way/{way_id}"}], "ski_areas": areas}
    net = topology.network({
        "bbox": BBOX, "osm": {"elements": nodes(1, 2) + ways}, "ski_areas": ["Ours"],
        "openskimap": {"lifts": [cite(10, []), cite(11, ["Ours"]), cite(12, ["Ours"]),
                                 {**cite(13, ["Ours"]), "status": "planned"}], "runs": []},
    })
    assert sorted(net.ways) == [12]
    assert {s["way_id"]: s["reason"] for s in net.skipped} == {
        10: "no_ski_area", 11: "not_a_ski_lift", 13: "not_operating"}


def test_piste_area_does_not_claim_a_centerline_identity():
    ways = [
        {"type": "way", "id": 10, "nodes": [1, 2, 3, 1],
         "tags": {"piste:type": "downhill", "name": "Alpine", "area": "yes"}},
        {"type": "way", "id": 20, "nodes": [1, 2, 3],
         "tags": {"piste:type": "downhill", "name": "Alpine", "area": "no"}},
    ]
    found = items.osm_items(network(nodes(1, 2, 3) + ways))
    assert len(found) == 1
    assert found[0].osm_way_ids == ("20",)


def test_overpass_query_quotes_colon_tag_keys():
    query = overpass.build_query([2, 1, 4, 3])
    assert 'way["piste:type"](1,2,3,4)' in query
    assert 'way["aerialway"](1,2,3,4)' in query


def test_osm_excludes_station_and_non_transport_ways():
    ways = [
        {"type": "way", "id": 10, "nodes": [1, 2], "tags": {"aerialway": "station", "name": "Base Station"}},
        {"type": "way", "id": 11, "nodes": [1, 2], "tags": {"aerialway": "zip_line", "name": "Adventure Zip"}},
        {"type": "way", "id": 12, "nodes": [1, 2], "tags": {"aerialway": "chair_lift", "name": "Chair One"}},
    ]
    found = items.osm_items(network(nodes(1, 2) + ways))
    assert [item.name for item in found] == ["Chair One"]
    assert found[0].extra["lift_type"] == "chair"


def test_openskimap_excludes_non_transport_aerialways():
    net = network(nodes(1, 2) + [
        {"type": "way", "id": 12, "nodes": [1, 2], "tags": {"aerialway": "chair_lift", "name": "Chair One"}},
    ])
    source = [{"type": "openstreetmap", "id": "way/12"}]
    found = items.openskimap_items({"lifts": [
        {"name": "Base", "liftType": "station", "sources": source},
        {"name": "Chair One", "liftType": "chair_lift", "sources": source},
    ]}, net)
    assert [item.name for item in found] == ["Chair One"]


def test_duplicate_segments_retain_every_way_and_flag_attribute_conflicts():
    merged = merge_duplicate_items([
        SourceItem(kind="trail", name="Born Free", osm_way_ids=("20",), extra={"difficulty": "blue"}),
        SourceItem(kind="trail", name="born free", osm_way_ids=("10",), extra={"difficulty": "green"}),
    ])
    assert len(merged) == 1
    assert merged[0].osm_way_ids == ("10", "20")
    assert merged[0].extra["source_segment_count"] == 2
    assert merged[0].extra["attribute_conflicts"] == ("difficulty",)
    assert merged[0].extra["attribute_observations"]["difficulty"] == ('"blue"', '"green"')


def test_missing_grooming_remains_unknown():
    assert normalize_grooming(None) is None
    assert normalize_grooming("unsupported-tag") is None
    assert normalize_grooming("classic") is True
    assert normalize_grooming("backcountry") is False


def test_a_run_tagged_mogul_carries_the_moguls_flag_and_an_ordinary_run_does_not():
    mountain = Mountain()
    mountain.ways[202][1]["piste:grooming"] = "mogul"
    mountain.ways[203][1]["piste:grooming"] = "backcountry"
    edges = mountain.bundle().document["edges"]
    beta = [e for e in edges if e["id"].startswith("w202:")]
    others = [e for e in edges if not e["id"].startswith("w202:")]
    assert beta and all(e["moguls"] is True and e["groomed_default"] is False for e in beta)
    assert not any("moguls" in e for e in others)


def test_reconcile_rejects_all_empty_sources():
    with pytest.raises(identities.SourceDataUnavailableError):
        identities.reconcile([SourceResult(source="osm", resort_id="vail")])


def test_reconcile_merges_ids_and_attributes_without_hiding_conflicts():
    results = [
        SourceResult(source="official", resort_id="vail", role="inventory", items=(SourceItem(
            kind="trail", name="Born Free", extra={"difficulty": "blue", "is_groomed": True},
        ),)),
        SourceResult(source="osm", resort_id="vail", items=(SourceItem(
            kind="trail", name="Born Free", osm_way_ids=("10", "20"),
            extra={"difficulty": "black", "is_groomed": True, "source_segment_count": 2},
        ),)),
    ]
    (row,) = identities.reconcile(results)
    assert row.difficulty == "blue"
    assert row.is_groomed is True
    assert row.osm_way_ids == ("10", "20")
    assert row.sources_seen == ("official", "osm")
    assert row.confidence == 1.0
    assert row.source_segment_counts == {"official": 1, "osm": 2}
    assert row.unresolved_conflicts == ("difficulty",)
    assert row.source_attribute_observations["official"]["difficulty"] == ('"blue"',)
    assert row.source_attribute_observations["osm"]["difficulty"] == ('"black"',)


def test_approximate_names_are_never_auto_merged():
    results = [
        SourceResult(source="official", resort_id="vail", role="inventory",
                     items=(SourceItem(kind="trail", name="Wild Card"),)),
        SourceResult(source="osm", resort_id="vail",
                     items=(SourceItem(kind="trail", name="Wildcard", osm_way_ids=("10",)),)),
    ]
    rows = identities.reconcile(results)
    assert [row.name for row in rows] == ["Wild Card", "Wildcard"]
    assert identities.compact_name("Wild Card") == identities.compact_name("Wildcard")


def test_decision_merges_exact_members_only():
    results = [
        SourceResult(source="official", resort_id="vail", role="inventory",
                     items=(SourceItem(kind="trail", name="Avanti"),)),
        SourceResult(source="osm", resort_id="vail", items=(
            SourceItem(kind="trail", name="Avanti - Lower", osm_way_ids=("10",), extra={"difficulty": "blue"}),
            SourceItem(kind="trail", name="Avanti - Upper", osm_way_ids=("20",), extra={"difficulty": "blue"}),
        )),
    ]
    merges = decisions.normalize("vail", {"merges": [{
        "id": "trail:avanti", "kind": "trail", "canonical_name": "Avanti",
        "members": [
            {"source": "official", "name": "Avanti"},
            {"source": "osm", "name": "Avanti - Lower"},
            {"source": "osm", "name": "Avanti - Upper"},
        ],
    }]})["merges"]
    (row,) = identities.reconcile(decisions.apply_merges(merges, results))
    assert row.name == "Avanti"
    assert row.osm_way_ids == ("10", "20")
    assert row.source_name_variants == ("Avanti", "Avanti - Lower", "Avanti - Upper")
    assert row.unresolved_conflicts == ()
    assert row.identity_decision_ids == ("trail:avanti",)
    assert row.difficulty == "blue"
    assert row.source_segment_counts == {"official": 1, "osm": 2}

    stale = [results[0], SourceResult(source="osm", resort_id="vail", items=results[1].items[:1])]
    with pytest.raises(decisions.DecisionError, match="expected exactly one"):
        decisions.apply_merges(merges, stale)


def test_decision_rejects_overlapping_members():
    raw = {"merges": [
        {"id": "first", "kind": "trail", "canonical_name": "A",
         "members": [{"source": "osm", "name": "A"}, {"source": "osm", "name": "B"}]},
        {"id": "second", "kind": "trail", "canonical_name": "B",
         "members": [{"source": "osm", "name": "B"}, {"source": "osm", "name": "C"}]},
    ]}
    with pytest.raises(decisions.DecisionError, match="claimed by multiple"):
        decisions.normalize("vail", raw)


def test_auto_accept_needs_two_sources_and_one_way_cluster():
    mountain = Mountain()
    mountain.official = None
    # Only OSM knows this run.
    mountain.node(6, -3, 4, 1200.0).way(
        204, [5, 6, 1], {"piste:type": "downhill", "name": "Solo"}, openskimap=False)
    # Two pieces with the same name that do not touch.
    mountain.node(7, 5, 9, 1450.0).node(8, 6, 8, 1380.0)
    mountain.way(205, [4, 7], {"piste:type": "downhill", "name": "Beta"})
    mountain.ways[205] = ([7, 8], mountain.ways[205][1])
    manifest = mountain.manifest()

    trails = {t["group_id"]: t for t in manifest["trails"]}
    assert trails["trail:alpha"]["accepted"] is True
    assert trails["trail:alpha"]["way_ids"] == [200, 201]
    assert trails["trail:alpha"]["clusters"] == 1
    assert trails["trail:solo"]["accepted"] is False
    assert trails["trail:beta"]["accepted"] is False
    assert trails["trail:beta"]["clusters"] == 2
    blocking = {(f["code"], f["group_id"]) for f in manifest["review"]["flagged"] if f["blocking"]}
    assert blocking == {("single_source", "trail:solo"), ("multi_cluster", "trail:beta")}
    assert manifest["review"]["auto_accepted"] == 3  # Alpha, Gamma and the lift
    assert manifest["status_aliases"] == {"epic": {}}

    mountain.decisions = {"accept": ["trail:solo"], "reject": ["trail:beta"]}
    decided = mountain.manifest()
    assert {t["group_id"] for t in decided["trails"]} == {"trail:alpha", "trail:gamma", "trail:solo"}
    assert decided["exclude_ways"] == [202, 205]
    assert not [f for f in decided["review"]["flagged"] if f["blocking"]]


def test_official_names_become_status_aliases():
    manifest = Mountain().manifest()
    assert manifest["status_aliases"]["epic"]["Summit Express"] == "lift:summit-express"
    assert all(t["official"] for t in manifest["trails"])


def test_official_name_differing_only_in_punctuation_is_matched_one_to_one():
    mountain = Mountain()
    mountain.ways[200][1]["name"] = mountain.ways[201][1]["name"] = "Alpha - Lower"
    mountain.official["trails"] = [{"name": "Alpha Lower"}, {"name": "Beta"}, {"name": "Gamma Glades"}]
    manifest = mountain.manifest()
    trails = {t["group_id"]: t for t in manifest["trails"]}
    assert trails["trail:alpha-lower"]["name"] == "Alpha - Lower"
    assert trails["trail:alpha-lower"]["official"] is True
    assert manifest["status_aliases"]["epic"]["Alpha Lower"] == "trail:alpha-lower"
    assert trails["trail:gamma"]["official"] is False  # "Gamma Glades" is a different name


def test_official_lift_names_match_mapped_lifts_only_when_unambiguous():
    groups = {
        "lift:heavenly-gondola": ["Heavenly Gondola"],
        "lift:apollo-27": ["Apollo #27"],
        "lift:powderhorn-2": ["Powderhorn 2"],
        "lift:chateau-carpet": ["Chateau Carpet"],
        "lift:creekside-carpet": ["Creekside Carpet"],
        "lift:creekside-gondola": ["Creekside Gondola"],
        "lift:treeline-cirque-lower": ["Treeline Cirque Lower"],
        "lift:treeline-cirque-upper": ["Treeline Cirque Upper"],
        "lift:chair-10": ["Chair 10"],
        "lift:stella": ["Stella"],
    }
    official = [
        "Gondola", "Apollo", "Powderhorn II", "Chateau Carpet - Blackcomb",
        "Creekside", "Treeline Cirque", "Chair 1", "Stella Express", "Stella Chair",
    ]
    matched = {name: group for name, group, _ in alias_matching.match_lifts(official, groups, {}, "Heavenly")}
    assert matched == {
        "Gondola": "lift:heavenly-gondola",      # the resort's own name dropped
        "Apollo": "lift:apollo-27",              # a lift number the map adds
        "Powderhorn II": "lift:powderhorn-2",    # roman numeral
        "Chateau Carpet - Blackcomb": "lift:chateau-carpet",  # Epic's mountain qualifier
    }
    # "Creekside" could be the carpet or the gondola, "Treeline Cirque" is two
    # lifts, "Chair 1" is not "Chair 10", and two feed names claim Stella.


def test_vendor_spellings_of_lift_names_match():
    def matched(official, groups, resort):
        return {name: group for name, group, _ in alias_matching.match_lifts(official, groups, {}, resort)}

    assert matched(
        ["Broadway Express 1", "High 5 Express", "Double Barrel 1", "Double Barrel 2"],
        {"lift:broadway": ["Broadway Express"], "lift:high-five": ["High Five Express"],
         "lift:double-barrel": ["Double Barrel"]}, "Mammoth Mountain",
    ) == {"Broadway Express 1": "lift:broadway", "High 5 Express": "lift:high-five"}
    assert matched(
        ["Lower BC Mtn Express", "High Lift T-Bar"],
        {"lift:lower": ["Lower Beaver Creek Mountain Express Lift"], "lift:high": ["The High Lift"]},
        "Beaver Creek",
    ) == {"Lower BC Mtn Express": "lift:lower", "High Lift T-Bar": "lift:high"}
    # Only lift-type words are left without the resort's name: the whole name decides.
    assert matched(["Wildcat Express"], {"lift:wildcat-express": ["Wildcat Express Quad"]}, "Wildcat") \
        == {"Wildcat Express": "lift:wildcat-express"}


def test_a_lift_keeps_a_name_it_shares_with_a_trail():
    mountain = Mountain()
    mountain.ways[100][1]["name"] = "Alpha"
    mountain.official["lifts"] = [{"name": "Alpha"}]
    aliases = mountain.manifest()["status_aliases"]["epic"]
    assert aliases["Alpha"] == "lift:alpha"


def test_epic_page_is_tried_under_its_other_spelling_after_a_404():
    tried = []

    class Page:
        def __enter__(self):
            return self

        def __exit__(self, *_):
            return False

        def read(self):
            return b'<script>FR.TerrainStatusFeed = {"GroomingAreas": [{"Lifts": [{"Name": "Chair"}]}]};</script>'

    def opener(request, timeout):
        tried.append(request.full_url)
        if request.full_url.endswith("terrain-and-lift-status.aspx"):
            raise HTTPError(request.full_url, 404, "Not Found", {}, None)
        return Page()

    lists = official_epic.fetch("https://www.okemo.com/x/terrain-and-lift-status.aspx", opener=opener)
    assert tried == ["https://www.okemo.com/x/terrain-and-lift-status.aspx",
                     "https://www.okemo.com/x/lift-and-terrain-status.aspx"]
    # Before opening day the page lists lifts and no trails; the lifts are kept.
    assert lists == {"trails": [], "lifts": [{"name": "Chair"}]}


def test_overpass_retries_a_dropped_connection_and_a_502():
    calls, waits = [], []

    class Answer:
        def __enter__(self):
            return self

        def __exit__(self, *_):
            return False

        def read(self):
            return b'{"elements": []}'

    def opener(request, timeout):
        calls.append(request.full_url)
        if len(calls) == 1:
            raise http.client.RemoteDisconnected("Remote end closed connection without response")
        if len(calls) == 2:
            raise HTTPError(request.full_url, 502, "Bad Gateway", {}, None)
        return Answer()

    assert overpass._post("[out:json];", waits=(1, 2, 3), sleep=waits.append, opener=opener) == {"elements": []}
    assert waits == [1, 2] and len(calls) == 3


def test_each_section_of_a_trail_takes_the_harder_of_its_map_tag_and_the_feed():
    def alpha(mountain):
        document = mountain.bundle().document
        trail = next(t for t in mountain.manifest()["trails"] if t["group_id"] == "trail:alpha")
        group = next(g for g in document["groups"] if g["id"] == "trail:alpha")
        edges = {e["id"].split(":")[0]: e["difficulty"] for e in document["edges"] if e.get("group") == "trail:alpha"}
        return trail["difficulty"], trail["difficulty_source"], group["difficulty"], edges

    mountain = Mountain()
    mountain.ways[201][1]["piste:difficulty"] = "advanced"  # Alpha: way 200 green, way 201 black
    mountain.official["trails"][0]["difficulty"] = "blue"
    # The black section stays black, the green one takes the feed's blue, and the
    # trail shows black: what a skier must ski to take all of it.
    assert alpha(mountain) == ("black", "map_harder_than_official", "black", {"w200": "blue", "w201": "black"})
    flag = next(f for f in mountain.manifest()["review"]["flagged"] if f["group_id"] == "trail:alpha")
    assert (flag["code"], flag["blocking"]) == ("difficulty_differs_from_official", False)

    mountain.official["trails"][0]["difficulty"] = "double_black"
    assert alpha(mountain) == ("double_black", "official", "double_black",
                               {"w200": "double_black", "w201": "double_black"})
    # A manifest reconciled before the feed's value was stored still builds to it.
    manifest = mountain.manifest()
    for trail in manifest["trails"]:
        trail.pop("official_difficulty", None)
    document = build.build(RESORT, mountain.extract(), manifest).document
    assert {e["difficulty"] for e in document["edges"] if e.get("group") == "trail:alpha"} == {"double_black"}

    mountain.official["trails"][0]["difficulty"] = "blue"
    mountain.decisions = {"difficulty": {"trail:alpha": "blue"}}
    assert alpha(mountain) == ("blue", "decision", "blue", {"w200": "blue", "w201": "blue"})


def test_a_misspelt_decisions_key_fails_instead_of_being_ignored():
    with pytest.raises(decisions.DecisionError, match="unknown keys: exclude_way"):
        decisions.normalize("vail", {"exclude_way": [1]})
    with pytest.raises(decisions.DecisionError, match="rendezvous has unknown keys: rejects"):
        decisions.normalize("vail", {"rendezvous": {"rejects": ["summit"]}})


def test_overpass_retries_an_answer_cut_short_by_a_runtime_error():
    answers = [
        b'{"remark": "runtime error: Query timed out in \\"query\\"", "elements": [{"type": "node", "id": 1}]}',
        b'{"elements": []}',
    ]

    class Answer:
        def __init__(self, body):
            self.body = body

        def __enter__(self):
            return self

        def __exit__(self, *_):
            return False

        def read(self):
            return self.body

    waits = []
    data = overpass._post("[out:json];", waits=(1, 2), sleep=waits.append,
                          opener=lambda request, timeout: Answer(answers.pop(0)))
    assert data == {"elements": []} and waits == [1]


def test_one_official_name_with_two_difficulties_stamps_neither_on_the_map():
    page = ('FR.TerrainStatusFeed = {"GroomingAreas": [{"Trails": ['
            '{"Name": "Alpha", "TrailType": 1, "Difficulty": "Green"}, '
            '{"Name": "Alpha", "TrailType": 1, "Difficulty": "Black"}], "Lifts": []}]};')
    official = official_epic.parse(page)["trails"]
    assert official == [{"name": "Alpha", "difficulty": "black"}, {"name": "Alpha", "difficulty": "green"}]
    mountain = Mountain()
    mountain.official["trails"] = official + mountain.official["trails"][1:]
    trail = next(t for t in mountain.manifest()["trails"] if t["group_id"] == "trail:alpha")
    assert (trail["difficulty"], "official_difficulty" in trail) == ("black", False)
    flag = next(f for f in mountain.manifest()["review"]["flagged"] if f["group_id"] == "trail:alpha")
    assert flag["code"] == "difficulty_conflict"
    edges = {e["difficulty"] for e in mountain.bundle().document["edges"] if e.get("group") == "trail:alpha"}
    assert edges == {"green"}


def test_decisions_that_no_longer_match_fail():
    with pytest.raises(decisions.DecisionError, match="quoted time"):
        decisions.normalize("vail", {"operating_hours": {"default": [{"days": [1], "open": "08:30", "close": 930}]}})
    with pytest.raises(decisions.DecisionError, match="between 0 and 1"):
        decisions.normalize("vail", {"rendezvous": {"confidence": {"summit": 9}}})
    for stale, match in (
        ({"rendezvous": {"reject": ["nowhere"]}}, "not proposed: nowhere"),
        ({"operating_hours": {"lift:gone": [{"days": [1], "open": "09:00", "close": "15:00"}]}}, "lift:gone"),
        ({"exclude_ways": [999]}, "not in the extract: 999"),
        ({"status_aliases": {"mtnpowder": {"Summit": "lift:summit-express"}}}, "mtnpowder"),
        ({"areas": ["n4"]}, "areas names nodes"),
    ):
        mountain = Mountain()
        mountain.decisions = stale
        with pytest.raises(decisions.DecisionError, match=match):
            mountain.manifest()


def test_meeting_points_number_repeats_without_taking_a_real_name():
    mountain = Mountain()
    mountain.points[3] = (2, 5, {"name": "Hut"})                      # a named junction
    mountain.points[901] = (0.1, 0.1, {"amenity": "restaurant", "name": "Hut"})
    mountain.points[902] = (0.2, 9.9, {"amenity": "restaurant", "name": "Hut 2"})
    mountain.points[903] = (2.1, 5.1, {"tourism": "wilderness_hut", "name": "Shelter"})
    mountain.points[904] = (0.1, -0.1, {"amenity": "cafe", "name": "Staff Canteen", "access": "private"})
    proposed = {r["id"]: r for r in mountain.manifest()["rendezvous"]}
    assert (proposed["hut"]["node_id"], proposed["hut-2"]["node_id"], proposed["hut-3"]["node_id"]) == ("n3", "n2", "n1")
    assert (proposed["shelter"]["kind"], proposed["shelter"]["amenities"]) == ("landmark", ["indoor"])
    assert "staff-canteen" not in proposed


def test_a_newly_mapped_namesake_does_not_take_an_existing_meeting_point_id():
    mountain = Mountain()
    mountain.points[950] = (0.1, 10.1, {"natural": "peak", "name": "Lookout"})
    before = {r["id"]: r["node_id"] for r in mountain.manifest()["rendezvous"]}
    mountain.points[960] = (0.1, 0.2, {"natural": "peak", "name": "Lookout"})
    after = {r["id"]: r["node_id"] for r in mountain.manifest()["rendezvous"]}
    assert before["lookout"] == "n2"
    assert (after["lookout"], after["lookout-2"]) == ("n2", "n1")


def test_a_closed_place_is_not_a_meeting_point():
    mountain = Mountain()
    mountain.points[901] = (0.1, 0.1, {"amenity": "restaurant", "name": "Harmony Snack Hut (closed)"})
    mountain.points[902] = (0.2, 9.9, {"amenity": "restaurant", "name": "Harmony Hut"})
    mountain.points[903] = (2.1, 5.1, {"amenity": "cafe", "name": "Old Cafe", "disused": "yes"})
    proposed = {r["id"] for r in mountain.manifest()["rendezvous"]}
    assert "harmony-hut" in proposed
    assert not {"harmony-snack-hut-closed", "old-cafe"} & proposed


def test_a_name_with_no_latin_letters_gets_its_own_stable_id():
    assert identities.slugify("Franz's Run") == "franzs-run"
    assert identities.slugify("Pähtli") == "pahtli"
    lodge, other = identities.slugify("山頂レストラン"), identities.slugify("ゴンドラ")
    assert lodge.startswith("u-") and lodge != other and lodge == identities.slugify(" 山頂レストラン ")
