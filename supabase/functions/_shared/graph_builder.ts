// Graph builder — TypeScript port of GraphBuilder.swift.
//
// Determinism contract: given identical inputs (ResortData + resortID),
// produces byte-identical output across runs. This is STRONGER than the
// Swift original, which iterates Dictionary<String, GraphNode> in
// implementation-defined order (Swift dicts are not insertion-ordered
// nor sort-ordered). We sort by id at every Map iteration so the TS
// pipeline is reproducibly deterministic.
//
// Source: PowderMeet/Services/GraphBuilder.swift (1691 lines).
// Pipeline:
//   1. Trails → run edges (orientation by elevation)
//   2. Lifts → lift edges (oriented base→top)
//   3. splitLongEdges (resort-scaled split)
//   4. detectTrailIntersections (spatial-grid 50m, 30m grouping)
//   5. snapNearbyNodes (resort-scaled threshold, kindPriority preference)
//   6. connectLiftTopsToruns (lift tops MUST have outgoing run)
//   7. generateTraverseEdges (10m bidirectional cap, 30m absolute cap)
//   8. bridgeDisconnectedComponents (iterative BFS unification)
//   9. repairDirectedDeadEnds (logs only — does NOT fabricate)
//   10. ensureLiftReachability (8-hop BFS, 2km traverse)
//   11. pruneIsolatedNodes (named-edge nodes preserved)
//   12. assignTrailGroups (union-find by normalized name + difficulty)
//   13. computeFingerprint (matches MountainGraph.computeFingerprint)

import {
  type Coord,
  type EdgeAttributes,
  type EdgeKind,
  type GraphEdge,
  type GraphNode,
  type LiftType,
  type MountainGraph,
  type NodeKind,
  type RunDifficulty,
} from "./graph_types.ts";

// ── Inputs (mirror Swift's ResortData) ──────────────────────────────

export interface ResortDataTrail {
  id: string;
  name?: string | null;
  displayName?: string | null;
  difficulty?: RunDifficulty | null;
  coordinates: Array<{ lat: number; lon: number; ele?: number | null }>;
  lengthMeters: number;
  grooming?: string | null;
  isOpen: boolean;
}

export interface ResortDataLift {
  id: string;
  name?: string | null;
  type: LiftType;
  capacity?: number | null;
  coordinates: Array<{ lat: number; lon: number; ele?: number | null }>;
  isOpen: boolean;
}

export interface ResortDataBounds {
  diagonalMeters: number;
}

export interface ResortGraphBuildHints {
  mergeNamedTraverseGroups?: boolean;
}

export interface ResortData {
  trails: ResortDataTrail[];
  lifts: ResortDataLift[];
  bounds: ResortDataBounds;
  graphBuildHints?: ResortGraphBuildHints | null;
}

// ── Constants ───────────────────────────────────────────────────────

const MAX_TRAVERSE_ELEVATION_GAIN = 30;
const BIDIRECTIONAL_TRAVERSE_GAIN = 10;
const OUT_OF_RESORT_MAX_METERS = 1000;

// ── Public API ──────────────────────────────────────────────────────

export function buildGraph(resort: ResortData, resortID: string): MountainGraph {
  const nodes = new Map<string, GraphNode>();
  let edges: GraphEdge[] = [];

  // ── 1. Trails → run edges ──
  for (const trail of resort.trails) {
    if (trail.coordinates.length < 2) continue;
    const startCoord = trail.coordinates[0];
    const endCoord = trail.coordinates[trail.coordinates.length - 1];
    const allElevations = trail.coordinates
      .map((c) => c.ele)
      .filter((e): e is number => e != null);
    const startEle = startCoord.ele ?? allElevations[0] ?? 0;
    const endEle = endCoord.ele ?? allElevations[allElevations.length - 1] ?? 0;

    const startNodeID = nodeID(startCoord);
    const endNodeID = nodeID(endCoord);

    ensureNode(nodes, startNodeID, startCoord, startEle, "trailHead");
    ensureNode(nodes, endNodeID, endCoord, endEle, "trailEnd");

    let goesDownhill: boolean;
    if (startEle !== endEle) {
      goesDownhill = startEle >= endEle;
    } else if (allElevations.length >= 3) {
      const peakEle = Math.max(...allElevations);
      if (peakEle > 0) {
        const peakIdx = allElevations.indexOf(peakEle);
        const midpoint = Math.floor(allElevations.length / 2);
        goesDownhill = peakIdx <= midpoint;
      } else {
        goesDownhill = true;
      }
    } else {
      goesDownhill = true;
    }
    const srcID = goesDownhill ? startNodeID : endNodeID;
    const tgtID = goesDownhill ? endNodeID : startNodeID;

    const clCoords: Coord[] = trail.coordinates.map((c) => [c.lon, c.lat]);
    const geom = goesDownhill ? clCoords : [...clCoords].reverse();

    const length = trail.lengthMeters;
    const netDrop = Math.abs(startEle - endEle);
    const maxEle = allElevations.length > 0 ? Math.max(...allElevations) : startEle;
    const minEle = allElevations.length > 0 ? Math.min(...allElevations) : endEle;
    const vDrop = Math.max(netDrop, maxEle - minEle);
    const avgGrad = length > 0 ? Math.atan(netDrop / length) * 180 / Math.PI : 0;
    const maxGrad = computeMaxGradient(trail.coordinates);
    const [aspect, aspectVar] = computeAspect(clCoords);
    const name = trail.name ?? "";

    const attrs = makeEdgeAttributes({
      difficulty: trail.difficulty ?? null,
      lengthMeters: length,
      verticalDrop: vDrop,
      averageGradient: avgGrad,
      maxGradient: maxGrad,
      aspect,
      aspectVariance: aspectVar,
      trailName: trail.displayName ?? trail.name ?? null,
      hasMoguls: trail.grooming === "mogul",
      isGroomed: defaultGroomed(trail.grooming, trail.difficulty ?? null),
      isGladed: detectGladed(name),
      isOpen: trail.isOpen,
      midpointElevation: (startEle + endEle) / 2,
    });

    edges.push({
      id: `t${trail.id}`,
      sourceID: srcID,
      targetID: tgtID,
      kind: "run",
      geometry: geom,
      attributes: attrs,
    });
  }

  // ── 2. Lifts → lift edges ──
  for (const lift of resort.lifts) {
    if (lift.coordinates.length < 2) continue;
    const rawStart = lift.coordinates[0];
    const rawEnd = lift.coordinates[lift.coordinates.length - 1];
    const liftEles = lift.coordinates
      .map((c) => c.ele)
      .filter((e): e is number => e != null);
    const rawStartEle = rawStart.ele ?? liftEles[0] ?? 0;
    const rawEndEle = rawEnd.ele ?? liftEles[liftEles.length - 1] ?? 0;
    const isReversed = rawStartEle > rawEndEle && rawStartEle !== rawEndEle;

    const baseCoord = isReversed ? rawEnd : rawStart;
    const topCoord = isReversed ? rawStart : rawEnd;
    const baseEle = isReversed ? rawEndEle : rawStartEle;
    const topEle = isReversed ? rawStartEle : rawEndEle;

    const baseNodeID = nodeID(baseCoord);
    const topNodeID = nodeID(topCoord);

    ensureNode(nodes, baseNodeID, baseCoord, baseEle, "liftBase");
    ensureNode(nodes, topNodeID, topCoord, topEle, "liftTop");

    const rawClCoords: Coord[] = lift.coordinates.map((c) => [c.lon, c.lat]);
    const clCoords = isReversed ? [...rawClCoords].reverse() : rawClCoords;
    const length = polylineLength(clCoords);
    const liftMax = liftEles.length ? Math.max(...liftEles) : topEle;
    const liftMin = liftEles.length ? Math.min(...liftEles) : baseEle;
    const vDrop = Math.max(Math.abs(topEle - baseEle), liftMax - liftMin);
    const avgGrad = length > 0 ? Math.atan(vDrop / length) * 180 / Math.PI : 0;

    const attrs = makeEdgeAttributes({
      lengthMeters: length,
      verticalDrop: vDrop,
      averageGradient: avgGrad,
      maxGradient: avgGrad,
      trailName: lift.name ?? null,
      liftType: lift.type,
      liftCapacity: lift.capacity ?? null,
      rideTimeSeconds: estimateLiftTime(length, lift.type),
      isOpen: lift.isOpen,
      midpointElevation: (baseEle + topEle) / 2,
    });

    edges.push({
      id: `l${lift.id}`,
      sourceID: baseNodeID,
      targetID: topNodeID,
      kind: "lift",
      geometry: clCoords,
      attributes: attrs,
    });
  }

  // ── Resort scale ──
  const resortScale = Math.min(1.25, Math.max(0.5, resort.bounds.diagonalMeters / 5000));
  const snapThreshold = 80.0 * resortScale;
  const splitLength = 150.0 * resortScale;
  const traverseThreshold = 200.0 * resortScale;

  // ── 3..12. Pipeline ──
  edges = splitLongEdges(nodes, edges, splitLength);
  edges = detectTrailIntersections(nodes, edges, 15.0);
  edges = snapNearbyNodes(nodes, edges, snapThreshold);
  edges = connectLiftTopsToruns(nodes, edges, snapThreshold * 2);
  edges = generateTraverseEdges(nodes, edges, traverseThreshold);
  edges = bridgeDisconnectedComponents(nodes, edges);
  // repairDirectedDeadEnds is logs-only in Swift; no edges added; skip.
  edges = ensureLiftReachability(nodes, edges);
  ({ edges } = pruneIsolatedNodes(nodes, edges));
  edges = assignTrailGroups(edges, resort.graphBuildHints ?? undefined);

  // ── Convert to plain Record<string, GraphNode> + sort edges by id ──
  // Sort gives deterministic on-disk encoding; iteration order doesn't
  // matter for solver correctness but matters for reproducible blobs.
  const nodesObj: Record<string, GraphNode> = {};
  for (const id of [...nodes.keys()].sort()) {
    nodesObj[id] = nodes.get(id)!;
  }
  edges = [...edges].sort((a, b) => a.id < b.id ? -1 : a.id > b.id ? 1 : 0);

  const fingerprint = computeFingerprint(nodesObj, edges);
  return { resortID, nodes: nodesObj, edges, fingerprint };
}

