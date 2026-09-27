import { computeFingerprint } from "./graph_builder.ts";
import type { Coord, GraphEdge, MountainGraph } from "./graph_types.ts";

export type GraphIntegrityFailureCode =
  | "resort_mismatch"
  | "empty_nodes"
  | "empty_edges"
  | "invalid_node_identity"
  | "invalid_node_coordinate"
  | "invalid_node_elevation"
  | "invalid_edge_identity"
  | "duplicate_edge_id"
  | "missing_endpoint"
  | "invalid_geometry"
  | "geometry_endpoint_mismatch"
  | "invalid_attribute"
  | "fingerprint_mismatch";

export interface GraphIntegrityFailure {
  code: GraphIntegrityFailureCode;
  entity_id?: string;
  field?: string;
  detail: string;
}

const MAX_ENDPOINT_METERS = 3;

/** Final fail-closed safety gate before a canonical graph can be uploaded. */
export function validateCanonicalGraph(
  graph: MountainGraph,
  expectedResortID: string,
): GraphIntegrityFailure[] {
  const failures: GraphIntegrityFailure[] = [];
  if (graph.resortID !== expectedResortID) {
    failures.push({
      code: "resort_mismatch",
      detail: "expected " + JSON.stringify(expectedResortID) +
        ", got " + JSON.stringify(graph.resortID),
    });
  }
  const nodeEntries = Object.entries(graph.nodes).sort(([a], [b]) =>
    a.localeCompare(b)
  );
  if (nodeEntries.length === 0) {
    failures.push({ code: "empty_nodes", detail: "graph has no nodes" });
  }
  if (graph.edges.length === 0) {
    failures.push({ code: "empty_edges", detail: "graph has no edges" });
  }
  for (const [key, node] of nodeEntries) {
    if (node.id.trim().length === 0 || key !== node.id) {
      failures.push({
        code: "invalid_node_identity",
        entity_id: node.id,
        detail: "node key must equal a nonblank node ID",
      });
    }
    if (!validCoordinate([node.coordinate.lon, node.coordinate.lat])) {
      failures.push({
        code: "invalid_node_coordinate",
        entity_id: node.id,
        detail: "node coordinate is invalid",
      });
    }
    if (!Number.isFinite(node.elevation)) {
      failures.push({
        code: "invalid_node_elevation",
        entity_id: node.id,
        detail: "node elevation is not finite",
      });
    }
  }

  const seen = new Set<string>();
  const ordered = graph.edges.map((edge, index) => ({ edge, index }))
    .sort((a, b) => a.edge.id.localeCompare(b.edge.id) || a.index - b.index);
  for (const { edge, index } of ordered) {
    if (edge.id.trim().length === 0) {
      failures.push({
        code: "invalid_edge_identity",
        detail: "edge " + index + " has a blank ID",
      });
    } else if (seen.has(edge.id)) {
      failures.push({
        code: "duplicate_edge_id",
        entity_id: edge.id,
        detail: "duplicate edge ID",
      });
    }
    seen.add(edge.id);
    const source = graph.nodes[edge.sourceID];
    const target = graph.nodes[edge.targetID];
    if (edge.sourceID.trim().length === 0 || source == null) {
      failures.push({
        code: "missing_endpoint",
        entity_id: edge.id,
        field: "sourceID",
        detail: "source node is missing",
      });
    }
    if (edge.targetID.trim().length === 0 || target == null) {
      failures.push({
        code: "missing_endpoint",
        entity_id: edge.id,
        field: "targetID",
        detail: "target node is missing",
      });
    }
    if (
      edge.geometry.length < 2 ||
      edge.geometry.some((coordinate) => !validCoordinate(coordinate))
    ) {
      failures.push({
        code: "invalid_geometry",
        entity_id: edge.id,
        detail: "geometry requires two or more valid [lon, lat] points",
      });
    } else {
      if (
        source != null &&
        distanceMeters(
            edge.geometry[0],
            [source.coordinate.lon, source.coordinate.lat],
          ) > MAX_ENDPOINT_METERS
      ) {
        failures.push({
          code: "geometry_endpoint_mismatch",
          entity_id: edge.id,
          field: "sourceID",
          detail: "geometry start is detached from source",
        });
      }
      if (
        target != null &&
        distanceMeters(
            edge.geometry[edge.geometry.length - 1],
            [target.coordinate.lon, target.coordinate.lat],
          ) > MAX_ENDPOINT_METERS
      ) {
        failures.push({
          code: "geometry_endpoint_mismatch",
          entity_id: edge.id,
          field: "targetID",
          detail: "geometry end is detached from target",
        });
      }
    }
    validateAttributes(edge, failures);
  }
  if (failures.length === 0) {
    const computed = computeFingerprint(
      graph.resortID,
      graph.nodes,
      graph.edges,
    );
    if (graph.fingerprint !== computed) {
      failures.push({
        code: "fingerprint_mismatch",
        detail: "advertised fingerprint does not match computed graph",
      });
    }
  }
  return failures;
}

