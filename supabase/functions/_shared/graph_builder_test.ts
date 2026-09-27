import {
  buildGraph,
  computeFingerprint,
  computeAspect,
  type ResortData,
} from "./graph_builder.ts";
import { applyCuratedOverlay, stripEdgeIdToOSMId } from "./curated_overlay.ts";
import type { EdgeAttributes, MountainGraph } from "./graph_types.ts";

function assert(condition: unknown, message: string): asserts condition {
  if (!condition) throw new Error(message);
}

function baseData(): ResortData {
  return {
    trails: [],
    lifts: [],
    connections: [],
    bounds: { diagonalMeters: 100 },
  };
}

Deno.test("source elevation and maximum pitch survive junction and resolution splitting", () => {
  const data = baseData();
  const elevations = [1100, 1098, 1096, 1050, 1049, 1048, 1047, 990, 900];
  const coordinates = elevations.map((ele, i) => ({
    lat: 40.002 - i * 0.0002, lon: -106, ele, sourceNodeID: String(i + 1),
  }));
  data.trails = [{
    id: "1", name: "Main", difficulty: "blue", coordinates,
    lengthMeters: 178, isOpen: true,
  }, {
    id: "2", name: "Crossing", difficulty: "blue",
    coordinates: [
      { lat: coordinates[4].lat, lon: -106.001, ele: 1070, sourceNodeID: "20" },
      coordinates[4],
      { lat: coordinates[4].lat, lon: -105.999, ele: 1020, sourceNodeID: "21" },
    ], lengthMeters: 170, isOpen: true,
  }];
  const graph = buildGraph(data, "elevation");
  assert(graph.nodes["src:5"].elevation === 1049, "shared source elevation must not be replaced by endpoint slope");
  const main = graph.edges.filter((e) => e.id.startsWith("t1_"));
  assert(main.length === 4, "both source-junction pieces must also undergo resolution splitting");
  for (const edge of main) {
    for (const id of [edge.sourceID, edge.targetID]) {
      const node = graph.nodes[id];
      const index = coordinates.findIndex((c) => c.lat === node.coordinate.lat && c.lon === node.coordinate.lon);
      assert(index >= 0 && node.elevation === elevations[index], "every split node keeps its measured source elevation");
    }
  }
  assert(main.some((e) => e.attributes.maxGradient > e.attributes.averageGradient + 5),
    "a short steep pitch cannot be flattened into the whole segment average");
  assert(main.some((e) => e.attributes.maxGradient > 50), "the steep source pitch survives splitting");
  const reordered = buildGraph({ ...data, trails: [...data.trails].reverse() }, "elevation");
  assert(reordered.nodes["src:5"].elevation === 1049, "source ordering cannot change the sampled junction height");
});

Deno.test("missing elevation uses distance between measured anchors rather than vertex count", () => {
  const data = baseData();
  data.trails = [{ id: "1", name: "Uneven sampling", difficulty: "blue", isOpen: true,
    lengthMeters: 111,
    coordinates: [
      { lat: 40.001, lon: -106, ele: 100, sourceNodeID: "1" },
      { lat: 40.0009, lon: -106, ele: 90, sourceNodeID: "2" },
      { lat: 40.0008, lon: -106, sourceNodeID: "3" },
      { lat: 40, lon: -106, ele: 0, sourceNodeID: "4" },
    ],
  }];
  const graph = buildGraph(data, "elevation");
  const split = Object.values(graph.nodes).find((n) => n.coordinate.lat === 40.0008);
  assert(split != null && Math.abs(split.elevation - 80) < 0.001,
    "missing samples interpolate between nearby known anchors by distance, not vertex index");
});

