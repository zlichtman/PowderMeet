"""Each publication threshold in specs/05-PIPELINE.md, tripped on a small
synthetic mountain."""

from powdermeet_pipeline import validate
from synthetic import Mountain

RUN = {"piste:type": "downhill"}


def outcome(mountain: Mountain):
    document = mountain.bundle().document
    evaluation = validate.evaluate(document)
    rows = {row["metric"]: row for row in evaluation["rows"]}
    codes = [flag["code"] for flag in document["integrity"]["flags"]]
    assert validate.check_constraints(document) == []
    assert all(e["vertical_m"] <= 0 for e in document["edges"] if e["kind"] == "run")
    return document, evaluation, rows, codes


def test_clean_mountain_publishes_live():
    document, evaluation, rows, codes = outcome(Mountain())
    assert all(row["passed"] for row in rows.values())
    assert evaluation["publishable"] is True
    assert document["status_mode"] == "live"
    assert codes == []


def test_lift_top_with_no_way_down_blocks_publishing():
    mountain = Mountain().node(7, 4, 3, 1300.0)
    mountain.way(101, [1, 7], {"aerialway": "chair_lift", "name": "Far Chair"})
    document, evaluation, rows, codes = outcome(mountain)
    assert rows["lift_tops_reaching_base"]["value"] == 0.5
    assert rows["lift_tops_reaching_base"]["passed"] is False
    assert rows["lift_exit_dead_end"]["value"] == 1
    assert evaluation["publishable"] is False
    assert document["status_mode"] == "scheduled_only"


OFF = {"snap_tolerance_m": 0, "link_tolerance_m": 0}


def test_cut_off_lift_is_joined_within_the_link_tolerance_and_listed():
    # The far chair unloads 10 m from the mid-mountain junction, with no shared node.
    mountain = Mountain().node(7, 2, 5.09, 1251.0)
    mountain.way(101, [1, 7], {"aerialway": "chair_lift", "name": "Far Chair"})
    mountain.official["lifts"].append({"name": "Far Chair"})
    mountain.decisions = dict(OFF)
    _, _, rows, codes = outcome(mountain)
    assert rows["lift_exit_dead_end"]["value"] == 1  # closeness alone never joins ways

    mountain.decisions = {}  # the defaults: unattended
    document, evaluation, rows, codes = outcome(mountain)
    assert rows["lift_exit_dead_end"]["value"] == 0
    assert codes.count("auto_link") == 1
    assert evaluation["publishable"] is True
    walk = next(e for e in document["edges"] if e["id"] == "w101:1")
    assert (walk["kind"], walk["from"], walk["to"]) == ("connection", "n7", "n3")
    assert "group" not in walk and walk["length_m"] == 10.0


def test_gap_beyond_the_tolerance_is_only_proposed_until_a_link_names_it():
    # 40 m from the junction.
    mountain = Mountain().node(7, 2, 5.36, 1255.0)
    mountain.way(101, [1, 7], {"aerialway": "chair_lift", "name": "Far Chair"})
    mountain.official["lifts"].append({"name": "Far Chair"})
    mountain.decisions = {"link_tolerance_m": 15}
    document, evaluation, rows, codes = outcome(mountain)
    assert rows["lift_exit_dead_end"]["value"] == 1 and "auto_link" not in codes
    assert rows["lift_tops_reaching_base"]["value"] == 0.5
    proposal = next(f for f in document["integrity"]["flags"] if f["code"] == "link_proposed")
    assert "{from: n7, to: n3}" in proposal["note"]

    mountain.decisions = {"link_tolerance_m": 15, "links": [{"from": "n7", "to": "n3"}]}
    document, evaluation, rows, codes = outcome(mountain)
    assert rows["lift_exit_dead_end"]["value"] == 0
    assert codes == ["link"]
    assert evaluation["publishable"] is True and document["status_mode"] == "live"


