// The four workers, driven through their handlers with a scripted network.

import { handler as avatarSweep } from "./avatar-sweep/handler.ts";
import { handler as conditionsRefresh } from "./conditions-refresh/handler.ts";
import { handler as pushDrain } from "./push-drain/handler.ts";
import { handler as statusRefresh } from "./status-refresh/handler.ts";
import { assert, assertEquals, type Call, fakeDeps, post, TEST_SECRET } from "./_shared/testing.ts";

const workers = {
  "status-refresh": statusRefresh,
  "conditions-refresh": conditionsRefresh,
  "push-drain": pushDrain,
  "avatar-sweep": avatarSweep,
};
const authed = { "x-worker-secret": TEST_SECRET };

function jsonResponse(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json" } });
}

Deno.test("worker_endpoints_reject_missing_secret", async () => {
  for (const [name, handler] of Object.entries(workers)) {
    const { deps, calls } = fakeDeps(() => jsonResponse([]));
    assert((await handler(post(), deps)).status === 401, `${name}: no secret`);
    assert((await handler(post({ "x-worker-secret": "wrong" }), deps)).status === 401, `${name}: wrong secret`);
    assert(
      (await handler(post({ authorization: `Bearer ${TEST_SECRET}` }), deps)).status === 401,
      `${name}: the secret in another header`,
    );
    assert(
      (await handler(new Request("http://worker.test/", { headers: authed }), deps)).status === 405,
      `${name}: GET`,
    );
    assert(calls.length === 0, `${name}: a refused request touches nothing`);

    // A worker deployed without its secret refuses everything, even an empty match.
    const unset = fakeDeps(() => jsonResponse([]), { WORKER_SECRET: "" });
    assert((await handler(post({ "x-worker-secret": "" }), unset.deps)).status === 401, `${name}: unset secret`);
    assert(unset.calls.length === 0, `${name}: unset secret touches nothing`);

    const ok = fakeDeps(() => jsonResponse([]));
    assert((await handler(post(authed), ok.deps)).status === 200, `${name}: the right secret is accepted`);
    assert(
      ok.calls.length === 1 && ok.calls[0].headers.get("authorization") === "Bearer service-key",
      `${name}: and the worker talks to the database with the service role`,
    );
  }
});

async function gzip(text: string): Promise<Uint8Array> {
  const stream = new Blob([text]).stream().pipeThrough(new CompressionStream("gzip"));
  return new Uint8Array(await new Response(stream).arrayBuffer());
}

async function sha256Hex(bytes: Uint8Array): Promise<string> {
  const digest = new Uint8Array(await crypto.subtle.digest("SHA-256", bytes as BufferSource));
  return [...digest].map((b) => b.toString(16).padStart(2, "0")).join("");
}

const bundle = JSON.stringify({
  schema_version: 1,
  resort_id: "vail",
  status_aliases: { epic: { "Gondola One": "lift:gondola-one", "Riva Ridge": "trail:riva-ridge" } },
  groups: [{ id: "lift:gondola-one", kind: "lift" }, { id: "trail:riva-ridge", kind: "trail" }],
});

function epicPage(liftStatus: string): string {
  return `<script>FR.TerrainStatusFeed = ${
    JSON.stringify({
      Date: "2026-01-10T17:55:00Z",
      GroomingAreas: [{
        Trails: [{ Name: "Riva Ridge", TrailType: "Skiing", IsOpen: true, IsGroomed: true }],
        Lifts: [{ Name: "Gondola One", Status: liftStatus, WaitTimeInMinutes: 6 }],
      }],
    })
  };</script>`;
}

