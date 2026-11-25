// Epic (Vail Resorts) terrain and lift status.
//
// Epic pages expose two copies of FR.TerrainStatusFeed on some resorts: the
// first uses numeric enums and the second display strings. Every balanced JSON
// assignment is parsed and the last valid copy is used.
//
// Summer pages use the same feed for biking and hiking. Unless at least one
// trail identifies itself as skiing, the observation is off-season: no ski
// trail or lift status is produced from it.

import type { VendorEntry, VendorState, VendorTerrainStatus } from "./status.ts";

const EPIC_RESORT_DOMAINS: Readonly<Record<string, string>> = {
  "whistler-blackcomb": "www.whistlerblackcomb.com",
  "vail": "www.vail.com",
  "park-city": "www.parkcity.com",
  "breckenridge": "www.breckenridge.com",
  "keystone": "www.keystoneresort.com",
  "beaver-creek": "www.beavercreek.com",
  "stowe": "www.stowe.com",
  "heavenly": "www.skiheavenly.com",
  "northstar": "www.northstarcalifornia.com",
  "kirkwood": "www.kirkwood.com",
  "crested-butte": "www.skicb.com",
  "stevens-pass": "www.stevenspass.com",
  "liberty": "www.libertymountainresort.com",
  "roundtop": "www.skiroundtop.com",
  "whitetail": "www.skiwhitetail.com",
  "jack-frost": "www.jfbb.com",
  "big-boulder": "www.jfbb.com",
  "mt-brighton": "www.mtbrighton.com",
  "afton-alps": "www.aftonalps.com",
  "wilmot": "www.wilmotmountain.com",
  "perisher": "www.perisher.com.au",
  "falls-creek": "www.fallscreek.com.au",
  "hotham": "www.mthotham.com.au",
  "okemo": "www.okemo.com",
  "mount-sunapee": "www.mountsunapee.com",
  "hunter": "www.huntermtn.com",
  "attitash": "www.attitash.com",
  "wildcat": "www.skiwildcat.com",
  "crotched": "www.crotchedmtn.com",
  "mount-snow": "www.mountsnow.com",
};

type JsonRecord = Record<string, unknown>;

// Epic sites name the page either way round and some answer only to one
// (aftonalps.com, okemo.com and others 404 on the first).
const PAGE_SPELLINGS = ["terrain-and-lift-status.aspx", "lift-and-terrain-status.aspx"];

export function epicTerrainURLs(resortId: string): string[] {
  const domain = EPIC_RESORT_DOMAINS[resortId.trim().toLowerCase()];
  return domain
    ? PAGE_SPELLINGS.map((page) => `https://${domain}/the-mountain/mountain-conditions/${page}`)
    : [];
}

// The spelling that last answered, per resort and isolate, is tried first so a
// resort that serves only the second costs one request per round, not two.
const answeredSpelling = new Map<string, number>();

export async function fetchEpicTerrainStatus(
  resortId: string,
  fetcher: typeof fetch = fetch,
  fetchedAt = new Date(),
): Promise<VendorTerrainStatus> {
  const all = epicTerrainURLs(resortId);
  if (all.length === 0) throw new Error(`no Epic terrain source for resort_id=${resortId}`);
  const key = resortId.trim().toLowerCase();
  const preferred = answeredSpelling.get(key) ?? 0;
  const order = [preferred, ...all.keys().filter((i) => i !== preferred)];

  let response: Response | null = null;
  for (const index of order) {
    const url = all[index];
    try {
      response = await fetcher(url, {
        headers: {
          "User-Agent": "PowderMeet-LiveStatus/2.0",
          "Accept": "text/html,application/xhtml+xml",
        },
        signal: AbortSignal.timeout(15_000),
      });
    } catch (error) {
      throw new Error(
        `Epic terrain request failed: ${error instanceof Error ? error.message : String(error)}`,
      );
    }
    // Only a missing page sends the request to the other spelling.
    if (response.status !== 404) {
      if (response.ok) answeredSpelling.set(key, index);
      break;
    }
    await response.body?.cancel();
  }
  if (!response || !response.ok) {
    throw new Error(`Epic terrain request returned HTTP ${response?.status}`);
  }
  return parseEpicTerrainStatus(await response.text(), fetchedAt);
}

