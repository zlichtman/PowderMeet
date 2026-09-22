import { parseMtnPowderStatus } from "./mtnpowder_status.ts";
import { createTerrainStatusFetcher } from "./terrain_status.ts";
import { projectCanonicalStatus } from "./live_status.ts";
const now = new Date("2026-01-02T12:30:00Z");
function assert(x: unknown, message: string): asserts x {
  if (!x) throw new Error(message);
}
function resort(Name = "Stratton", extra: Record<string, unknown> = {}) {
  return {
    Name,
    LastUpdate: "2026-01-02T12:00:00Z",
    OperatingStatus: "Open",
    MountainAreas: [{
      Trails: [
        { Name: "Alpine", TrailIcon: "BlueSquare", StatusEnglish: "open" },
        { Name: "Closed", TrailIcon: "GreenCircle", StatusEnglish: "closed" },
        { Name: "Walk", TrailIcon: "Snowshoe", StatusEnglish: "open" },
        {
          Name: "Mystery",
          TrailIcon: "BlackDiamond",
          StatusEnglish: "unknown",
        },
      ],
      Lifts: [{ Name: "Express", StatusEnglish: "open", WaitTime: "4" }, {
        Name: "Hold",
        StatusEnglish: "wind_hold",
      }],
    }],
    ...extra,
  };
}
function reject(data: unknown, id = "stratton") {
  let failed = false;
  try {
    parseMtnPowderStatus(data, id, now);
  } catch {
    failed = true;
  }
  assert(failed, "invalid source must fail closed");
}
Deno.test("MtnPowder keeps winter status, waits, closures and source observation time", () => {
  const data = parseMtnPowderStatus({ Resorts: [resort()] }, "stratton", now);
  assert(
    data.trails.length === 2 && data.trails[0].status.is_open,
    "only known downhill statuses",
  );
  assert(
    !data.trails[1].status.is_open && !data.lifts[1].status.is_open,
    "closures retained",
  );
  assert(data.lifts[0].status.wait_minutes === 4, "wait minutes retained");
  assert(
    data.observedAt === "2026-01-02T12:00:00.000Z",
    "fetch cannot renew observation time",
  );
});
Deno.test("closed resort cannot inherit stale open trail flags", () => {
  const data = parseMtnPowderStatus(
    { Resorts: [resort("Stratton", { OperatingStatus: "Closed" })] },
    "stratton",
    now,
  );
  assert(
    [...data.trails, ...data.lifts].every((x) => !x.status.is_open),
    "closed resort stays closed",
  );
});
Deno.test("forecast-only, summer-only, duplicate and wrong-resort responses are rejected", () => {
  for (
    const entry of [
      resort("Stratton Summer"),
      resort("Windham Mountain"),
      resort("Stratton", { MountainAreas: undefined }),
      resort("Stratton", { OperatingStatus: "Unknown" }),
    ]
  ) {
    reject({ Resorts: [entry] });
  }
  reject({ Resorts: [resort(), resort()] });
  reject({ Resorts: [resort("Windham Mountain")] }, "hunter");
  reject({ Resorts: "not-an-array" });
});
Deno.test("missing, stale and future observations never become current status", () => {
  for (
    const LastUpdate of [
      null,
      "invalid",
      "2026-01-02T11:30:00Z",
      "2026-01-03T12:00:00Z",
    ]
  ) {
    reject({ Resorts: [resort("Stratton", { LastUpdate })] });
  }
});
Deno.test("combined resort requires every mapped winter area and preserves conflicting names", () => {
  reject({ Resorts: [resort("Bear Mountain")] }, "big-bear");
  const second = resort("Snow Summit", { OperatingStatus: "Closed" });
  const data = parseMtnPowderStatus(
    { Resorts: [resort("Bear Mountain"), second] },
    "big-bear",
    now,
  );
  const projected = projectCanonicalStatus(data, ["Alpine", "Closed"], [
    "Express",
  ]);
  assert(
    !("Alpine" in projected.trails) && !("Express" in projected.lifts),
    "conflicting duplicate identities are not picked arbitrarily",
  );
});
Deno.test("season-closed winter terrain cannot expose summer lift operations", () => {
  const entry = resort();
  for (const t of entry.MountainAreas[0].Trails) {
    t.StatusEnglish = "closed_for_season";
  }
  const data = parseMtnPowderStatus({ Resorts: [entry] }, "stratton", now);
  assert(
    data.mode === "off_season" && !data.lifts.length && !data.trails.length,
    "season closure is explicit",
  );
});
Deno.test("a refresh downloads the shared terrain feed once and isolates HTTP failure", async () => {
  let calls = 0;
  const loader = createTerrainStatusFetcher(async () => {
    calls++;
    return Response.json({ Resorts: [resort(), resort("Snowshoe")] });
  });
  await loader("stratton", now);
  await loader("snowshoe", now);
  assert(calls === 1, "one download per batch");
  const broken = createTerrainStatusFetcher(async () =>
    new Response("upstream down", { status: 503 })
  );
  let rejected = false;
  try {
    await broken("stratton", now);
  } catch {
    rejected = true;
  }
  assert(rejected, "unavailable feed is never empty success");
});
