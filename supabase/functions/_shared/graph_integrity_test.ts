import { computeFingerprint } from "./graph_builder.ts";
import { validateCanonicalGraph } from "./graph_integrity.ts";
import type {
  EdgeAttributes,
  GraphEdge,
  GraphNode,
  MountainGraph,
} from "./graph_types.ts";

function assertEquals(actual: unknown, expected: unknown): void {
  const actualJSON = JSON.stringify(actual);
  const expectedJSON = JSON.stringify(expected);
  if (actualJSON !== expectedJSON) {
    throw new Error("expected " + expectedJSON + ", got " + actualJSON);
  }
}

function assertExists<T>(value: T | null | undefined): asserts value is T {
  if (value == null) throw new Error("expected a value");
}

function attributes(overrides: Partial<EdgeAttributes> = {}): EdgeAttributes {
  return {
    difficulty: "blue",
    lengthMeters: 111,
    verticalDrop: 100,
    averageGradient: 42,
    maxGradient: 45,
    aspect: 180,
    aspectVariance: 0.1,
    trailName: "Test Run",
    hasMoguls: false,
    isGroomed: true,
    isGladed: false,
    liftType: null,
    liftCapacity: null,
    rideTimeSeconds: null,
    waitTimeMinutes: null,
    weekdayWaitMinutes: null,
    weekendWaitMinutes: null,
    chargesLiftWait: null,
    isOpen: true,
    isOfficiallyValidated: true,
    estimatedTrailWidthMeters: 25,
    obstacleDensity: 0.2,
    fallLineExposure: 0.4,
    nightGroomedFlag: false,
    lastGroomedHoursAgo: null,
    estimatedSurfaceCondition: null,
    trailGroupId: "test-run",
    midpointElevation: 2950,
    ...overrides,
  };
}

function validGraph(): MountainGraph {
  const nodes: Record<string, GraphNode> = {
    start: {
      id: "start",
      coordinate: { lat: 39.6, lon: -106.3 },
      elevation: 3000,
      kind: "trailHead",
    },
    end: {
      id: "end",
      coordinate: { lat: 39.599, lon: -106.3 },
      elevation: 2900,
      kind: "trailEnd",
    },
  };
  const edges: GraphEdge[] = [{
    id: "run-1",
    sourceID: "start",
    targetID: "end",
    kind: "run",
    geometry: [[-106.3, 39.6], [-106.3, 39.599]],
    attributes: attributes(),
  }];
  return {
    resortID: "test",
    nodes,
    edges,
    fingerprint: computeFingerprint("test", nodes, edges),
  };
}

Deno.test("graph integrity accepts complete fingerprint-matched graph", () => {
  assertEquals(validateCanonicalGraph(validGraph(), "test"), []);
});

Deno.test("graph integrity rejects stale fingerprint", () => {
  const graph = validGraph();
  graph.fingerprint = "stale";
  assertEquals(
    validateCanonicalGraph(graph, "test").map((failure) => failure.code),
    ["fingerprint_mismatch"],
  );
});

Deno.test("graph integrity rejects dangling and duplicate edge IDs", () => {
  const graph = validGraph();
  graph.edges.push({ ...graph.edges[0] });
  graph.edges[0] = { ...graph.edges[0], targetID: "missing" };
  const failures = validateCanonicalGraph(graph, "test");
  assertExists(failures.find((failure) => failure.code === "missing_endpoint"));
  assertExists(
    failures.find((failure) => failure.code === "duplicate_edge_id"),
  );
});

Deno.test("graph integrity rejects detached geometry and unsafe weights", () => {
  const graph = validGraph();
  graph.edges[0] = {
    ...graph.edges[0],
    geometry: [[-106.3, 39.61], [-106.3, 39.599]],
    attributes: attributes({ lengthMeters: 0, obstacleDensity: 1.1 }),
  };
  const failures = validateCanonicalGraph(graph, "test");
  assertExists(
    failures.find((failure) => failure.code === "geometry_endpoint_mismatch"),
  );
  assertExists(
    failures.find((failure) =>
      failure.code === "invalid_attribute" && failure.field === "lengthMeters"
    ),
  );
  assertExists(
    failures.find((failure) =>
      failure.code === "invalid_attribute" &&
      failure.field === "obstacleDensity"
    ),
  );
});

Deno.test("graph integrity enforces one lift queue entry", () => {
  const graph = validGraph();
  graph.edges[0] = {
    ...graph.edges[0],
    kind: "lift",
    attributes: attributes({
      difficulty: null,
      liftType: "chair_lift",
      rideTimeSeconds: 90,
      weekdayWaitMinutes: 3,
      chargesLiftWait: false,
    }),
  };
  const failures = validateCanonicalGraph(graph, "test");
  assertExists(
    failures.find((failure) =>
      failure.code === "invalid_attribute" &&
      failure.field === "continuationLiftWait"
    ),
  );
});