// ── Helpers ─────────────────────────────────────────────────────────

function nodeID(coord: { lat: number; lon: number }): string {
  const latKey = Math.round(coord.lat * 100000);
  const lonKey = Math.round(coord.lon * 100000);
  return `n${latKey}_${lonKey}`;
}

function ensureNode(
  nodes: Map<string, GraphNode>,
  id: string,
  coord: { lat: number; lon: number },
  elevation: number,
  kind: NodeKind,
): void {
  if (nodes.has(id)) return;
  nodes.set(id, {
    id,
    coordinate: { lat: coord.lat, lon: coord.lon },
    elevation,
    kind,
  });
}

function makeEdgeAttributes(p: Partial<EdgeAttributes>): EdgeAttributes {
  return {
    difficulty: p.difficulty ?? null,
    lengthMeters: p.lengthMeters ?? 0,
    verticalDrop: p.verticalDrop ?? 0,
    averageGradient: p.averageGradient ?? 0,
    maxGradient: p.maxGradient ?? 0,
    aspect: p.aspect ?? null,
    aspectVariance: p.aspectVariance ?? 0,
    trailName: p.trailName ?? null,
    hasMoguls: p.hasMoguls ?? false,
    isGroomed: p.isGroomed === undefined ? null : p.isGroomed,
    isGladed: p.isGladed ?? false,
    liftType: p.liftType ?? null,
    liftCapacity: p.liftCapacity ?? null,
    rideTimeSeconds: p.rideTimeSeconds ?? null,
    waitTimeMinutes: p.waitTimeMinutes ?? null,
    isOpen: p.isOpen ?? true,
    isOfficiallyValidated: p.isOfficiallyValidated ?? false,
    estimatedTrailWidthMeters: p.estimatedTrailWidthMeters ?? null,
    obstacleDensity: p.obstacleDensity ?? null,
    fallLineExposure: p.fallLineExposure ?? null,
    nightGroomedFlag: p.nightGroomedFlag ?? false,
    lastGroomedHoursAgo: p.lastGroomedHoursAgo ?? null,
    estimatedSurfaceCondition: p.estimatedSurfaceCondition ?? null,
    trailGroupId: p.trailGroupId ?? null,
    midpointElevation: p.midpointElevation ?? null,
  };
}

function polylineLength(coords: Coord[]): number {
  let total = 0;
  for (let i = 1; i < coords.length; i++) {
    total += haversineMeters(
      { lon: coords[i - 1][0], lat: coords[i - 1][1] },
      { lon: coords[i][0], lat: coords[i][1] },
    );
  }
  return total;
}

function haversineMeters(
  a: { lat: number; lon: number },
  b: { lat: number; lon: number },
): number {
  const R = 6371000;
  const toRad = (deg: number) => deg * Math.PI / 180;
  const dLat = toRad(b.lat - a.lat);
  const dLon = toRad(b.lon - a.lon);
  const lat1 = toRad(a.lat);
  const lat2 = toRad(b.lat);
  const h = Math.sin(dLat / 2) ** 2 +
    Math.cos(lat1) * Math.cos(lat2) * Math.sin(dLon / 2) ** 2;
  return 2 * R * Math.asin(Math.sqrt(h));
}

function computeMaxGradient(
  coords: Array<{ lat: number; lon: number; ele?: number | null }>,
): number {
  let max = 0;
  for (let i = 1; i < coords.length; i++) {
    const a = coords[i - 1];
    const b = coords[i];
    if (a.ele == null || b.ele == null) continue;
    const hDist = haversineMeters(a, b);
    const vDist = Math.abs(b.ele - a.ele);
    if (hDist > 5) {
      max = Math.max(max, Math.atan(vDist / hDist) * 180 / Math.PI);
    }
  }
  return Math.min(60, max);
}

function computeAspect(coords: Coord[]): [number, number] {
  if (coords.length < 2) return [0, 0];
  let sinSum = 0, cosSum = 0, totalWeight = 0;
  for (let i = 0; i < coords.length - 1; i++) {
    const a = coords[i], b = coords[i + 1];
    const dlat = b[1] - a[1];
    const dlon = b[0] - a[0];
    const segLength = Math.sqrt(dlat * dlat + dlon * dlon) * 111000;
    if (segLength <= 1) continue;
    let bearing = Math.atan2(dlon, dlat) * 180 / Math.PI;
    if (bearing < 0) bearing += 360;
    const radians = bearing * Math.PI / 180;
    sinSum += Math.sin(radians) * segLength;
    cosSum += Math.cos(radians) * segLength;
    totalWeight += segLength;
  }
  if (totalWeight <= 0) return [0, 0];
  sinSum /= totalWeight;
  cosSum /= totalWeight;
  let meanBearing = Math.atan2(sinSum, cosSum) * 180 / Math.PI;
  if (meanBearing < 0) meanBearing += 360;
  const R = Math.sqrt(sinSum * sinSum + cosSum * cosSum);
  return [meanBearing, 1.0 - R];
}

function estimateLiftTime(length: number, type: LiftType): number {
  let speed: number;
  switch (type) {
    case "cableCar": case "funicular":  speed = 8.0; break;
    case "gondola":                     speed = 5.0; break;
    case "chairlift":                   speed = 2.5; break;
    case "tBar":                        speed = 3.0; break;
    case "platter":                     speed = 2.5; break;
    case "rope":                        speed = 2.0; break;
    case "magicCarpet":                 speed = 1.0; break;
    default:                            speed = 3.0; break;
  }
  return length / speed;
}

