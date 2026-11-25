// push-drain: one claimed batch of the push outbox per invocation.
//
// The database has already done the deciding: `push_outbox_claim` retires
// stale rows, collapses duplicates for the same meet within 60 seconds, leases
// what is left and returns each row with the recipient's device tokens. This
// worker renders, sends, and reports back. A token APNs says is dead is
// deleted. The caller controls nothing: there is no request body.

import { createApns } from "../_shared/apns.ts";
import { renderNotification } from "../_shared/push.ts";
import { Db, type Deps, defaultDeps, errorMessage, json, refuse } from "../_shared/worker.ts";

const BATCH = 25;

interface OutboxRow {
  id: number;
  user_id: string;
  kind: string;
  payload: Record<string, unknown> | null;
  tokens: { token: string; environment: string }[] | null;
}

interface Outcome {
  error: string | null;
  dead: string[];
}

async function deliver(row: OutboxRow, deps: Deps): Promise<Outcome> {
  const tokens = row.tokens ?? [];
  // Signed out everywhere since the row was queued: nothing to send.
  if (tokens.length === 0) return { error: null, dead: [] };

  const notification = renderNotification(row.kind, row.payload ?? {}, deps.now());
  const apns = createApns(deps);
  const results = await Promise.all(
    tokens.map((t) => apns.send(t.token, t.environment, notification)),
  );
  const dead = tokens.filter((_, i) => results[i].outcome === "dead").map((t) => t.token);
  const failures = results.flatMap((r) => r.outcome === "failed" ? [r.error] : []);
  // Any transient failure keeps the row for retry. A device that already got
  // the push sees it again, but apns-collapse-id replaces it.
  return { error: failures.length > 0 ? failures.join("; ") : null, dead };
}

export async function handler(req: Request, deps: Deps = defaultDeps()): Promise<Response> {
  const refused = refuse(req, deps);
  if (refused) return refused;

  let db: Db;
  let rows: OutboxRow[];
  try {
    db = Db.fromDeps(deps);
    rows = await db.rpc<OutboxRow[]>("push_outbox_claim", { p_limit: BATCH }) ?? [];
  } catch (error) {
    return json(500, { error: errorMessage(error) });
  }

  let sent = 0;
  let failed = 0;
  await Promise.all(rows.map(async (row) => {
    let outcome: Outcome;
    try {
      outcome = await deliver(row, deps);
    } catch (error) {
      outcome = { error: errorMessage(error), dead: [] };
    }
    if (outcome.error) failed += 1;
    else sent += 1;
    try {
      await db.rpc("push_outbox_complete", {
        p_id: row.id,
        p_error: outcome.error,
        p_dead_tokens: outcome.dead.length ? outcome.dead : null,
      });
    } catch (error) {
      // The lease runs out in two minutes and the row is claimed again.
      console.error(`push ${row.id}: outcome not recorded: ${errorMessage(error)}`);
    }
  }));
  return json(200, { claimed: rows.length, sent, failed });
}
