// Atomic canonical-manifest reconciliation for the server graph builder.
//
// Canonical rows are identities, while graph edges are directed geometry
// segments. A canonical total therefore belongs to the complete matched chain,
// never to each segment. Source IDs are authoritative when present; exact-name
// matching is permitted only for an explicitly source-less canonical row.

import type { CanonicalLift, CanonicalTrail } from "./types.ts";
import type {
  GraphEdge,
  LiftType,
  MountainGraph,
  RunDifficulty,
} from "./graph_types.ts";
import { computeFingerprint, stableTrailGroupID } from "./graph_builder.ts";

export interface CuratedOverlayInput {
  trails: CanonicalTrail[];
  lifts: CanonicalLift[];
}

export type CuratedOverlayFailureCode =
  | "invalid_name"
  | "invalid_source_id"
  | "invalid_attribute"
  | "duplicate_name"
  | "duplicate_source_id"
  | "no_graph_match"
  | "missing_source_segment"
  | "edge_claimed_multiple_times"
  | "branched_identity"
  | "disconnected_identity";

export interface CuratedOverlayFailure {
  code: CuratedOverlayFailureCode;
  identityKind: "trail" | "lift";
  canonicalName: string;
  detail: string;
  sourceIDs?: string[];
  edgeIDs?: string[];
}

export interface CuratedOverlayResult {
  graph: MountainGraph;
  failures: CuratedOverlayFailure[];
  appliedTrailIdentities: number;
  appliedLiftIdentities: number;
}

interface ReconciledIdentity<T> {
  canonical: T;
  orderedEdges: GraphEdge[];
  reverseEdges?: GraphEdge[];
}

const VALID_DIFFICULTIES = new Set<RunDifficulty>([
  "green",
  "blue",
  "black",
  "doubleBlack",
  "terrainPark",
]);

/**
 * Reconcile the complete manifest before changing any edge. A failed batch
 * returns the exact input graph, so callers cannot accidentally upload a
 * partially canonical dataset.
 */
export function applyCuratedOverlay(
  graph: MountainGraph,
  curated: CuratedOverlayInput,
): CuratedOverlayResult {
  const failures = validateManifest(curated);
  if (failures.length > 0) return failed(graph, failures);

  const claimedEdgeIDs = new Map<string, string>();
  const trails = reconcileIdentities(
    graph,
    curated.trails,
    "trail",
    "run",
    claimedEdgeIDs,
    failures,
  );
  const lifts = reconcileIdentities(
    graph,
    curated.lifts,
    "lift",
    "lift",
    claimedEdgeIDs,
    failures,
  );
  if (failures.length > 0) return failed(graph, failures);

  const replacements = new Map<string, GraphEdge>();
  for (const identity of trails) {
    applyTrailIdentity(identity, replacements);
  }
  for (const identity of lifts) {
    applyLiftIdentity(identity, replacements);
  }

  const hasTrailAuthority = curated.trails.length > 0;
  const hasLiftAuthority = curated.lifts.length > 0;
  const edges = graph.edges.map((edge) => {
    const replacement = replacements.get(edge.id);
    if (replacement) return replacement;
    if (
      (edge.kind === "run" && hasTrailAuthority) ||
      (edge.kind === "lift" && hasLiftAuthority)
    ) {
      return {
        ...edge,
        attributes: {
          ...edge.attributes,
          isOpen: false,
          isOfficiallyValidated: false,
        },
      };
    }
    return edge;
  });
  const updated: MountainGraph = {
    ...graph,
    edges,
    fingerprint: computeFingerprint(graph.resortID, graph.nodes, edges),
  };
  return {
    graph: updated,
    failures: [],
    appliedTrailIdentities: trails.length,
    appliedLiftIdentities: lifts.length,
  };
}

function failed(
  graph: MountainGraph,
  failures: CuratedOverlayFailure[],
): CuratedOverlayResult {
  return {
    graph,
    failures,
    appliedTrailIdentities: 0,
    appliedLiftIdentities: 0,
  };
}

