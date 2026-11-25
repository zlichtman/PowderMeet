// Status types and the projection from a vendor feed onto a bundle's groups.
//
// Vendor data is observation data, never topology (I-18). A feed can only set
// the status of a group the bundle's `status_aliases` names for that provider,
// matched after conservative Unicode, case and whitespace normalization.
// Ambiguous names are dropped, never guessed. No row is produced unless at
// least 80 % of the bundle's lift groups are mapped (specs/05-PIPELINE.md
// section 2): the previous row is left to age into `stale` instead.

export type VendorState = "open" | "closed" | "hold";
export type GroupState = VendorState | "scheduled";

export interface VendorEntry {
  name: string;
  state: VendorState;
  wait_minutes?: number;
  groomed?: boolean;
}

export interface VendorTerrainStatus {
  source: "epic" | "mtnpowder" | "liftie";
  mode: "active" | "off_season";
  observedAt: string | null;
  fetchedAt: string;
  trails: VendorEntry[];
  lifts: VendorEntry[];
}

/** What the worker needs from a bundle; see specs/02-DOMAIN.md section 2. */
export interface BundleStatusMeta {
  aliases: Record<string, Record<string, string>>;
  liftGroups: string[];
  trailGroups: string[];
}

/** A `resort_status` row without its resort id; specs/02-DOMAIN.md section 3. */
export interface StatusRow {
  observed_at: string;
  expires_at: string;
  source: "epic" | "mtnpowder" | "liftie";
  groups: Record<string, GroupState>;
  groomed: string[];
  /** Live queue minutes for running lifts (open or on hold); absent is unknown. */
  wait_minutes: Record<string, number>;
}

export const STATUS_TTL_MS = 75 * 60_000;
export const MIN_LIFT_COVERAGE = 0.8;
/** A reported wait above this is a feed error, not a queue. */
export const MAX_WAIT_MINUTES = 240;

export function canonicalNameKey(name: string): string {
  return name.normalize("NFKC").trim().replace(/\s+/gu, " ").toLocaleLowerCase("en-US");
}

const SEVERITY: Record<VendorState, number> = { open: 0, hold: 1, closed: 2 };

interface Observation {
  state: VendorState;
  groomed: boolean;
  /** The longest believable wait any name for this lift reported. */
  wait?: number;
}

function believableWait(minutes: number | undefined): number | undefined {
  return minutes !== undefined && Number.isFinite(minutes) && minutes >= 0 && minutes <= MAX_WAIT_MINUTES
    ? minutes
    : undefined;
}

function longer(lhs: number | undefined, rhs: number | undefined): number | undefined {
  if (lhs === undefined) return rhs;
  if (rhs === undefined) return lhs;
  return Math.max(lhs, rhs);
}

// One observation per normalized vendor name. Two entries with the same name
// and different states are a conflict: the name is dropped entirely.
function uniqueByName(entries: readonly VendorEntry[]): Map<string, Observation> {
  const result = new Map<string, Observation>();
  const ambiguous = new Set<string>();
  for (const entry of entries) {
    const key = canonicalNameKey(entry.name);
    if (!key || ambiguous.has(key)) continue;
    const previous = result.get(key);
    const wait = believableWait(entry.wait_minutes);
    if (!previous) {
      result.set(key, { state: entry.state, groomed: entry.groomed === true, wait });
    } else if (previous.state !== entry.state) {
      result.delete(key);
      ambiguous.add(key);
    } else {
      previous.groomed = previous.groomed && entry.groomed === true;
      previous.wait = longer(previous.wait, wait);
    }
  }
  return result;
}

// Normalized vendor name -> group id. A name that normalizes onto two
// different groups is dropped.
function aliasIndex(aliases: Record<string, string>): Map<string, string> {
  const result = new Map<string, string>();
  const ambiguous = new Set<string>();
  for (const [name, groupId] of Object.entries(aliases)) {
    const key = canonicalNameKey(name);
    if (!key || ambiguous.has(key)) continue;
    const previous = result.get(key);
    if (previous === undefined) result.set(key, groupId);
    else if (previous !== groupId) {
      result.delete(key);
      ambiguous.add(key);
    }
  }
  return result;
}

