// Test helpers. No dependencies, so the suite runs offline.

import type { Deps } from "./worker.ts";

export function assert(condition: unknown, message: string): asserts condition {
  if (!condition) throw new Error(message);
}

export function assertEquals(actual: unknown, expected: unknown, message: string): void {
  const a = JSON.stringify(actual);
  const e = JSON.stringify(expected);
  if (a !== e) throw new Error(`${message}\n  actual:   ${a}\n  expected: ${e}`);
}

export async function assertRejects(run: () => unknown, message: string): Promise<void> {
  let failed = false;
  try {
    await run();
  } catch {
    failed = true;
  }
  assert(failed, message);
}

export const TEST_SECRET = "test-worker-secret-0123456789";

export interface Call {
  url: string;
  method: string;
  headers: Headers;
  body: unknown;
}

/** Dependencies with a scripted `fetch`; every call is recorded. */
export function fakeDeps(
  respond: (call: Call) => Response | Promise<Response>,
  env: Record<string, string> = {},
  now = new Date("2026-01-10T18:00:00Z"),
): { deps: Deps; calls: Call[] } {
  const calls: Call[] = [];
  const vars: Record<string, string> = {
    WORKER_SECRET: TEST_SECRET,
    SUPABASE_URL: "http://db.test",
    SUPABASE_SERVICE_ROLE_KEY: "service-key",
    ...env,
  };
  const deps: Deps = {
    env: (name) => vars[name],
    now: () => now,
    fetch: (async (input: RequestInfo | URL, init?: RequestInit) => {
      const text = typeof init?.body === "string" ? init.body : "";
      const call: Call = {
        url: String(input instanceof Request ? input.url : input),
        method: init?.method ?? "GET",
        headers: new Headers(init?.headers),
        body: text ? JSON.parse(text) : null,
      };
      calls.push(call);
      return await respond(call);
    }) as typeof fetch,
  };
  return { deps, calls };
}

export function post(headers: Record<string, string> = {}): Request {
  return new Request("http://worker.test/", { method: "POST", headers, body: "{}" });
}