function validateManifest(
  curated: CuratedOverlayInput,
): CuratedOverlayFailure[] {
  const failures: CuratedOverlayFailure[] = [];
  validateIdentityKeys(curated.trails, "trail", failures);
  validateIdentityKeys(curated.lifts, "lift", failures);

  for (const trail of curated.trails) {
    const name = trail.name ?? "";
    if (
      trail.difficulty != null &&
      !VALID_DIFFICULTIES.has(trail.difficulty as RunDifficulty)
    ) {
      failures.push(attributeFailure(
        "trail",
        name,
        `difficulty must be a Swift RunDifficulty raw value; got ${
          JSON.stringify(trail.difficulty)
        }`,
      ));
    }
    validateNonnegativeNumber(
      trail.length_m,
      "length_m",
      "trail",
      name,
      failures,
    );
    validateNonnegativeNumber(trail.vert_m, "vert_m", "trail", name, failures);
  }

  for (const lift of curated.lifts) {
    const name = lift.name ?? "";
    validateNonnegativeNumber(
      lift.ride_time_s,
      "ride_time_s",
      "lift",
      name,
      failures,
    );
    validateNonnegativeNumber(
      lift.vertical_rise_m,
      "vertical_rise_m",
      "lift",
      name,
      failures,
    );
    validateBoundedNumber(
      lift.weekday_wait_min,
      "weekday_wait_min",
      0,
      60,
      "lift",
      name,
      failures,
    );
    validateBoundedNumber(
      lift.weekend_wait_min,
      "weekend_wait_min",
      0,
      60,
      "lift",
      name,
      failures,
    );
    if (
      lift.capacity != null &&
      (
        typeof lift.capacity !== "number" ||
        !Number.isInteger(lift.capacity) ||
        lift.capacity <= 0
      )
    ) {
      failures.push(attributeFailure(
        "lift",
        name,
        `capacity must be a positive integer; got ${
          JSON.stringify(lift.capacity)
        }`,
      ));
    }
  }
  return failures;
}

function validateIdentityKeys<
  T extends { name: string; osm_way_ids: string[] },
>(
  identities: T[],
  identityKind: "trail" | "lift",
  failures: CuratedOverlayFailure[],
): void {
  const names = new Map<string, string>();
  const sourceOwners = new Map<string, string>();
  for (const identity of identities) {
    const name = identity.name ?? "";
    const nameKey = normalizeName(name);
    if (nameKey.length === 0) {
      failures.push({
        code: "invalid_name",
        identityKind,
        canonicalName: name,
        detail: "canonical names must contain non-whitespace text",
      });
    } else {
      const prior = names.get(nameKey);
      if (prior != null) {
        failures.push({
          code: "duplicate_name",
          identityKind,
          canonicalName: name,
          detail: `normalized name is already owned by ${
            JSON.stringify(prior)
          }`,
        });
      } else {
        names.set(nameKey, name);
      }
    }

    for (const rawID of identity.osm_way_ids ?? []) {
      const sourceID = String(rawID).trim();
      if (sourceID.length === 0) {
        failures.push({
          code: "invalid_source_id",
          identityKind,
          canonicalName: name,
          detail: "osm_way_ids cannot contain an empty ID",
        });
        continue;
      }
      const prior = sourceOwners.get(sourceID);
      if (prior != null) {
        failures.push({
          code: "duplicate_source_id",
          identityKind,
          canonicalName: name,
          detail: `source way ${sourceID} is already owned by ${
            JSON.stringify(prior)
          }`,
          sourceIDs: [sourceID],
        });
      } else {
        sourceOwners.set(sourceID, name);
      }
    }
  }
}

function reconcileIdentities<
  T extends { name: string; osm_way_ids: string[] },
