import { parseEpicTerrainStatus } from "./epic.ts";
import { parseBundleStatusMeta } from "./bundle.ts";
import { parseOpenMeteo } from "./open_meteo.ts";
import { type BundleStatusMeta, canonicalNameKey, projectStatus } from "./status.ts";
import { assert, assertEquals, assertRejects } from "../testing.ts";

const now = new Date("2026-01-02T12:05:00Z");

function epic(trails: unknown[], lifts: unknown[], date = "2026-01-02T12:00:00Z") {
  return parseEpicTerrainStatus(
    `FR.TerrainStatusFeed = ${JSON.stringify({ Date: date, GroomingAreas: [{ Trails: trails, Lifts: lifts }] })};`,
    now,
  );
}

const meta: BundleStatusMeta = parseBundleStatusMeta({
  status_aliases: {
    epic: {
      "Riva Ridge": "trail:riva-ridge",
      "Riva Ridge Lower": "trail:riva-ridge",
      "Prima": "trail:prima",
      "Gondola One": "lift:gondola-one",
      "Avanti Express #2": "lift:avanti-express",
      "Riva Bahn #6": "lift:riva-bahn",
      "Chair 5": "lift:chair-5",
      "High Noon #5": "lift:high-noon",
    },
  },
  groups: [
    { id: "trail:riva-ridge", kind: "trail" },
    { id: "trail:prima", kind: "trail" },
    { id: "trail:unlisted", kind: "trail" },
    { id: "lift:gondola-one", kind: "lift" },
    { id: "lift:avanti-express", kind: "lift" },
    { id: "lift:riva-bahn", kind: "lift" },
    { id: "lift:chair-5", kind: "lift" },
    { id: "lift:high-noon", kind: "lift" },
  ],
});

Deno.test("projection maps provider names to group ids through the bundle's aliases", () => {
  const row = projectStatus(
    epic(
      [
        { Name: "  RIVA   Ridge ", TrailType: "Skiing", IsOpen: true, IsGroomed: true },
        { Name: "Riva Ridge Lower", TrailType: "Skiing", IsOpen: false, IsGroomed: true },
        { Name: "Prima", TrailType: "Skiing", IsOpen: true, IsGroomed: true },
        { Name: "Not In The Bundle", TrailType: "Skiing", IsOpen: false },
      ],
      [
        { Name: "Gondola One", Status: "Open" },
        { Name: "Avanti Express #2", Status: "Hold" },
        { Name: "Riva Bahn #6", Status: "Closed" },
        { Name: "Chair 5", Status: "Open" },
      ],
    ),
    meta,
    now,
  );
  assert(row !== null, "an active feed produces a row");
  assert(canonicalNameKey(" RIVA   Ridge ") === "riva ridge", "normalization changed");
  assertEquals(row.groups, {
    "lift:avanti-express": "hold",
    "lift:chair-5": "open",
    "lift:gondola-one": "open",
    // Not in the feed: no live information, use operating hours.
    "lift:high-noon": "scheduled",
    "lift:riva-bahn": "closed",
    "trail:prima": "open",
    // One open segment never makes a partly closed trail look open (I-15).
    "trail:riva-ridge": "closed",
  }, "group states");
  assertEquals(row.groomed, ["trail:prima"], "only open, groomed trails are listed as groomed");
  assert(row.source === "epic", "source is the provider");
  assert(row.observed_at === "2026-01-02T12:00:00.000Z", "the feed's own time is the observation time");
  assert(row.expires_at === "2026-01-02T13:15:00.000Z", "a row expires 75 minutes after it was observed");
});

Deno.test("no row unless 80 % of lift groups are mapped", async () => {
  const feed = epic(
    [{ Name: "Prima", TrailType: "Skiing", IsOpen: true }],
    [
      { Name: "Gondola One", Status: "Open" },
      { Name: "Avanti Express #2", Status: "Open" },
      { Name: "Riva Bahn #6", Status: "Open" },
    ],
  );
  await assertRejects(() => projectStatus(feed, meta, now), "3 of 5 lift groups is not enough");
  await assertRejects(
    () => projectStatus(feed, { aliases: {}, liftGroups: ["lift:a"], trailGroups: [] }, now),
    "a bundle with no aliases for the provider maps nothing",
  );
});