def test_lift_nobody_can_ski_to_is_cut_off_and_its_meeting_point_dropped():
    # Nothing leads to the bottom of this chair, and nothing is near enough to join.
    mountain = Mountain().node(20, -4, 9, 1200.0)
    mountain.way(102, [20, 2], {"aerialway": "chair_lift", "name": "Side Chair"})
    document, evaluation, rows, codes = outcome(mountain)
    assert rows["lift_tops_reaching_base"]["value"] == 0.5
    assert "lift_cut_off" in codes and "rendezvous_dropped" in codes
    assert "side-chair-base" not in {r["id"] for r in document["rendezvous"]}
    assert rows["rendezvous_reachable_from_all_lift_tops"]["value"] == 1.0
    assert evaluation["publishable"] is False


def test_lift_skiers_can_ski_to_keeps_its_base_when_its_top_is_cut_off():
    # Delta runs from the junction to the bottom of a chair whose top has no run.
    mountain = Mountain().node(7, 4, 3, 1100.0).node(8, 6, 8, 1450.0)
    mountain.way(204, [3, 7], {**RUN, "name": "Delta"})
    mountain.way(102, [7, 8], {"aerialway": "chair_lift", "name": "Far Chair"})
    mountain.official["lifts"].append({"name": "Far Chair"})
    mountain.decisions = dict(OFF)
    document, evaluation, rows, codes = outcome(mountain)
    assert "lift_exit_dead_end" in codes
    kept = {r["id"]: r["node_id"] for r in document["rendezvous"]}
    assert kept.get("far-chair-base") == "n7" and "far-chair-top" not in kept
    assert validate.measure(document)["unreachable_rendezvous"] == []


def test_unnamed_lift_gets_meeting_points_named_for_a_run_beside_it():
    mountain = Mountain()
    mountain.way(104, [1, 4], {"aerialway": "chair_lift"})
    document, _, _, _ = outcome(mountain)
    stops = {r["id"]: (r["node_id"], r["name"]) for r in document["rendezvous"]}
    assert stops["unnamed-104-base"] == ("n1", "Chairlift base by Alpha")
    assert stops["unnamed-104-top"] == ("n4", "Chairlift top by Beta")


def test_lift_mapped_top_first_has_its_base_at_the_bottom():
    mountain = Mountain()
    mountain.way(105, [4, 1], {"aerialway": "chair_lift", "name": "Back Chair"})
    mountain.official["lifts"].append({"name": "Back Chair"})
    document, _, _, codes = outcome(mountain)
    assert "lift_reversed" in codes
    stops = {r["id"]: r["node_id"] for r in document["rendezvous"]}
    assert (stops["back-chair-base"], stops["back-chair-top"]) == ("n1", "n4")


def test_gondola_between_two_base_areas_joins_them():
    # A second hill to the east, reached only by a two-way gondola between the
    # bases. Neither gondola station shares a node with a run.
    mountain = Mountain().node(90, 10, 0, 1000.0).node(91, 10, 8, 1400.0).node(94, 9.8, 0.5, 1010.0)
    mountain.node(92, 0.3, 0.2, 1005.0).node(93, 9.7, 0.2, 1005.0)
    mountain.way(120, [90, 91], {"aerialway": "chair_lift", "name": "East Chair"})
    mountain.way(121, [91, 94, 90], {**RUN, "name": "East Run"})
    mountain.way(130, [92, 93], {"aerialway": "gondola", "name": "Base Gondola"})
    document, evaluation, rows, codes = outcome(mountain)
    # Riders get off the gondola at its west end too, so that end is tied back in.
    assert rows["lift_tops_reaching_base"]["value"] == 1.0
    assert any(f["note"].startswith("no way on from a station of Base Gondola: n92 joined to n1")
               for f in document["integrity"]["flags"])
    assert evaluation["publishable"] is True