>(
  graph: MountainGraph,
  identities: T[],
  identityKind: "trail" | "lift",
  edgeKind: "run" | "lift",
  claimedEdgeIDs: Map<string, string>,
  failures: CuratedOverlayFailure[],
): ReconciledIdentity<T>[] {
  const graphEdges = graph.edges.filter((edge) => edge.kind === edgeKind);
  const reconciled: ReconciledIdentity<T>[] = [];
  const sorted = [...identities].sort((a, b) =>
    normalizeName(a.name).localeCompare(normalizeName(b.name))
  );

  for (const canonical of sorted) {
    const sourceIDs = [
      ...new Set(
        (canonical.osm_way_ids ?? []).map((id) => String(id).trim()),
      ),
    ].sort();
    const sourceSet = new Set(sourceIDs);
    const matching = sourceIDs.length > 0
      ? graphEdges.filter((edge) => sourceSet.has(stripEdgeIdToOSMId(edge.id)))
      : graphEdges.filter((edge) =>
        edge.attributes.trailName != null &&
        normalizeName(edge.attributes.trailName) ===
          normalizeName(canonical.name)
      );

    if (matching.length === 0) {
      failures.push({
        code: "no_graph_match",
        identityKind,
        canonicalName: canonical.name,
        detail: sourceIDs.length > 0
          ? "none of the canonical source ways produced a graph edge"
          : "source-less identity had no exact normalized-name graph match",
        sourceIDs,
      });
      continue;
    }
    if (sourceIDs.length > 0) {
      const matchedSources = new Set(
        matching.map((edge) => stripEdgeIdToOSMId(edge.id)),
      );
      const missingSources = sourceIDs.filter((id) => !matchedSources.has(id));
      if (missingSources.length > 0) {
        failures.push({
          code: "missing_source_segment",
          identityKind,
          canonicalName: canonical.name,
          detail: "some canonical source ways produced no graph edge",
          sourceIDs: missingSources,
          edgeIDs: matching.map((edge) => edge.id).sort(),
        });
        continue;
      }
    }

    const reverse = edgeKind === "lift"
      ? matching.filter((e) => e.id.endsWith("_rev"))
      : [];
    const forward = matching.filter((e) => !reverse.includes(e));
    const reverseByForward = new Map(
      reverse.map((e) => [e.id.slice(0, -4), e]),
    );
    // A reverse lane must exactly mirror the same physical source chain.
    // Never reinterpret a branched or incomplete identity as two-way travel.
    if (
      reverse.length &&
      (reverse.length !== forward.length || forward.some((e) => {
        const r = reverseByForward.get(e.id);
        return !r || r.sourceID !== e.targetID || r.targetID !== e.sourceID ||
          JSON.stringify(r.geometry) !==
            JSON.stringify([...e.geometry].reverse());
      }))
    ) {
      failures.push({
        code: "disconnected_identity",
        identityKind,
        canonicalName: canonical.name,
        sourceIDs,
        detail:
          "bidirectional lift must contain exact reverse geometry for every source segment",
      });
      continue;
    }
    const ordered = orderLinearChain(forward);
    if ("failure" in ordered) {
      failures.push({
        code: ordered.failure,
        identityKind,
        canonicalName: canonical.name,
        detail: ordered.detail,
        sourceIDs,
        edgeIDs: matching.map((edge) => edge.id).sort(),
      });
      continue;
    }

    const claimedEdges = [...ordered.edges, ...reverse];
    let multiplyClaimed = false;
    for (const edge of claimedEdges) {
      const prior = claimedEdgeIDs.get(edge.id);
      if (prior != null) {
        multiplyClaimed = true;
        failures.push({
          code: "edge_claimed_multiple_times",
          identityKind,
          canonicalName: canonical.name,
          detail: `edge ${edge.id} is already owned by ${
            JSON.stringify(prior)
          }`,
          sourceIDs,
          edgeIDs: [edge.id],
        });
      }
    }
    if (multiplyClaimed) continue;
    for (const edge of claimedEdges) {
      claimedEdgeIDs.set(edge.id, canonical.name);
    }
    reconciled.push({
      canonical,
      orderedEdges: ordered.edges,
      reverseEdges: reverse.length
        ? [...ordered.edges].reverse().map((e) => reverseByForward.get(e.id)!)
        : undefined,
    });
  }
  return reconciled;
}

function orderLinearChain(
  edges: GraphEdge[],
):
  | { edges: GraphEdge[] }
  | {
    failure: "branched_identity" | "disconnected_identity";
    detail: string;
  } {
  const outgoing = new Map<string, GraphEdge[]>();
  const incoming = new Map<string, GraphEdge[]>();
  const nodeIDs = new Set<string>();
  for (const edge of edges) {
    nodeIDs.add(edge.sourceID);
    nodeIDs.add(edge.targetID);
    pushMap(outgoing, edge.sourceID, edge);
    pushMap(incoming, edge.targetID, edge);
  }
  for (const nodeID of nodeIDs) {
    if (
      (outgoing.get(nodeID)?.length ?? 0) > 1 ||
      (incoming.get(nodeID)?.length ?? 0) > 1
    ) {
      return {
        failure: "branched_identity",
        detail: `node ${nodeID} has multiple canonical-chain inputs or outputs`,
      };
    }
  }

  const starts = [...nodeIDs].filter((nodeID) =>
    (incoming.get(nodeID)?.length ?? 0) === 0 &&
    (outgoing.get(nodeID)?.length ?? 0) === 1
  );
  const ends = [...nodeIDs].filter((nodeID) =>
    (incoming.get(nodeID)?.length ?? 0) === 1 &&
    (outgoing.get(nodeID)?.length ?? 0) === 0
  );
  if (starts.length !== 1 || ends.length !== 1) {
    return {
      failure: "disconnected_identity",
      detail:
        `identity must be one directed chain; found ${starts.length} starts and ${ends.length} ends`,
    };
  }

  const ordered: GraphEdge[] = [];
  const visited = new Set<string>();
  let nodeID = starts[0];
  while (true) {
    const next = outgoing.get(nodeID)?.[0];
    if (!next) break;
    if (visited.has(next.id)) {
      return {
        failure: "disconnected_identity",
        detail: "identity contains a directed cycle",
      };
    }
    visited.add(next.id);
    ordered.push(next);
    nodeID = next.targetID;
  }
  if (nodeID !== ends[0] || ordered.length !== edges.length) {
    return {
      failure: "disconnected_identity",
      detail:
        `only ${ordered.length} of ${edges.length} matched edges belong to one directed chain`,
    };
  }
  return { edges: ordered };
}