Deno.test("shared source vertices split ways without proximity inference", () => {
  const data = baseData();
  data.trails = [
    {
      id: "1",
      name: "One",
      difficulty: "blue",
      coordinates: [
        { lat: 40.0002, lon: -106, ele: 20, sourceNodeID: "a" },
        { lat: 40.0001, lon: -106, ele: 10, sourceNodeID: "shared" },
        { lat: 40, lon: -106, ele: 0, sourceNodeID: "b" },
      ],
      lengthMeters: 22,
      isOpen: true,
    },
    {
      id: "2",
      name: "Two",
      difficulty: "green",
      coordinates: [
        { lat: 40.0001, lon: -106.0001, ele: 15, sourceNodeID: "c" },
        { lat: 40.0001, lon: -106, ele: 10, sourceNodeID: "shared" },
        { lat: 40, lon: -106.0001, ele: 0, sourceNodeID: "d" },
      ],
      lengthMeters: 30,
      isOpen: true,
    },
  ];

  const graph = buildGraph(data, "test");
  assert(
    graph.edges.filter((edge) => edge.kind === "run").length === 4,
    "both ways should split once",
  );
  assert(
    graph.edges.every((edge) => !edge.id.includes("_ix")),
    "no inferred intersections should appear",
  );
  const sharedID = "src:shared";
  assert(
    graph.edges.filter((edge) =>
      edge.sourceID === sharedID || edge.targetID === sharedID
    ).length === 4,
    "shared node should join both ways",
  );
});

Deno.test("coincident coordinates with different source nodes stay disconnected", () => {
  const data = baseData();
  data.trails = ["1", "2"].map((id) => ({
    id,
    name: `Run ${id}`,
    difficulty: "blue" as const,
    coordinates: [
      {
        lat: 40.0002,
        lon: -106 - Number(id) * 0.001,
        ele: 20,
        sourceNodeID: `${id}-a`,
      },
      { lat: 40.0001, lon: -106, ele: 10, sourceNodeID: `${id}-different` },
      {
        lat: 40,
        lon: -106 - Number(id) * 0.001,
        ele: 0,
        sourceNodeID: `${id}-b`,
      },
    ],
    lengthMeters: 200,
    isOpen: true,
  }));
  const graph = buildGraph(data, "test");
  const coincidentNodes = Object.values(graph.nodes).filter((node) =>
    node.coordinate.lat === 40.0001 && node.coordinate.lon === -106
  );
  assert(
    coincidentNodes.length === 2 &&
      coincidentNodes[0].id !== coincidentNodes[1].id,
    "resolution splits on different source ways must remain edge scoped",
  );
});

Deno.test("coincident endpoints with different source nodes stay disconnected", () => {
  const data = baseData();
  data.trails = [
    {
      id: "1",
      name: "Upper",
      difficulty: "blue",
      coordinates: [
        { lat: 40.001, lon: -106, ele: 100, sourceNodeID: "upper-top" },
        { lat: 40, lon: -106, ele: 0, sourceNodeID: "upper-end" },
      ],
      lengthMeters: 111,
      isOpen: true,
    },
    {
      id: "2",
      name: "Lower",
      difficulty: "blue",
      coordinates: [
        { lat: 40, lon: -106, ele: 100, sourceNodeID: "lower-start" },
        { lat: 39.999, lon: -106, ele: 0, sourceNodeID: "lower-end" },
      ],
      lengthMeters: 111,
      isOpen: true,
    },
  ];
  const graph = buildGraph(data, "test");
  const upper = graph.edges.find((edge) => edge.id === "t1")!;
  const lower = graph.edges.find((edge) => edge.id === "t2")!;
  assert(
    upper.targetID !== lower.sourceID,
    "coordinate coincidence cannot join distinct source endpoint IDs",
  );
  const coincidentNodes = Object.values(graph.nodes).filter((node) =>
    node.coordinate.lat === 40 && node.coordinate.lon === -106
  );
  assert(
    coincidentNodes.length === 2,
    "both exact source endpoints must remain represented",
  );
});

Deno.test("explicit connection ways are bidirectional and lift stations win node kind", () => {
  const data = baseData();
  data.trails = [{
    id: "1",
    name: "Run",
    difficulty: "blue",
    coordinates: [
      { lat: 40.0002, lon: -106, ele: 20, sourceNodeID: "top" },
      { lat: 40, lon: -106, ele: 0, sourceNodeID: "base" },
    ],
    lengthMeters: 22,
    isOpen: true,
  }];
  data.lifts = [{
    id: "2",
    name: "Lift",
    type: "chair_lift",
    coordinates: [
      { lat: 40, lon: -106, ele: 0, sourceNodeID: "base" },
      { lat: 40.0002, lon: -106, ele: 20, sourceNodeID: "top" },
    ],
    isOpen: true,
  }];
  data.connections = [{
    id: "3",
    name: "Walkway",
    coordinates: [
      { lat: 40, lon: -106, ele: 0, sourceNodeID: "base" },
      { lat: 40, lon: -106.0001, ele: 1, sourceNodeID: "other" },
    ],
    isOpen: true,
  }];

  const graph = buildGraph(data, "test");
  assert(
    graph.edges.filter((edge) => edge.kind === "traverse").length === 2,
    "connector needs both directions",
  );
  assert(
    graph.nodes["src:base"].kind === "liftBase",
    "lift base must upgrade an existing trail node",
  );
  assert(
    graph.nodes["src:top"].kind === "liftTop",
    "lift top must upgrade an existing trail node",
  );
});

