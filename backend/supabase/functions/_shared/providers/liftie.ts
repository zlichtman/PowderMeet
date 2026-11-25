// Liftie (liftie.info) lift status. Lift-only: Liftie reports no runs, so it
// can never establish trail status. It is one more provider behind the same
// fail-closed rules.
//
// Response shape:
//   { "id": "vail", "name": "Vail",
//     "lifts": { "status": { "<lift name>": "open" | "closed" | "hold" | "scheduled" }, "stats": {...} },
//     "timestamp": { "lifts": <epoch ms> } }          // timestamp is optional
//
// Liftie sits behind Cloudflare, which may answer an automated client with a
// challenge page (HTTP 403, HTML). That is a refusal, not data: the adapter
// fails and no row is written. It does not try to get past the challenge.
//
// Attribution required where the status is shown: "Lift status provided by Liftie".

import type { VendorEntry, VendorState, VendorTerrainStatus } from "./status.ts";

// Liftie's resort id where it differs from ours. Any other resort is looked up
// under its own id.
const LIFTIE_IDS: Readonly<Record<string, string>> = {
  "northstar": "northstar-at-tahoe",
  "mammoth": "mammoth-mountain",
  "aspen": "aspen-snowmass",
  "copper": "copper-mountain",
  "solitude": "solitude-mountain",
  "loon": "loon-mountain",
  "tremblant": "mont-tremblant",
};

const STATES: Readonly<Record<string, VendorState>> = {
  open: "open",
  closed: "closed",
  hold: "hold",
  // Expected today but not turning: not routable.
  scheduled: "hold",
};

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

export function liftieId(resortId: string): string {
  const id = resortId.trim().toLowerCase();
  return LIFTIE_IDS[id] ?? id;
}

export function liftieURL(resortId: string): string {
  return `https://liftie.info/api/resort/${encodeURIComponent(liftieId(resortId))}`;
}

export async function fetchLiftieStatus(
  resortId: string,
  fetcher: typeof fetch = fetch,
  fetchedAt = new Date(),
): Promise<VendorTerrainStatus> {
  const response = await fetcher(liftieURL(resortId), {
    headers: { Accept: "application/json", "User-Agent": "PowderMeet-LiveStatus/2.0" },
    signal: AbortSignal.timeout(15_000),
  });
  if (!response.ok) {
    const challenged = response.headers.get("cf-mitigated") === "challenge";
    await response.body?.cancel();
    throw new Error(
      `Liftie request returned HTTP ${response.status}${challenged ? " (bot challenge)" : ""}`,
    );
  }
  if (!(response.headers.get("content-type") ?? "").includes("json")) {
    await response.body?.cancel();
    throw new Error("Liftie did not answer with JSON");
  }
  return parseLiftieStatus(await response.json(), resortId, fetchedAt);
}

export function parseLiftieStatus(
  body: unknown,
  resortId: string,
  fetchedAt = new Date(),
): VendorTerrainStatus {
  if (!isRecord(body) || !isRecord(body.lifts) || !isRecord(body.lifts.status)) {
    throw new Error("Malformed Liftie response");
  }
  if (body.id !== liftieId(resortId)) {
    throw new Error(`Liftie answered for a different resort: ${String(body.id)}`);
  }

  // The lift timestamp is optional. When present it must be recent: a fetch
  // never renews an old observation.
  let observedAt: string | null = null;
  const stamp = isRecord(body.timestamp) ? body.timestamp.lifts : undefined;
  if (stamp !== undefined) {
    if (
      typeof stamp !== "number" || !Number.isFinite(stamp) || stamp > fetchedAt.getTime() ||
      fetchedAt.getTime() - stamp >= 3_600_000
    ) {
      throw new Error("Stale or invalid Liftie observation");
    }
    observedAt = new Date(stamp).toISOString();
  }

  const lifts: VendorEntry[] = [];
  for (const [rawName, rawState] of Object.entries(body.lifts.status)) {
    const name = rawName.trim();
    const state = typeof rawState === "string" ? STATES[rawState.trim().toLowerCase()] : undefined;
    // An unknown status is dropped, never guessed.
    if (name && state) lifts.push({ name, state });
  }
  if (lifts.length === 0) throw new Error("Liftie response has no usable lift status");

  return {
    source: "liftie",
    mode: "active",
    observedAt,
    fetchedAt: fetchedAt.toISOString(),
    trails: [],
    lifts,
  };
}