// A database and the outside world for one status job on `vail`.
async function statusWorld(
  options: {
    page?: Response;
    mode?: string;
    provider?: string;
    tamper?: boolean;
    liftie?: Response;
    variant?: string;
    stored?: unknown;
  },
) {
  // Verified bundles are cached by id, so the tampered case publishes an id of
  // its own and serves bytes that do not hash to it; `variant` gives a case a
  // bundle id no earlier case has cached.
  const bytes = await gzip((options.tamper ? bundle + "\n" : bundle) + (options.variant ?? ""));
  const bundleId = await sha256Hex(bytes);
  const served = options.tamper ? await gzip(bundle.replace("gondola-one", "gondola-two")) : bytes;
  return fakeDeps((call: Call) => {
    const url = call.url;
    if (url.endsWith("/rpc/jobs_claim")) {
      return jsonResponse([{ id: 7, kind: "status_refresh", resort_id: "vail", attempts: 1 }]);
    }
    if (url.includes("/rest/v1/resorts?")) {
      return jsonResponse([{
        id: "vail",
        published: true,
        status_mode: options.mode ?? "live",
        status_provider: options.provider ?? "epic",
      }]);
    }
    if (url.includes("/rest/v1/resort_active_bundle?")) return jsonResponse([{ bundle_id: bundleId }]);
    if (url.includes("/rest/v1/resort_bundles?") && call.method === "GET") {
      return jsonResponse([{ status_meta: options.stored ?? null }]);
    }
    if (url.includes("/rest/v1/resort_bundles?") && call.method === "PATCH") return new Response(null, { status: 204 });
    if (url.includes("/storage/v1/object/public/resort-bundles/vail/")) {
      return new Response(served as BodyInit);
    }
    if (url.startsWith("https://www.vail.com/")) return options.page ?? new Response(epicPage("Open"));
    if (url === "https://liftie.info/api/resort/vail" && options.liftie) return options.liftie;
    if (url.endsWith("/rest/v1/resort_status")) return new Response(null, { status: 201 });
    if (url.endsWith("/rpc/jobs_complete")) return new Response(null, { status: 204 });
    return new Response("unexpected " + url, { status: 500 });
  });
}

const inserted = (calls: Call[]) => calls.filter((c) => c.url.endsWith("/rest/v1/resort_status"));
const downloads = (calls: Call[]) => calls.filter((c) => c.url.includes("/storage/v1/object/public/resort-bundles/"));
const metaStores = (calls: Call[]) =>
  calls.filter((c) => c.url.includes("/rest/v1/resort_bundles?") && c.method === "PATCH");
const completed = (calls: Call[]) => calls.filter((c) => c.url.endsWith("/rpc/jobs_complete"));

Deno.test("status-refresh claims one job and writes one status row", async () => {
  const { deps, calls } = await statusWorld({});
  const response = await statusRefresh(post(authed), deps);
  assert(response.status === 200, "ok");
  assertEquals(calls[0].body, { p_kind: "status_refresh", p_limit: 1 }, "one job per invocation");
  assertEquals(inserted(calls).map((c) => c.body), [{
    resort_id: "vail",
    observed_at: "2026-01-10T17:55:00.000Z",
    expires_at: "2026-01-10T19:10:00.000Z",
    source: "epic",
    groups: { "lift:gondola-one": "open", "trail:riva-ridge": "open" },
    groomed: ["trail:riva-ridge"],
    wait_minutes: { "lift:gondola-one": 6 },
  }], "the row follows specs/02-DOMAIN.md section 3");
  assertEquals(completed(calls).map((c) => c.body), [{ p_id: 7 }], "the job is completed without an error");
  assertEquals(metaStores(calls).map((c) => c.body), [{
    status_meta: {
      aliases: { epic: { "Gondola One": "lift:gondola-one", "Riva Ridge": "trail:riva-ridge" } },
      lift_groups: ["lift:gondola-one"],
      trail_groups: ["trail:riva-ridge"],
    },
  }], "what the worker read from the bundle is kept on its row");
});