Deno.test("canonical manifest closes unvalidated source terrain", () => {
  const data = baseData();
  data.trails = ["Allowed", "Phantom"].map((name, index) => ({
    id: String(index + 1),
    name,
    difficulty: "blue" as const,
    coordinates: [
      { lat: 40 + index * 0.001, lon: -106, ele: 20 },
      { lat: 40 + index * 0.001 - 0.0001, lon: -106, ele: 0 },
    ],
    lengthMeters: 20,
    isOpen: true,
  }));
  const graph = buildGraph(data, "test");
  const overlay = applyCuratedOverlay(graph, {
    trails: [
      { name: "Allowed", difficulty: "blue", osm_way_ids: ["1"] } as any,
    ],
    lifts: [],
  });
  assert(overlay.failures.length === 0, "valid manifest must reconcile");
  const allowed = overlay.graph.edges.find((edge) =>
    edge.attributes.trailName === "Allowed"
  )!;
  const phantom = overlay.graph.edges.find((edge) =>
    edge.attributes.trailName === "Phantom"
  )!;
  assert(
    allowed.attributes.isOpen && allowed.attributes.isOfficiallyValidated,
    "canonical run should remain open",
  );
  assert(
    !phantom.attributes.isOpen && !phantom.attributes.isOfficiallyValidated,
    "unlisted run must fail closed",
  );
  assert(
    stripEdgeIdToOSMId("t123_vx1_s2") === "123",
    "all topology suffixes must strip",
  );
});

Deno.test("canonical lift waits remain separate and lift type matches Swift wire values", () => {
  const data = baseData();
  data.lifts = [{
    id: "2",
    name: "Legacy Name",
    type: "chair_lift",
    coordinates: [
      { lat: 40, lon: -106, ele: 0, sourceNodeID: "base" },
      { lat: 40.001, lon: -106, ele: 100, sourceNodeID: "top" },
    ],
    isOpen: true,
  }];
  const graph = buildGraph(data, "test");
  const overlay = applyCuratedOverlay(graph, {
    trails: [],
    lifts: [{
      name: "Official Lift",
      lift_type: "chairlift",
      weekday_wait_min: 2,
      weekend_wait_min: 5,
      osm_way_ids: ["2"],
    } as any],
  });
  assert(overlay.failures.length === 0, "valid lift must reconcile");

  const lift = overlay.graph.edges.find((edge) => edge.kind === "lift")!;
  assert(
    lift.attributes.liftType === "chair_lift",
    "wire value must decode in Swift",
  );
  assert(
    lift.attributes.waitTimeMinutes == null,
    "build day must not become live state",
  );
  assert(
    lift.attributes.weekdayWaitMinutes === 2,
    "weekday baseline must survive",
  );
  assert(
    lift.attributes.weekendWaitMinutes === 5,
    "weekend baseline must survive",
  );
});

