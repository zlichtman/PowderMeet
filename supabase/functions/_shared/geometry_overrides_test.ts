import {
  buildGraph,
  computeFingerprint,
  type ResortData,
} from "./graph_builder.ts";
import { applyCuratedOverlay } from "./curated_overlay.ts";
import { applyGeometryOverrides } from "./geometry_overrides.ts";

function assert(condition: unknown, message: string): asserts condition {
  if (!condition) throw new Error(message);
}

function singleTrailGraph() {
  const data: ResortData = {
    trails: [{
      id: "1",
      name: "Born Free",
      difficulty: "blue",
      coordinates: [
        { lat: 40.001, lon: -106, ele: 100, sourceNodeID: "top" },
        { lat: 40, lon: -106, ele: 0, sourceNodeID: "bottom" },
      ],
      lengthMeters: 111,
      isOpen: true,
    }],
    lifts: [],
    connections: [],
    bounds: { diagonalMeters: 500 },
  };
  const graph = buildGraph(data, "test");
  assert(graph.edges.length === 1, "fixture must produce one edge");
  return graph;
}

Deno.test("canonical overlay refreshes the final graph fingerprint", () => {
  const graph = singleTrailGraph();
  const before = graph.fingerprint;
  const overlay = applyCuratedOverlay(graph, {
    trails: [{ name: "Official Born Free", osm_way_ids: ["1"] } as any],
    lifts: [],
  });
  assert(overlay.failures.length === 0, "valid overlay should reconcile");
  const updated = overlay.graph;
  assert(
    updated.fingerprint !== before,
    "canonical naming must change fingerprint",
  );
  assert(
    updated.fingerprint ===
      computeFingerprint(updated.resortID, updated.nodes, updated.edges),
    "overlay fingerprint must describe the returned edges",
  );
});

Deno.test("unique endpoint-compatible geometry override is oriented, snapped, and hashed", () => {
  const graph = singleTrailGraph();
  const edge = graph.edges[0];
  const source = graph.nodes[edge.sourceID].coordinate;
  const target = graph.nodes[edge.targetID].coordinate;
  const before = graph.fingerprint;
  const originalGeometry = JSON.stringify(edge.geometry);
  const originalAspectVariance = edge.attributes.aspectVariance;

  const result = applyGeometryOverrides(graph, [{
    target_kind: "trail",
    target_name: " Born   Free ",
    geometry: {
      type: "LineString",
      // Deliberately reversed; transform must orient source -> target.
      coordinates: [
        [target.lon, target.lat],
        [-106.001, 40.0005],
        [source.lon, source.lat],
      ],
    },
  }]);

  assert(result.failures.length === 0, "valid override should not fail");
  assert(result.applied === 1, "one override should apply");
  assert(
    result.graph.fingerprint !== before,
    "geometry change must change fingerprint",
  );
  assert(
    JSON.stringify(graph.edges[0].geometry) === originalGeometry,
    "input graph is immutable",
  );
  const geometry = result.graph.edges[0].geometry;
  assert(
    geometry[0][0] === source.lon && geometry[0][1] === source.lat,
    "start snaps to source",
  );
  const last = geometry[geometry.length - 1];
  assert(
    last[0] === target.lon && last[1] === target.lat,
    "end snaps to target",
  );
  assert(
    result.graph.fingerprint === computeFingerprint(
      result.graph.resortID,
      result.graph.nodes,
      result.graph.edges,
    ),
    "geometry fingerprint must describe returned edges",
  );
  assert(
    result.graph.edges[0].attributes.aspectVariance !== originalAspectVariance,
    "override geometry must refresh sun-exposure inputs",
  );
});

Deno.test("ambiguous name-level override fails atomically", () => {
  const data: ResortData = {
    trails: ["1", "2"].map((id, index) => ({
      id,
      name: "Repeated Name",
      difficulty: "blue" as const,
      coordinates: [
        {
          lat: 40.001,
          lon: -106 - index * 0.01,
          ele: 100,
          sourceNodeID: `${id}-top`,
        },
        {
          lat: 40,
          lon: -106 - index * 0.01,
          ele: 0,
          sourceNodeID: `${id}-bottom`,
        },
      ],
      lengthMeters: 111,
      isOpen: true,
    })),
    lifts: [],
    connections: [],
    bounds: { diagonalMeters: 2_000 },
  };
  const graph = buildGraph(data, "test");
  const result = applyGeometryOverrides(graph, [{
    target_kind: "trail",
    target_name: "Repeated Name",
    geometry: {
      type: "LineString",
      coordinates: [[-106, 40.001], [-106, 40]],
    },
  }]);
  assert(result.applied === 0, "ambiguous override must not partially apply");
  assert(
    result.failures[0]?.code === "ambiguous_target",
    "ambiguity must be explicit",
  );
  assert(result.graph === graph, "failed batch returns the original graph");
});

Deno.test("malformed or endpoint-incompatible override fails atomically", () => {
  const graph = singleTrailGraph();
  const result = applyGeometryOverrides(graph, [
    {
      target_kind: "trail",
      target_name: "Born Free",
      geometry: JSON.stringify({
        type: "LineString",
        coordinates: [[-100, 30], [-100, 29]],
      }),
    },
    {
      target_kind: "lift",
      target_name: "Missing Lift",
      geometry: { type: "Point", coordinates: [[-106, 40]] },
    },
  ]);
  assert(result.applied === 0, "a failed batch must be atomic");
  assert(
    result.failures.length === 2,
    "all override failures should be reported",
  );
  assert(
    result.failures.some((failure) => failure.code === "endpoint_mismatch"),
    "endpoint mismatch should be explicit",
  );
  assert(
    result.failures.some((failure) => failure.code === "missing_target"),
    "missing target should be explicit before geometry parsing",
  );
});