function defaultGroomed(
  grooming: string | null | undefined,
  difficulty: RunDifficulty | null,
): boolean | null {
  const g = grooming?.toLowerCase();
  if (g === "backcountry" || g === "mogul") return false;
  if (g === "classic" || g === "groomed") return true;
  if (difficulty === "terrainPark") return true;
  if (difficulty === "doubleBlack") return false;
  return null;
}

function detectGladed(name: string): boolean {
  const lower = name.toLowerCase();
  const keywords = ["glade", "glades", "tree", "trees", "wood", "woods", "forest"];
  return keywords.some((k) => lower.includes(k));
}

function kindPriority(kind: NodeKind): number {
  switch (kind) {
    case "liftBase": case "liftTop": return 3;
    case "midStation":               return 2;
    case "trailHead":                return 1;
    default:                         return 0;
  }
}

// ── splitLongEdges ──────────────────────────────────────────────────

function splitLongEdges(
  nodes: Map<string, GraphNode>,
  edges: GraphEdge[],
  maxSegmentLength: number,
): GraphEdge[] {
  const newEdges: GraphEdge[] = [];
  const removeIds = new Set<string>();

  for (const edge of edges) {
    if (edge.kind !== "run") continue;
    const length = edge.attributes.lengthMeters;
    if (length <= maxSegmentLength) continue;
    if (edge.geometry.length < 3) continue;

    const coords = edge.geometry;
    const srcEle = nodes.get(edge.sourceID)?.elevation ?? 0;
    const tgtEle = nodes.get(edge.targetID)?.elevation ?? 0;

    const numSegments = Math.max(2, Math.ceil(length / maxSegmentLength));
    const stepSize = Math.floor(coords.length / numSegments);
    if (stepSize < 1) continue;

    const splitIndices: number[] = [0];
    for (let seg = 1; seg < numSegments; seg++) {
      const idx = Math.min(seg * stepSize, coords.length - 1);
      if (idx !== splitIndices[splitIndices.length - 1] && idx !== coords.length - 1) {
        splitIndices.push(idx);
      }
    }
    splitIndices.push(coords.length - 1);
    if (splitIndices.length < 3) continue;

    const segmentNodeIds: string[] = [edge.sourceID];
    for (let i = 1; i < splitIndices.length - 1; i++) {
      const midCoord = coords[splitIndices[i]];
      const midNodeId = nodeID({ lat: midCoord[1], lon: midCoord[0] });
      if (midNodeId === edge.sourceID || midNodeId === edge.targetID) continue;
      const fraction = splitIndices[i] / (coords.length - 1);
      const midEle = srcEle + (tgtEle - srcEle) * fraction;
      if (!nodes.has(midNodeId)) {
        nodes.set(midNodeId, {
          id: midNodeId,
          coordinate: { lat: midCoord[1], lon: midCoord[0] },
          elevation: midEle,
          kind: "junction",
        });
      }
      segmentNodeIds.push(midNodeId);
    }
    segmentNodeIds.push(edge.targetID);

    const deduped: string[] = [];
    for (const id of segmentNodeIds) {
      if (deduped[deduped.length - 1] !== id) deduped.push(id);
    }
    if (deduped.length < 3) continue;

    let prevIdx = 0;
    for (let seg = 1; seg < deduped.length; seg++) {
      const nextIdx = seg === deduped.length - 1
        ? coords.length - 1
        : splitIndices[Math.min(seg, splitIndices.length - 1)];
      const geom = coords.slice(prevIdx, Math.min(nextIdx, coords.length - 1) + 1);
      const segLength = polylineLength(geom);
      const srcE = nodes.get(deduped[seg - 1])?.elevation ?? 0;
      const tgtE = nodes.get(deduped[seg])?.elevation ?? 0;
      const segDrop = Math.abs(srcE - tgtE);
      const segAvgGrad = segLength > 0 ? Math.atan(segDrop / segLength) * 180 / Math.PI : 0;
      newEdges.push({
        id: `${edge.id}_s${seg}`,
        sourceID: deduped[seg - 1],
        targetID: deduped[seg],
        kind: edge.kind,
        geometry: geom,
        attributes: makeEdgeAttributes({
          ...edge.attributes,
          lengthMeters: segLength,
          verticalDrop: segDrop,
          averageGradient: segAvgGrad,
          maxGradient: segAvgGrad,
        }),
      });
      prevIdx = nextIdx;
    }
    removeIds.add(edge.id);
  }

  if (removeIds.size === 0) return edges;
  return [...edges.filter((e) => !removeIds.has(e.id)), ...newEdges];
}

// ── detectTrailIntersections ────────────────────────────────────────