function parityFixture(): MountainGraph {
  return {
    resortID: "parity-resort",
    nodes: {
      "n-base": {
        id: "n-base",
        coordinate: { lat: 39.5, lon: -106.25 },
        elevation: 2500,
        kind: "liftBase",
      },
      "n-top": {
        id: "n-top",
        coordinate: { lat: 39.75, lon: -106.5 },
        elevation: 3500,
        kind: "liftTop",
      },
    },
    edges: [{
      id: "edge-1",
      sourceID: "n-top",
      targetID: "n-base",
      kind: "run",
      geometry: [[-106.5, 39.75], [-106.4, 39.6], [-106.25, 39.5]],
      attributes: {
        difficulty: "blue",
        lengthMeters: 1234.5,
        verticalDrop: 1000,
        averageGradient: 12.25,
        maxGradient: 31.5,
        aspect: 180,
        aspectVariance: 0.125,
        trailName: "Alpine Ω",
        hasMoguls: true,
        isGroomed: false,
        isGladed: true,
        liftType: "chair_lift",
        liftCapacity: 6,
        rideTimeSeconds: 321.5,
        waitTimeMinutes: 4.25,
        weekdayWaitMinutes: 3,
        weekendWaitMinutes: 8,
        chargesLiftWait: true,
        isOpen: true,
        isOfficiallyValidated: true,
        estimatedTrailWidthMeters: 17.5,
        obstacleDensity: 0.3,
        fallLineExposure: 0.75,
        nightGroomedFlag: true,
        lastGroomedHoursAgo: 7,
        estimatedSurfaceCondition: "crust",
        trailGroupId: "group-α",
        midpointElevation: 3000,
      },
    }],
    fingerprint: "",
  };
}

Deno.test("v11 fingerprint matches the Swift golden fixture", () => {
  const graph = parityFixture();
  const actual = computeFingerprint(graph.resortID, graph.nodes, graph.edges);
  assert(
    actual === "2:1:1d81c2adcccecaa9",
    `server and Swift fingerprints must remain byte-for-byte compatible; got ${actual}`,
  );
});

Deno.test("fingerprint normalizes negative zero to JSON wire semantics", () => {
  const graph = parityFixture();
  const edge = graph.edges[0];
  const withLength = (lengthMeters: number) =>
    computeFingerprint(
      graph.resortID,
      graph.nodes,
      [{
        ...edge,
        attributes: { ...edge.attributes, lengthMeters },
      }],
    );
  assert(
    withLength(0) === withLength(-0),
    "JSON cannot preserve a negative-zero distinction",
  );
});

Deno.test("fingerprint covers every EdgeAttributes wire field", () => {
  const graph = parityFixture();
  const edge = graph.edges[0];
  const baseline = computeFingerprint(graph.resortID, graph.nodes, graph.edges);
  const mutations: Partial<Record<keyof EdgeAttributes, unknown>> = {
    difficulty: "black",
    lengthMeters: 1235.5,
    verticalDrop: 999,
    averageGradient: 13.25,
    maxGradient: 32.5,
    aspect: 181,
    aspectVariance: 0.25,
    trailName: "Different",
    hasMoguls: false,
    isGroomed: true,
    isGladed: false,
    liftType: "gondola",
    liftCapacity: 8,
    rideTimeSeconds: 322.5,
    waitTimeMinutes: 5.25,
    weekdayWaitMinutes: 4,
    weekendWaitMinutes: 9,
    chargesLiftWait: false,
    isOpen: false,
    isOfficiallyValidated: false,
    estimatedTrailWidthMeters: 18.5,
    obstacleDensity: 0.4,
    fallLineExposure: 0.8,
    nightGroomedFlag: false,
    lastGroomedHoursAgo: 8,
    estimatedSurfaceCondition: "hero",
    trailGroupId: "different-group",
    midpointElevation: 3001,
  };

  for (const [field, value] of Object.entries(mutations)) {
    const attributes = {
      ...edge.attributes,
      [field]: value,
    } as EdgeAttributes;
    const changed = computeFingerprint(
      graph.resortID,
      graph.nodes,
      [{ ...edge, attributes }],
    );
    assert(changed !== baseline, `fingerprint omitted EdgeAttributes.${field}`);
  }
});

Deno.test("straight source segments cannot acquire negative aspect variance", () => {
  // Attitash OSM way 1361942429 previously produced -2.22e-16.
  const [bearing, variance] = computeAspect([
    [-71.233771, 44.0795068], [-71.233748, 44.0797602],
  ]);
  assert(Number.isFinite(bearing) && bearing >= 0 && bearing < 360, "valid bearing");
  assert(variance >= 0 && variance <= 1, "variance must satisfy graph integrity");
  assert(variance < 1e-12, "a single segment is straight");
  const [, opposed] = computeAspect([[0, 0], [0, 0.01], [0, 0]]);
  assert(opposed > 0.999, "clamping must preserve opposing directions");
});