def test_lift_nobody_can_reach_is_joined_through_the_run_that_feeds_it():
    # The side chair's bottom is 460 m from the network, but the run that feeds
    # it starts 57 m from Gamma.
    mountain = Mountain().node(6, -1.6, 4, 1190.0)
    mountain.ways[203] = ([2, 5, 6, 1], mountain.ways[203][1])
    mountain.node(80, -8, 2, 1100.0).node(81, -8, 8, 1350.0).node(84, -2.4, 4, 1180.0)
    mountain.way(140, [80, 81], {"aerialway": "chair_lift", "name": "Side Chair"})
    mountain.way(142, [81, 5], {**RUN, "name": "Side Return"})
    mountain.way(143, [84, 80], {**RUN, "name": "Side Feeder"})
    document, evaluation, rows, codes = outcome(mountain)
    assert rows["lift_tops_reaching_base"]["value"] == 1.0
    assert any(f["note"].startswith("no way in to Side Chair: n6 joined to n84")
               for f in document["integrity"]["flags"])


def test_runs_drawn_near_a_lift_station_are_tied_to_it():
    # "Side" starts 36 m from the summit station and nothing reaches it; "Low"
    # ends 44 m from the base station, past the 15 m snap, with nothing leaving.
    mountain = Mountain().node(95, 0.5, 10, 1495.0).node(97, 0.4, 0.3, 1005.0)
    mountain.way(150, [95, 3], {**RUN, "name": "Side"})
    mountain.way(151, [4, 97], {**RUN, "name": "Low"})
    document, _, rows, _ = outcome(mountain)
    notes = [f["note"] for f in document["integrity"]["flags"] if f["code"] == "auto_link"]
    assert any(n.startswith("nothing reaches the start of Side near Summit Express: n2 joined to n95") for n in notes)
    assert any(n.startswith("Low ends near Summit Express with nothing leaving: n97 joined to n1") for n in notes)
    core = validate.Graph(document).core()
    assert all(e["from"] in core and e["to"] in core for e in document["edges"])


def test_orphan_edges_block_publishing():
    mountain = Mountain().node(30, 8, 8, 1300.0).node(31, 9, 7, 1200.0)
    mountain.way(300, [30, 31], {**RUN, "name": "Lost"})
    _, evaluation, rows, codes = outcome(mountain)
    assert rows["orphan_edge_share"]["value"] > 0.03
    assert "orphan_edge" in codes
    assert evaluation["publishable"] is False


def test_unnamed_runs_are_kept_unknown_and_leave_status_mode_alone():
    mountain = Mountain().node(40, 1, 5, 1260.0)
    mountain.way(400, [2, 40, 1], RUN)
    document, evaluation, rows, codes = outcome(mountain)
    edge = next(e for e in document["edges"] if e["id"] == "w400:0")
    assert edge["difficulty"] == "unknown" and "name" not in edge
    assert edge["group"] == "trail:unnamed-400"
    assert rows["unnamed_run_share"]["value"] == 0.2
    assert rows["unnamed_run_share"]["passed"] is False
    assert "unnamed_run" in codes
    assert evaluation["publishable"] is True
    assert document["status_mode"] == "live"


def test_unnamed_runs_keep_their_mapped_difficulty_one_group_per_way():
    mountain = Mountain().node(40, 1, 5, 1260.0).node(41, -1, 4, 1200.0)
    mountain.way(400, [2, 40, 1], {**RUN, "piste:difficulty": "advanced"})
    mountain.way(401, [2, 41, 1], {**RUN, "piste:difficulty": "easy"})
    document, _, _, _ = outcome(mountain)
    edges = {e["id"]: e for e in document["edges"]}
    groups = {g["id"]: g for g in document["groups"]}
    for way_id, difficulty in ((400, "black"), (401, "green")):
        edge = edges[f"w{way_id}:0"]
        assert edge["difficulty"] == difficulty and "name" not in edge
        assert edge["group"] == f"trail:unnamed-{way_id}"
        group = groups[f"trail:unnamed-{way_id}"]
        assert (group["difficulty"], group["name"]) == (difficulty, "")
    notes = [f["note"] for f in document["integrity"]["flags"] if f["code"] == "unnamed_run"]
    assert notes and not any("unknown" in note for note in notes)