function detectTrailIntersections(
  nodes: Map<string, GraphNode>,
  edges: GraphEdge[],
  proximityThreshold: number,
): GraphEdge[] {
  const runEdges = edges.filter((e) => e.kind === "run" && e.geometry.length >= 2);
  if (runEdges.length < 2) return edges;

  type Intersection = {
    edgeA: string; edgeB: string; idxA: number; idxB: number;
    distance: number; coordinate: Coord; elevation: number;
  };

  const edgeIndex = new Map<string, GraphEdge>();
  for (const e of runEdges) edgeIndex.set(e.id, e);

  const cellSize = 0.0005;

  const cellToEdges = new Map<string, Set<string>>();
  for (const edge of runEdges) {
    const cellsForEdge = new Set<string>();
    for (const pt of edge.geometry) {
      const cellKey = `${Math.floor(pt[1] / cellSize)}_${Math.floor(pt[0] / cellSize)}`;
      cellsForEdge.add(cellKey);
    }
    for (const cell of cellsForEdge) {
      let s = cellToEdges.get(cell);
      if (!s) { s = new Set(); cellToEdges.set(cell, s); }
      s.add(edge.id);
    }
  }

  const candidatePairs = new Set<string>();
  // Sort cell keys for deterministic iteration
  const cellKeysSorted = [...cellToEdges.keys()].sort();
  for (const cellKey of cellKeysSorted) {
    const edgeIds = cellToEdges.get(cellKey)!;
    const parts = cellKey.split("_");
    if (parts.length !== 2) continue;
    const cellLat = parseInt(parts[0], 10);
    const cellLon = parseInt(parts[1], 10);
    if (!Number.isFinite(cellLat) || !Number.isFinite(cellLon)) continue;

    const nearbyEdges = new Set<string>(edgeIds);
    for (let dLat = -1; dLat <= 1; dLat++) {
      for (let dLon = -1; dLon <= 1; dLon++) {
        if (dLat === 0 && dLon === 0) continue;
        const neighborKey = `${cellLat + dLat}_${cellLon + dLon}`;
        const neighborEdges = cellToEdges.get(neighborKey);
        if (neighborEdges) for (const e of neighborEdges) nearbyEdges.add(e);
      }
    }

    const sorted = [...nearbyEdges].sort();
    for (let i = 0; i < sorted.length; i++) {
      for (let j = i + 1; j < sorted.length; j++) {
        candidatePairs.add(`${sorted[i]}|${sorted[j]}`);
      }
    }
  }

  const intersections: Intersection[] = [];
  // Sorted iteration for determinism
  const pairs = [...candidatePairs].sort();
  for (const pairKey of pairs) {
    const ids = pairKey.split("|");
    if (ids.length !== 2) continue;
    const a = edgeIndex.get(ids[0]);
    const b = edgeIndex.get(ids[1]);
    if (!a || !b) continue;
    if (a.sourceID === b.sourceID || a.sourceID === b.targetID ||
        a.targetID === b.sourceID || a.targetID === b.targetID) continue;

    const strideA = Math.max(1, Math.floor(a.geometry.length / 50));
    const strideB = Math.max(1, Math.floor(b.geometry.length / 50));

    let bestDist = Infinity, bestIdxA = 0, bestIdxB = 0;
    let idxA = 1;
    while (idxA < a.geometry.length - 1) {
      const ptA = a.geometry[idxA];
      let idxB = 1;
      while (idxB < b.geometry.length - 1) {
        const ptB = b.geometry[idxB];
        const dLat = ptA[1] - ptB[1];
        const dLon = ptA[0] - ptB[0];
        const approxM = Math.sqrt(dLat * dLat + dLon * dLon) * 111000;
        if (approxM < bestDist) {
          bestDist = approxM;
          bestIdxA = idxA;
          bestIdxB = idxB;
        }
        idxB += strideB;
      }
      idxA += strideA;
    }

    if (bestDist < proximityThreshold * 3) {
      for (let da = -2; da <= 2; da++) {
        for (let db = -2; db <= 2; db++) {
          const ia = Math.max(1, Math.min(a.geometry.length - 2, bestIdxA + da));
          const ib = Math.max(1, Math.min(b.geometry.length - 2, bestIdxB + db));
          const ptA = a.geometry[ia];
          const ptB = b.geometry[ib];
          const dist = haversineMeters(
            { lon: ptA[0], lat: ptA[1] },
            { lon: ptB[0], lat: ptB[1] },
          );
          if (dist < bestDist) {
            bestDist = dist;
            bestIdxA = ia;
            bestIdxB = ib;
          }
        }
      }
    }

    if (bestDist >= proximityThreshold) continue;

    const ptA = a.geometry[bestIdxA];
    const ptB = b.geometry[bestIdxB];
    const midCoord: Coord = [(ptA[0] + ptB[0]) / 2, (ptA[1] + ptB[1]) / 2];

    const eleA = nodes.get(a.sourceID)?.elevation ?? 0;
    const eleAEnd = nodes.get(a.targetID)?.elevation ?? 0;
    const fracA = bestIdxA / Math.max(1, a.geometry.length - 1);
    const midEle = eleA + (eleAEnd - eleA) * fracA;

    intersections.push({
      edgeA: a.id, edgeB: b.id,
      idxA: bestIdxA, idxB: bestIdxB,
      distance: bestDist,
      coordinate: midCoord,
      elevation: midEle,
    });
  }

  if (intersections.length === 0) return edges;

  // Stable sort: by distance asc, then edgeA, then edgeB for ties.
  const sortedAll = [...intersections].sort((x, y) => {
    if (x.distance !== y.distance) return x.distance - y.distance;
    if (x.edgeA !== y.edgeA) return x.edgeA < y.edgeA ? -1 : 1;
    return x.edgeB < y.edgeB ? -1 : 1;
  });
  const grouped: Intersection[] = [];
  const usedCoords: Coord[] = [];
  const groupingRadius = 30.0;
  for (const ix of sortedAll) {
    const tooClose = usedCoords.some((u) =>
      haversineMeters(
        { lon: ix.coordinate[0], lat: ix.coordinate[1] },
        { lon: u[0], lat: u[1] },
      ) < groupingRadius
    );
    if (!tooClose) {
      grouped.push(ix);
      usedCoords.push(ix.coordinate);
    }
  }

  const edgeSplits = new Map<string, Array<{ idx: number; junctionId: string }>>();
  for (const ix of grouped) {
    const junctionId = nodeID({ lat: ix.coordinate[1], lon: ix.coordinate[0] });
    if (!nodes.has(junctionId)) {
      nodes.set(junctionId, {
        id: junctionId,
        coordinate: { lat: ix.coordinate[1], lon: ix.coordinate[0] },
        elevation: ix.elevation,
        kind: "junction",
      });
    }
    let arrA = edgeSplits.get(ix.edgeA);
    if (!arrA) { arrA = []; edgeSplits.set(ix.edgeA, arrA); }
    arrA.push({ idx: ix.idxA, junctionId });
    let arrB = edgeSplits.get(ix.edgeB);
    if (!arrB) { arrB = []; edgeSplits.set(ix.edgeB, arrB); }
    arrB.push({ idx: ix.idxB, junctionId });
  }

  const newEdges: GraphEdge[] = [];
  const removedIds = new Set<string>();
  // Sort edge IDs for determinism
  const edgeIdsSorted = [...edgeSplits.keys()].sort();
  for (const edgeId of edgeIdsSorted) {
    const splits = edgeSplits.get(edgeId)!;
    const edge = edgeIndex.get(edgeId);
    if (!edge) continue;
    if (removedIds.has(edgeId)) continue;
    const sortedSplits = [...splits].sort((a, b) => a.idx - b.idx);

    type SegNode = { id: string; idx: number };
    const segNodes: SegNode[] = [{ id: edge.sourceID, idx: 0 }];
    for (const s of sortedSplits) {
      if (s.junctionId !== edge.sourceID && s.junctionId !== edge.targetID) {
        segNodes.push({ id: s.junctionId, idx: s.idx });
      }
    }
    segNodes.push({ id: edge.targetID, idx: edge.geometry.length - 1 });

    const deduped: SegNode[] = [];
    for (const sn of segNodes) {
      if (deduped[deduped.length - 1]?.id !== sn.id) deduped.push(sn);
    }
    if (deduped.length < 3) continue;

    for (let i = 1; i < deduped.length; i++) {
      const startIdx = deduped[i - 1].idx;
      const endIdx = deduped[i].idx;
      if (endIdx <= startIdx) continue;
      const geom = edge.geometry.slice(startIdx, endIdx + 1);
      const segLength = polylineLength(geom);
      const srcE = nodes.get(deduped[i - 1].id)?.elevation ?? 0;
      const tgtE = nodes.get(deduped[i].id)?.elevation ?? 0;
      const segDrop = Math.abs(srcE - tgtE);
      const segAvgGrad = segLength > 0 ? Math.atan(segDrop / segLength) * 180 / Math.PI : 0;
      newEdges.push({
        id: `${edge.id}_ix${i}`,
        sourceID: deduped[i - 1].id,
        targetID: deduped[i].id,
        kind: edge.kind,
        geometry: geom,
        attributes: makeEdgeAttributes({
          ...edge.attributes,
          lengthMeters: segLength,
          verticalDrop: segDrop,
          averageGradient: segAvgGrad,
          maxGradient: segAvgGrad,
        }),
      });
    }
    removedIds.add(edgeId);
  }

  if (removedIds.size === 0) return edges;
  return [...edges.filter((e) => !removedIds.has(e.id)), ...newEdges];
}

// ── snapNearbyNodes ─────────────────────────────────────────────────

