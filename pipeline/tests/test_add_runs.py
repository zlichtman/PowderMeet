"""`add_runs`: runs no one has mapped, drawn along the fall line from a decisions file."""

import pytest

from powdermeet_pipeline import drawn, validate
from powdermeet_pipeline.reconcile import decisions as decisions_mod
from synthetic import Mountain

MAP = "https://example.com/trail-map.pdf"


def _with_run(**changes) -> Mountain:
    mountain = Mountain()
    mountain.official["trails"].append({"name": "Delta"})
    run = {"name": "Delta", "difficulty": "black", "from": "n2", "to": "n1", "source": MAP}
    mountain.decisions = {"add_runs": [{**run, **changes}]}
    return mountain


def test_a_drawn_run_joins_its_two_nodes_downhill_and_is_marked_approximate():
    mountain = _with_run()
    bundle = mountain.bundle()
    document = bundle.document
    edges = [e for e in document["edges"] if e.get("name") == "Delta"]
    assert len(edges) == 1
    edge = edges[0]
    assert (edge["from"], edge["to"], edge["kind"]) == ("n2", "n1", "run")
    assert edge["approximate"] is True and edge["difficulty"] == "black"
    assert edge["vertical_m"] < 0 and len(edge["geometry"]) >= 2
    group = next(g for g in document["groups"] if g["id"] == edge["group"])
    assert group["approximate"] is True and group["official"] is True
    assert not any(e.get("approximate") for e in document["edges"] if e is not edge)
    assert "run_drawn" in {f["code"] for f in document["integrity"]["flags"]}
    assert validate.check_constraints(document) == []
    assert mountain.bundle().bundle_id == bundle.bundle_id


def test_a_drawn_run_must_start_and_end_at_nodes_of_the_graph():
    with pytest.raises(drawn.DrawError, match="not a node of the built graph"):
        _with_run(to="n999").bundle()


def test_a_drawn_run_must_go_downhill():
    with pytest.raises(drawn.DrawError, match="goes downhill"):
        _with_run(**{"from": "n1", "to": "n2"}).bundle()


def test_a_drawn_run_has_a_length_cap():
    mountain = _with_run(to="n6")
    mountain.node(6, 0, -50, 0.0).way(204, [6, 1], {"piste:type": "downhill", "name": "Long Way"})
    with pytest.raises(drawn.DrawError, match="apart"):
        mountain.bundle()


@pytest.mark.parametrize("entry, message", [
    ({"difficulty": "park"}, "difficulty"),
    ({"to": "n2"}, "two different node ids"),
    ({"source": ""}, "source"),
    ({"approximate": True}, "unknown keys"),
])
def test_add_runs_entries_are_validated(entry, message):
    run = {"name": "Delta", "difficulty": "black", "from": "n2", "to": "n1", "source": MAP, **entry}
    with pytest.raises(decisions_mod.DecisionError, match=message):
        decisions_mod.normalize("test-mountain", {"add_runs": [run]})
