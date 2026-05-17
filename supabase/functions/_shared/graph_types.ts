// Graph types: TS mirror of Swift's MountainGraph / GraphNode /
// GraphEdge / EdgeAttributes for use in the build-resort-graph
// pipeline. The wire format (JSON encode) MUST match Swift's Codable
// shape exactly so the client decodes the blob without translation.
//
// Swift source: PowderMeet/Models/MountainGraph.swift
//
// Encoding contract (matches Swift CodingKeys):
//   GraphNode  → { id, lat, lon, elevation, kind }
//   GraphEdge  → { id, sourceID, targetID, kind, geometryPairs: [[lon,lat],...], attributes }
//
// Therefore, when serializing for the blob, geometry must be encoded
// as `geometryPairs` (lon, lat) pairs, NOT as objects. The TS port
// keeps geometry as a Coord[] tuple internally for ergonomics and
// converts to wire format at the very end.

export type Coord = [number, number]; // [lon, lat]

export type NodeKind =
  | "liftBase"
  | "liftTop"
  | "junction"
  | "trailHead"
  | "trailEnd"
  | "midStation";

export type EdgeKind = "run" | "lift" | "traverse";

export type RunDifficulty =
  | "green"
  | "blue"
  | "black"
  | "doubleBlack"
  | "terrainPark";

export type LiftType =
  | "chairlift"
  | "gondola"
  | "funicular"
  | "tBar"
  | "platter"
  | "magicCarpet"
  | "rope"
  | "cableCar";

export interface GraphNode {
  id: string;
  // Internal: keep as object; encode flattens to lat/lon at wire time.
  coordinate: { lat: number; lon: number };
  elevation: number; // meters
  kind: NodeKind;
}

export interface EdgeAttributes {
  difficulty: RunDifficulty | null;
  lengthMeters: number;
  verticalDrop: number;
  averageGradient: number;
  maxGradient: number;
  aspect: number | null;
  aspectVariance: number;
  trailName: string | null;

  hasMoguls: boolean;
  isGroomed: boolean | null;     // tri-state
  isGladed: boolean;

  liftType: LiftType | null;
  liftCapacity: number | null;
  rideTimeSeconds: number | null;
  waitTimeMinutes: number | null;

  isOpen: boolean;
  isOfficiallyValidated: boolean;

  estimatedTrailWidthMeters: number | null;
  obstacleDensity: number | null;
  fallLineExposure: number | null;
  nightGroomedFlag: boolean;
  lastGroomedHoursAgo: number | null;
  estimatedSurfaceCondition: string | null;

  trailGroupId: string | null;
  midpointElevation: number | null;
}

export interface GraphEdge {
  id: string;
  sourceID: string;
  targetID: string;
  kind: EdgeKind;
  geometry: Coord[];  // internal repr; encoded as geometryPairs
  attributes: EdgeAttributes;
}

export interface MountainGraph {
  resortID: string;
  nodes: Record<string, GraphNode>;
  edges: GraphEdge[];
  fingerprint: string;
}

// ── Wire encoding (JSON) ────────────────────────────────────────────

export interface GraphNodeWire {
  id: string;
  lat: number;
  lon: number;
  elevation: number;
  kind: NodeKind;
}

export interface GraphEdgeWire {
  id: string;
  sourceID: string;
  targetID: string;
  kind: EdgeKind;
  geometryPairs: number[][];   // [[lon, lat], ...]
  attributes: EdgeAttributes;
}

export interface MountainGraphWire {
  resortID: string;
  nodes: Record<string, GraphNodeWire>;
  edges: GraphEdgeWire[];
  fingerprint: string;
}

export function encodeGraph(g: MountainGraph): MountainGraphWire {
  const nodes: Record<string, GraphNodeWire> = {};
  for (const [id, n] of Object.entries(g.nodes)) {
    nodes[id] = {
      id: n.id,
      lat: n.coordinate.lat,
      lon: n.coordinate.lon,
      elevation: n.elevation,
      kind: n.kind,
    };
  }
  return {
    resortID: g.resortID,
    nodes,
    edges: g.edges.map((e) => ({
      id: e.id,
      sourceID: e.sourceID,
      targetID: e.targetID,
      kind: e.kind,
      geometryPairs: e.geometry.map((c) => [c[0], c[1]]),
      attributes: e.attributes,
    })),
    fingerprint: g.fingerprint,
  };
}