function pushMap(
  map: Map<string, GraphEdge[]>,
  key: string,
  edge: GraphEdge,
): void {
  const values = map.get(key);
  if (values) values.push(edge);
  else map.set(key, [edge]);
}

function applyTrailIdentity(
  identity: ReconciledIdentity<CanonicalTrail>,
  replacements: Map<string, GraphEdge>,
): void {
  const { canonical, orderedEdges } = identity;
  const lengthWeights = orderedEdges.map((edge) =>
    edge.attributes.lengthMeters
  );
  const verticalWeights = orderedEdges.map((edge) =>
    edge.attributes.verticalDrop
  );
  const lengths = allocateOptionalTotal(canonical.length_m, lengthWeights);
  const drops = allocateOptionalTotal(
    canonical.vert_m,
    hasPositiveWeight(verticalWeights) ? verticalWeights : lengthWeights,
  );
  const trailGroupId = stableTrailGroupID(orderedEdges.map((edge) => edge.id));

  for (let index = 0; index < orderedEdges.length; index++) {
    const edge = orderedEdges[index];
    const lengthMeters = lengths?.[index] ?? edge.attributes.lengthMeters;
    const verticalDrop = drops?.[index] ?? edge.attributes.verticalDrop;
    const averageGradient = lengthMeters > 0
      ? Math.atan(verticalDrop / lengthMeters) * 180 / Math.PI
      : 0;
    replacements.set(edge.id, {
      ...edge,
      attributes: {
        ...edge.attributes,
        difficulty: canonical.difficulty == null
          ? edge.attributes.difficulty
          : canonical.difficulty as RunDifficulty,
        lengthMeters,
        verticalDrop,
        averageGradient,
        maxGradient: Math.max(edge.attributes.maxGradient, averageGradient),
        trailName: canonical.name,
        hasMoguls: canonical.has_moguls ?? edge.attributes.hasMoguls,
        isGroomed: canonical.is_groomed ?? edge.attributes.isGroomed,
        isGladed: canonical.is_gladed ?? edge.attributes.isGladed,
        isOfficiallyValidated: true,
        trailGroupId,
      },
    });
  }
}

function applyLiftIdentity(
  identity: ReconciledIdentity<CanonicalLift>,
  replacements: Map<string, GraphEdge>,
): void {
  const { canonical } = identity;
  const trailGroupId = stableTrailGroupID([
    ...identity.orderedEdges,
    ...(identity.reverseEdges ?? []),
  ].map((edge) => edge.id));
  for (
    const orderedEdges of [identity.orderedEdges, identity.reverseEdges ?? []]
  ) {
    const lengthWeights = orderedEdges.map((edge) =>
      edge.attributes.lengthMeters
    );
    const rises = allocateOptionalTotal(
      canonical.vertical_rise_m,
      lengthWeights,
    );
    const rides = allocateOptionalTotal(canonical.ride_time_s, lengthWeights);

    for (let index = 0; index < orderedEdges.length; index++) {
      const edge = orderedEdges[index];
      const isQueueEntry = index === 0;
      const verticalDrop = rises?.[index] ?? edge.attributes.verticalDrop;
      const rideTimeSeconds = rides?.[index] ?? edge.attributes.rideTimeSeconds;
      const averageGradient = edge.attributes.lengthMeters > 0
        ? Math.atan(verticalDrop / edge.attributes.lengthMeters) * 180 / Math.PI
        : 0;
      replacements.set(edge.id, {
        ...edge,
        attributes: {
          ...edge.attributes,
          verticalDrop,
          averageGradient,
          maxGradient: Math.max(edge.attributes.maxGradient, averageGradient),
          trailName: canonical.name,
          hasMoguls: false,
          isGroomed: false,
          isGladed: false,
          liftType: normalizeCanonicalLiftType(canonical.lift_type) ??
            edge.attributes.liftType,
          liftCapacity: canonical.capacity ?? edge.attributes.liftCapacity,
          rideTimeSeconds,
          waitTimeMinutes: isQueueEntry
            ? edge.attributes.waitTimeMinutes
            : null,
          weekdayWaitMinutes: isQueueEntry
            ? canonical.weekday_wait_min ?? edge.attributes.weekdayWaitMinutes
            : null,
          weekendWaitMinutes: isQueueEntry
            ? canonical.weekend_wait_min ?? edge.attributes.weekendWaitMinutes
            : null,
          chargesLiftWait: isQueueEntry,
          isOfficiallyValidated: true,
          trailGroupId,
        },
      });
    }
  }
}

