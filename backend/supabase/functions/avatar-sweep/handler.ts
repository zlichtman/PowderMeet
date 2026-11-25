// avatar-sweep: one `avatar_sweep` job per invocation.
//
// `avatar_orphans` names every avatar object nobody uses: its owner's profile
// is gone, or it is not the owner's current `avatar_url` and is over an hour
// old. This worker removes them through the Storage API, which deletes the
// stored bytes with the row, in batches until none are left or the round cap
// is reached (the next hourly sweep takes the rest).

import { type Db, type Deps, defaultDeps, runOneJob } from "../_shared/worker.ts";

const BATCH = 100;
const ROUNDS = 10;

async function sweep(db: Db): Promise<Record<string, unknown>> {
  let removed = 0;
  for (let round = 0; round < ROUNDS; round += 1) {
    const paths = await db.rpc<string[]>("avatar_orphans", { p_limit: BATCH }) ?? [];
    if (paths.length === 0) break;
    const gone = await db.storageRemove("avatars", paths);
    // Storage answered but removed none of them: stop rather than spin, and
    // let the job retry with backoff.
    if (gone.length === 0) throw new Error(`storage removed none of ${paths.length} orphaned avatars`);
    removed += gone.length;
  }
  return { removed };
}

export function handler(req: Request, deps: Deps = defaultDeps()): Promise<Response> {
  return runOneJob(req, deps, "avatar_sweep", (db) => sweep(db));
}
