// Shared plumbing for the edge workers: the worker-secret check, a small
// PostgREST client on the service-role key, and injectable dependencies so the
// handlers can be tested without a network.
//
// Workers are called by pg_cron through pg_net (verify_jwt is off for them in
// config.toml), so the only thing standing between the internet and a worker
// is the `x-worker-secret` header. A missing or wrong secret is refused before
// anything else happens; a worker with no WORKER_SECRET configured refuses
// every request.

export interface Deps {
  env: (name: string) => string | undefined;
  fetch: typeof fetch;
  now: () => Date;
}

export function defaultDeps(): Deps {
  return {
    env: (name) => Deno.env.get(name),
    fetch: (input, init) => fetch(input, init),
    now: () => new Date(),
  };
}

export function json(status: number, body: unknown): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json" },
  });
}

export function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}

function timingSafeEqual(a: string, b: string): boolean {
  const x = new TextEncoder().encode(a);
  const y = new TextEncoder().encode(b);
  let diff = x.length ^ y.length;
  for (let i = 0; i < x.length; i += 1) {
    diff |= x[i] ^ (y.length ? y[i % y.length] : 0xff);
  }
  return diff === 0;
}

/** Returns a refusal, or null when the request may proceed. */
export function refuse(req: Request, deps: Deps): Response | null {
  if (req.method !== "POST") return json(405, { error: "method_not_allowed" });
  const expected = deps.env("WORKER_SECRET") ?? "";
  const given = req.headers.get("x-worker-secret") ?? "";
  if (expected.length < 16 || !timingSafeEqual(given, expected)) {
    return json(401, { error: "unauthorized" });
  }
  return null;
}

export class Db {
  constructor(
    readonly baseUrl: string,
    private readonly key: string,
    private readonly fetcher: typeof fetch,
  ) {}

  static fromDeps(deps: Deps): Db {
    const url = deps.env("SUPABASE_URL");
    const key = deps.env("SUPABASE_SERVICE_ROLE_KEY");
    if (!url || !key) throw new Error("SUPABASE_URL or SUPABASE_SERVICE_ROLE_KEY is not set");
    return new Db(url.replace(/\/+$/, ""), key, deps.fetch);
  }

  private async request(path: string, init: RequestInit, api = "rest/v1"): Promise<unknown> {
    const response = await this.fetcher(`${this.baseUrl}/${api}/${path}`, {
      ...init,
      headers: {
        apikey: this.key,
        authorization: `Bearer ${this.key}`,
        "content-type": "application/json",
        ...(init.headers ?? {}),
      },
      signal: AbortSignal.timeout(15_000),
    });
    const text = await response.text();
    if (!response.ok) {
      throw new Error(`${api === "rest/v1" ? "database" : "storage"} ${path.split("?")[0]} returned HTTP ${response.status}: ${text.slice(0, 200)}`);
    }
    return text ? JSON.parse(text) : null;
  }

  async rpc<T>(name: string, args: Record<string, unknown> = {}): Promise<T> {
    return await this.request(`rpc/${name}`, { method: "POST", body: JSON.stringify(args) }) as T;
  }

  /** `path` is a PostgREST table path with its query string. */
  async select<T>(path: string): Promise<T[]> {
    return (await this.request(path, { method: "GET" }) ?? []) as T[];
  }

  async insert(table: string, row: Record<string, unknown>): Promise<void> {
    await this.request(table, {
      method: "POST",
      body: JSON.stringify(row),
      headers: { prefer: "return=minimal" },
    });
  }

  /** `path` is a PostgREST table path whose query string picks the rows. */
  async update(path: string, patch: Record<string, unknown>): Promise<void> {
    await this.request(path, {
      method: "PATCH",
      body: JSON.stringify(patch),
      headers: { prefer: "return=minimal" },
    });
  }

  /**
   * Removes objects through the Storage API, which deletes the stored bytes
   * as well as the `storage.objects` row (a SQL delete leaves the bytes).
   * Returns the names Storage reports removed.
   */
  async storageRemove(bucket: string, paths: string[]): Promise<string[]> {
    const removed = await this.request(
      `object/${encodeURIComponent(bucket)}`,
      { method: "DELETE", body: JSON.stringify({ prefixes: paths }) },
      "storage/v1",
    ) as { name: string }[] | null;
    return (removed ?? []).map((o) => o.name);
  }
}

/**
 * A failure the job must not be retried for in this cycle. A status provider
 * that is down or refusing us gets one request per resort per cycle, not five;
 * the next cron tick queues a fresh job.
 */
export class NoRetry extends Error {}

export interface Job {
  id: number;
  kind: string;
  resort_id: string | null;
  attempts: number;
}

/**
 * One job per invocation: claim a single job of `kind`, run it, and record the
 * outcome. A failure is written back to the job (which reschedules it with
 * backoff) and reported in the response; it never leaves the lease dangling.
 */
export async function runOneJob(
  req: Request,
  deps: Deps,
  kind: string,
  run: (db: Db, job: Job) => Promise<Record<string, unknown>>,
): Promise<Response> {
  const refused = refuse(req, deps);
  if (refused) return refused;

  let db: Db;
  let job: Job | undefined;
  try {
    db = Db.fromDeps(deps);
    [job] = await db.rpc<Job[]>("jobs_claim", { p_kind: kind, p_limit: 1 });
  } catch (error) {
    return json(500, { error: errorMessage(error) });
  }
  if (!job) return json(200, { claimed: 0 });

  try {
    const result = await run(db, job);
    await db.rpc("jobs_complete", { p_id: job.id });
    return json(200, { claimed: 1, job: job.id, resort_id: job.resort_id, ...result });
  } catch (error) {
    const message = errorMessage(error);
    console.error(`${kind} job ${job.id} (${job.resort_id}) failed: ${message}`);
    try {
      await db.rpc("jobs_complete", error instanceof NoRetry ? { p_id: job.id } : { p_id: job.id, p_error: message });
    } catch (completeError) {
      console.error(`could not record the failure: ${errorMessage(completeError)}`);
    }
    return json(200, { claimed: 1, job: job.id, resort_id: job.resort_id, error: message });
  }
}
