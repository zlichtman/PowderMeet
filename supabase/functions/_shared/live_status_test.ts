import {
  canonicalNameKey,
  fetchEpicTerrainStatus,
  parseEpicTerrainStatus,
  projectCanonicalStatus,
} from "./live_status.ts";

function assert(condition: unknown, message: string): asserts condition {
  if (!condition) throw new Error(message);
}

function feed(areas: unknown[], date = "2026-01-02T12:00:00Z"): string {
  return `<script>FR.TerrainStatusFeed = ${
    JSON.stringify({
      Date: date,
      GroomingAreas: areas,
    })
  };</script>`;
}

Deno.test("Epic parser balances braces inside strings and uses the last valid assignment", () => {
  const numeric = feed([{ Name: "First", Trails: [], Lifts: [] }]);
  const display = feed([{
    Name: "Game Creek {North}",
    Trails: [{
      Name: "Dealer's Choice {Upper}",
      TrailType: "Skiing",
      IsOpen: true,
    }],
    Lifts: [{
      Name: "Game Creek Express",
      Status: "Open",
      WaitTimeInMinutes: "4",
    }],
  }]);
  const parsed = parseEpicTerrainStatus(`${numeric}\n${display}`);
  assert(parsed.mode === "active", "winter feed should be active");
  assert(
    parsed.trails[0]?.name === "Dealer's Choice {Upper}",
    "string braces must not terminate JSON",
  );
  assert(
    parsed.lifts[0]?.status.wait_minutes === 4,
    "numeric wait strings should parse",
  );
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
  assert(
    parsed.mode === "off_season",
    "summer feed should be explicitly off-season",
  );
  assert(
    parsed.trails.length === 0 && parsed.lifts.length === 0,
    "summer status must be neutral",
  );
});

Deno.test("winter Epic feed parses open, closed, and waits", () => {
  const parsed = parseEpicTerrainStatus(feed([{
    Name: "Front Side",
    Trails: [
      { Name: "Riva Ridge", TrailType: "Skiing", IsOpen: true },
      { Name: "Prima", TrailType: 1, IsOpen: false },
      { Name: "Bike Trail", TrailType: "Biking", IsOpen: true },
    ],
    Lifts: [
      { Name: "Avanti Express #2", Status: "Operating", WaitTimeInMinutes: 7 },
      { Name: "Riva Bahn #6", Status: "Hold" },
    ],
  }]));
  assert(
    parsed.mode === "active" && parsed.trails.length === 2,
    "only ski trails should parse",
  );
  assert(
    parsed.trails[1].status.is_open === false,
    "closed trail should remain closed",
  );
  assert(
    parsed.lifts[0].status.is_open && parsed.lifts[0].status.wait_minutes === 7,
    "open lift wait missing",
  );
  assert(parsed.lifts[1].status.is_open === false, "hold must not be routable");
});

Deno.test("canonical projection is conservative, deterministic, and ambiguity-safe", () => {
  const source = parseEpicTerrainStatus(feed([{
    Name: "Front Side",
    Trails: [
      { Name: "  Riva   Ridge ", TrailType: "Skiing", IsOpen: true },
      { Name: "Prima", TrailType: "Skiing", IsOpen: true },
      { Name: "PRIMA", TrailType: "Skiing", IsOpen: false },
      { Name: "Not Canonical", TrailType: "Skiing", IsOpen: false },
    ],
    Lifts: [{ Name: "Gondola One", Status: "Open", WaitTimeInMinutes: 3 }],
  }]));
  const projected = projectCanonicalStatus(
    source,
    ["Prima", "Riva Ridge", "Missing"],
    ["Gondola One"],
  );
  assert(
    canonicalNameKey(" RIVA   Ridge ") === "riva ridge",
    "normalization changed",
  );
  assert(
    Object.keys(projected.trails).join(",") === "Riva Ridge",
    "only unambiguous exact-normalized trail should map",
  );
  assert(
    projected.lifts["Gondola One"].wait_minutes === 3,
    "canonical lift key should be preserved exactly",
  );
  assert(
    projected.ambiguousSourceNames[0] === "prima",
    "conflicting duplicate should be reported",
  );
});

Deno.test("malformed and unavailable Epic sources fail instead of becoming empty success", async () => {
  let malformedFailed = false;
  try {
    parseEpicTerrainStatus("FR.TerrainStatusFeed = {not-json};");
  } catch {
    malformedFailed = true;
  }
  assert(malformedFailed, "malformed source must fail");

  let unavailableFailed = false;
  try {
    await fetchEpicTerrainStatus(
      "vail",
      async () => new Response("nope", { status: 503 }),
    );
  } catch {
    unavailableFailed = true;
  }
  assert(
    unavailableFailed,
    "HTTP failure must not produce an empty status blob",
  );
});
