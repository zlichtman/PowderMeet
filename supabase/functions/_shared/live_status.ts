// Pure live-terrain parsing and canonical-name projection.
//
// Vendor data is observation data, never topology. A feed can only update a
// canonical trail/lift whose name matches after conservative Unicode, case,
// and whitespace normalization. Ambiguous duplicates are omitted.

// Epic exposes two copies of FR.TerrainStatusFeed on some pages: the first
// uses numeric enums and the second uses display strings. We parse every
// balanced JSON assignment and use the last valid copy.

// Summer pages use the same feed for biking/hiking. Unless at least one
// trail explicitly identifies itself as Skiing (or enum 1), the observation
// is neutral/off-season: no ski trail or lift closures are emitted.

export interface LiveStatusEntry {
  is_open: boolean;
  wait_minutes?: number | null;
}

export interface VendorStatusEntry {
  name: string;
  status: LiveStatusEntry;
}

export interface VendorTerrainStatus {
  source: "epic" | "mtnpowder";
  mode: "active" | "off_season";
  observedAt: string | null;
  fetchedAt: string;
  trails: VendorStatusEntry[];
  lifts: VendorStatusEntry[];
}

export interface CanonicalProjection {
  trails: Record<string, LiveStatusEntry>;
  lifts: Record<string, LiveStatusEntry>;
  matchedTrailCount: number;
  matchedLiftCount: number;
  ambiguousSourceNames: string[];
}

