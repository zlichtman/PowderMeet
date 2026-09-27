// Fail-closed canonical geometry overrides.
//
// The legacy implementation copied a name-level LineString onto every graph
// edge sharing that name. A fragmented trail could therefore render its full
// mountain-length polyline several times while retaining unrelated endpoints
// and routing weights. Until overrides are keyed per source way, a name-level
// override is eligible only when it resolves to exactly one run/lift edge.

// Every override batch is atomic: malformed, missing, ambiguous, or endpoint-
// incompatible input leaves the graph unchanged and returns diagnostics.

import type { Coord, GraphEdge, MountainGraph } from "./graph_types.ts";
import { computeAspect, computeFingerprint } from "./graph_builder.ts";

export interface CanonicalGeometryOverride {
  target_kind: "trail" | "lift";
  target_name: string;
  geometry: string | { type?: unknown; coordinates?: unknown };
}

export type GeometryOverrideFailureCode =
  | "duplicate_target"
  | "missing_target"
  | "ambiguous_target"
  | "invalid_geometry"
  | "endpoint_mismatch";

export interface GeometryOverrideFailure {
  target: string;
  code: GeometryOverrideFailureCode;
  detail: string;
}

export interface GeometryOverrideResult {
  graph: MountainGraph;
  applied: number;
  failures: GeometryOverrideFailure[];
}

interface PreparedOverride {
  edgeIndex: number;
  geometry: Coord[];
}

export function applyGeometryOverrides(
  graph: MountainGraph,
  overrides: CanonicalGeometryOverride[],
  endpointToleranceMeters = 25,
): GeometryOverrideResult {
  if (overrides.length === 0) return { graph, applied: 0, failures: [] };

  const failures: GeometryOverrideFailure[] = [];
  const prepared: PreparedOverride[] = [];
  const seenTargets = new Set<string>();

  const ordered = [...overrides].sort((a, b) =>
    targetKey(a).localeCompare(targetKey(b))
  );
  for (const override of ordered) {
    const key = targetKey(override);
    if (seenTargets.has(key)) {
      failures.push({
        target: key,
        code: "duplicate_target",
        detail:
          "more than one active override resolves to the same name-level target",
      });
      continue;
    }
    seenTargets.add(key);

    const matches = graph.edges
      .map((edge, index) => ({ edge, index }))
      .filter(({ edge }) => edgeMatches(edge, override));
    if (matches.length === 0) {
      failures.push({
        target: key,
        code: "missing_target",
        detail: "no run/lift edge matches this override in the pinned graph",
      });
      continue;
    }
    if (matches.length !== 1) {
      failures.push({
        target: key,
        code: "ambiguous_target",
        detail:
          `${matches.length} edges share this name; use source geometry until per-way overrides exist`,
      });
      continue;
    }

    const parsed = parseLineString(override.geometry);
    if (!parsed) {
      failures.push({
        target: key,
        code: "invalid_geometry",
        detail:
          "override must be a finite, in-bounds GeoJSON LineString with at least two distinct points",
      });
      continue;
    }

    const { edge, index } = matches[0];
    const source = graph.nodes[edge.sourceID];
    const target = graph.nodes[edge.targetID];
    if (!source || !target) {
      failures.push({
        target: key,
        code: "missing_target",
        detail: "matched edge references a missing graph endpoint",
      });
      continue;
    }

    const oriented = orientAndSnap(
      parsed,
      [source.coordinate.lon, source.coordinate.lat],
      [target.coordinate.lon, target.coordinate.lat],
      endpointToleranceMeters,
    );
    if (!oriented) {
      failures.push({
        target: key,
        code: "endpoint_mismatch",
        detail:
          `override endpoints exceed ${endpointToleranceMeters} m from the edge endpoints`,
      });
      continue;
    }
    prepared.push({ edgeIndex: index, geometry: oriented });
  }

  if (failures.length > 0) {
    return { graph, applied: 0, failures };
  }

  const edges = [...graph.edges];
  for (const override of prepared) {
    const edge = edges[override.edgeIndex];
    const lengthMeters = polylineLengthMeters(override.geometry);
    const averageGradient = lengthMeters > 0
      ? Math.atan(Math.abs(edge.attributes.verticalDrop) / lengthMeters) * 180 /
        Math.PI
      : edge.attributes.averageGradient;
    const [aspect, aspectVariance] = computeAspect(override.geometry);
    edges[override.edgeIndex] = {
      ...edge,
      geometry: override.geometry,
      attributes: {
        ...edge.attributes,
        lengthMeters,
        averageGradient,
        maxGradient: Math.max(edge.attributes.maxGradient, averageGradient),
        aspect,
        aspectVariance,
      },
    };
  }

  const updated: MountainGraph = { ...graph, edges };
  updated.fingerprint = computeFingerprint(
    updated.resortID,
    updated.nodes,
    updated.edges,
  );
  return { graph: updated, applied: prepared.length, failures: [] };
}

