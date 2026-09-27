/** Export unreviewed source graphs for opt-in iPhone solver acceptance tests.
 * This never publishes, marks terrain open, or approves a canonical dataset. */
import { osmToResortData } from "../supabase/functions/_shared/osm_snapshot.ts";
import { buildGraph } from "../supabase/functions/_shared/graph_builder.ts";
import { encodeGraph } from "../supabase/functions/_shared/graph_types.ts";

const root = Deno.args[0] ?? "_local";
const output = Deno.args[1] ?? `${root}/route-acceptance`;
const coverage = JSON.parse(
  await Deno.readTextFile(`${root}/resort-rollout/coverage.json`),
);
const bounds = JSON.parse(
  await Deno.readTextFile("tools/resort_bounds_review.json"),
);
const corrected = new Set(
  bounds.resorts.map((r: { resort_id: string }) => r.resort_id),
);
await Deno.mkdir(output, { recursive: true });
const ids = Object.keys(coverage.resorts).sort();
for (const id of ids) {
  const folder = `${root}/${
    corrected.has(id) ? "resort-corrected" : "resort-rollout"
  }/${id}`;
  const osm = JSON.parse(await Deno.readTextFile(`${folder}/osm.json`));
  const elevation = JSON.parse(
    await Deno.readTextFile(`${folder}/elevation.json`),
  );
  const graph = buildGraph(osmToResortData(osm, elevation), id);
  await Deno.writeTextFile(
    `${output}/${id}.json`,
    JSON.stringify(encodeGraph(graph)),
  );
}
await Deno.writeTextFile(
  `${output}/manifest.json`,
  JSON.stringify(
    {
      source: "unreviewed source geometry; local rehearsal only",
      graphVersion: "v15",
      resorts: ids,
    },
    null,
    2,
  ),
);
console.log(
  `Exported ${ids.length} local source graphs. No canonical publication.`,
);
