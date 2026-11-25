// The sample below is written from the response shape in `liftie.ts`. It is
// not a captured response: Liftie answered this project's automated requests
// with a Cloudflare challenge, which the second test covers.
import { fetchLiftieStatus, liftieURL, parseLiftieStatus } from "./liftie.ts";
import { projectStatus } from "./status.ts";
import { assert, assertEquals, assertRejects } from "../testing.ts";

const now = new Date("2026-01-02T12:30:00Z");

function sample(extra: Record<string, unknown> = {}) {
  return {
    id: "vail",
    name: "Vail",
    ll: [-106.3742, 39.6403],
    lifts: {
      status: {
        "Gondola One": "open",
        "Avanti Express #2": "hold",
        "Riva Bahn Express #6": "closed",
        "Born Free Express #8": "scheduled",
        "Mystery Chair": "sideways",
      },
      stats: { open: 1, hold: 1, scheduled: 1, closed: 1, percentage: { open: 25, hold: 25, scheduled: 25, closed: 25 } },
    },
    weather: { temperature: 21, forecast: "Snow" },
    timestamp: { lifts: Date.parse("2026-01-02T12:20:00Z"), weather: Date.parse("2026-01-02T12:00:00Z") },
    ...extra,
  };
}

Deno.test("Liftie reports lifts only, and a lift that is not turning is not open", () => {
  const data = parseLiftieStatus(sample(), "vail", now);
  assert(data.source === "liftie" && data.mode === "active", "source");
  assert(data.trails.length === 0, "Liftie cannot establish trail status");
  assertEquals(
    data.lifts,
    [
      { name: "Gondola One", state: "open" },
      { name: "Avanti Express #2", state: "hold" },
      { name: "Riva Bahn Express #6", state: "closed" },
      { name: "Born Free Express #8", state: "hold" },
    ],
    "open, hold, closed, scheduled; an unknown status is dropped",
  );
  assert(data.observedAt === "2026-01-02T12:20:00.000Z", "the feed's lift timestamp is the observation time");
  assert(parseLiftieStatus(sample({ timestamp: undefined }), "vail", now).observedAt === null, "the timestamp is optional");
  assert(liftieURL("mammoth") === "https://liftie.info/api/resort/mammoth-mountain", "ids that differ are mapped");

  const row = projectStatus(data, {
    aliases: { liftie: { "Gondola One": "lift:gondola-one", "Avanti Express #2": "lift:avanti-express" } },
    liftGroups: ["lift:gondola-one", "lift:avanti-express"],
    trailGroups: ["trail:riva-ridge"],
  }, now);
  assertEquals(row?.groups, { "lift:avanti-express": "hold", "lift:gondola-one": "open" }, "lift groups only");
});

Deno.test("a challenge page, a wrong resort, a stale or empty response all fail closed", async () => {
  const challenge = () =>
    Promise.resolve(
      new Response("<!DOCTYPE html><title>Just a moment...</title>", {
        status: 403,
        headers: { "content-type": "text/html", "cf-mitigated": "challenge" },
      }),
    );
  let message = "";
  try {
    await fetchLiftieStatus("vail", challenge, now);
  } catch (error) {
    message = (error as Error).message;
  }
  assert(message === "Liftie request returned HTTP 403 (bot challenge)", "a bot challenge is a refusal, not data");
  await assertRejects(
    () => fetchLiftieStatus("vail", () => Promise.resolve(new Response("<html>ok</html>", { headers: { "content-type": "text/html" } })), now),
    "an HTML page with status 200 is not a status",
  );
  await assertRejects(() => parseLiftieStatus(sample({ id: "beaver-creek" }), "vail", now), "wrong resort");
  await assertRejects(() => parseLiftieStatus(sample({ lifts: { status: {} } }), "vail", now), "no lifts");
  await assertRejects(() => parseLiftieStatus(sample({ lifts: undefined }), "vail", now), "no lifts block");
  await assertRejects(
    () => parseLiftieStatus(sample({ timestamp: { lifts: Date.parse("2026-01-02T10:00:00Z") } }), "vail", now),
    "a stale observation never becomes current status",
  );
  await assertRejects(
    () => parseLiftieStatus(sample({ timestamp: { lifts: Date.parse("2026-01-03T10:00:00Z") } }), "vail", now),
    "nor one stamped in the future",
  );
});