// Group id -> state. Several vendor names may feed one group; the group takes
// the most restrictive state, so one open segment never makes a partly closed
// trail look open (I-15). A group counts as groomed only if every part is,
// and a lift fed by several names waits as long as the longest queue reported.
function byGroup(
  entries: readonly VendorEntry[],
  index: ReadonlyMap<string, string>,
  known: ReadonlySet<string>,
): Map<string, Observation> {
  const result = new Map<string, Observation>();
  for (const [key, observation] of uniqueByName(entries)) {
    const groupId = index.get(key);
    if (!groupId || !known.has(groupId)) continue;
    const previous = result.get(groupId);
    if (!previous) {
      result.set(groupId, { ...observation });
    } else {
      if (SEVERITY[observation.state] > SEVERITY[previous.state]) previous.state = observation.state;
      previous.groomed = previous.groomed && observation.groomed;
      previous.wait = longer(previous.wait, observation.wait);
    }
  }
  return result;
}

function compareText(lhs: string, rhs: string): number {
  return lhs < rhs ? -1 : lhs > rhs ? 1 : 0;
}

/**
 * Projects a vendor observation onto the bundle's groups. Returns null for an
 * off-season feed (nothing to say about skiing). Throws when too few lift
 * groups are mapped to trust the result.
 */
export function projectStatus(
  vendor: VendorTerrainStatus,
  meta: BundleStatusMeta,
  now: Date,
): StatusRow | null {
  if (vendor.mode === "off_season") return null;

  const index = aliasIndex(meta.aliases[vendor.source] ?? {});
  const lifts = byGroup(vendor.lifts, index, new Set(meta.liftGroups));
  const trails = byGroup(vendor.trails, index, new Set(meta.trailGroups));

  const total = meta.liftGroups.length;
  if (total === 0 || lifts.size / total < MIN_LIFT_COVERAGE) {
    throw new Error(
      `${vendor.source} mapped ${lifts.size} of ${total} lift groups; ` +
        `${Math.round(MIN_LIFT_COVERAGE * 100)} % is required`,
    );
  }

  const groups: Record<string, GroupState> = {};
  const waits: Record<string, number> = {};
  // A lift the feed says nothing about is `scheduled`: no live information,
  // use operating hours. A wait is kept only for a lift that is loading or
  // expected to (open or hold); a closed lift's last queue means nothing.
  for (const id of [...meta.liftGroups].sort(compareText)) {
    const lift = lifts.get(id);
    groups[id] = lift?.state ?? "scheduled";
    if (lift && lift.state !== "closed" && lift.wait !== undefined) waits[id] = lift.wait;
  }
  const groomed: string[] = [];
  for (const id of [...trails.keys()].sort(compareText)) {
    const trail = trails.get(id)!;
    // Trails are open or closed; a held trail is not skiable.
    groups[id] = trail.state === "open" ? "open" : "closed";
    if (trail.state === "open" && trail.groomed) groomed.push(id);
  }

  // observed_at is when the vendor saw the data, never when we fetched it: a
  // missing, unreadable, future or hour-old stamp means the feed is stale, so no
  // row is written and the previous one ages into `stale` (same rule as the
  // MtnPowder and Liftie providers).
  const fetched = Date.parse(vendor.fetchedAt);
  const reference = Number.isFinite(fetched) ? fetched : now.getTime();
  const observed = vendor.observedAt ? Date.parse(vendor.observedAt) : Number.NaN;
  if (!Number.isFinite(observed) || observed > reference || reference - observed >= 3_600_000) {
    throw new Error(`${vendor.source} observation is missing, in the future or over an hour old`);
  }

  return {
    observed_at: new Date(observed).toISOString(),
    expires_at: new Date(observed + STATUS_TTL_MS).toISOString(),
    source: vendor.source,
    groups,
    groomed,
    wait_minutes: waits,
  };
}
