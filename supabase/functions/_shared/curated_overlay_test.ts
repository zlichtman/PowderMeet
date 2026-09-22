import {
  applyCuratedOverlay,
  type CuratedOverlayFailureCode,
} from "./curated_overlay.ts";
import { buildGraph, type ResortData } from "./graph_builder.ts";

function assert(condition: unknown, message: string): asserts condition {
  if (!condition) throw new Error(message);
}

function assertClose(
  actual: number,
  expected: number,
  message: string,
): void {
  if (Math.abs(actual - expected) > 1e-9) {
    throw new Error(`${message}: expected ${expected}, got ${actual}`);
  }
}

function baseData(): ResortData {
  return {
    trails: [],
    lifts: [],
    connections: [],
    bounds: { diagonalMeters: 100 },
  };
}

function failureCodes(
  result: ReturnType<typeof applyCuratedOverlay>,
): Set<CuratedOverlayFailureCode> {
  return new Set(result.failures.map((failure) => failure.code));
}

Deno.test("source-bound canonical identity does not claim an unlisted same-name way", () => {
  const data = baseData();
  data.trails = ["1", "2"].map((id, index) => ({
    id,
    name: "Repeated Name",
    difficulty: "blue" as const,
    coordinates: [
      {
        lat: 40.001 + index * 0.01,
        lon: -106,
        ele: 100,
        sourceNodeID: `${id}-top`,
      },
      {
        lat: 40 + index * 0.01,
        lon: -106,
        ele: 0,
        sourceNodeID: `${id}-bottom`,
      },
    ],
    lengthMeters: 111,
    isOpen: true,
  }));
  const graph = buildGraph(data, "test");
  const result = applyCuratedOverlay(graph, {
    trails: [{
      name: "Official Repeated Name",
      difficulty: "blue",
      osm_way_ids: ["1"],
    } as any],
    lifts: [],
  });

  assert(
    result.failures.length === 0,
    "exact source identity should reconcile",
  );
  const official = result.graph.edges.find((edge) => edge.id.startsWith("t1"))!;
  const unclaimed = result.graph.edges.find((edge) =>
    edge.id.startsWith("t2")
  )!;
  assert(
    official.attributes.isOpen &&
      official.attributes.isOfficiallyValidated &&
      official.attributes.trailName === "Official Repeated Name",
    "listed source way must receive the canonical identity",
  );
  assert(
    !unclaimed.attributes.isOpen &&
      !unclaimed.attributes.isOfficiallyValidated &&
      unclaimed.attributes.trailName === "Repeated Name",
    "same name is not authority when canonical source IDs exist",
  );
});

Deno.test("multi-segment trail receives one allocated official total", () => {
  const data = baseData();
  data.trails = [
    {
      id: "1",
      name: "Fragmented",
      difficulty: "green",
      coordinates: [
        { lat: 40.002, lon: -106, ele: 200, sourceNodeID: "top" },
        { lat: 40.001, lon: -106, ele: 100, sourceNodeID: "shared" },
        { lat: 40, lon: -106, ele: 0, sourceNodeID: "bottom" },
      ],
      lengthMeters: 500,
      isOpen: true,
    },
    {
      id: "2",
      name: "Crossing",
      difficulty: "blue",
      coordinates: [
        { lat: 40.0015, lon: -106.001, ele: 150, sourceNodeID: "cross-top" },
        { lat: 40.001, lon: -106, ele: 100, sourceNodeID: "shared" },
        { lat: 40.0005, lon: -106.001, ele: 50, sourceNodeID: "cross-bottom" },
      ],
      lengthMeters: 300,
      isOpen: true,
    },
  ];
  const graph = buildGraph(data, "test");
  const result = applyCuratedOverlay(graph, {
    trails: [{
      name: "Official Fragmented",
      difficulty: "black",
      length_m: 900,
      vert_m: 180,
      osm_way_ids: ["1"],
    } as any],
    lifts: [],
  });

  assert(
    result.failures.length === 0,
    "linear fragmented run should reconcile",
  );
  const segments = result.graph.edges.filter((edge) =>
    edge.kind === "run" &&
    edge.attributes.trailName === "Official Fragmented"
  );
  assert(
    segments.length === 2,
    "fixture should produce two canonical segments",
  );
  assertClose(
    segments.reduce((sum, edge) => sum + edge.attributes.lengthMeters, 0),
    900,
    "official length must be allocated once",
  );
  assertClose(
    segments.reduce((sum, edge) => sum + edge.attributes.verticalDrop, 0),
    180,
    "official vertical must be allocated once",
  );
  assert(
    new Set(segments.map((edge) => edge.attributes.trailGroupId)).size === 1,
    "all canonical segments must render and summarize as one trail identity",
  );
  assert(
    segments.every((edge) =>
      edge.attributes.difficulty === "black" &&
      edge.attributes.isOfficiallyValidated
    ),
    "canonical attributes must cover every segment",
  );
});

