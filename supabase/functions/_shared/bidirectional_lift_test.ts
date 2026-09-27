import { buildGraph, type ResortData } from "./graph_builder.ts";
import { applyCuratedOverlay, stripEdgeIdToOSMId } from "./curated_overlay.ts";
import { validateCanonicalGraph } from "./graph_integrity.ts";
function assert(x: unknown, message: string): asserts x {
  if (!x) throw new Error(message);
}
export function fixture(isBidirectional = true): ResortData {
  const coordinates = [1, 2, 3].map((id, i) => ({
    lat: 40 + i * .001,
    lon: -106,
    ele: 100 + i * 100,
    sourceNodeID: String(id),
  }));
  return {
    bounds: { diagonalMeters: 100 },
    connections: [],
    lifts: [{
      id: "10",
      name: "Gondola",
      type: "gondola",
      coordinates,
      isOpen: true,
      isBidirectional,
    }],
    trails: [{
      id: "20",
      name: "Run",
      difficulty: "blue",
      isOpen: true,
      lengthMeters: 85.178,
      coordinates: [coordinates[1], {
        lat: 40.001,
        lon: -105.999,
        ele: 150,
        sourceNodeID: "4",
      }],
    }],
  };
}
Deno.test("explicit two-way lift keeps reverse source geometry and one queue per direction", () => {
  const graph = buildGraph(fixture(), "two-way");
  const lifts = graph.edges.filter((e) => e.kind === "lift");
  assert(lifts.length === 4, "two source segments in each direction");
  for (const reversed of [false, true]) {
    const lane = lifts.filter((e) => e.id.endsWith("_rev") === reversed);
    assert(
      lane.filter((e) => e.attributes.chargesLiftWait).length === 1,
      "one boarding queue",
    );
    assert(
      lane.find((e) => e.attributes.chargesLiftWait)?.sourceID ===
        (reversed ? "src:3" : "src:1"),
      "boarding at correct end",
    );
  }
  for (const reverse of lifts.filter((e) => e.id.endsWith("_rev"))) {
    const forward = lifts.find((e) => e.id === reverse.id.slice(0, -4))!;
    assert(
      JSON.stringify(reverse.geometry) ===
        JSON.stringify([...forward.geometry].reverse()),
      "exact source geometry",
    );
    assert(
      reverse.attributes.rideTimeSeconds === forward.attributes.rideTimeSeconds,
      "same physical ride duration",
    );
    assert(
      stripEdgeIdToOSMId(reverse.id) === "10",
      "physical identity retained through segmentation",
    );
  }
  assert(
    validateCanonicalGraph(graph, "two-way").length === 0,
    "graph integrity",
  );
  assert(
    buildGraph(fixture(false), "two-way").edges.every((e) =>
      !e.id.endsWith("_rev")
    ),
    "no invented downhill travel without source permission",
  );
});
Deno.test("canonical two-way lift allocates full ride and queue totals to each direction", () => {
  const graph = buildGraph(fixture(), "two-way");
  const manifest = {
    trails: [],
    lifts: [{
      name: "Gondola",
      osm_way_ids: ["10"],
      lift_type: "gondola",
      ride_time_s: 600,
      vertical_rise_m: 200,
      weekday_wait_min: 8,
      weekend_wait_min: 12,
    }] as any,
  };
  const result = applyCuratedOverlay(graph, manifest);
  assert(
    result.failures.length === 0 && result.appliedLiftIdentities === 1,
    "one physical canonical lift",
  );
  assert(
    validateCanonicalGraph(result.graph, "two-way").length === 0,
    "canonical two-way graph integrity",
  );
  for (const reversed of [false, true]) {
    const lane = result.graph.edges.filter((e) =>
      e.kind === "lift" && e.id.endsWith("_rev") === reversed
    );
    assert(
      Math.abs(
        lane.reduce((n, e) => n + (e.attributes.rideTimeSeconds ?? 0), 0) - 600,
      ) < 1e-8,
      "full ride time, not half",
    );
    assert(
      lane.reduce((n, e) => n + (e.attributes.weekdayWaitMinutes ?? 0), 0) ===
        8,
      "one full queue",
    );
  }
  const broken = {
    ...graph,
    edges: graph.edges.filter((e) => e.id !== "l10_vx1_rev"),
  };
  assert(
    applyCuratedOverlay(broken, manifest).failures.length > 0,
    "partial reverse identity fails atomically",
  );
});