function validateAttributes(
  edge: GraphEdge,
  failures: GraphIntegrityFailure[],
): void {
  const a = edge.attributes;
  requireNumber(
    failures,
    edge.id,
    "lengthMeters",
    a.lengthMeters,
    (n) => n > 0,
  );
  requireNumber(failures, edge.id, "verticalDrop", a.verticalDrop, nonnegative);
  requireNumber(
    failures,
    edge.id,
    "averageGradient",
    a.averageGradient,
    nonnegative,
  );
  requireNumber(failures, edge.id, "maxGradient", a.maxGradient, nonnegative);
  requireOptional(
    failures,
    edge.id,
    "aspect",
    a.aspect,
    (n) => n >= 0 && n <= 360,
  );
  requireNumber(
    failures,
    edge.id,
    "aspectVariance",
    a.aspectVariance,
    unitRange,
  );
  requireOptional(
    failures,
    edge.id,
    "estimatedTrailWidthMeters",
    a.estimatedTrailWidthMeters,
    (n) => n > 0,
  );
  requireOptional(
    failures,
    edge.id,
    "obstacleDensity",
    a.obstacleDensity,
    unitRange,
  );
  requireOptional(
    failures,
    edge.id,
    "fallLineExposure",
    a.fallLineExposure,
    unitRange,
  );
  requireOptional(
    failures,
    edge.id,
    "midpointElevation",
    a.midpointElevation,
    () => true,
  );
  if (
    a.lastGroomedHoursAgo != null &&
    (!Number.isInteger(a.lastGroomedHoursAgo) || a.lastGroomedHoursAgo < 0)
  ) {
    invalidAttribute(failures, edge.id, "lastGroomedHoursAgo");
  }

  if (edge.kind === "lift") {
    if (a.chargesLiftWait == null) {
      invalidAttribute(failures, edge.id, "chargesLiftWait");
    }
    requireOptional(
      failures,
      edge.id,
      "rideTimeSeconds",
      a.rideTimeSeconds,
      (n) => n > 0,
    );
    if (
      a.liftCapacity != null &&
      (!Number.isInteger(a.liftCapacity) || a.liftCapacity <= 0)
    ) {
      invalidAttribute(failures, edge.id, "liftCapacity");
    }
    requireOptional(
      failures,
      edge.id,
      "waitTimeMinutes",
      a.waitTimeMinutes,
      nonnegative,
    );
    requireOptional(
      failures,
      edge.id,
      "weekdayWaitMinutes",
      a.weekdayWaitMinutes,
      nonnegative,
    );
    requireOptional(
      failures,
      edge.id,
      "weekendWaitMinutes",
      a.weekendWaitMinutes,
      nonnegative,
    );
    if (
      a.chargesLiftWait === false &&
      (
        a.waitTimeMinutes != null ||
        a.weekdayWaitMinutes != null ||
        a.weekendWaitMinutes != null
      )
    ) {
      invalidAttribute(failures, edge.id, "continuationLiftWait");
    }
  } else if (
    a.liftType != null ||
    a.liftCapacity != null ||
    a.rideTimeSeconds != null ||
    a.waitTimeMinutes != null ||
    a.weekdayWaitMinutes != null ||
    a.weekendWaitMinutes != null ||
    a.chargesLiftWait != null
  ) {
    invalidAttribute(failures, edge.id, "nonLiftLiftMetadata");
  }
}

function requireNumber(
  failures: GraphIntegrityFailure[],
  edgeID: string,
  field: string,
  value: number,
  predicate: (value: number) => boolean,
): void {
  if (!Number.isFinite(value) || !predicate(value)) {
    invalidAttribute(failures, edgeID, field);
  }
}

function requireOptional(
  failures: GraphIntegrityFailure[],
  edgeID: string,
  field: string,
  value: number | null,
  predicate: (value: number) => boolean,
): void {
  if (value != null) requireNumber(failures, edgeID, field, value, predicate);
}

function invalidAttribute(
  failures: GraphIntegrityFailure[],
  edgeID: string,
  field: string,
): void {
  failures.push({
    code: "invalid_attribute",
    entity_id: edgeID,
    field,
    detail: "edge has invalid " + field,
  });
}

function nonnegative(value: number): boolean {
  return value >= 0;
}

function unitRange(value: number): boolean {
  return value >= 0 && value <= 1;
}

function validCoordinate(coordinate: Coord): boolean {
  return Array.isArray(coordinate) &&
    coordinate.length === 2 &&
    Number.isFinite(coordinate[0]) &&
    Number.isFinite(coordinate[1]) &&
    coordinate[0] >= -180 &&
    coordinate[0] <= 180 &&
    coordinate[1] >= -90 &&
    coordinate[1] <= 90;
}

function distanceMeters(lhs: Coord, rhs: Coord): number {
  const radians = Math.PI / 180;
  const dLat = (rhs[1] - lhs[1]) * radians;
  const dLon = (rhs[0] - lhs[0]) * radians;
  const lat1 = lhs[1] * radians;
  const lat2 = rhs[1] * radians;
  const h = Math.sin(dLat / 2) ** 2 +
    Math.cos(lat1) * Math.cos(lat2) * Math.sin(dLon / 2) ** 2;
  return 2 * 6_371_000 * Math.asin(Math.sqrt(Math.min(1, Math.max(0, h))));
}