Deno.test("split physical lift allocates ride and rise once and charges one queue", () => {
  const data = baseData();
  data.lifts = [{
    id: "10",
    name: "Fragmented Lift",
    type: "chair_lift",
    capacity: 4,
    coordinates: [
      { lat: 40, lon: -106, ele: 0, sourceNodeID: "base" },
      { lat: 40.001, lon: -106, ele: 100, sourceNodeID: "shared" },
      { lat: 40.002, lon: -106, ele: 200, sourceNodeID: "top" },
    ],
    isOpen: true,
  }];
  data.trails = [{
    id: "20",
    name: "Crossing Run",
    difficulty: "blue",
    coordinates: [
      { lat: 40.0015, lon: -106.001, ele: 150, sourceNodeID: "run-top" },
      { lat: 40.001, lon: -106, ele: 100, sourceNodeID: "shared" },
      { lat: 40.0005, lon: -106.001, ele: 50, sourceNodeID: "run-bottom" },
    ],
    lengthMeters: 300,
    isOpen: true,
  }];
  const unsplitData = baseData();
  unsplitData.lifts = data.lifts;
  const unsplitGraph = buildGraph(unsplitData, "test");
  const unsplitRide = unsplitGraph.edges.find((edge) => edge.kind === "lift")!
    .attributes.rideTimeSeconds!;
  const graph = buildGraph(data, "test");
  const rawLiftSegments = graph.edges.filter((edge) => edge.kind === "lift");
  assertClose(
    rawLiftSegments.reduce(
      (sum, edge) => sum + (edge.attributes.rideTimeSeconds ?? 0),
      0,
    ),
    unsplitRide,
    "source splitting must preserve the estimated physical ride total",
  );
  assert(
    rawLiftSegments.filter((edge) => edge.attributes.chargesLiftWait === true)
          .length === 1 &&
      rawLiftSegments.filter((edge) =>
          edge.attributes.chargesLiftWait === false
        ).length === 1,
    "source splitting must create one queue entry before canonical overlay",
  );
  const result = applyCuratedOverlay(graph, {
    trails: [],
    lifts: [{
      name: "Official Fragmented Lift",
      lift_type: "chairlift",
      capacity: 6,
      ride_time_s: 600,
      vertical_rise_m: 240,
      weekday_wait_min: 3,
      weekend_wait_min: 7,
      osm_way_ids: ["10"],
    } as any],
  });

  assert(
    result.failures.length === 0,
    "linear fragmented lift should reconcile",
  );
  const segments = result.graph.edges.filter((edge) => edge.kind === "lift");
  assert(segments.length === 2, "fixture should produce two lift segments");
  assertClose(
    segments.reduce(
      (sum, edge) => sum + (edge.attributes.rideTimeSeconds ?? 0),
      0,
    ),
    600,
    "official ride time must be allocated once",
  );
  assertClose(
    segments.reduce((sum, edge) => sum + edge.attributes.verticalDrop, 0),
    240,
    "official lift rise must be allocated once",
  );
  assert(
    segments.filter((edge) => edge.attributes.chargesLiftWait === true)
      .length ===
      1,
    "exactly one segment must charge the physical queue",
  );
  const entry = segments.find((edge) =>
    edge.attributes.chargesLiftWait === true
  )!;
  const continuation = segments.find((edge) =>
    edge.attributes.chargesLiftWait === false
  )!;
  assert(
    entry.attributes.weekdayWaitMinutes === 3 &&
      entry.attributes.weekendWaitMinutes === 7,
    "queue baselines belong on the lift entry",
  );
  assert(
    continuation.attributes.waitTimeMinutes == null &&
      continuation.attributes.weekdayWaitMinutes == null &&
      continuation.attributes.weekendWaitMinutes == null,
    "continuation segments must carry no duplicate queue values",
  );
});