def test_run_piece_that_climbs_is_built_as_a_connection():
    mountain = Mountain().node(50, -4, 8, 1400.0).node(51, -4, 6, 1420.0)
    mountain.way(210, [2, 50, 51, 1], {**RUN, "name": "Delta"})
    mountain.way(211, [50, 5], {**RUN, "name": "Echo"})
    mountain.way(212, [51, 5], {**RUN, "name": "Foxtrot"})
    for name in ("Delta", "Echo", "Foxtrot"):
        mountain.official["trails"].append({"name": name})
    document, evaluation, rows, codes = outcome(mountain)
    climbing = next(e for e in document["edges"] if e["id"] == "w210:1")
    assert climbing["kind"] == "connection" and climbing["vertical_m"] == 20.0
    assert climbing["group"] == "trail:delta"
    assert rows["run_uphill"]["value"] == 1
    assert evaluation["publishable"] is True
    assert document["status_mode"] == "live"


def test_small_rise_is_elevation_noise_and_is_flattened():
    mountain = Mountain().node(50, -4, 8, 1400.0).node(51, -4, 6, 1403.0)
    mountain.way(210, [2, 50, 51, 1], {**RUN, "name": "Delta"})
    mountain.way(211, [50, 5], {**RUN, "name": "Echo"})
    mountain.way(212, [51, 5], {**RUN, "name": "Foxtrot"})
    for name in ("Delta", "Echo", "Foxtrot"):
        mountain.official["trails"].append({"name": name})
    document, _, rows, codes = outcome(mountain)
    flat = next(e for e in document["edges"] if e["id"] == "w210:1")
    assert flat["kind"] == "run" and flat["vertical_m"] == 0.0
    nodes = {n["id"]: n["ele_m"] for n in document["nodes"]}
    assert nodes["n50"] == nodes["n51"] == 1401.5
    assert rows["run_uphill"]["value"] == 0
    assert document["status_mode"] == "live"


def test_run_mapped_uphill_is_reversed_and_listed():
    mountain = Mountain().node(60, 4, 4, 1220.0)
    mountain.way(220, [1, 60, 3], {**RUN, "name": "Hotel"})
    mountain.official["trails"].append({"name": "Hotel"})
    document, _, _, codes = outcome(mountain)
    edge = next(e for e in document["edges"] if e["id"] == "w220:0")
    assert (edge["from"], edge["to"]) == ("n3", "n1")
    assert edge["geometry"][0][2] == 1250.0 and edge["geometry"][-1][2] == 1000.0
    assert codes == ["run_reversed"]


def test_live_needs_status_aliases_for_most_lifts():
    mountain = Mountain()
    mountain.official = None
    document, evaluation, rows, _ = outcome(mountain)
    assert rows["status_alias_coverage"]["value"] == 0.0
    assert evaluation["publishable"] is True
    assert document["status_mode"] == "scheduled_only"
    assert document["source"]["official"] == []


def test_two_way_lift_is_one_edge_numbered_bottom_to_top():
    # A gondola mapped from the summit down, with a mid-station.
    mountain = Mountain().node(70, 1, 5, 1260.0)
    mountain.points[70] = (1, 5, {"aerialway": "station"})
    del mountain.nodes[70]
    mountain.nodes[70] = (1, 5, 1260.0)
    # No oneway tag: a gondola carries people both ways unless the map says not.
    mountain.way(110, [2, 70, 1], {"aerialway": "gondola", "name": "Download"})
    mountain.way(230, [70, 3], {**RUN, "name": "Midway"})
    mountain.official["lifts"].append({"name": "Download"})
    mountain.official["trails"].append({"name": "Midway"})
    document, _, _, _ = outcome(mountain)
    lower, upper = (next(e for e in document["edges"] if e["id"] == i) for i in ("w110:0", "w110:1"))
    assert (lower["from"], lower["to"], upper["from"], upper["to"]) == ("n1", "n70", "n70", "n2")
    assert lower["one_way"] is False and lower["lift"]["queue_entry"] == "both"
    assert lower["vertical_m"] > 0 and upper["vertical_m"] > 0


def test_duplicate_node_at_a_dead_end_is_merged_not_joined_by_a_zero_length_edge():
    # Gamma is mapped to a second node at exactly the base's coordinates.
    mountain = Mountain().node(80, 0, 0, 1000.0)
    mountain.ways[203] = ([2, 5, 80], mountain.ways[203][1])
    document, evaluation, _, codes = outcome(mountain)
    gamma = next(e for e in document["edges"] if e["id"] == "w203:0")
    assert gamma["to"] == "n1"
    assert "n80" not in {n["id"] for n in document["nodes"]}
    assert all(e["length_m"] > 0 for e in document["edges"])
    assert codes == ["snap"]