Deno.test("status-refresh reads a bundle's stored status meta instead of downloading it", async () => {
  const { deps, calls } = await statusWorld({
    variant: " ",
    stored: {
      aliases: { epic: { "Gondola One": "lift:gondola-one", "Riva Ridge": "trail:riva-ridge" } },
      lift_groups: ["lift:gondola-one"],
      trail_groups: ["trail:riva-ridge"],
    },
  });
  await statusRefresh(post(authed), deps);
  assert(downloads(calls).length === 0, "the bundle is not downloaded");
  assert(metaStores(calls).length === 0, "nor stored again");
  assert(inserted(calls).length === 1, "and the status row is written from the stored meta");

  const malformed = await statusWorld({ variant: "  ", stored: { aliases: {}, lift_groups: "lift:gondola-one" } });
  await statusRefresh(post(authed), malformed.deps);
  assert(downloads(malformed.calls).length === 1, "a stored meta that does not parse sends the worker to the bundle");
  assert(inserted(malformed.calls).length === 1, "which still writes the row");
});

Deno.test("status-refresh writes nothing when the provider fails or the bundle is not the published one", async () => {
  const down = await statusWorld({ page: new Response("upstream down", { status: 503 }) });
  await statusRefresh(post(authed), down.deps);
  assert(inserted(down.calls).length === 0, "provider failure writes no row");
  assertEquals(
    completed(down.calls).map((c) => c.body),
    [{ p_id: 7 }],
    "and the provider is not asked again until the next cycle",
  );

  const unmapped = await statusWorld({ page: new Response(epicPage("Sideways")) });
  await statusRefresh(post(authed), unmapped.deps);
  assert(inserted(unmapped.calls).length === 0, "fewer than 80 % of lifts mapped writes no row");

  const tampered = await statusWorld({ tamper: true });
  await statusRefresh(post(authed), tampered.deps);
  assert(inserted(tampered.calls).length === 0, "bytes that do not hash to the bundle id are refused");
  assert(metaStores(tampered.calls).length === 0, "and nothing read from them is kept");
  assertEquals(
    (completed(tampered.calls)[0].body as { p_error: string }).p_error,
    "bundle bytes do not match bundle_id",
    "with the reason",
  );
});

Deno.test("status-refresh does nothing for a resort without a live provider", async () => {
  const { deps, calls } = await statusWorld({ mode: "scheduled_only" });
  await statusRefresh(post(authed), deps);
  assert(inserted(calls).length === 0, "scheduled rows are the database's job");
  assert(!calls.some((c) => c.url.startsWith("https://www.vail.com/")), "and no provider is called");
  assertEquals(completed(calls).map((c) => c.body), [{ p_id: 7 }], "the stray job is cleared");
});

Deno.test("status-refresh uses the provider the resort declares: Liftie, lifts only", async () => {
  const ok = await statusWorld({
    provider: "liftie",
    liftie: jsonResponse({ id: "vail", name: "Vail", lifts: { status: { "Gondola One": "hold" } } }),
  });
  await statusRefresh(post(authed), ok.deps);
  // The test bundle has no liftie aliases, so nothing maps: no row.
  assert(inserted(ok.calls).length === 0, "a bundle with no aliases for the provider writes nothing");
  assert(!ok.calls.some((c) => c.url.startsWith("https://www.vail.com/")), "Epic is not asked");

  const blocked = await statusWorld({
    provider: "liftie",
    liftie: new Response("<title>Just a moment...</title>", {
      status: 403,
      headers: { "content-type": "text/html", "cf-mitigated": "challenge" },
    }),
  });
  const response = await statusRefresh(post(authed), blocked.deps);
  assert(inserted(blocked.calls).length === 0, "a bot challenge writes no row");
  assert(
    (await response.json()).error === "Liftie request returned HTTP 403 (bot challenge)",
    "and is reported as what it is",
  );
  assertEquals(completed(blocked.calls).map((c) => c.body), [{ p_id: 7 }], "without a retry this cycle");
});