Deno.test("conflicting duplicates and cross-kind aliases are dropped, not guessed", async () => {
  const feed = epic(
    [
      { Name: "Prima", TrailType: "Skiing", IsOpen: true },
      { Name: "PRIMA", TrailType: "Skiing", IsOpen: false },
      // A trail whose name is aliased to a lift group must not set the lift.
      { Name: "Chair 5", TrailType: "Skiing", IsOpen: true },
    ],
    [
      { Name: "Gondola One", Status: "Open" },
      { Name: "Avanti Express #2", Status: "Open" },
      { Name: "Riva Bahn #6", Status: "Open" },
      { Name: "High Noon #5", Status: "Open" },
    ],
  );
  const row = projectStatus(feed, meta, now);
  assert(row !== null, "4 of 5 lift groups is enough");
  assert(!("trail:prima" in row.groups), "a name with two different states is omitted");
  assert(row.groups["lift:chair-5"] === "scheduled", "a trail entry cannot set a lift group");

  const stale = epic([{ Name: "Prima", TrailType: "Skiing", IsOpen: true }], [
    { Name: "Gondola One", Status: "Open" },
    { Name: "Avanti Express #2", Status: "Open" },
    { Name: "Riva Bahn #6", Status: "Open" },
    { Name: "High Noon #5", Status: "Open" },
  ], "2026-01-01T08:00:00Z");
  await assertRejects(
    () => projectStatus(stale, meta, now),
    "an old feed stamp is refused, never stored as fresh",
  );
  const future = epic([{ Name: "Prima", TrailType: "Skiing", IsOpen: true }], [
    { Name: "Gondola One", Status: "Open" },
    { Name: "Avanti Express #2", Status: "Open" },
    { Name: "Riva Bahn #6", Status: "Open" },
    { Name: "High Noon #5", Status: "Open" },
  ], "2026-01-02T14:00:00Z");
  await assertRejects(() => projectStatus(future, meta, now), "a stamp in the future is refused");
  const undated = { ...future, observedAt: null };
  await assertRejects(() => projectStatus(undated, meta, now), "a missing stamp is refused");
  await assertRejects(() => parseBundleStatusMeta({ nodes: [] }), "a bundle without groups is refused");
});

Deno.test("off-season feeds write nothing", () => {
  const summer = epic([{ Name: "Bike Park", TrailType: "Biking", IsOpen: true }], [
    { Name: "Gondola One", Status: "Open" },
  ]);
  assert(projectStatus(summer, meta, now) === null, "off season produces no row");
});

Deno.test("Open-Meteo response becomes a conditions row and a short response fails", async () => {
  const hours = 72;
  const start = Date.parse("2026-01-01T00:00:00Z") / 1000;
  const time = Array.from({ length: hours }, (_, i) => start + i * 3600);
  const fill = (v: number) => Array.from({ length: hours }, () => v);
  const body = {
    current: { temperature_2m: -4, wind_speed_10m: 6.1, wind_gusts_10m: 11, visibility: 8000, cloud_cover: 70, weather_code: 71 },
    hourly: {
      time,
      temperature_2m: fill(-5),
      wind_speed_10m: fill(5),
      wind_gusts_10m: fill(9),
      visibility: fill(9000),
      cloud_cover: fill(60),
      precipitation: fill(0.4),
      snowfall: fill(0.5),
      weather_code: fill(71),
    },
  };
  const row = parseOpenMeteo(body, now);
  assert(row.source === "open-meteo" && row.current.temp_c === -4, "current block is used");
  assert(row.current.snow_24h_cm === 12, "24 hours of 0.5 cm an hour is 12 cm");
  assert(row.hourly.length === 24 && row.hourly[0].at === "2026-01-02T13:00:00.000Z", "the next 24 hours");
  assert(row.expires_at === "2026-01-02T13:35:00.000Z", "conditions expire after 90 minutes");
  await assertRejects(
    () => parseOpenMeteo({ current: {}, hourly: { time, temperature_2m: fill(1) } }, now),
    "a response missing a series fails closed",
  );
});

Deno.test("live waits travel with running lifts only, longest name wins", () => {
  const row = projectStatus(
    epic(
      [{ Name: "Prima", TrailType: "Skiing", IsOpen: true }],
      [
        { Name: "Gondola One", Status: "Open", WaitTimeInMinutes: 12 },
        { Name: "Avanti Express #2", Status: "Hold", WaitTimeInMinutes: "4" },
        // Closed: its last queue says nothing about routing.
        { Name: "Riva Bahn #6", Status: "Closed", WaitTimeInMinutes: 9 },
        // No wait reported: unknown, not zero.
        { Name: "Chair 5", Status: "Open" },
        // Beyond belief: dropped.
        { Name: "High Noon #5", Status: "Open", WaitTimeInMinutes: 999 },
      ],
    ),
    meta,
    now,
  );
  assert(row !== null, "an active feed produces a row");
  assertEquals(row.wait_minutes, { "lift:avanti-express": 4, "lift:gondola-one": 12 }, "waits");
});
