import type {
  MountainGraph,
  RendezvousCatalogWire,
  RendezvousKind,
  RendezvousPointWire,
} from "./graph_types.ts";

export interface CanonicalRendezvousRow {
  anchor_osm_node_id: string | number;
  kind: string;
  display_name: string;
  confidence: number;
  quality: number;
}

export interface RendezvousOverlayFailure {
  anchor: string;
  detail: string;
}

/**
 * Produces the explicit stopping-point contract embedded in every new graph
 * blob. This intentionally excludes arbitrary junctions, trail heads/ends,
 * and lift tops: reachability does not make a place safe or recognizable to
 * wait. Operator-curated lodges/patrol/meeting zones can be layered onto this
 * contract later without changing solver semantics.
 */
export function buildRendezvousCatalog(
  graph: MountainGraph,
): RendezvousCatalogWire {
  const incident = new Map<string, typeof graph.edges>();
  for (const edge of graph.edges) {
    const source = incident.get(edge.sourceID) ?? [];
    source.push(edge);
    incident.set(edge.sourceID, source);
    const target = incident.get(edge.targetID) ?? [];
    target.push(edge);
    incident.set(edge.targetID, target);
  }

  const points: RendezvousPointWire[] = [];
  for (
    const node of Object.values(graph.nodes).sort((a, b) =>
      a.id.localeCompare(b.id)
    )
  ) {
    if (node.kind !== "liftBase" && node.kind !== "midStation") continue;
    const edges = incident.get(node.id) ?? [];
    if (edges.length === 0) continue;

    const officialCount = edges.filter((edge) =>
      edge.attributes.isOfficiallyValidated
    ).length;
    const officialRatio = officialCount / edges.length;
    const baseQuality = node.kind === "liftBase" ? 0.85 : 0.75;
    const names = edges
      .map((edge) => edge.attributes.trailName?.trim() ?? "")
      .filter((name) => name.length > 0)
      .sort((a, b) => a.localeCompare(b));
    const liftNames = edges
      .filter((edge) => edge.kind === "lift")
      .map((edge) => edge.attributes.trailName?.trim() ?? "")
      .filter((name) => name.length > 0)
      .sort((a, b) => a.localeCompare(b));
    const preferredName = liftNames[0] ?? names[0] ?? null;
    const suffix = node.kind === "liftBase" ? "Base" : "Mid-Station";
    const alreadyHasSuffix = preferredName != null && new RegExp(
      `(?:\\s|·|-)${suffix.replace("-", "[- ]?")}$`,
      "i",
    ).test(preferredName);
    const displayName = preferredName == null
      ? null
      : alreadyHasSuffix
      ? preferredName
      : `${preferredName} ${suffix}`;

    points.push({
      id: node.id,
      nodeID: node.id,
      kind: node.kind,
      displayName,
      confidence: 0.8 + Math.min(0.15, officialRatio * 0.15),
      quality: Math.min(1, baseQuality + Math.min(0.1, edges.length * 0.015)),
    });
  }
  return { points };
}

/** Applies reviewed landmark copy/types without weakening safe anchor rules. */
export function overlayCuratedRendezvous(
  graph: MountainGraph,
  catalog: RendezvousCatalogWire,
  rows: CanonicalRendezvousRow[],
): { catalog: RendezvousCatalogWire; failures: RendezvousOverlayFailure[] } {
  const pointsByNode = new Map(
    catalog.points.map((point) => [point.nodeID, point]),
  );
  const failures: RendezvousOverlayFailure[] = [];
  const seen = new Set<string>();
  const allowedKinds = new Set<RendezvousKind>([
    "liftBase",
    "midStation",
    "signedMeetingArea",
    "lodge",
    "patrol",
  ]);

  for (
    const row of [...rows].sort((a, b) =>
      String(a.anchor_osm_node_id).localeCompare(String(b.anchor_osm_node_id))
    )
  ) {
    const anchor = String(row.anchor_osm_node_id).trim();
    const nodeID = `src:${anchor}`;
    const node = graph.nodes[nodeID];
    const kind = row.kind as RendezvousKind;
    const displayName = row.display_name?.trim() ?? "";
    const compatible = node?.kind === "liftBase" || node?.kind === "midStation";
    const connected = graph.edges.some((edge) =>
      edge.sourceID === nodeID || edge.targetID === nodeID
    );
    const exactKindCompatible = kind === "liftBase"
      ? node?.kind === "liftBase"
      : kind === "midStation"
      ? node?.kind === "midStation"
      : compatible;

    if (!/^\d+$/.test(anchor)) {
      failures.push({ anchor, detail: "anchor_osm_node_id must be numeric" });
    } else if (!seen.add(nodeID)) {
      failures.push({ anchor, detail: "duplicate rendezvous anchor" });
    } else if (node == null) {
      failures.push({ anchor, detail: `graph node ${nodeID} does not exist` });
    } else if (!connected) {
      failures.push({ anchor, detail: `graph node ${nodeID} is disconnected` });
    } else if (!allowedKinds.has(kind)) {
      failures.push({
        anchor,
        detail: `unsupported rendezvous kind ${row.kind}`,
      });
    } else if (!exactKindCompatible) {
      failures.push({
        anchor,
        detail: `${kind} is incompatible with graph node kind ${node.kind}`,
      });
    } else if (displayName.length === 0 || displayName.length > 80) {
      failures.push({
        anchor,
        detail: "display_name must contain 1...80 characters",
      });
    } else if (
      !Number.isFinite(row.confidence) || row.confidence < 0 ||
      row.confidence > 1 ||
      !Number.isFinite(row.quality) || row.quality < 0 || row.quality > 1
    ) {
      failures.push({
        anchor,
        detail: "confidence and quality must be within 0...1",
      });
    } else {
      pointsByNode.set(nodeID, {
        id: nodeID,
        nodeID,
        kind,
        displayName,
        confidence: row.confidence,
        quality: row.quality,
      });
    }
  }

  return {
    catalog: {
      points: [...pointsByNode.values()].sort((a, b) =>
        a.id.localeCompare(b.id)
      ),
    },
    failures,
  };
}