function snapNearbyNodes(
  nodes: Map<string, GraphNode>,
  edges: GraphEdge[],
  threshold: number,
): GraphEdge[] {
  // Sort nodes by id for deterministic pairwise iteration
  const nodeList = [...nodes.values()].sort((a, b) =>
    a.id < b.id ? -1 : a.id > b.id ? 1 : 0
  );
  const mergeMap = new Map<string, string>();

  for (let i = 0; i < nodeList.length; i++) {
    for (let j = i + 1; j < nodeList.length; j++) {
      const a = nodeList[i], b = nodeList[j];
      const dist = haversineMeters(
        { lat: a.coordinate.lat, lon: a.coordinate.lon },
        { lat: b.coordinate.lat, lon: b.coordinate.lon },
      );
      if (dist >= threshold) continue;
      const priI = kindPriority(a.kind);
      const priJ = kindPriority(b.kind);
      let keep: string, remove: string;
      if (priI >= priJ) { keep = a.id; remove = b.id; }
      else              { keep = b.id; remove = a.id; }
      if (!mergeMap.has(remove) && !mergeMap.has(keep)) {
        mergeMap.set(remove, keep);
      }
    }
  }

  const resolvedId = (id: string): string => {
    let current = id;
    const seen = new Set<string>();
    while (mergeMap.has(current) && !seen.has(mergeMap.get(current)!)) {
      seen.add(current);
      current = mergeMap.get(current)!;
    }
    return current;
  };

  // Group: keepId → [removedIds]
  const mergeGroups = new Map<string, string[]>();
  // Sort keys for deterministic iteration
  const removeIds = [...mergeMap.keys()].sort();
  for (const removeID of removeIds) {
    const keepID = mergeMap.get(removeID)!;
    const resolved = resolvedId(keepID);
    let arr = mergeGroups.get(resolved);
    if (!arr) { arr = []; mergeGroups.set(resolved, arr); }
    arr.push(removeID);
  }

  // Move surviving non-lift-station nodes to centroid
  const groupKeys = [...mergeGroups.keys()].sort();
  for (const keepId of groupKeys) {
    const removed = mergeGroups.get(keepId)!;
    const keepNode = nodes.get(keepId);
    if (!keepNode) continue;
    if (kindPriority(keepNode.kind) >= 3) continue;
    let totalLat = keepNode.coordinate.lat;
    let totalLon = keepNode.coordinate.lon;
    let totalEle = keepNode.elevation;
    let count = 1;
    for (const r of removed) {
      const rn = nodes.get(r);
      if (!rn) continue;
      totalLat += rn.coordinate.lat;
      totalLon += rn.coordinate.lon;
      totalEle += rn.elevation;
      count += 1;
    }
    nodes.set(keepId, {
      id: keepId,
      coordinate: { lat: totalLat / count, lon: totalLon / count },
      elevation: totalEle / count,
      kind: keepNode.kind,
    });
  }

  // Rewrite edges through resolvedId
  const rewritten = edges.map((edge) => {
    const newSource = resolvedId(edge.sourceID);
    const newTarget = resolvedId(edge.targetID);
    if (newSource === edge.sourceID && newTarget === edge.targetID) return edge;
    return {
      id: edge.id,
      sourceID: newSource,
      targetID: newTarget,
      kind: edge.kind,
      geometry: edge.geometry,
      attributes: edge.attributes,
    };
  });

  // Drop self-loops
  const filtered = rewritten.filter((e) => e.sourceID !== e.targetID);

  // Drop merged-away nodes
  for (const remove of mergeMap.keys()) nodes.delete(remove);

  return filtered;
}

// ── connectLiftTopsToruns ──────────────────────────────────────────

function connectLiftTopsToruns(
  nodes: Map<string, GraphNode>,
  edges: GraphEdge[],
  maxDistance: number,
): GraphEdge[] {
  const outgoing = new Map<string, GraphEdge[]>();
  for (const edge of edges) {
    let arr = outgoing.get(edge.sourceID);
    if (!arr) { arr = []; outgoing.set(edge.sourceID, arr); }
    arr.push(edge);
  }

  const newEdges: GraphEdge[] = [];

  // Lift tops: must have outgoing run
  const liftTopIds = [...nodes.keys()].filter((id) => nodes.get(id)!.kind === "liftTop").sort();
  const minDescent = 5;
  for (const nodeId of liftTopIds) {
    const node = nodes.get(nodeId)!;
    const outArr = outgoing.get(nodeId) ?? [];
    if (outArr.some((e) => e.kind === "run")) continue;

    let bestTarget: string | null = null;
    let bestDist = Infinity;
    // Sort candidates for determinism
    const candidateIds = [...nodes.keys()].sort();
    for (const candidateId of candidateIds) {
      if (candidateId === nodeId) continue;
      const candidate = nodes.get(candidateId)!;
      const candOut = outgoing.get(candidateId);
      if (!candOut || candOut.length === 0) continue;
      if (node.elevation - candidate.elevation < minDescent) continue;
      const dist = haversineMeters(
        { lat: node.coordinate.lat, lon: node.coordinate.lon },
        { lat: candidate.coordinate.lat, lon: candidate.coordinate.lon },
      );
      if (dist < bestDist && dist < maxDistance) {
        bestDist = dist;
        bestTarget = candidateId;
      }
    }
    if (!bestTarget) continue;
    const target = nodes.get(bestTarget)!;
    const geom: Coord[] = [
      [node.coordinate.lon, node.coordinate.lat],
      [target.coordinate.lon, target.coordinate.lat],
    ];
    newEdges.push({
      id: `lt${nodeId}_${bestTarget}`,
      sourceID: nodeId,
      targetID: bestTarget,
      kind: "traverse",
      geometry: geom,
      attributes: makeEdgeAttributes({
        lengthMeters: bestDist,
        verticalDrop: Math.max(0, target.elevation - node.elevation),
      }),
    });
  }

  // Rebuild incoming after first pass adds
  const updatedEdges = [...edges, ...newEdges];
  const incoming = new Map<string, GraphEdge[]>();
  for (const edge of updatedEdges) {
    let arr = incoming.get(edge.targetID);
    if (!arr) { arr = []; incoming.set(edge.targetID, arr); }
    arr.push(edge);
  }

  const liftBaseNewEdges: GraphEdge[] = [];
  const liftBaseIds = [...nodes.keys()].filter((id) => nodes.get(id)!.kind === "liftBase").sort();
  for (const nodeId of liftBaseIds) {
    const node = nodes.get(nodeId)!;
    const inArr = incoming.get(nodeId) ?? [];
    if (inArr.some((e) => e.kind === "run")) continue;

    let bestSource: string | null = null;
    let bestDist = Infinity;
    const candidateIds = [...nodes.keys()].sort();
    for (const candidateId of candidateIds) {
      if (candidateId === nodeId) continue;
      const candidate = nodes.get(candidateId)!;
      if (candidate.elevation <= node.elevation - 30) continue;
      const dist = haversineMeters(
        { lat: node.coordinate.lat, lon: node.coordinate.lon },
        { lat: candidate.coordinate.lat, lon: candidate.coordinate.lon },
      );
      if (dist < bestDist && dist < maxDistance) {
        bestDist = dist;
        bestSource = candidateId;
      }
    }
    if (!bestSource) continue;
    const sourceNode = nodes.get(bestSource)!;
    const geom: Coord[] = [
      [sourceNode.coordinate.lon, sourceNode.coordinate.lat],
      [node.coordinate.lon, node.coordinate.lat],
    ];
    liftBaseNewEdges.push({
      id: `lb${bestSource}_${nodeId}`,
      sourceID: bestSource,
      targetID: nodeId,
      kind: "traverse",
      geometry: geom,
      attributes: makeEdgeAttributes({
        lengthMeters: bestDist,
        verticalDrop: Math.max(0, node.elevation - sourceNode.elevation),
      }),
    });
  }

  return [...edges, ...newEdges, ...liftBaseNewEdges];
}

// ── generateTraverseEdges ───────────────────────────────────────────