Deno.test("conditions-refresh skips a resort refreshed in the last 50 minutes", async () => {
  const { deps, calls } = fakeDeps((call: Call) => {
    if (call.url.endsWith("/rpc/jobs_claim")) {
      return jsonResponse([{ id: 9, kind: "conditions_refresh", resort_id: "vail", attempts: 1 }]);
    }
    if (call.url.includes("/rest/v1/resorts?")) {
      return jsonResponse([{ id: "vail", published: true, center: [-106.37, 39.62] }]);
    }
    if (call.url.includes("/rest/v1/resort_conditions?")) {
      return jsonResponse([{ observed_at: "2026-01-10T17:30:00Z" }]);
    }
    if (call.url.endsWith("/rpc/jobs_complete")) return new Response(null, { status: 204 });
    return new Response("unexpected " + call.url, { status: 500 });
  });
  const response = await conditionsRefresh(post(authed), deps);
  assert((await response.json()).skipped !== undefined, "skipped");
  assert(!calls.some((c) => c.url.includes("open-meteo")), "Open-Meteo is not called");
  assertEquals(completed(calls).map((c) => c.body), [{ p_id: 9 }], "the job is still completed");
});

Deno.test("conditions-refresh does not retry a failed Open-Meteo request within the hour", async () => {
  const { deps, calls } = fakeDeps((call: Call) => {
    if (call.url.endsWith("/rpc/jobs_claim")) {
      return jsonResponse([{ id: 9, kind: "conditions_refresh", resort_id: "vail", attempts: 1 }]);
    }
    if (call.url.includes("/rest/v1/resorts?")) {
      return jsonResponse([{ id: "vail", published: true, center: [-106.37, 39.62] }]);
    }
    if (call.url.includes("/rest/v1/resort_conditions?")) return jsonResponse([]);
    if (call.url.includes("open-meteo")) return new Response("busy", { status: 503 });
    if (call.url.endsWith("/rpc/jobs_complete")) return new Response(null, { status: 204 });
    return new Response("unexpected " + call.url, { status: 500 });
  });
  const response = await conditionsRefresh(post(authed), deps);
  assert((await response.json()).error !== undefined, "the failure is reported");
  assert(!calls.some((c) => c.url.endsWith("/rest/v1/resort_conditions")), "no row is written");
  assertEquals(completed(calls).map((c) => c.body), [{ p_id: 9 }], "and the job is completed without a retry");
});

// A throwaway P-256 key in PKCS#8, generated for the test run.
async function testKeyPem(): Promise<string> {
  const pair = await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"]);
  const der = new Uint8Array(await crypto.subtle.exportKey("pkcs8", pair.privateKey));
  let binary = "";
  for (const byte of der) binary += String.fromCharCode(byte);
  return `-----BEGIN PRIVATE KEY-----\n${btoa(binary)}\n-----END PRIVATE KEY-----`;
}