def test_two_nodes_of_one_way_at_the_same_point_do_not_make_a_zero_length_edge():
    # Alpha's lower way starts with a duplicate of the junction node, and Beta ends on it.
    mountain = Mountain().node(81, 2, 5, 1250.0)
    mountain.ways[201] = ([3, 81, 1], mountain.ways[201][1])
    mountain.ways[202] = ([2, 4, 81], mountain.ways[202][1])
    document, evaluation, _, _ = outcome(mountain)
    assert all(e["length_m"] > 0 for e in document["edges"])
    assert "n81" not in {n["id"] for n in document["nodes"]}
    assert next(e for e in document["edges"] if e["id"] == "w202:0")["to"] == "n3"
    assert evaluation["publishable"] is True


def test_a_chair_mapped_running_downhill_is_turned_around():
    mountain = Mountain()
    mountain.ways[100] = ([2, 1], mountain.ways[100][1])
    document, evaluation, rows, codes = outcome(mountain)
    chair = next(e for e in document["edges"] if e["id"] == "w100:0")
    assert (chair["from"], chair["to"]) == ("n1", "n2")
    assert codes == ["lift_reversed"]
    assert rows["lift_tops_reaching_base"]["value"] == 1.0


def test_a_run_that_touches_nothing_is_tied_in_at_both_ends():
    from powdermeet_pipeline import build
    from synthetic import RESORT
    # Delta starts 26 m below a bend in Beta and ends 24 m above the junction, sharing no node.
    mountain = Mountain().node(10, 3.2, 7.8, 1395.0).node(11, 2.1, 5.2, 1255.0)
    mountain.way(204, [10, 11], {"piste:type": "downhill", "name": "Delta"})
    mountain.official["trails"].append({"name": "Delta"})
    off = validate.measure(mountain.bundle().document)
    assert off["orphan_edge_share"] > 0
    document = build.build(RESORT, mountain.extract(), {**mountain.manifest(), "orphan_join_m": 50}).document
    codes = [flag["code"] for flag in document["integrity"]["flags"]]
    assert codes.count("orphan_link") == 2
    assert document["integrity"]["orphan_edge_share"] == 0


def _with_line_joins(mountain: Mountain) -> dict:
    from powdermeet_pipeline import build
    from synthetic import RESORT
    document = build.build(RESORT, mountain.extract(), {**mountain.manifest(), "line_join_m": 40}).document
    assert validate.check_constraints(document) == []
    return document


def test_a_run_ending_short_of_another_runs_line_joins_it_there():
    # Delta ends 17 m beside the middle of Alpha's lower way, nearly 300 m from
    # either of its nodes (Pete's Peril above Werner's Schuss at Palisades Tahoe).
    mountain = Mountain().node(10, 1.25, 2.5, 1130.0)
    mountain.way(204, [2, 10], {**RUN, "name": "Delta"})
    mountain.official["trails"].append({"name": "Delta"})
    assert "run_dead_end" in [f["code"] for f in mountain.bundle().document["integrity"]["flags"]]

    document = _with_line_joins(mountain)
    flags = [f for f in document["integrity"]["flags"] if f["code"] in ("line_join", "run_dead_end")]
    assert [f["code"] for f in flags] == ["line_join"]
    walk = next(e for e in document["edges"] if e["id"] == flags[0]["edge_id"])
    assert walk["kind"] == "connection" and walk["from"] == "n10" and walk["to"].startswith("v")
    assert 17.0 <= walk["length_m"] <= 18.0
    # Alpha is split at the new vertex and carries on from it to the base.
    alpha = sorted((e for e in document["edges"] if e["id"].startswith("w201:")), key=lambda e: e["id"])
    assert [(e["from"], e["to"]) for e in alpha] == [("n3", walk["to"]), (walk["to"], "n1")]

    # Ending 15 m below the line instead, the join would climb: left open.
    mountain.node(10, 1.25, 2.5, 1110.0)
    document = _with_line_joins(mountain)
    assert "line_join" not in [f["code"] for f in document["integrity"]["flags"]]


