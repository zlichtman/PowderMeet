// status-refresh: one `status_refresh` job per invocation.
//
// Claims a job for a `live` resort, reads the resort's active bundle for its
// lift groups and provider aliases, asks the provider the resort declares
// (`resorts.status_provider`: epic, mtnpowder or liftie) and writes one
// `resort_status` row. Nothing is written when the provider fails, the parse
// fails or fewer than 80 % of lift groups are mapped: the previous row ages
// into `stale`, and the provider is not asked again until the next cycle.
// Resorts without a provider are `scheduled_only`; their hourly rows are
// written by the database and never reach this worker.

import { type Db, type Deps, defaultDeps, errorMessage, type Job, NoRetry, runOneJob } from "../_shared/worker.ts";
import { loadBundleStatusMeta } from "../_shared/providers/bundle.ts";
import { fetchEpicTerrainStatus } from "../_shared/providers/epic.ts";
import { fetchLiftieStatus } from "../_shared/providers/liftie.ts";
import { fetchMtnPowderFeed, parseMtnPowderStatus } from "../_shared/providers/mtnpowder.ts";
import { projectStatus, type VendorTerrainStatus } from "../_shared/providers/status.ts";

interface ResortRow {
  id: string;
  published: boolean;
  status_mode: "live" | "scheduled_only";
  status_provider: "epic" | "mtnpowder" | "liftie" | null;
}

async function fetchVendor(resort: ResortRow, deps: Deps): Promise<VendorTerrainStatus> {
  const now = deps.now();
  switch (resort.status_provider) {
    case "epic":
      return await fetchEpicTerrainStatus(resort.id, deps.fetch, now);
    case "mtnpowder":
      return parseMtnPowderStatus(await fetchMtnPowderFeed(deps.fetch), resort.id, now);
    case "liftie":
      return await fetchLiftieStatus(resort.id, deps.fetch, now);
    default:
      throw new Error(`no status provider for ${resort.id}`);
  }
}

async function refresh(db: Db, job: Job, deps: Deps): Promise<Record<string, unknown>> {
  if (!job.resort_id) throw new Error("status_refresh job has no resort_id");
  const id = encodeURIComponent(job.resort_id);
  const [resort] = await db.select<ResortRow>(
    `resorts?id=eq.${id}&select=id,published,status_mode,status_provider`,
  );
  if (!resort || !resort.published) return { skipped: "resort is not published" };
  if (resort.status_mode !== "live") return { skipped: "resort has no live status provider" };
  const [active] = await db.select<{ bundle_id: string }>(
    `resort_active_bundle?resort_id=eq.${id}&select=bundle_id`,
  );
  if (!active) return { skipped: "resort has no active bundle" };

  const meta = await loadBundleStatusMeta(db, resort.id, active.bundle_id, deps.fetch);
  let row;
  try {
    row = projectStatus(await fetchVendor(resort, deps), meta, deps.now());
  } catch (error) {
    // The provider's answer was unusable. Do not ask it again this cycle.
    throw new NoRetry(errorMessage(error));
  }
  if (!row) return { skipped: "provider reports off season" };

  await db.insert("resort_status", { resort_id: resort.id, ...row });
  return { source: row.source, groups: Object.keys(row.groups).length };
}

export function handler(req: Request, deps: Deps = defaultDeps()): Promise<Response> {
  return runOneJob(req, deps, "status_refresh", (db, job) => refresh(db, job, deps));
}