function generateTraverseEdges(
  nodes: Map<string, GraphNode>,
  edges: GraphEdge[],
  threshold: number,
): GraphEdge[] {
  const connectedPairs = new Set<string>();
  for (const edge of edges) {
    connectedPairs.add(`${edge.sourceID}->${edge.targetID}`);
    connectedPairs.add(`${edge.targetID}->${edge.sourceID}`);
  }

  const cellSize = 0.001;
  const grid = new Map<string, GraphNode[]>();
  // Use sorted node iteration for deterministic grid bucket order
  const allNodeIds = [...nodes.keys()].sort();
  for (const id of allNodeIds) {
    const node = nodes.get(id)!;
    const cellKey = `${Math.floor(node.coordinate.lat / cellSize)}_${Math.floor(node.coordinate.lon / cellSize)}`;
    let arr = grid.get(cellKey);
    if (!arr) { arr = []; grid.set(cellKey, arr); }
    arr.push(node);
  }

  const newEdges: GraphEdge[] = [];
  for (const id of allNodeIds) {
    const node = nodes.get(id)!;
    const cellLat = Math.floor(node.coordinate.lat / cellSize);
    const cellLon = Math.floor(node.coordinate.lon / cellSize);
    for (let dLat = -1; dLat <= 1; dLat++) {
      for (let dLon = -1; dLon <= 1; dLon++) {
        const neighborKey = `${cellLat + dLat}_${cellLon + dLon}`;
        const neighbors = grid.get(neighborKey);
        if (!neighbors) continue;
        // Sort neighbors for determinism
        const neighborsSorted = [...neighbors].sort((a, b) =>
          a.id < b.id ? -1 : a.id > b.id ? 1 : 0
        );
        for (const neighbor of neighborsSorted) {
          if (neighbor.id === node.id) continue;
          const pairKey = `${node.id}->${neighbor.id}`;
          if (connectedPairs.has(pairKey)) continue;
          const dist = haversineMeters(
            { lat: node.coordinate.lat, lon: node.coordinate.lon },
            { lat: neighbor.coordinate.lat, lon: neighbor.coordinate.lon },
          );
          if (dist >= threshold) continue;
          const elevGain_AB = neighbor.elevation - node.elevation;
          const elevGain_BA = node.elevation - neighbor.elevation;
          const absGain = Math.abs(elevGain_AB);
          const geom: Coord[] = [
            [node.coordinate.lon, node.coordinate.lat],
            [neighbor.coordinate.lon, neighbor.coordinate.lat],
          ];

          const bidirectional = absGain <= BIDIRECTIONAL_TRAVERSE_GAIN;
          const withinCap = absGain <= MAX_TRAVERSE_ELEVATION_GAIN;

          if (bidirectional) {
            newEdges.push({
              id: `x${node.id}_${neighbor.id}`,
              sourceID: node.id,
              targetID: neighbor.id,
              kind: "traverse",
              geometry: geom,
              attributes: makeEdgeAttributes({
                lengthMeters: dist,
                verticalDrop: Math.max(0, elevGain_AB),
              }),
            });
            newEdges.push({
              id: `x${neighbor.id}_${node.id}`,
              sourceID: neighbor.id,
              targetID: node.id,
              kind: "traverse",
              geometry: [...geom].reverse(),
              attributes: makeEdgeAttributes({
                lengthMeters: dist,
                verticalDrop: Math.max(0, elevGain_BA),
              }),
            });
            connectedPairs.add(`${node.id}->${neighbor.id}`);
            connectedPairs.add(`${neighbor.id}->${node.id}`);
          } else if (withinCap) {
            if (elevGain_AB < 0) {
              newEdges.push({
                id: `x${node.id}_${neighbor.id}`,
                sourceID: node.id,
                targetID: neighbor.id,
                kind: "traverse",
                geometry: geom,
                attributes: makeEdgeAttributes({ lengthMeters: dist, verticalDrop: 0 }),
              });
              connectedPairs.add(`${node.id}->${neighbor.id}`);
            } else {
              newEdges.push({
                id: `x${neighbor.id}_${node.id}`,
                sourceID: neighbor.id,
                targetID: node.id,
                kind: "traverse",
                geometry: [...geom].reverse(),
                attributes: makeEdgeAttributes({ lengthMeters: dist, verticalDrop: 0 }),
              });
              connectedPairs.add(`${neighbor.id}->${node.id}`);
            }
          }
        }
      }
    }
  }
  return [...edges, ...newEdges];
}

// ── bridgeDisconnectedComponents ────────────────────────────────────

function findComponents(
  nodes: Map<string, GraphNode>,
  edges: GraphEdge[],
): string[][] {
  const adj = new Map<string, string[]>();
  for (const edge of edges) {
    let a = adj.get(edge.sourceID);
    if (!a) { a = []; adj.set(edge.sourceID, a); }
    a.push(edge.targetID);
    let b = adj.get(edge.targetID);
    if (!b) { b = []; adj.set(edge.targetID, b); }
    b.push(edge.sourceID);
  }
  const visited = new Set<string>();
  const components: string[][] = [];
  // Sort node ids for deterministic component ordering
  const sortedIds = [...nodes.keys()].sort();
  for (const startId of sortedIds) {
    if (visited.has(startId)) continue;
    const component: string[] = [];
    const queue: string[] = [startId];
    visited.add(startId);
    while (queue.length > 0) {
      const current = queue.shift()!;
      component.push(current);
      const neighbors = adj.get(current) ?? [];
      // Sort neighbors for determinism
      const sortedNeighbors = [...neighbors].sort();
      for (const n of sortedNeighbors) {
        if (visited.has(n)) continue;
        visited.add(n);
        queue.push(n);
      }
    }
    components.push(component);
  }
  return components;
}

function bridgeDisconnectedComponents(
  nodes: Map<string, GraphNode>,
  edges: GraphEdge[],
): GraphEdge[] {
  let working = [...edges];
  let iteration = 0;
  while (true) {
    const components = findComponents(nodes, working);
    if (components.length <= 1) return working;

    // Sort by size desc, then by min id asc for stable tie-break
    const sortedComps = [...components].sort((a, b) => {
      if (a.length !== b.length) return b.length - a.length;
      const minA = a.reduce((m, x) => m < x ? m : x);
      const minB = b.reduce((m, x) => m < x ? m : x);
      return minA < minB ? -1 : 1;
    });
    const mainSet = new Set(sortedComps[0]);

    for (const component of sortedComps.slice(1)) {
      let bestDist = Infinity;
      let bestA: string | null = null;
      let bestB: string | null = null;
      // Sort component members for deterministic search
      const componentSorted = [...component].sort();
      const mainSorted = [...mainSet].sort();
      for (const aId of componentSorted) {
        const a = nodes.get(aId);
        if (!a) continue;
        for (const bId of mainSorted) {
          const b = nodes.get(bId);
          if (!b) continue;
          const dist = haversineMeters(
            { lat: a.coordinate.lat, lon: a.coordinate.lon },
            { lat: b.coordinate.lat, lon: b.coordinate.lon },
          );
          if (dist < bestDist) {
            bestDist = dist;
            bestA = aId;
            bestB = bId;
          }
        }
      }
      if (!bestA || !bestB) continue;
      const nodeA = nodes.get(bestA)!;
      const nodeB = nodes.get(bestB)!;
      const geom: Coord[] = [
        [nodeA.coordinate.lon, nodeA.coordinate.lat],
        [nodeB.coordinate.lon, nodeB.coordinate.lat],
      ];
      const elevGain_AB = nodeB.elevation - nodeA.elevation;
      const elevGain_BA = nodeA.elevation - nodeB.elevation;
      const absGain = Math.abs(elevGain_AB);
      if (absGain <= BIDIRECTIONAL_TRAVERSE_GAIN) {
        working.push({
          id: `b${bestA}_${bestB}`,
          sourceID: bestA, targetID: bestB,
          kind: "traverse", geometry: geom,
          attributes: makeEdgeAttributes({ lengthMeters: bestDist, verticalDrop: Math.max(0, elevGain_AB) }),
        });
        working.push({
          id: `b${bestB}_${bestA}`,
          sourceID: bestB, targetID: bestA,
          kind: "traverse", geometry: [...geom].reverse(),
          attributes: makeEdgeAttributes({ lengthMeters: bestDist, verticalDrop: Math.max(0, elevGain_BA) }),
        });
      } else if (absGain <= MAX_TRAVERSE_ELEVATION_GAIN) {
        if (nodeA.elevation >= nodeB.elevation) {
          working.push({
            id: `b${bestA}_${bestB}`, sourceID: bestA, targetID: bestB,
            kind: "traverse", geometry: geom,
            attributes: makeEdgeAttributes({ lengthMeters: bestDist, verticalDrop: 0 }),
          });
        } else {
          working.push({
            id: `b${bestB}_${bestA}`, sourceID: bestB, targetID: bestA,
            kind: "traverse", geometry: [...geom].reverse(),
            attributes: makeEdgeAttributes({ lengthMeters: bestDist, verticalDrop: 0 }),
          });
        }
      } else {
        if (nodeA.elevation >= nodeB.elevation) {
          working.push({
            id: `b${bestA}_${bestB}`, sourceID: bestA, targetID: bestB,
            kind: "traverse", geometry: geom,
            attributes: makeEdgeAttributes({ lengthMeters: bestDist, verticalDrop: 0 }),
          });
        } else {
          working.push({
            id: `b${bestB}_${bestA}`, sourceID: bestB, targetID: bestA,
            kind: "traverse", geometry: [...geom].reverse(),
            attributes: makeEdgeAttributes({ lengthMeters: bestDist, verticalDrop: 0 }),
          });
        }
      }
    }

    iteration++;
    if (iteration > 50) return working;
  }
}

