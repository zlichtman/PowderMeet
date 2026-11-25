// MtnPowder (Alterra and others) terrain and lift status.
//
// Explicit winter feed identities, checked against the provider's
// terrain-bearing entries. Summer, forecast-only, neighbouring and combined
// duplicate entries are never substitutes. Big Bear needs both of its areas,
// not a partial response.

import type { VendorEntry, VendorState, VendorTerrainStatus } from "./status.ts";

export const MTNPOWDER_TERRAIN_NAMES: Readonly<Record<string, readonly string[]>> = {
  stratton: ["Stratton"],
  snowshoe: ["Snowshoe"],
  "blue-mountain-on": ["Blue"],
  tremblant: ["Tremblant"],
  "winter-park": ["Winter Park"],
  steamboat: ["Steamboat"],
  "deer-valley": ["Deer Valley"],
  "big-bear": ["Bear Mountain", "Snow Summit"],
  "june-mountain": ["June Mountain"],
  mammoth: ["Mammoth Mountain"],
  "palisades-tahoe": ["Palisades Tahoe"],
  solitude: ["Solitude"],
  sugarbush: ["Sugarbush"],
  "crystal-mountain": ["Crystal Mountain"],
  schweitzer: ["Schweitzer"],
  "snow-valley": ["Snow Valley"],
};

const WINTER_ICONS = new Set([
  "greencircle",
  "bluesquare",
  "blackdiamond",
  "doubleblackdiamond",
  "blueblacksquare",
  "bluebluesquare",
  "park",
  "glades",
  "extremeterrain",
  "halfpipe",
]);

const STATES: Readonly<Record<string, VendorState>> = {
  open: "open",
  closed: "closed",
  closed_for_season: "closed",
  lightning_closure: "closed",
  hold: "hold",
  on_hold: "hold",
  wind_hold: "hold",
  scheduled: "hold",
  // Mammoth and Snow Valley report lifts due to open as "expected". Left out,
  // those lifts counted as unmapped and the 80 % rule dropped the whole resort
  // whenever most of its lifts were waiting to open.
  expected: "hold",
};

type Row = Record<string, unknown>;
const isRow = (x: unknown): x is Row => !!x && typeof x === "object" && !Array.isArray(x);
const text = (x: unknown): string => typeof x === "string" ? x.trim() : "";

function rows(x: unknown): Row[] {
  if (!Array.isArray(x) || !x.every(isRow)) {
    throw new Error("Malformed MtnPowder terrain rows");
  }
  return x;
}

function state(x: unknown): VendorState | null {
  return STATES[text(x).toLowerCase()] ?? null;
}

export async function fetchMtnPowderFeed(fetcher: typeof fetch = fetch): Promise<unknown> {
  const response = await fetcher("https://mtnpowder.com/feed/", {
    headers: { Accept: "application/json", "User-Agent": "PowderMeet-LiveStatus/2.0" },
    signal: AbortSignal.timeout(20_000),
  });
  if (!response.ok) {
    throw new Error(`MtnPowder request returned HTTP ${response.status}`);
  }
  return await response.json();
}

export function parseMtnPowderStatus(
  feed: unknown,
  resortID: string,
  fetchedAt = new Date(),
): VendorTerrainStatus {
  const expected = MTNPOWDER_TERRAIN_NAMES[resortID];
  if (!expected) {
    throw new Error(`No reviewed MtnPowder terrain identity for ${resortID}`);
  }
  if (!isRow(feed)) throw new Error("Malformed MtnPowder feed");
  const resorts = rows(feed.Resorts);
  const trails: VendorEntry[] = [];
  const lifts: VendorEntry[] = [];
  const observedTimes: number[] = [];
  let allSeasonClosed = true;

  for (const expectedName of expected) {
    const matches = resorts.filter((r) => text(r.Name) === expectedName);
    if (matches.length !== 1) {
      throw new Error(`Missing or ambiguous MtnPowder resort: ${expectedName}`);
    }
    const resort = matches[0];
    const observed = Date.parse(text(resort.LastUpdate));
    if (
      !Number.isFinite(observed) || observed > fetchedAt.getTime() ||
      fetchedAt.getTime() - observed >= 3_600_000
    ) {
      throw new Error(`Stale or invalid MtnPowder observation: ${expectedName}`);
    }
    observedTimes.push(observed);
    const operating = text(resort.OperatingStatus).toLowerCase();
    if (operating !== "open" && operating !== "closed") {
      throw new Error(`Unknown MtnPowder operating status: ${expectedName}`);
    }
    const areas = rows(resort.MountainAreas);
    const beforeTrails = trails.length;
    const beforeLifts = lifts.length;
    for (const area of areas) {
      for (const trail of rows(area.Trails ?? [])) {
        if (
          !WINTER_ICONS.has(text(trail.TrailIcon).toLowerCase()) ||
          text(trail.Nordic).toLowerCase() === "yes"
        ) continue;
        const trailState = state(trail.StatusEnglish);
        if (!text(trail.Name) || trailState === null) continue;
        allSeasonClosed &&= text(trail.StatusEnglish).toLowerCase() === "closed_for_season";
        // A closed resort cannot inherit stale open flags.
        const effective = operating === "open" ? trailState : "closed";
        trails.push({
          name: text(trail.Name),
          state: effective,
          ...(effective === "open" && text(trail.Grooming).toLowerCase() === "yes" ? { groomed: true } : {}),
        });
      }
      for (const lift of rows(area.Lifts ?? [])) {
        const liftState = state(lift.StatusEnglish);
        if (!text(lift.Name) || liftState === null) continue;
        const wait = typeof lift.WaitTime === "number" ||
            (typeof lift.WaitTime === "string" && lift.WaitTime.trim() !== "")
          ? Number(lift.WaitTime)
          : NaN;
        lifts.push({
          name: text(lift.Name),
          state: operating === "open" ? liftState : "closed",
          ...(Number.isFinite(wait) && wait >= 0 && wait <= 1440 ? { wait_minutes: wait } : {}),
        });
      }
    }
    if (trails.length === beforeTrails || lifts.length === beforeLifts) {
      throw new Error(`MtnPowder entry lacks usable winter terrain: ${expectedName}`);
    }
  }

  return {
    source: "mtnpowder",
    mode: allSeasonClosed ? "off_season" : "active",
    observedAt: new Date(Math.min(...observedTimes)).toISOString(),
    fetchedAt: fetchedAt.toISOString(),
    trails: allSeasonClosed ? [] : trails,
    lifts: allSeasonClosed ? [] : lifts,
  };
}
