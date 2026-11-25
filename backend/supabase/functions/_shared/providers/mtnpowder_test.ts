import { parseMtnPowderStatus } from "./mtnpowder.ts";
import { projectStatus } from "./status.ts";
import { assert, assertRejects } from "../testing.ts";

const now = new Date("2026-01-02T12:30:00Z");

function resort(Name = "Stratton", extra: Record<string, unknown> = {}) {
  return {
    Name,
    LastUpdate: "2026-01-02T12:00:00Z",
    OperatingStatus: "Open",
    MountainAreas: [{
      Trails: [
        { Name: "Alpine", TrailIcon: "BlueSquare", StatusEnglish: "open", Grooming: "Yes" },
        { Name: "Closed", TrailIcon: "GreenCircle", StatusEnglish: "closed" },
        { Name: "Walk", TrailIcon: "Snowshoe", StatusEnglish: "open" },
        { Name: "Mystery", TrailIcon: "BlackDiamond", StatusEnglish: "unknown" },
      ],
      Lifts: [
        { Name: "Express", StatusEnglish: "open", WaitTime: "4" },
        { Name: "Hold", StatusEnglish: "wind_hold" },
      ],
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
  assert(data.trails.length === 2 && data.trails[0].state === "open", "only known downhill statuses");
  assert(data.trails[0].groomed === true, "grooming is carried for open trails");
  assert(data.trails[1].state === "closed" && data.lifts[1].state === "hold", "closures and holds retained");
  assert(data.lifts[0].wait_minutes === 4, "wait minutes retained");
  assert(data.observedAt === "2026-01-02T12:00:00.000Z", "fetch cannot renew observation time");
});

Deno.test("closed resort cannot inherit stale open trail flags", () => {
  const data = parseMtnPowderStatus(
    { Resorts: [resort("Stratton", { OperatingStatus: "Closed" })] },
    "stratton",
    now,
  );
  assert([...data.trails, ...data.lifts].every((x) => x.state === "closed"), "closed resort stays closed");
  assert(data.trails.every((x) => !x.groomed), "and reports no grooming");
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
  for (const LastUpdate of [null, "invalid", "2026-01-02T11:30:00Z", "2026-01-03T12:00:00Z"]) {
    reject({ Resorts: [resort("Stratton", { LastUpdate })] });
  }
});

Deno.test("combined resort requires every mapped winter area and never picks between conflicting names", async () => {
  reject({ Resorts: [resort("Bear Mountain")] }, "big-bear");
  const second = resort("Snow Summit", { OperatingStatus: "Closed" });
  const data = parseMtnPowderStatus({ Resorts: [resort("Bear Mountain"), second] }, "big-bear", now);
  // "Express" is open at one area and closed at the other: the name is
  // ambiguous, so its lift group is not mapped and the row is refused.
  await assertRejects(
    () =>
      projectStatus(data, {
        aliases: { mtnpowder: { Express: "lift:express", Alpine: "trail:alpine" } },
        liftGroups: ["lift:express"],
        trailGroups: ["trail:alpine"],
      }, now),
    "conflicting duplicate identities are not picked arbitrarily",
  );
});

Deno.test("season-closed winter terrain cannot expose summer lift operations", () => {
  const entry = resort();
  for (const t of entry.MountainAreas[0].Trails) t.StatusEnglish = "closed_for_season";
  const data = parseMtnPowderStatus({ Resorts: [entry] }, "stratton", now);
  assert(data.mode === "off_season" && !data.lifts.length && !data.trails.length, "season closure is explicit");
});

Deno.test("a lift the resort expects to open is on hold, not left out", () => {
  const entry = resort("Stratton");
  entry.MountainAreas[0].Lifts.push({ Name: "Morning", StatusEnglish: "expected" });
  const data = parseMtnPowderStatus({ Resorts: [entry] }, "stratton", now);
  const morning = data.lifts.find((lift) => lift.name === "Morning");
  assert(morning?.state === "hold", "an expected lift is kept as a hold");
});