def test_a_run_starting_just_below_a_ridge_run_is_joined_from_it():
    # Epsilon starts 17 m off the middle of Gamma's upper way and 5 m below it
    # (Peril Ridge below D8). A lift line between them would refuse the join.
    mountain = Mountain().node(11, -1.25, 8.0, 1395.0)
    mountain.way(205, [11, 1], {**RUN, "name": "Epsilon"})
    mountain.official["trails"].append({"name": "Epsilon"})
    document = _with_line_joins(mountain)
    join = next(f for f in document["integrity"]["flags"] if f["code"] == "line_join")
    walk = next(e for e in document["edges"] if e["id"] == join["edge_id"])
    assert walk["from"].startswith("v") and walk["to"] == "n11" and walk["one_way"]
    assert walk["id"].startswith("w203:")
    core = validate.Graph(document).core()
    assert all(e["from"] in core and e["to"] in core for e in document["edges"])

    mountain.node(60, -1.12, 7.0, 1300.0).node(61, -1.12, 9.0, 1450.0)
    mountain.way(106, [60, 61], {"aerialway": "chair_lift", "name": "Ridge Chair"})
    document = _with_line_joins(mountain)
    assert "line_join" not in [f["code"] for f in document["integrity"]["flags"]]


def test_a_second_ski_area_with_its_own_base_counts_and_a_high_pod_does_not():
    def with_pod(height):
        mountain = Mountain().node(20, 10, 0, height).node(21, 10, 3, height + 100)
        mountain.way(300, [20, 21], {"aerialway": "chair_lift", "name": "Pod Chair"})
        mountain.way(301, [21, 20], {"piste:type": "downhill", "name": "Pod Run"})
        mountain.official["lifts"].append({"name": "Pod Chair"})
        mountain.official["trails"].append({"name": "Pod Run"})
        return outcome(mountain)
    document, _, rows, codes = with_pod(1000.0)  # 710 m away, down at the base
    assert rows["lift_tops_reaching_base"]["value"] == 1.0
    assert "separate_area" in codes
    _, _, rows, codes = with_pod(1300.0)  # the same pod halfway up the mountain
    assert rows["lift_tops_reaching_base"]["value"] == 0.5
    assert "separate_area" not in codes


def test_live_status_coverage_matches_the_worker():
    from powdermeet_pipeline import validate
    groups = [{"id": f"lift:{i}", "kind": "lift"} for i in range(5)]
    def coverage(mapped: int) -> dict:
        document = {
            "integrity": {"flags": [], "lift_tops_reaching_base": 1.0,
                          "rendezvous_reachable_from_all_lift_tops": 1.0,
                          "orphan_edge_share": 0.0, "unnamed_run_share": 0.0},
            "groups": groups,
            "status_aliases": {"epic": {f"Lift {i}": f"lift:{i}" for i in range(mapped)}},
        }
        return validate.evaluate(document)
    assert coverage(4)["status_mode"] == "live"
    assert coverage(3)["status_mode"] == "scheduled_only"


def test_steepest_pitch_ignores_a_short_tail():
    from powdermeet_pipeline import build
    metre = 1 / 111_195.0
    # 5 m down over 40 m, then 3 m over the last 4 m: about 7 degrees, not 37.
    assert round(build._grade_max([(0, 0, 100.0), (0, 40 * metre, 95.0), (0, 44 * metre, 92.0)])) == 7


def test_a_mid_station_is_not_a_lift_top():
    mountain = Mountain().node(6, 0, 5, 1250.0)
    mountain.points[6] = (0, 5, {"aerialway": "station"})
    mountain.ways[100] = ([1, 6, 2], mountain.ways[100][1])
    kinds = {n["id"]: n["kind"] for n in mountain.bundle().document["nodes"]}
    assert (kinds["n6"], kinds["n2"]) == ("lift_bottom", "lift_top")