Deno.test("missing canonical target fails without mutating or closing the graph", () => {
  const data = baseData();
  data.trails = [{
    id: "1",
    name: "Present",
    difficulty: "blue",
    coordinates: [
      { lat: 40.001, lon: -106, ele: 100, sourceNodeID: "top" },
      { lat: 40, lon: -106, ele: 0, sourceNodeID: "bottom" },
    ],
    lengthMeters: 111,
    isOpen: true,
  }];
  const graph = buildGraph(data, "test");
  const result = applyCuratedOverlay(graph, {
    trails: [{
      name: "Missing",
      difficulty: "blue",
      osm_way_ids: ["999"],
    } as any],
    lifts: [],
  });

  assert(
    failureCodes(result).has("no_graph_match"),
    "missing source identity must be explicit",
  );
  assert(
    result.graph === graph,
    "failed reconciliation returns the exact input graph",
  );
  assert(
    graph.edges[0].attributes.isOpen,
    "atomic failure cannot close source terrain",
  );
});

Deno.test("partially missing multi-way identity fails instead of publishing a partial trail", () => {
  const data = baseData();
  data.trails = [{
    id: "1",
    name: "Partial",
    difficulty: "blue",
    coordinates: [
      { lat: 40.001, lon: -106, ele: 100, sourceNodeID: "top" },
      { lat: 40, lon: -106, ele: 0, sourceNodeID: "bottom" },
    ],
    lengthMeters: 111,
    isOpen: true,
  }];
  const graph = buildGraph(data, "test");
  const result = applyCuratedOverlay(graph, {
    trails: [{
      name: "Partial",
      difficulty: "blue",
      osm_way_ids: ["1", "2"],
    } as any],
    lifts: [],
  });

  assert(
    failureCodes(result).has("missing_source_segment"),
    "every reviewed source way must exist in the pinned snapshot",
  );
  assert(result.graph === graph, "partial identity failure must be atomic");
});

Deno.test("duplicate canonical names and source IDs fail before reconciliation", () => {
  const graph = buildGraph(baseData(), "test");
  const result = applyCuratedOverlay(graph, {
    trails: [
      { name: "Duplicate", osm_way_ids: ["1"] } as any,
      { name: " duplicate ", osm_way_ids: ["1"] } as any,
    ],
    lifts: [],
  });
  const codes = failureCodes(result);

  assert(codes.has("duplicate_name"), "normalized duplicate name must fail");
  assert(
    codes.has("duplicate_source_id"),
    "multiply owned source ID must fail",
  );
  assert(result.graph === graph, "manifest validation failure must be atomic");
});

Deno.test("branched canonical source identity is rejected", () => {
  const data = baseData();
  data.trails = ["1", "2"].map((id, index) => ({
    id,
    name: `Branch ${id}`,
    difficulty: "blue" as const,
    coordinates: [
      { lat: 40.001, lon: -106, ele: 100, sourceNodeID: "shared-top" },
      {
        lat: 40,
        lon: -106 - index * 0.001,
        ele: 0,
        sourceNodeID: `bottom-${id}`,
      },
    ],
    lengthMeters: 111,
    isOpen: true,
  }));
  const graph = buildGraph(data, "test");
  const result = applyCuratedOverlay(graph, {
    trails: [{
      name: "Invalid Branch",
      difficulty: "blue",
      osm_way_ids: ["1", "2"],
    } as any],
    lifts: [],
  });

  assert(
    failureCodes(result).has("branched_identity"),
    "one identity cannot fork into multiple directed routes",
  );
  assert(result.graph === graph, "topology failure must be atomic");
});

Deno.test("source-less canonical identity may use one exact-name chain", () => {
  const data = baseData();
  data.trails = [{
    id: "1",
    name: "Name Only",
    difficulty: "blue",
    coordinates: [
      { lat: 40.001, lon: -106, ele: 100, sourceNodeID: "top" },
      { lat: 40, lon: -106, ele: 0, sourceNodeID: "bottom" },
    ],
    lengthMeters: 111,
    isOpen: true,
  }];
  const graph = buildGraph(data, "test");
  const result = applyCuratedOverlay(graph, {
    trails: [{
      name: " name   only ",
      difficulty: "black",
      osm_way_ids: [],
    } as any],
    lifts: [],
  });

  assert(
    result.failures.length === 0,
    "unique exact-name fallback should reconcile",
  );
  assert(
    result.graph.edges[0].attributes.difficulty === "black" &&
      result.graph.edges[0].attributes.isOfficiallyValidated,
    "source-less fallback must still apply the reviewed canonical row",
  );
});