// ── ensureLiftReachability ──────────────────────────────────────────

function ensureLiftReachability(
  nodes: Map<string, GraphNode>,
  edges: GraphEdge[],
): GraphEdge[] {
  const outgoing = new Map<string, GraphEdge[]>();
  for (const edge of edges) {
    let arr = outgoing.get(edge.sourceID);
    if (!arr) { arr = []; outgoing.set(edge.sourceID, arr); }
    arr.push(edge);
  }
  const liftBaseIds = new Set<string>();
  for (const [id, n] of nodes) if (n.kind === "liftBase") liftBaseIds.add(id);
  if (liftBaseIds.size === 0) return edges;

  const maxHops = 8;
  const stranded: string[] = [];
  const sortedNodeIds = [...nodes.keys()].sort();
  for (const nodeId of sortedNodeIds) {
    const out = outgoing.get(nodeId);
    if (!out || out.length === 0) continue;
    const visited = new Set<string>([nodeId]);
    const queue: Array<[string, number]> = [[nodeId, 0]];
    let foundLift = false;
    while (queue.length > 0 && !foundLift) {
      const [current, depth] = queue.shift()!;
      if (liftBaseIds.has(current)) { foundLift = true; break; }
      if (depth >= maxHops) continue;
      const outEdges = outgoing.get(current) ?? [];
      // Sort for deterministic BFS order
      const sortedOut = [...outEdges].sort((a, b) =>
        a.targetID < b.targetID ? -1 : a.targetID > b.targetID ? 1 : 0
      );
      for (const e of sortedOut) {
        if (visited.has(e.targetID)) continue;
        visited.add(e.targetID);
        queue.push([e.targetID, depth + 1]);
      }
    }
    if (!foundLift) stranded.push(nodeId);
  }

  if (stranded.length === 0) return edges;

  const newEdges: GraphEdge[] = [];
  const sortedLiftBases = [...liftBaseIds].sort();
  for (const nodeId of stranded) {
    const node = nodes.get(nodeId);
    if (!node) continue;
    let bestDist = Infinity;
    let bestId: string | null = null;
    for (const lbId of sortedLiftBases) {
      const lb = nodes.get(lbId);
      if (!lb) continue;
      const d = haversineMeters(
        { lat: node.coordinate.lat, lon: node.coordinate.lon },
        { lat: lb.coordinate.lat, lon: lb.coordinate.lon },
      );
      if (d < bestDist) { bestDist = d; bestId = lbId; }
    }
    if (!bestId || bestDist >= 2000) continue;
    const target = nodes.get(bestId)!;
    const geom: Coord[] = [
      [node.coordinate.lon, node.coordinate.lat],
      [target.coordinate.lon, target.coordinate.lat],
    ];
    newEdges.push({
      id: `lr${nodeId}_${bestId}`,
      sourceID: nodeId, targetID: bestId,
      kind: "traverse", geometry: geom,
      attributes: makeEdgeAttributes({
        lengthMeters: bestDist,
        verticalDrop: Math.max(0, target.elevation - node.elevation),
      }),
    });
  }
  return [...edges, ...newEdges];
}

// ── pruneIsolatedNodes ──────────────────────────────────────────────

function pruneIsolatedNodes(
  nodes: Map<string, GraphNode>,
  edges: GraphEdge[],
): { edges: GraphEdge[] } {
  const edgeCount = new Map<string, number>();
  for (const edge of edges) {
    edgeCount.set(edge.sourceID, (edgeCount.get(edge.sourceID) ?? 0) + 1);
    edgeCount.set(edge.targetID, (edgeCount.get(edge.targetID) ?? 0) + 1);
  }
  const namedNodeIds = new Set<string>();
  for (const e of edges) {
    if (e.attributes.trailName != null) {
      namedNodeIds.add(e.sourceID);
      namedNodeIds.add(e.targetID);
    }
  }
  const pruneIds = new Set<string>();
  for (const id of nodes.keys()) {
    const count = edgeCount.get(id) ?? 0;
    if (count <= 1 && !namedNodeIds.has(id)) pruneIds.add(id);
  }
  if (pruneIds.size === 0) return { edges };
  for (const id of pruneIds) nodes.delete(id);
  return {
    edges: edges.filter((e) => !pruneIds.has(e.sourceID) && !pruneIds.has(e.targetID)),
  };
}

// ── assignTrailGroups ───────────────────────────────────────────────

function normalizedTrailKey(name: string): string {
  // Swift's folding(.caseInsensitive, .diacriticInsensitive, .widthInsensitive)
  // → JS: NFKD normalize, strip combining marks, lowercase, replace non-alnum with spaces.
  const folded = name.normalize("NFKD").replace(/\p{M}/gu, "").toLowerCase();
  let collapsed = "";
  for (const ch of folded) {
    if (/[\p{L}\p{N}]/u.test(ch)) collapsed += ch;
    else collapsed += " ";
  }
  return collapsed.split(/\s+/).filter((s) => s.length > 0).join(" ");
}