export function parseEpicTerrainStatus(
  html: string,
  fetchedAt = new Date(),
): VendorTerrainStatus {
  const feeds = extractAssignedJSONObjects(html, "FR.TerrainStatusFeed");
  if (feeds.length === 0) {
    throw new Error("Epic terrain feed assignment was not found or was malformed");
  }
  const feed = feeds[feeds.length - 1];
  const areas = recordArray(feed.GroomingAreas);
  if (!areas) throw new Error("Epic terrain feed has no GroomingAreas array");

  const winterTrails: VendorEntry[] = [];
  const allLifts: VendorEntry[] = [];

  for (const area of areas) {
    for (const trail of recordArray(area.Trails) ?? []) {
      if (!isWinterTrailType(trail.TrailType)) continue;
      const name = nonemptyString(trail.Name);
      if (!name || typeof trail.IsOpen !== "boolean") continue;
      winterTrails.push({
        name,
        state: trail.IsOpen ? "open" : "closed",
        ...(trail.IsGroomed === true ? { groomed: true } : {}),
      });
    }
    for (const lift of recordArray(area.Lifts) ?? []) {
      const name = nonemptyString(lift.Name);
      const state = epicLiftState(lift.Status);
      if (!name || state == null) continue;
      const wait = nonnegativeNumber(lift.WaitTimeInMinutes);
      allLifts.push({ name, state, ...(wait == null ? {} : { wait_minutes: wait }) });
    }
  }

  const fetchedAtISO = fetchedAt.toISOString();
  const observedAt = parseVendorDate(feed.Date);

  // No explicit winter terrain is positive evidence that this is the summer
  // feed. Summer lift operations must not open or close ski-network lifts.
  if (winterTrails.length === 0) {
    return { source: "epic", mode: "off_season", observedAt, fetchedAt: fetchedAtISO, trails: [], lifts: [] };
  }
  return { source: "epic", mode: "active", observedAt, fetchedAt: fetchedAtISO, trails: winterTrails, lifts: allLifts };
}

function extractAssignedJSONObjects(html: string, marker: string): JsonRecord[] {
  const result: JsonRecord[] = [];
  let cursor = 0;
  while (cursor < html.length) {
    const markerIndex = html.indexOf(marker, cursor);
    if (markerIndex < 0) break;
    const start = html.indexOf("{", markerIndex + marker.length);
    if (start < 0) break;
    const end = matchingObjectEnd(html, start);
    cursor = end > start ? end : start + 1;
    if (end <= start) continue;
    try {
      const parsed: unknown = JSON.parse(html.slice(start, end));
      if (isRecord(parsed)) result.push(parsed);
    } catch {
      // A page can carry an inert template assignment before the real feed.
      // Keep looking rather than accepting malformed data.
    }
  }
  return result;
}

function matchingObjectEnd(text: string, start: number): number {
  let depth = 0;
  let inString = false;
  let escaped = false;
  for (let index = start; index < text.length; index += 1) {
    const character = text[index];
    if (inString) {
      if (escaped) escaped = false;
      else if (character === "\\") escaped = true;
      else if (character === '"') inString = false;
      continue;
    }
    if (character === '"') inString = true;
    else if (character === "{") depth += 1;
    else if (character === "}") {
      depth -= 1;
      if (depth === 0) return index + 1;
    }
  }
  return -1;
}

function isWinterTrailType(value: unknown): boolean {
  if (value === 1) return true;
  if (typeof value !== "string") return false;
  const type = value.trim().toLocaleLowerCase("en-US");
  return type === "skiing" || type === "ski";
}

// Anything that is not running is not routable. "Scheduled" and "delayed" mean
// the lift is expected but not turning yet, which for routing is a hold.
function epicLiftState(value: unknown): VendorState | null {
  if (value === 3) return "open";
  if (typeof value === "number" && Number.isFinite(value)) return "closed";
  if (typeof value !== "string") return null;
  switch (value.trim().toLocaleLowerCase("en-US")) {
    case "open":
    case "operating":
      return "open";
    case "closed":
      return "closed";
    case "hold":
    case "scheduled":
    case "delayed":
      return "hold";
    default:
      return null;
  }
}

function parseVendorDate(value: unknown): string | null {
  if (typeof value !== "string") return null;
  const dotNet = /^\/Date\((\d+)(?:[+-]\d+)?\)\/$/.exec(value);
  const millis = dotNet ? Number(dotNet[1]) : Date.parse(value);
  if (!Number.isFinite(millis)) return null;
  return new Date(millis).toISOString();
}

function nonnegativeNumber(value: unknown): number | null {
  const number = typeof value === "number"
    ? value
    : typeof value === "string" && value.trim()
    ? Number(value)
    : Number.NaN;
  return Number.isFinite(number) && number >= 0 ? number : null;
}

function nonemptyString(value: unknown): string | null {
  if (typeof value !== "string") return null;
  const result = value.trim();
  return result || null;
}

function recordArray(value: unknown): JsonRecord[] | null {
  return Array.isArray(value) && value.every(isRecord) ? value : null;
}

function isRecord(value: unknown): value is JsonRecord {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}
