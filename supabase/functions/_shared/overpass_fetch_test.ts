import { fetchOverpassSource, resortSourceQuery } from "./overpass_fetch.ts";
function assert(value: unknown, message: string): asserts value {
  if (!value) throw new Error(message);
}
function fake(responses: Response[], calls: { url: string; method?: string }[]): typeof fetch {
  return ((url: string | URL | Request, init?: RequestInit) => {
    calls.push({ url: String(url), method: init?.method });
    const response = responses.shift();
    if (!response) throw new Error("unexpected request");
    return Promise.resolve(response);
  }) as typeof fetch;
}
Deno.test("POST rejection retries the unchanged source query with GET", async () => {
  const calls: { url: string; method?: string }[] = [];
  const payload = { elements: [{ type: "node", id: 17 }], osm3s: { timestamp_osm_base: "2026-09-20T00:00:00Z" } };
  const result = await fetchOverpassSource("[out:json];node(17);out;", fake([
    new Response("rejected", { status: 406 }), Response.json(payload),
  ], calls));
  assert(calls.length === 2 && calls[1].method === "GET", "GET fallback missing");
  assert(new URL(calls[1].url).searchParams.get("data") === "[out:json];node(17);out;", "query changed");
  assert(JSON.stringify(result) === JSON.stringify(payload), "source identity was changed");
});
Deno.test("mirror recovers primary failures without accepting a partial response", async () => {
  const calls: { url: string; method?: string }[] = [];
  const result = await fetchOverpassSource("query", fake([
    new Response("unavailable", { status: 502 }),
    Response.json({ elements: [], remark: "runtime error: Query timed out" }),
    Response.json({ elements: [{ type: "way", id: 29, nodes: [1, 2] }] }),
  ], calls));
  assert(calls.length === 3 && calls[2].url.includes("maps.mail.ru"), "mirror not used");
  assert(result.elements.length === 1, "partial result accepted");
});
Deno.test("all invalid responses fail instead of publishing an empty mountain", async () => {
  const calls: { url: string; method?: string }[] = [];
  let failed = false;
  try {
    await fetchOverpassSource("query", fake([
      new Response("bad", { status: 406 }), Response.json({}), new Response("<html>error</html>"),
    ], calls));
  } catch { failed = true; }
  assert(failed && calls.length === 3, "must fail closed after bounded attempts");
});

Deno.test("snapshot source query includes explicit piste connections and raw vertices", () => {
  const query = resortSourceQuery(39, -107, 40, -106);
  for (const selector of ['way["piste:type"="downhill"]', 'way["piste:type"="connection"]', 'way["aerialway"]']) {
    assert(query.includes(`${selector}(39,-107,40,-106)`), `missing source selection: ${selector}`);
  }
  assert(query.includes("out body;\n>;\nout qt;"), "raw source node IDs must survive");
  let rejected = false;
  try { resortSourceQuery(40, -107, 39, -106); } catch { rejected = true; }
  assert(rejected, "invalid bounds accepted");
});