Deno.test("push-drain sends each claimed row, routes by environment and reports dead tokens", async () => {
  const apnsEnv = {
    APNS_AUTH_KEY: await testKeyPem(),
    APNS_KEY_ID: "KEY1234567",
    APNS_TEAM_ID: "TEAM123456",
    APNS_BUNDLE_ID: "com.powdermeet.PowderMeet",
  };
  const meetId = "10000000-0000-4000-8000-000000000001";
  const { deps, calls } = fakeDeps((call: Call) => {
    if (call.url.endsWith("/rpc/push_outbox_claim")) {
      return jsonResponse([
        {
          id: 1,
          user_id: "u1",
          kind: "meet.proposed",
          payload: { meet_id: meetId, rendezvous_id: "roundhouse-lodge", partner_name: "Alex" },
          tokens: [{ token: "aaaa", environment: "development" }, { token: "dead", environment: "production" }],
        },
        { id: 2, user_id: "u2", kind: "friend.accepted", payload: { display_name: "Sam" }, tokens: [] },
        {
          id: 3,
          user_id: "u3",
          kind: "meet.ended",
          payload: { meet_id: meetId, end_reason: "partner_left", partner_name: "Alex" },
          tokens: [{ token: "busy", environment: "production" }],
        },
      ]);
    }
    if (call.url.endsWith("/3/device/aaaa")) return new Response(null, { status: 200 });
    if (call.url.endsWith("/3/device/dead")) return jsonResponse({ reason: "Unregistered" }, 410);
    if (call.url.endsWith("/3/device/busy")) return jsonResponse({ reason: "TooManyRequests" }, 429);
    if (call.url.endsWith("/rpc/push_outbox_complete")) return new Response(null, { status: 204 });
    return new Response("unexpected " + call.url, { status: 500 });
  }, apnsEnv);

  const response = await pushDrain(post(authed), deps);
  assertEquals(await response.json(), { claimed: 3, sent: 2, failed: 1 }, "summary");

  const sandbox = calls.find((c) => c.url.endsWith("/3/device/aaaa"))!;
  assert(sandbox.url.startsWith("https://api.sandbox.push.apple.com/"), "development tokens go to the sandbox host");
  assert(
    calls.find((c) => c.url.endsWith("/3/device/dead"))!.url.startsWith("https://api.push.apple.com/"),
    "production tokens go to the production host",
  );
  assert(sandbox.headers.get("apns-collapse-id") === meetId, "apns-collapse-id is the meet id");
  assert(sandbox.headers.get("apns-topic") === "com.powdermeet.PowderMeet", "topic is the bundle id");
  assert(/^bearer [\w-]+\.[\w-]+\.[\w-]+$/.test(sandbox.headers.get("authorization") ?? ""), "signed provider token");
  assertEquals(
    ((sandbox.body as Record<string, unknown>).aps as Record<string, unknown>).alert,
    { title: "Meet request", body: "Alex wants to meet at Roundhouse Lodge." },
    "alert text",
  );

  const outcomes = calls.filter((c) => c.url.endsWith("/rpc/push_outbox_complete")).map((c) => c.body)
    .sort((a, b) => (a as { p_id: number }).p_id - (b as { p_id: number }).p_id);
  assertEquals(outcomes, [
    { p_id: 1, p_error: null, p_dead_tokens: ["dead"] },
    { p_id: 2, p_error: null, p_dead_tokens: null },
    { p_id: 3, p_error: "apns 429 TooManyRequests", p_dead_tokens: null },
  ], "sent with a dead token removed; nothing to send; failed and left for retry");
});

Deno.test("push-drain retries a row when one device failed and keeps a token on a topic mismatch", async () => {
  const { deps, calls } = fakeDeps((call: Call) => {
    if (call.url.endsWith("/rpc/push_outbox_claim")) {
      return jsonResponse([{
        id: 7,
        user_id: "u1",
        kind: "friend.accepted",
        payload: { display_name: "Sam" },
        tokens: [
          { token: "phone", environment: "production" },
          { token: "pad", environment: "production" },
          { token: "wrong", environment: "production" },
        ],
      }]);
    }
    if (call.url.endsWith("/3/device/phone")) return new Response(null, { status: 200 });
    if (call.url.endsWith("/3/device/pad")) return jsonResponse({ reason: "ServiceUnavailable" }, 503);
    if (call.url.endsWith("/3/device/wrong")) return jsonResponse({ reason: "DeviceTokenNotForTopic" }, 400);
    if (call.url.endsWith("/rpc/push_outbox_complete")) return new Response(null, { status: 204 });
    return new Response("unexpected " + call.url, { status: 500 });
  }, {
    APNS_AUTH_KEY: await testKeyPem(),
    APNS_KEY_ID: "KEY1234567",
    APNS_TEAM_ID: "TEAM123456",
    APNS_BUNDLE_ID: "com.powdermeet.PowderMeet",
  });
  const response = await pushDrain(post(authed), deps);
  assertEquals(await response.json(), { claimed: 1, sent: 0, failed: 1 }, "summary");
  const complete = calls.find((c) => c.url.endsWith("/rpc/push_outbox_complete"))!.body as Record<string, unknown>;
  assert(String(complete.p_error).includes("503"), "the failed device keeps the row for retry");
  assertEquals(complete.p_dead_tokens, null, "a topic mismatch never deletes a token");
});