const EPIC_RESORT_DOMAINS: Readonly<Record<string, string>> = {
  "whistler-blackcomb": "www.whistlerblackcomb.com",
  "whistler": "www.whistlerblackcomb.com",
  "vail": "www.vail.com",
  "park-city": "www.parkcity.com",
  "parkcity": "www.parkcity.com",
  "breckenridge": "www.breckenridge.com",
  "keystone": "www.keystoneresort.com",
  "beaver-creek": "www.beavercreek.com",
  "beavercreek": "www.beavercreek.com",
  "stowe": "www.stowe.com",
  "heavenly": "www.skiheavenly.com",
  "northstar": "www.northstarcalifornia.com",
  "kirkwood": "www.kirkwood.com",
  "crested-butte": "www.skicb.com",
  "crestedbutte": "www.skicb.com",
  "stevens-pass": "www.stevenspass.com",
  "stevenspass": "www.stevenspass.com",
  "liberty": "www.libertymountainresort.com",
  "roundtop": "www.skiroundtop.com",
  "whitetail": "www.skiwhitetail.com",
  "jack-frost": "www.jfbb.com",
  "big-boulder": "www.jfbb.com",
  "mount-brighton": "www.mtbrighton.com",
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

export function epicTerrainURL(resortId: string): string | null {
  const domain = EPIC_RESORT_DOMAINS[resortId.trim().toLowerCase()];
  return domain
    ? `https://${domain}/the-mountain/mountain-conditions/terrain-and-lift-status.aspx`
    : null;
}

export function canonicalNameKey(name: string): string {
  return name.normalize("NFKC").trim().replace(/\s+/gu, " ").toLocaleLowerCase(
    "en-US",
  );
}

export async function fetchEpicTerrainStatus(
  resortId: string,
  fetcher: typeof fetch = fetch,
  fetchedAt = new Date(),
): Promise<VendorTerrainStatus> {
  const url = epicTerrainURL(resortId);
  if (!url) throw new Error(`no Epic terrain source for resort_id=${resortId}`);

  let response: Response;
  try {
    response = await fetcher(url, {
      headers: {
        "User-Agent": "PowderMeet-LiveStatus/1.0",
        "Accept": "text/html,application/xhtml+xml",
      },
      signal: AbortSignal.timeout(15_000),
    });
  } catch (error) {
    throw new Error(`Epic terrain request failed: ${errorMessage(error)}`);
  }
  if (!response.ok) {
    throw new Error(`Epic terrain request returned HTTP ${response.status}`);
  }
  const html = await response.text();
  return parseEpicTerrainStatus(html, fetchedAt);
}

export function parseEpicTerrainStatus(
  html: string,
  fetchedAt = new Date(),
): VendorTerrainStatus {
  const feeds = extractAssignedJSONObjects(html, "FR.TerrainStatusFeed");
  if (feeds.length === 0) {
    throw new Error(
      "Epic terrain feed assignment was not found or was malformed",
    );
  }
  const feed = feeds[feeds.length - 1];
  const areas = recordArray(feed.GroomingAreas);
  if (!areas) throw new Error("Epic terrain feed has no GroomingAreas array");

  const winterTrails: VendorStatusEntry[] = [];
  const allLifts: VendorStatusEntry[] = [];

  for (const area of areas) {
    for (const trail of recordArray(area.Trails) ?? []) {
      if (!isWinterTrailType(trail.TrailType)) continue;
      const name = nonemptyString(trail.Name);
      if (!name || typeof trail.IsOpen !== "boolean") continue;
      winterTrails.push({ name, status: { is_open: trail.IsOpen } });
    }
    for (const lift of recordArray(area.Lifts) ?? []) {
      const name = nonemptyString(lift.Name);
      const isOpen = epicLiftIsOpen(lift.Status);
      if (!name || isOpen == null) continue;
      const wait = nonnegativeNumber(lift.WaitTimeInMinutes);
      allLifts.push({
        name,
        status: {
          is_open: isOpen,
          ...(wait == null ? {} : { wait_minutes: wait }),
        },
      });
    }
  }

  const fetchedAtISO = fetchedAt.toISOString();
  const observedAt = parseVendorDate(feed.Date);

  // No explicit winter terrain is positive evidence that this is the
  // summer/off-season feed. Summer lift operations must not close or open
  // ski-network lift edges.
  if (winterTrails.length === 0) {
    return {
      source: "epic",
      mode: "off_season",
      observedAt,
      fetchedAt: fetchedAtISO,
      trails: [],
      lifts: [],
    };
  }

  return {
    source: "epic",
    mode: "active",
    observedAt,
    fetchedAt: fetchedAtISO,
    trails: winterTrails,
    lifts: allLifts,
  };
}

export function projectCanonicalStatus(
  source: VendorTerrainStatus,
  canonicalTrailNames: readonly string[],
  canonicalLiftNames: readonly string[],
): CanonicalProjection {
  const ambiguous = new Set<string>();
  const sourceTrails = uniqueStatusByKey(source.trails, ambiguous);
  const sourceLifts = uniqueStatusByKey(source.lifts, ambiguous);
  const trails = projectNames(canonicalTrailNames, sourceTrails);
  const lifts = projectNames(canonicalLiftNames, sourceLifts);

  return {
    trails,
    lifts,
    matchedTrailCount: Object.keys(trails).length,
    matchedLiftCount: Object.keys(lifts).length,
    ambiguousSourceNames: [...ambiguous].sort(compareText),
  };
}

function projectNames(
  canonicalNames: readonly string[],
  sourceByKey: ReadonlyMap<string, LiveStatusEntry>,
): Record<string, LiveStatusEntry> {
  const result: Record<string, LiveStatusEntry> = {};
  const canonicalKeys = new Map<string, string | null>();

  for (const rawName of canonicalNames) {
    const name = rawName.trim();
    if (!name) {
      throw new Error("canonical status projection received an empty name");
    }
    const key = canonicalNameKey(name);
    canonicalKeys.set(key, canonicalKeys.has(key) ? null : name);
  }

  const orderedKeys = [...canonicalKeys.keys()].sort(compareText);
  for (const key of orderedKeys) {
    const canonicalName = canonicalKeys.get(key);
    const entry = sourceByKey.get(key);
    if (canonicalName && entry) result[canonicalName] = { ...entry };
  }
  return result;
}

function uniqueStatusByKey(
  entries: readonly VendorStatusEntry[],
  ambiguous: Set<string>,
): Map<string, LiveStatusEntry> {
  const result = new Map<string, LiveStatusEntry>();
  for (const entry of entries) {
    const key = canonicalNameKey(entry.name);
    if (!key || ambiguous.has(key)) continue;
    const previous = result.get(key);
    if (!previous) {
      result.set(key, { ...entry.status });
    } else if (!sameStatus(previous, entry.status)) {
      result.delete(key);
      ambiguous.add(key);
    }
  }
  return result;
}

function sameStatus(lhs: LiveStatusEntry, rhs: LiveStatusEntry): boolean {
  return lhs.is_open === rhs.is_open &&
    (lhs.wait_minutes ?? null) === (rhs.wait_minutes ?? null);
}

function extractAssignedJSONObjects(
  html: string,
  marker: string,
): JsonRecord[] {
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
      // A page can contain an inert template assignment before the real
      // feed. Continue looking rather than accepting malformed data.
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

function epicLiftIsOpen(value: unknown): boolean | null {
  if (value === 3) return true;
  if (typeof value === "number" && Number.isFinite(value)) return false;
  if (typeof value !== "string") return null;
  switch (value.trim().toLocaleLowerCase("en-US")) {
    case "open":
    case "operating":
      return true;
    case "closed":
    case "hold":
    case "scheduled":
    case "delayed":
      return false;
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

function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}

function compareText(lhs: string, rhs: string): number {
  return lhs < rhs ? -1 : lhs > rhs ? 1 : 0;
}
