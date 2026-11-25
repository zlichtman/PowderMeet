// conditions-refresh: one `conditions_refresh` job per invocation.
//
// Claims a job and writes one `resort_conditions` row from Open-Meteo for the
// resort's center point. A resort refreshed in the last 50 minutes is skipped,
// so a retry or a double ping never spends a second request. A failed request
// is not retried this hour, as with the status providers.

import { type Db, type Deps, defaultDeps, errorMessage, type Job, NoRetry, runOneJob } from "../_shared/worker.ts";
import { fetchOpenMeteo } from "../_shared/providers/open_meteo.ts";

const CACHE_MS = 50 * 60_000;

interface ResortRow {
  id: string;
  published: boolean;
  center: unknown;
}

async function refresh(db: Db, job: Job, deps: Deps): Promise<Record<string, unknown>> {
  if (!job.resort_id) throw new Error("conditions_refresh job has no resort_id");
  const id = encodeURIComponent(job.resort_id);
  const [resort] = await db.select<ResortRow>(`resorts?id=eq.${id}&select=id,published,center`);
  if (!resort || !resort.published) return { skipped: "resort is not published" };

  const now = deps.now();
  const [latest] = await db.select<{ observed_at: string }>(
    `resort_conditions?resort_id=eq.${id}&select=observed_at&order=observed_at.desc&limit=1`,
  );
  if (latest && now.getTime() - Date.parse(latest.observed_at) < CACHE_MS) {
    return { skipped: "refreshed less than 50 minutes ago" };
  }

  const center = resort.center;
  if (
    !Array.isArray(center) || center.length !== 2 ||
    typeof center[0] !== "number" || typeof center[1] !== "number"
  ) {
    throw new Error(`resort ${resort.id} has no center [lon, lat]`);
  }
  let row;
  try {
    row = await fetchOpenMeteo(center[0], center[1], deps.fetch, now);
  } catch (error) {
    // Open-Meteo is down or refusing us: retrying within the hour, for every
    // resort, only adds to its load. The next hourly job asks again.
    throw new NoRetry(errorMessage(error));
  }
  await db.insert("resort_conditions", { resort_id: resort.id, ...row });
  return { source: row.source, hours: row.hourly.length };
}

export function handler(req: Request, deps: Deps = defaultDeps()): Promise<Response> {
  return runOneJob(req, deps, "conditions_refresh", (db, job) => refresh(db, job, deps));
}
