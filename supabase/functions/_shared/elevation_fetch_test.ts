import { fetchElevationBatch } from "./elevation_fetch.ts";
function assert(value: unknown, message: string): asserts value { if (!value) throw new Error(message); }
Deno.test("elevation retries transient errors and preserves ordered measured samples", async () => {
  const responses = [new Response("temporary", { status: 502 }), Response.json({ elevation: [1500, 0] })];
  const delays: number[] = [];
  const result = await fetchElevationBatch(["50,-122", "50.1,-122.1"],
    (() => Promise.resolve(responses.shift()!)) as typeof fetch,
    async ms => { delays.push(ms); });
  assert(result[0] === 1500 && result[1] === 0 && delays.length === 1, "retry or sample order failed");
});
Deno.test("elevation refuses missing samples without fabricating zero", async () => {
  for (const elevation of [[null], [], ["1500"]]) {
    let failed = false;
    try { await fetchElevationBatch(["50,-122"], (() => Promise.resolve(Response.json({ elevation }))) as typeof fetch); }
    catch { failed = true; }
    assert(failed, "invalid elevation accepted");
  }
});
Deno.test("elevation retry count and deadline are bounded", async () => {
  let calls = 0;
  const fetcher = (() => { calls++; return Promise.resolve(new Response("busy", { status: 503 })); }) as typeof fetch;
  try { await fetchElevationBatch(["50,-122"], fetcher, async () => {}); } catch { /* expected */ }
  assert(calls === 3, "must stop after three attempts");
  calls = 0;
  try { await fetchElevationBatch(["50,-122"], fetcher, async () => {}, Date.now() - 1); } catch { /* expected */ }
  assert(calls === 0, "expired invocation must not start another request");
});
