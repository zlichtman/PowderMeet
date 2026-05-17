// Curated overlay (TS port of CuratedResortData.applyOverlay).
//
// Source: PowderMeet/Services/CuratedResortData.swift:138-300 + the
// match-by-osm-way-id-then-name logic in stripEdgeIdToOSMId.
//
// Behavior contract — must match Swift exactly:
//   1. Strip GraphBuilder edge prefix ("t" / "l") and split suffixes
//      ("_s1", "_ix2") to recover raw OSM way IDs.
//   2. For each run edge: try osmWayIds[edgeId] → osmWayIds[rawId] →
//      trailsByName[lowercased(trailName)]. First match wins.
//   3. For each lift edge: same lookup against lift maps.
//   4. Apply overrides only when present (?? semantics).
//   5. Whitelist enforcement: any edge whose lowercased(trimmed) name
//      matches a member of `trailWhitelist` / `liftWhitelist` gets
//      `isOfficiallyValidated = true`. Edges NOT in the whitelist
//      remain `false` (ResortDataEnricher's phantom-trail closure
//      then marks them isOpen=false).
//
// IMPORTANT: caller MUST rebuild graph indices after invoking
// applyCuratedOverlay (mirroring ResortDataManager.loadResort which
// calls one final rebuildIndices() after all overlay+enrichment passes).

import type {
  CanonicalLift,
  CanonicalTrail,
} from "./types.ts";
import type { GraphEdge, MountainGraph } from "./graph_types.ts";

// ── Public API ──────────────────────────────────────────────────────

export interface CuratedOverlayInput {
  trails: CanonicalTrail[];
  lifts: CanonicalLift[];
  trailWhitelist: string[];
  liftWhitelist: string[];
}

export function applyCuratedOverlay(
  graph: MountainGraph,
  curated: CuratedOverlayInput,
): MountainGraph {
  const trailsByName = byName(curated.trails);
  const trailsByOSM = byOSM(curated.trails);
  const liftsByName = byName(curated.lifts);
  const liftsByOSM = byOSM(curated.lifts);

  for (let i = 0; i < graph.edges.length; i++) {
    const edge = graph.edges[i];
    const rawOSMId = stripEdgeIdToOSMId(edge.id);

    if (edge.kind === "run") {
      const ct =
        trailsByOSM.get(edge.id) ??
        trailsByOSM.get(rawOSMId) ??
        (edge.attributes.trailName != null
          ? trailsByName.get(edge.attributes.trailName.toLowerCase())
          : undefined);
      if (!ct) continue;

      const difficulty = (ct.difficulty as any) ?? edge.attributes.difficulty;
      graph.edges[i] = {
        ...edge,
        attributes: {
          ...edge.attributes,
          difficulty: difficulty as any,
          lengthMeters: ct.length_m ?? edge.attributes.lengthMeters,
          verticalDrop: ct.vert_m ?? edge.attributes.verticalDrop,
          trailName: ct.name,
          hasMoguls: ct.has_moguls ?? edge.attributes.hasMoguls,
          isGroomed: ct.is_groomed ?? edge.attributes.isGroomed,
          isGladed: ct.is_gladed ?? edge.attributes.isGladed,
        },
      };
    } else if (edge.kind === "lift") {
      const cl =
        liftsByOSM.get(edge.id) ??
        liftsByOSM.get(rawOSMId) ??
        (edge.attributes.trailName != null
          ? liftsByName.get(edge.attributes.trailName.toLowerCase())
          : undefined);
      if (!cl) continue;

      graph.edges[i] = {
        ...edge,
        attributes: {
          ...edge.attributes,
          // Mirror Swift: lift edges have run-attributes zeroed
          difficulty: edge.attributes.difficulty,
          verticalDrop: cl.vertical_rise_m ?? edge.attributes.verticalDrop,
          trailName: cl.name,
          hasMoguls: false,
          isGroomed: false,
          isGladed: false,
          liftType: (cl.lift_type as any) ?? edge.attributes.liftType,
          liftCapacity: cl.capacity ?? edge.attributes.liftCapacity,
          rideTimeSeconds: cl.ride_time_s ?? edge.attributes.rideTimeSeconds,
          waitTimeMinutes: pickWaitMinutes(cl) ?? edge.attributes.waitTimeMinutes,
        },
      };
    }
  }

  // Whitelist validation. Mirrors Swift: lowercased + trimmed compare.
  applyWhitelist(graph, curated.trailWhitelist, /* runsOnly */ false);
  applyWhitelist(graph, curated.liftWhitelist, /* runsOnly */ false, /* liftsOnly */ true);

  return graph;
}

// ── Helpers ─────────────────────────────────────────────────────────

function byName<T extends { name: string }>(items: T[]): Map<string, T> {
  const m = new Map<string, T>();
  for (const it of items) {
    const k = it.name.toLowerCase();
    if (!m.has(k)) m.set(k, it);
  }
  return m;
}

function byOSM<T extends { osm_way_ids: string[] }>(items: T[]): Map<string, T> {
  const m = new Map<string, T>();
  for (const it of items) {
    for (const id of it.osm_way_ids ?? []) m.set(id, it);
  }
  return m;
}

/**
 * Strip GraphBuilder edge ID conventions to recover the raw OSM way ID.
 * Mirrors CuratedResortLoader.stripEdgeIdToOSMId (Swift).
 *
 *   "t123456"       → "123456"
 *   "l789"          → "789"
 *   "t123456_s1"    → "123456"
 *   "t123456_ix2"   → "123456"
 */
export function stripEdgeIdToOSMId(edgeId: string): string {
  let id = edgeId;
  if (id.length > 1 && (id[0] === "t" || id[0] === "l")) id = id.slice(1);

  const sIdx = id.lastIndexOf("_s");
  if (sIdx >= 0) {
    id = id.slice(0, sIdx);
  } else {
    const ixIdx = id.lastIndexOf("_ix");
    if (ixIdx >= 0) id = id.slice(0, ixIdx);
  }
  return id;
}

function applyWhitelist(
  graph: MountainGraph,
  whitelist: string[] | undefined,
  _runsOnly: boolean,
  liftsOnly: boolean = false,
): void {
  if (!whitelist || whitelist.length === 0) return;
  const normalized = new Set(
    whitelist.map((s) => s.toLowerCase().trim()),
  );
  for (let i = 0; i < graph.edges.length; i++) {
    const edge = graph.edges[i];
    if (liftsOnly && edge.kind !== "lift") continue;
    if (!liftsOnly && edge.kind !== "run" && edge.kind !== "lift") continue;
    const name = edge.attributes.trailName;
    if (!name) continue;
    const k = name.toLowerCase().trim();
    if (normalized.has(k)) {
      graph.edges[i] = {
        ...edge,
        attributes: { ...edge.attributes, isOfficiallyValidated: true },
      };
    }
  }
}

function pickWaitMinutes(lift: CanonicalLift): number | null | undefined {
  // Mirror CuratedLift.currentWaitMinutes (Swift): weekday vs weekend
  // by Calendar.current.component(.weekday). We use UTC-equivalent
  // here; build-resort-graph runs ahead of read time so this resolves
  // when the graph blob is built. The client merge of live status
  // replaces this at read time anyway.
  const day = new Date().getUTCDay(); // 0 = Sun, 6 = Sat
  const isWeekend = day === 0 || day === 6;
  return isWeekend
    ? (lift.weekend_wait_min ?? lift.weekday_wait_min)
    : (lift.weekday_wait_min ?? lift.weekend_wait_min);
}
