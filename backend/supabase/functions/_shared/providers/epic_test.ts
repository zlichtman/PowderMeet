import { fetchEpicTerrainStatus, parseEpicTerrainStatus } from "./epic.ts";
import { assert, assertRejects } from "../testing.ts";

function feed(areas: unknown[], date = "2026-01-02T12:00:00Z"): string {
  return `<script>FR.TerrainStatusFeed = ${JSON.stringify({ Date: date, GroomingAreas: areas })};</script>`;
}

Deno.test("Epic parser balances braces inside strings and uses the last valid assignment", () => {
  const numeric = feed([{ Name: "First", Trails: [], Lifts: [] }]);
  const display = feed([{
    Name: "Game Creek {North}",
    Trails: [{ Name: "Dealer's Choice {Upper}", TrailType: "Skiing", IsOpen: true }],
    Lifts: [{ Name: "Game Creek Express", Status: "Open", WaitTimeInMinutes: "4" }],
  }]);
  const parsed = parseEpicTerrainStatus(`${numeric}\n${display}`);
  assert(parsed.mode === "active", "winter feed should be active");
  assert(parsed.trails[0]?.name === "Dealer's Choice {Upper}", "string braces must not terminate JSON");
  assert(parsed.lifts[0]?.wait_minutes === 4, "numeric wait strings should parse");
});

Deno.test("summer-only Epic feed is neutral and cannot alter ski lifts", () => {
  const parsed = parseEpicTerrainStatus(feed([{
    Name: "All Summer Terrain",
    Trails: [
      { Name: "Avanti Lane", TrailType: "Biking", IsOpen: true },
      { Name: "Meadow Loop", TrailType: 2, IsOpen: false },
    ],
    Lifts: [{ Name: "Gondola One", Status: "Open", WaitTimeInMinutes: 5 }],
  }]));
  assert(parsed.mode === "off_season", "summer feed should be explicitly off-season");
  assert(parsed.trails.length === 0 && parsed.lifts.length === 0, "summer status must be neutral");
});

Deno.test("winter Epic feed parses open, closed, hold, grooming and waits", () => {
  const parsed = parseEpicTerrainStatus(feed([{
    Name: "Front Side",
    Trails: [
      { Name: "Riva Ridge", TrailType: "Skiing", IsOpen: true, IsGroomed: true },
      { Name: "Prima", TrailType: 1, IsOpen: false },
      { Name: "Bike Trail", TrailType: "Biking", IsOpen: true },
    ],
    Lifts: [
      { Name: "Avanti Express #2", Status: "Operating", WaitTimeInMinutes: 7 },
      { Name: "Riva Bahn #6", Status: "Hold" },
      { Name: "Gondola One", Status: "Closed" },
      { Name: "Chair 5", Status: "Scheduled" },
      { Name: "Mystery", Status: "Sideways" },
    ],
  }]));
  assert(parsed.mode === "active" && parsed.trails.length === 2, "only ski trails should parse");
  assert(parsed.trails[0].groomed === true && parsed.trails[0].state === "open", "grooming is carried");
  assert(parsed.trails[1].state === "closed", "closed trail should remain closed");
  assert(parsed.lifts[0].state === "open" && parsed.lifts[0].wait_minutes === 7, "open lift wait missing");
  assert(parsed.lifts[1].state === "hold", "hold must not be routable");
  assert(parsed.lifts[2].state === "closed", "closed lift");
  assert(parsed.lifts[3].state === "hold", "a lift that is scheduled but not turning is not open");
  assert(parsed.lifts.length === 4, "an unknown lift status is dropped, never guessed");
});

Deno.test("an Epic page missing under one spelling is fetched under the other", async () => {
  const asked: string[] = [];
  const parsed = await fetchEpicTerrainStatus("okemo", (input) => {
    const url = String(input);
    asked.push(url);
    return Promise.resolve(
      url.endsWith("terrain-and-lift-status.aspx")
        ? new Response("not here", { status: 404 })
        : new Response(feed([{
          Name: "Main Face",
          Trails: [{ Name: "Upper Arrow", TrailType: "Skiing", IsOpen: true }],
          Lifts: [{ Name: "Sunburst Six", Status: "Open" }],
        }])),
    );
  });
  assert(asked.length === 2 && asked[1].endsWith("lift-and-terrain-status.aspx"), "second spelling tried");
  assert(parsed.lifts[0]?.name === "Sunburst Six", "the page found under the second spelling is parsed");

  asked.length = 0;
  await fetchEpicTerrainStatus("okemo", (input) => {
    asked.push(String(input));
    return Promise.resolve(new Response(feed([{ Name: "Main Face", Trails: [], Lifts: [] }])));
  });
  assert(
    asked.length === 1 && asked[0].endsWith("lift-and-terrain-status.aspx"),
    "the spelling that answered is asked first next time",
  );
});

Deno.test("malformed and unavailable Epic sources fail instead of becoming empty success", async () => {
  await assertRejects(
    () => parseEpicTerrainStatus("FR.TerrainStatusFeed = {not-json};"),
    "malformed source must fail",
  );
  await assertRejects(
    () => fetchEpicTerrainStatus("vail", () => Promise.resolve(new Response("nope", { status: 503 }))),
    "HTTP failure must not produce an empty status",
  );
  await assertRejects(
    () => fetchEpicTerrainStatus("not-an-epic-resort", () => Promise.resolve(new Response(""))),
    "a resort with no Epic source must fail",
  );
});