Deno.test("push-drain leaves rows for retry when APNs is not configured", async () => {
  const { deps, calls } = fakeDeps((call: Call) => {
    if (call.url.endsWith("/rpc/push_outbox_claim")) {
      return jsonResponse([{
        id: 4,
        user_id: "u1",
        kind: "meet.accepted",
        payload: {},
        tokens: [{ token: "aaaa", environment: "production" }],
      }]);
    }
    if (call.url.endsWith("/rpc/push_outbox_complete")) return new Response(null, { status: 204 });
    return new Response("unexpected " + call.url, { status: 500 });
  });
  await pushDrain(post(authed), deps);
  const outcome = calls.find((c) => c.url.endsWith("/rpc/push_outbox_complete"))!.body as { p_error: string };
  assert(outcome.p_error.startsWith("APNs is not configured"), "the row records why it was not sent");
  assert(!calls.some((c) => c.url.includes("push.apple.com")), "and nothing is sent");
});

Deno.test("avatar-sweep removes every orphan through the Storage API and completes the job", async () => {
  const batches = [["b0000000-0000-4000-8000-00000000000b/x.jpg", "a0000000-0000-4000-8000-00000000000a/old.jpg"], []];
  const { deps, calls } = fakeDeps((call) => {
    if (call.url.endsWith("/rpc/jobs_claim")) return jsonResponse([{ id: 9, kind: "avatar_sweep", resort_id: null, attempts: 1 }]);
    if (call.url.endsWith("/rpc/avatar_orphans")) return jsonResponse(batches.shift());
    if (call.url === "http://db.test/storage/v1/object/avatars" && call.method === "DELETE") {
      return jsonResponse((call.body as { prefixes: string[] }).prefixes.map((name) => ({ name })));
    }
    if (call.url.endsWith("/rpc/jobs_complete")) return new Response(null, { status: 204 });
    return new Response("unexpected " + call.url, { status: 500 });
  });
  const response = await avatarSweep(post(authed), deps);
  assertEquals(await response.json(), { claimed: 1, job: 9, resort_id: null, removed: 2 }, "both orphans removed");
  const removal = calls.filter((c) => c.url.includes("/storage/v1/"));
  assertEquals(removal.map((c) => c.body), [{ prefixes: [
    "b0000000-0000-4000-8000-00000000000b/x.jpg",
    "a0000000-0000-4000-8000-00000000000a/old.jpg",
  ] }], "one removal call with the listed paths");
  assert(removal[0].headers.get("authorization") === "Bearer service-key", "with the service role");
  assertEquals(calls.filter((c) => c.url.endsWith("/rpc/jobs_complete")).map((c) => c.body), [{ p_id: 9 }],
    "the job is completed without an error");
});

Deno.test("avatar-sweep keeps the job for retry when Storage refuses", async () => {
  const { deps, calls } = fakeDeps((call) => {
    if (call.url.endsWith("/rpc/jobs_claim")) return jsonResponse([{ id: 9, kind: "avatar_sweep", resort_id: null, attempts: 1 }]);
    if (call.url.endsWith("/rpc/avatar_orphans")) return jsonResponse(["b0000000-0000-4000-8000-00000000000b/x.jpg"]);
    if (call.url.includes("/storage/v1/")) return new Response("down", { status: 503 });
    if (call.url.endsWith("/rpc/jobs_complete")) return new Response(null, { status: 204 });
    return new Response("unexpected " + call.url, { status: 500 });
  });
  await avatarSweep(post(authed), deps);
  const [complete] = calls.filter((c) => c.url.endsWith("/rpc/jobs_complete"));
  assert(typeof (complete.body as { p_error?: string }).p_error === "string", "the failure is written back to the job");
});