function allocateOptionalTotal(
  total: number | null,
  rawWeights: number[],
): number[] | null {
  if (total == null) return null;
  const weights = hasPositiveWeight(rawWeights)
    ? rawWeights.map((value) => Number.isFinite(value) && value > 0 ? value : 0)
    : rawWeights.map(() => 1);
  const weightTotal = weights.reduce((sum, value) => sum + value, 0);
  const values = weights.map((weight) => total * weight / weightTotal);
  const allocated = values.reduce((sum, value) => sum + value, 0);
  values[values.length - 1] += total - allocated;
  return values;
}

function hasPositiveWeight(weights: number[]): boolean {
  return weights.some((value) => Number.isFinite(value) && value > 0);
}

function normalizeName(name: string): string {
  return name.normalize("NFKC").trim().toLowerCase().replace(/\s+/g, " ");
}

/**
 * Recover the raw OSM way ID through all builder segmentation suffixes.
 *
 *   t123_vx1_s2 -> 123
 *   l789_vx3    -> 789
 */
export function stripEdgeIdToOSMId(edgeId: string): string {
  let id = edgeId.endsWith("_rev") ? edgeId.slice(0, -4) : edgeId;
  if (id.length > 1 && (id[0] === "t" || id[0] === "l")) id = id.slice(1);
  while (/_(?:s|ix|vx)\d+$/.test(id)) {
    id = id.replace(/_(?:s|ix|vx)\d+$/, "");
  }
  return id;
}

function validateNonnegativeNumber(
  value: number | null,
  field: string,
  identityKind: "trail" | "lift",
  name: string,
  failures: CuratedOverlayFailure[],
): void {
  validateBoundedNumber(
    value,
    field,
    0,
    Number.POSITIVE_INFINITY,
    identityKind,
    name,
    failures,
  );
}

function validateBoundedNumber(
  value: number | null,
  field: string,
  minimum: number,
  maximum: number,
  identityKind: "trail" | "lift",
  name: string,
  failures: CuratedOverlayFailure[],
): void {
  if (value == null) return;
  if (
    typeof value !== "number" ||
    !Number.isFinite(value) ||
    value < minimum ||
    value > maximum
  ) {
    failures.push(attributeFailure(
      identityKind,
      name,
      `${field} must be finite and within [${minimum}, ${maximum}]; got ${
        JSON.stringify(value)
      }`,
    ));
  }
}

function attributeFailure(
  identityKind: "trail" | "lift",
  canonicalName: string,
  detail: string,
): CuratedOverlayFailure {
  return {
    code: "invalid_attribute",
    identityKind,
    canonicalName,
    detail,
  };
}

function normalizeCanonicalLiftType(raw: string | null): LiftType | null {
  if (raw == null) return null;
  switch (raw.trim().toLowerCase()) {
    case "chair_lift":
    case "chairlift":
      return "chair_lift";
    case "gondola":
      return "gondola";
    case "cable_car":
    case "cablecar":
      return "cable_car";
    case "drag_lift":
    case "draglift":
      return "drag_lift";
    case "t-bar":
    case "tbar":
      return "t-bar";
    case "j-bar":
    case "jbar":
      return "j-bar";
    case "platter":
      return "platter";
    case "rope_tow":
    case "ropetow":
    case "rope":
      return "rope_tow";
    case "magic_carpet":
    case "magiccarpet":
      return "magic_carpet";
    case "funicular":
      return "funicular";
    case "zip_line":
    case "zipline":
      return "zip_line";
    case "station":
      return "station";
    case "unknown":
      return "unknown";
    default:
      return "unknown";
  }
}