function assignTrailGroups(
  edges: GraphEdge[],
  hints: ResortGraphBuildHints | undefined,
): GraphEdge[] {
  const mergeNamedTraverses = hints?.mergeNamedTraverseGroups ?? true;
  // Build index: key → [edge indices]. Sorted iteration on key.
  const keyToIndices = new Map<string, number[]>();
  for (let i = 0; i < edges.length; i++) {
    const edge = edges[i];
    const name = edge.attributes.trailName;
    if (!name) continue;
    const lower = name.toLowerCase().trim();
    if (lower.startsWith("unnamed")) continue;
    let key: string | null = null;
    if (edge.kind === "run" || edge.kind === "lift") {
      const normName = normalizedTrailKey(name);
      const diffKey = edge.attributes.difficulty ?? "none";
      key = `${normName}|${diffKey}`;
    } else if (edge.kind === "traverse" && mergeNamedTraverses) {
      const normName = normalizedTrailKey(name);
      key = `${normName}|traverse`;
    }
    if (!key) continue;
    let arr = keyToIndices.get(key);
    if (!arr) { arr = []; keyToIndices.set(key, arr); }
    arr.push(i);
  }

  let groupCounter = 0;
  const out = [...edges];

  // Sort keys for deterministic group counter assignment
  const sortedKeys = [...keyToIndices.keys()].sort();
  for (const key of sortedKeys) {
    const indices = keyToIndices.get(key)!;
    if (indices.length === 0) continue;
    if (indices.length === 1) {
      const idx = indices[0];
      const attrs = { ...out[idx].attributes, trailGroupId: `tg${groupCounter}` };
      out[idx] = { ...out[idx], attributes: attrs };
      groupCounter++;
      continue;
    }
    // Union-find
    const parent = indices.map((_, i) => i);
    const find = (x: number): number => {
      let cur = x;
      while (parent[cur] !== cur) {
        parent[cur] = parent[parent[cur]];
        cur = parent[cur];
      }
      return cur;
    };
    const union = (a: number, b: number) => {
      const ra = find(a), rb = find(b);
      if (ra !== rb) parent[ra] = rb;
    };
    const nodeToLocal = new Map<string, number[]>();
    for (let localIdx = 0; localIdx < indices.length; localIdx++) {
      const e = out[indices[localIdx]];
      let s = nodeToLocal.get(e.sourceID);
      if (!s) { s = []; nodeToLocal.set(e.sourceID, s); }
      s.push(localIdx);
      let t = nodeToLocal.get(e.targetID);
      if (!t) { t = []; nodeToLocal.set(e.targetID, t); }
      t.push(localIdx);
    }
    // Sort node keys for deterministic union order
    const nodeKeysSorted = [...nodeToLocal.keys()].sort();
    for (const nk of nodeKeysSorted) {
      const locals = nodeToLocal.get(nk)!;
      for (let j = 1; j < locals.length; j++) union(locals[0], locals[j]);
    }
    const componentEdges = new Map<number, number[]>();
    for (let localIdx = 0; localIdx < indices.length; localIdx++) {
      const root = find(localIdx);
      let arr = componentEdges.get(root);
      if (!arr) { arr = []; componentEdges.set(root, arr); }
      arr.push(indices[localIdx]);
    }
    // Sort root keys for determinism
    const sortedRoots = [...componentEdges.keys()].sort((a, b) => a - b);
    for (const root of sortedRoots) {
      const edgeIndices = componentEdges.get(root)!;
      const gid = `tg${groupCounter}`;
      for (const idx of edgeIndices) {
        out[idx] = {
          ...out[idx],
          attributes: { ...out[idx].attributes, trailGroupId: gid },
        };
      }
      groupCounter++;
    }
  }

  // Ungrouped runs and lifts get individual ids
  for (let i = 0; i < out.length; i++) {
    if (out[i].attributes.trailGroupId != null) continue;
    if (out[i].kind !== "run" && out[i].kind !== "lift") continue;
    out[i] = {
      ...out[i],
      attributes: { ...out[i].attributes, trailGroupId: `tg${groupCounter}` },
    };
    groupCounter++;
  }

  // Unnamed traverse component grouping
  return mergeUnnamedTraverseChainComponents(out, groupCounter);
}

function mergeUnnamedTraverseChainComponents(
  edges: GraphEdge[],
  initialCounter: number,
): GraphEdge[] {
  let groupCounter = initialCounter;
  const pending: number[] = [];
  for (let i = 0; i < edges.length; i++) {
    if (edges[i].kind === "traverse" && edges[i].attributes.trailGroupId == null) {
      pending.push(i);
    }
  }
  if (pending.length === 0) return edges;

  const parent = new Map<number, number>();
  for (const i of pending) parent.set(i, i);
  const find = (x: number): number => {
    let cur = x;
    while (parent.get(cur)! !== cur) {
      parent.set(cur, parent.get(parent.get(cur)!)!);
      cur = parent.get(cur)!;
    }
    return cur;
  };
  const union = (a: number, b: number) => {
    const ra = find(a), rb = find(b);
    if (ra !== rb) parent.set(ra, rb);
  };

  const nodeToIdx = new Map<string, number[]>();
  for (const i of pending) {
    const e = edges[i];
    let s = nodeToIdx.get(e.sourceID);
    if (!s) { s = []; nodeToIdx.set(e.sourceID, s); }
    s.push(i);
    let t = nodeToIdx.get(e.targetID);
    if (!t) { t = []; nodeToIdx.set(e.targetID, t); }
    t.push(i);
  }
  const nodeKeysSorted = [...nodeToIdx.keys()].sort();
  for (const nk of nodeKeysSorted) {
    const arr = nodeToIdx.get(nk)!;
    for (let j = 1; j < arr.length; j++) union(arr[0], arr[j]);
  }

  const components = new Map<number, number[]>();
  for (const i of pending) {
    const root = find(i);
    let arr = components.get(root);
    if (!arr) { arr = []; components.set(root, arr); }
    arr.push(i);
  }
  const sortedRoots = [...components.keys()].sort((a, b) => a - b);
  const out = [...edges];
  for (const root of sortedRoots) {
    const idxs = components.get(root)!;
    const gid = `tg${groupCounter}`;
    groupCounter++;
    for (const idx of idxs) {
      out[idx] = {
        ...out[idx],
        attributes: { ...out[idx].attributes, trailGroupId: gid },
      };
    }
  }
  return out;
}

// ── computeFingerprint ──────────────────────────────────────────────

/**
 * Matches MountainGraph.computeFingerprint (Swift):
 *  - 0.01 quantization on doubles
 *  - 3-state isGroomed mix (true=2, false=1, null=0)
 *  - difficulty.sortOrder (green=0, blue=1, black=2, doubleBlack=3, terrainPark=4)
 *  - mix sequence per edge: id, isOpen, difficulty, hasMoguls, isGladed,
 *    isGroomed, waitTimeMinutes, rideTimeSeconds, maxGradient, liftCapacity
 *  - final format: "<nodeCount>:<edgeCount>:<hex16>"
 *
 * Determinism note: Swift iterates `for e in edges` over an Array which
 * preserves insertion order. We sort by id before fingerprinting so the
 * TS output is stable across runs even if edge insertion order shifts.
 */
function computeFingerprint(
  nodes: Record<string, GraphNode>,
  edges: GraphEdge[],
): string {
  // 64-bit checksum via BigInt to match Swift's UInt64 wrapping arithmetic.
  let checksum = 0n;
  const MASK = (1n << 64n) - 1n;
  const mix = (v: bigint) => {
    checksum = ((checksum * 31n) + v) & MASK;
  };
  const mixString = (s: string) => {
    for (const b of new TextEncoder().encode(s)) mix(BigInt(b));
  };
  const mixDouble = (d: number | null | undefined) => {
    if (d == null) {
      mix(0xFFFFFFFFFFFFFFFFn);
      return;
    }
    // Quantize × 100 then round, store as signed-Int64 bit pattern
    const rounded = BigInt(Math.round(d * 100));
    // Convert signed to UInt64 bit pattern
    mix(rounded < 0n ? (rounded + (1n << 64n)) & MASK : rounded);
  };

  const sortedEdges = [...edges].sort((a, b) =>
    a.id < b.id ? -1 : a.id > b.id ? 1 : 0
  );

  const sortOrder: Record<string, number> = {
    green: 0, blue: 1, black: 2, doubleBlack: 3, terrainPark: 4,
  };

  for (const e of sortedEdges) {
    mixString(e.id);
    const a = e.attributes;
    mix(a.isOpen ? 1n : 0n);
    const diffSort = a.difficulty != null
      ? BigInt(sortOrder[a.difficulty] ?? -1)
      : -1n;
    mix(diffSort < 0n ? ((diffSort + (1n << 64n)) & 0xFFn) : diffSort & 0xFFn);
    mix(a.hasMoguls ? 1n : 0n);
    mix(a.isGladed ? 1n : 0n);
    if (a.isGroomed === true) mix(2n);
    else if (a.isGroomed === false) mix(1n);
    else mix(0n);
    mixDouble(a.waitTimeMinutes);
    mixDouble(a.rideTimeSeconds);
    mixDouble(a.maxGradient);
    if (a.liftCapacity != null) mix(BigInt(a.liftCapacity) & 0xFFFFn);
    else mix(0xFFFFn); // -1 & 0xFFFF
  }

  const hex16 = checksum.toString(16).padStart(16, "0").slice(-16);
  const nodeCount = Object.keys(nodes).length;
  return `${nodeCount}:${edges.length}:${hex16}`;
}