function targetKey(override: CanonicalGeometryOverride): string {
  return `${override.target_kind}|${normalizeName(override.target_name)}`;
}

function normalizeName(value: string): string {
  return value.trim().toLocaleLowerCase("en-US").replace(/\s+/g, " ");
}

function edgeMatches(
  edge: GraphEdge,
  override: CanonicalGeometryOverride,
): boolean {
  const expectedKind = override.target_kind === "lift" ? "lift" : "run";
  return edge.kind === expectedKind &&
    edge.attributes.trailName != null &&
    normalizeName(edge.attributes.trailName) ===
      normalizeName(override.target_name);
}

function parseLineString(
  raw: CanonicalGeometryOverride["geometry"],
): Coord[] | null {
  let value: unknown = raw;
  if (typeof value === "string") {
    try {
      value = JSON.parse(value);
    } catch {
      return null;
    }
  }
  if (typeof value !== "object" || value == null) return null;
  const geometry = value as { type?: unknown; coordinates?: unknown };
  if (geometry.type !== "LineString" || !Array.isArray(geometry.coordinates)) {
    return null;
  }

  const coordinates: Coord[] = [];
  for (const candidate of geometry.coordinates) {
    if (!Array.isArray(candidate) || candidate.length < 2) return null;
    const lon = candidate[0];
    const lat = candidate[1];
    if (typeof lon !== "number" || typeof lat !== "number") return null;
    if (!Number.isFinite(lon) || !Number.isFinite(lat)) return null;
    if (lon < -180 || lon > 180 || lat < -90 || lat > 90) return null;
    coordinates.push([lon, lat]);
  }
  if (coordinates.length < 2 || polylineLengthMeters(coordinates) <= 0.01) {
    return null;
  }
  return coordinates;
}

function orientAndSnap(
  geometry: Coord[],
  source: Coord,
  target: Coord,
  toleranceMeters: number,
): Coord[] | null {
  const first = geometry[0];
  const last = geometry[geometry.length - 1];
  const forwardError = Math.max(
    haversineMeters(first, source),
    haversineMeters(last, target),
  );
  const reverseError = Math.max(
    haversineMeters(last, source),
    haversineMeters(first, target),
  );
  if (Math.min(forwardError, reverseError) > toleranceMeters) return null;
  const oriented = reverseError < forwardError
    ? [...geometry].reverse()
    : [...geometry];
  oriented[0] = source;
  oriented[oriented.length - 1] = target;
  return oriented;
}

function polylineLengthMeters(geometry: Coord[]): number {
  let total = 0;
  for (let index = 1; index < geometry.length; index++) {
    total += haversineMeters(geometry[index - 1], geometry[index]);
  }
  return total;
}

function haversineMeters(a: Coord, b: Coord): number {
  const radians = (degrees: number) => degrees * Math.PI / 180;
  const latitudeDelta = radians(b[1] - a[1]);
  const longitudeDelta = radians(b[0] - a[0]);
  const latitudeA = radians(a[1]);
  const latitudeB = radians(b[1]);
  const h = Math.sin(latitudeDelta / 2) ** 2 +
    Math.cos(latitudeA) * Math.cos(latitudeB) *
      Math.sin(longitudeDelta / 2) ** 2;
  return 2 * 6_371_000 * Math.asin(Math.sqrt(h));
}
