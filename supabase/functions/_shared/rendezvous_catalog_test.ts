import { computeFingerprint } from "./graph_builder.ts";
import {
  buildRendezvousCatalog,
  overlayCuratedRendezvous,
} from "./rendezvous_catalog.ts";
import type {
  EdgeAttributes,
  GraphEdge,
  GraphNode,
  MountainGraph,
} from "./graph_types.ts";

function assert(condition: boolean, message: string): void {
  if (!condition) throw new Error(message);
}

function attributes(name: string, official = true): EdgeAttributes {
  return {
    difficulty: "blue",
    lengthMeters: 100,
    verticalDrop: 50,
    averageGradient: 20,
    maxGradient: 25,
    aspect: 180,
    aspectVariance: 0,
    trailName: name,
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
    isOfficiallyValidated: official,
    estimatedTrailWidthMeters: null,
    obstacleDensity: null,
    fallLineExposure: null,
    nightGroomedFlag: false,
    lastGroomedHoursAgo: null,
    estimatedSurfaceCondition: null,
    trailGroupId: null,
    midpointElevation: null,
  };
}

function graphFixture(): MountainGraph {
  const nodes: Record<string, GraphNode> = {
    base: {
      id: "base",
      coordinate: { lat: 50, lon: -122 },
      elevation: 1_000,
      kind: "liftBase",
    },
    top: {
      id: "top",
      coordinate: { lat: 50.01, lon: -122 },
      elevation: 1_500,
      kind: "liftTop",
    },
    junction: {
      id: "junction",
      coordinate: { lat: 50.005, lon: -122 },
      elevation: 1_250,
      kind: "junction",
    },
  };
  const run: GraphEdge = {
    id: "run",
    sourceID: "junction",
    targetID: "base",
    kind: "run",
    geometry: [[-122, 50.005], [-122, 50]],
    attributes: attributes("A Run"),
  };
  const lift: GraphEdge = {
    id: "lift",
    sourceID: "base",
    targetID: "top",
    kind: "lift",
    geometry: [[-122, 50], [-122, 50.01]],
    attributes: {
      ...attributes("Peak Chair"),
      difficulty: null,
      liftType: "chair_lift",
      rideTimeSeconds: 300,
      chargesLiftWait: true,
    },
  };
  const edges = [run, lift];
  return {
    resortID: "test",
    nodes,
    edges,
    fingerprint: computeFingerprint("test", nodes, edges),
  };
}

Deno.test("rendezvous catalog includes only safe stop nodes", () => {
  const catalog = buildRendezvousCatalog(graphFixture());
  assert(catalog.points.length === 1, "only the lift base should be eligible");
  assert(catalog.points[0].id === "base", "stable point ID must equal node ID");
  assert(
    catalog.points[0].kind === "liftBase",
    "kind must survive wire encoding",
  );
  assert(
    catalog.points[0].displayName === "Peak Chair Base",
    "a lift name should beat an incident run name",
  );
});

Deno.test("rendezvous catalog is deterministic across graph insertion order", () => {
  const first = graphFixture();
  const second = graphFixture();
  second.nodes = Object.fromEntries(Object.entries(second.nodes).reverse());
  second.edges.reverse();
  assert(
    JSON.stringify(buildRendezvousCatalog(first)) ===
      JSON.stringify(buildRendezvousCatalog(second)),
    "catalog output must not depend on object or edge insertion order",
  );
});

Deno.test("rendezvous catalog does not duplicate a landmark suffix", () => {
  const graph = graphFixture();
  graph.edges = graph.edges.map((edge) =>
    edge.kind === "lift"
      ? {
        ...edge,
        attributes: { ...edge.attributes, trailName: "Peak Chair Base" },
      }
      : edge
  );
  const point = buildRendezvousCatalog(graph).points[0];
  assert(
    point.displayName === "Peak Chair Base",
    "an authored Base suffix must not become Base Base",
  );
});

Deno.test("curated rendezvous overrides safe source anchor metadata", () => {
  const graph = graphFixture();
  graph.nodes["src:123"] = {
    ...graph.nodes.base,
    id: "src:123",
  };
  graph.edges[0] = { ...graph.edges[0], targetID: "src:123" };
  const result = overlayCuratedRendezvous(
    graph,
    buildRendezvousCatalog(graph),
    [{
      anchor_osm_node_id: 123,
      kind: "lodge",
      display_name: "Creekside Lodge",
      confidence: 1,
      quality: 0.98,
    }],
  );

  assert(result.failures.length === 0, "valid curated row must reconcile");
  const point = result.catalog.points.find((item) => item.id === "src:123");
  assert(point?.kind === "lodge", "curated kind must replace derived type");
  assert(point?.displayName === "Creekside Lodge", "curated name must survive");
});

Deno.test("curated rendezvous fails closed on missing and incompatible anchors", () => {
  const graph = graphFixture();
  graph.nodes["src:456"] = {
    ...graph.nodes.junction,
    id: "src:456",
  };
  graph.nodes["src:789"] = {
    ...graph.nodes.base,
    id: "src:789",
  };
  const result = overlayCuratedRendezvous(
    graph,
    buildRendezvousCatalog(graph),
    [
      {
        anchor_osm_node_id: 999,
        kind: "lodge",
        display_name: "Missing Lodge",
        confidence: 1,
        quality: 1,
      },
      {
        anchor_osm_node_id: 456,
        kind: "patrol",
        display_name: "Unsafe Junction Patrol",
        confidence: 1,
        quality: 1,
      },
      {
        anchor_osm_node_id: 789,
        kind: "lodge",
        display_name: "Disconnected Lodge",
        confidence: 1,
        quality: 1,
      },
    ],
  );

  assert(result.failures.length === 3, "every invalid row must be reported");
  assert(
    result.catalog.points.every((point) => point.id !== "src:456"),
    "an incompatible arbitrary junction must never enter the catalog",
  );
});
