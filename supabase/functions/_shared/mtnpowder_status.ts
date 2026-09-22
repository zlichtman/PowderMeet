import {
  type VendorStatusEntry,
  type VendorTerrainStatus,
} from "./live_status.ts";

// Explicit winter feed identities, checked against the provider's terrain-bearing
// entries. Summer, forecast-only, neighboring and combined duplicate entries are
// never substitutes. Big Bear requires both areas, not a partial resort response.
export const MTNPOWDER_TERRAIN_NAMES: Readonly<
  Record<string, readonly string[]>
> = {
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
const CLOSED = new Set([
  "closed",
  "closed_for_season",
  "hold",
  "on_hold",
  "scheduled",
  "lightning_closure",
  "wind_hold",
]);
type Row = Record<string, unknown>;
const isRow = (x: unknown): x is Row =>
  !!x && typeof x === "object" && !Array.isArray(x);
const name = (x: unknown): string => typeof x === "string" ? x.trim() : "";
function rows(x: unknown): Row[] {
  if (!Array.isArray(x) || !x.every(isRow)) {
    throw new Error("Malformed MtnPowder terrain rows");
  }
  return x;
}
function status(x: unknown): boolean | null {
  const value = name(x).toLowerCase();
  return value === "open" ? true : CLOSED.has(value) ? false : null;
}

export async function fetchMtnPowderFeed(
  fetcher: typeof fetch = fetch,
): Promise<unknown> {
  const response = await fetcher("https://mtnpowder.com/feed/", {
    headers: {
      Accept: "application/json",
      "User-Agent": "PowderMeet-LiveStatus/1.0",
    },
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
  const trails: VendorStatusEntry[] = [], lifts: VendorStatusEntry[] = [];
  const observedTimes: number[] = [];
  let allSeasonClosed = true;
  for (const expectedName of expected) {
    const matches = resorts.filter((r) => name(r.Name) === expectedName);
    if (matches.length !== 1) {
      throw new Error(`Missing or ambiguous MtnPowder resort: ${expectedName}`);
    }
    const resort = matches[0];
    const observed = Date.parse(name(resort.LastUpdate));
    if (
      !Number.isFinite(observed) || observed > fetchedAt.getTime() ||
      fetchedAt.getTime() - observed >= 3_600_000
    ) {
      throw new Error(
        `Stale or invalid MtnPowder observation: ${expectedName}`,
      );
    }
    observedTimes.push(observed);
    const operating = name(resort.OperatingStatus).toLowerCase();
    if (operating !== "open" && operating !== "closed") {
      throw new Error(`Unknown MtnPowder operating status: ${expectedName}`);
    }
    const areas = rows(resort.MountainAreas);
    const beforeTrails = trails.length, beforeLifts = lifts.length;
    for (const area of areas) {
      for (const trail of rows(area.Trails ?? [])) {
        if (
          !WINTER_ICONS.has(name(trail.TrailIcon).toLowerCase()) ||
          name(trail.Nordic).toLowerCase() === "yes"
        ) continue;
        const isOpen = status(trail.StatusEnglish);
        if (!name(trail.Name) || isOpen === null) continue;
        allSeasonClosed &&=
          name(trail.StatusEnglish).toLowerCase() === "closed_for_season";
        trails.push({
          name: name(trail.Name),
          status: { is_open: operating === "open" && isOpen },
        });
      }
      for (const lift of rows(area.Lifts ?? [])) {
        const isOpen = status(lift.StatusEnglish);
        if (!name(lift.Name) || isOpen === null) continue;
        const wait = typeof lift.WaitTime === "number" ||
            (typeof lift.WaitTime === "string" && lift.WaitTime.trim() !== "")
          ? Number(lift.WaitTime)
          : NaN;
        lifts.push({
          name: name(lift.Name),
          status: {
            is_open: operating === "open" && isOpen,
            ...(Number.isFinite(wait) && wait >= 0 && wait <= 1440
              ? { wait_minutes: wait }
              : {}),
          },
        });
      }
    }
    if (trails.length === beforeTrails || lifts.length === beforeLifts) {
      throw new Error(
        `MtnPowder entry lacks usable winter terrain: ${expectedName}`,
      );
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
