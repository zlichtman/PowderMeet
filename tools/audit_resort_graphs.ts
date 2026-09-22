/** Read-only source/topology audit. This never publishes or approves a canonical graph. */
import { osmToResortData } from "../supabase/functions/_shared/osm_snapshot.ts";
import { buildGraph } from "../supabase/functions/_shared/graph_builder.ts";
import { stripEdgeIdToOSMId } from "../supabase/functions/_shared/curated_overlay.ts";
import { validateCanonicalGraph } from "../supabase/functions/_shared/graph_integrity.ts";

const root = Deno.args[0] ?? "_local";
// Optional second argument audits one newly staged extraction without replacing
// the report for the currently pinned source maps.
const sourceDirectory = Deno.args[1];
const reportDirectory = sourceDirectory ?? `${root}/resort-rollout`;
const catalog = JSON.parse(await Deno.readTextFile(`${reportDirectory}/coverage.json`));
const bounds = JSON.parse(await Deno.readTextFile("tools/resort_bounds_review.json"));
const corrected = new Set(bounds.resorts.map((r: { resort_id: string }) => r.resort_id));
const report: Record<string, unknown> = {};
for (const id of Object.keys(catalog.resorts).sort()) {
  const folder = sourceDirectory ? `${sourceDirectory}/${id}`
    : `${root}/${corrected.has(id) ? "resort-corrected" : "resort-rollout"}/${id}`;
  try {
    const osm = JSON.parse(await Deno.readTextFile(`${folder}/osm.json`));
    const elevations = JSON.parse(await Deno.readTextFile(`${folder}/elevation.json`));
    const source = osmToResortData(osm, elevations);
    const graph = buildGraph(source, id);
    const failures = validateCanonicalGraph(graph, id);
    const outward = new Map<string, typeof graph.edges>();
    const neighbors = new Map<string, Set<string>>();
    for (const edge of graph.edges) {
      const edges = outward.get(edge.sourceID) ?? [];
      edges.push(edge); outward.set(edge.sourceID, edges);
      for (const [a, b] of [[edge.sourceID, edge.targetID], [edge.targetID, edge.sourceID]]) {
        const linked = neighbors.get(a) ?? new Set<string>(); linked.add(b); neighbors.set(a, linked);
      }
    }
    let components = 0;
    const seen = new Set<string>();
    for (const node of Object.keys(graph.nodes)) {
      if (seen.has(node)) continue;
      components++;
      const stack = [node]; seen.add(node);
      while (stack.length) {
        for (const next of neighbors.get(stack.pop()!) ?? []) {
          if (!seen.has(next)) { seen.add(next); stack.push(next); }
        }
      }
    }
    // Audit original source-way exits independently of reverse travel. Otherwise a
    // return gondola masks a missing downhill connection at its upper terminal.
    const lifts = graph.edges.filter(e => e.kind === "lift" && !e.id.endsWith("_rev"));
    const liftTerminals = lifts.filter(e => !(outward.get(e.targetID) ?? []).some(n =>
      n.kind === "lift" && !n.id.endsWith("_rev") &&
      stripEdgeIdToOSMId(n.id) === stripEdgeIdToOSMId(e.id)));
    const disconnectedLiftTerminals = liftTerminals.filter(e => !(outward.get(e.targetID) ?? []).some(n => n.kind === "run" || n.kind === "traverse"));
    report[id] = {
      source_trails: source.trails.length, source_lifts: source.lifts.length,
      nodes: Object.keys(graph.nodes).length, edges: graph.edges.length,
      fingerprint: graph.fingerprint, integrity_failures: failures,
      disconnected_components: components,
      lift_exits_without_explicit_downhill_link: disconnectedLiftTerminals.map(e => ({ id: e.id, name: e.attributes.trailName,
        source_way_id: stripEdgeIdToOSMId(e.id), terminal_node_id: e.targetID,
        coordinate: graph.nodes[e.targetID].coordinate })),
      canonical_review_required: true,
    };
  } catch (error) {
    report[id] = { source_unavailable: error instanceof Deno.errors.NotFound,
      error: error instanceof Error ? error.message : "unknown error", canonical_review_required: true };
  }
}
await Deno.writeTextFile(`${reportDirectory}/graph-audit.json`, JSON.stringify({
  generated_at: new Date().toISOString(),
  graph_version: "v15",
  meaning: "Source graph integrity and connectivity only; not canonical approval or live-routing availability.",
  resorts: report,
}, null, 2));
const rows = Object.values(report) as Record<string, unknown>[];
console.log(JSON.stringify({ resorts: rows.length, source_graphs: rows.filter(r => r.nodes).length,
  sources_unavailable: rows.filter(r => r.source_unavailable).length,
  graph_failures: rows.filter(r => r.error && !r.source_unavailable).length,
  with_integrity_failures: rows.filter(r => Array.isArray(r.integrity_failures) && r.integrity_failures.length).length,
}));
