// refresh-live-status — Edge Function (live status sidecar writer)
//
// Cron-driven hourly job that pulls real-time lift / trail open-closed
// status from the resort vendor feeds and writes a per-resort-per-hour
// JSON sidecar blob. Clients fetch this alongside the structural graph
// blob (which is immutable per manifest_version) so today's open/closed
// flags + current wait times override yesterday's.
//
// Replaces the on-device async race in `Services/ResortDataEnricher.swift`
// (which fetches Epic / MtnPowder / Liftie at cold-launch time, mutates
// the in-memory graph, and races with UI render). Server-side runs once
// per hour per resort; clients read the result instead of re-fetching
// on every device.
//
// Inputs (cron-only, no body fields required):
//   { resort_id?: string }   // optional: refresh just one resort
//                              (defaults to all resorts that have a
//                               current_resort_canonical_manifest)
//
// Output:
//   resort-graphs/{resort_id}/live-{YYYY-MM-DDTHH}.json
//
//   {
//     "resort_id": "vail",
//     "manifest_version": 1,
//     "built_at": "2026-05-08T14:00:00Z",
//     "expires_at": "2026-05-08T15:00:00Z",
//     "status_mode": "active",
//     "segments": { "stable-edge-id": { "is_open": true } },
//     "lifts":  { "Riva Bahn": { "is_open": true,  "wait_minutes": 4 }, ... },
//     "trails": { "Riva Ridge": { "is_open": true                    }, ... },
//     "sources": [{ "name": "epic", "observed_at": "...", ... }]
//   }
//
// Server status source:
//   Epic terrain feed (Vail Resorts / Whistler / Beaver Creek / ...).
// MtnPowder supplies explicitly mapped winter resorts with complete terrain.
// Unmapped, ambiguous, stale and forecast-only entries fail independently.
// Liftie remains lift-only legacy input; it cannot establish trail status.
//
// Naming: source observations map conservatively to the canonical manifest's
// names using only Unicode/case/whitespace normalization. Punctuation remains
// significant and ambiguous source names are omitted.
//
// Schedule: invoke from a Supabase pg_cron entry every hour (during
// ski season — adjust to coarser cadence in shoulder months). See
// migrations for the cron registration once this function ships.

import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import {
  createClient,
  SupabaseClient,
} from "https://esm.sh/@supabase/supabase-js@2.39.0";
import {
  type LiveStatusEntry,
  projectCanonicalStatus,
} from "../_shared/live_status.ts";

import { createTerrainStatusFetcher } from "../_shared/terrain_status.ts";

const TARGET_BUCKET = "resort-graphs";
const LIVE_TTL_HOURS = 1;

const CORS_HEADERS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
} as const;

interface RefreshRequest {
  resort_id?: string;
}

interface LiveStatusBlob {
  resort_id: string;
  manifest_version: number;
  built_at: string;
  expires_at: string;
  status_mode: "active" | "off_season";
  segments: Record<string, LiveStatusEntry>;
  lifts: Record<string, LiveStatusEntry>;
  trails: Record<string, LiveStatusEntry>;
  sources: Array<{
    name: string;
    observed_at: string | null;
    fetched_at: string;
    matched_trails: number;
    matched_lifts: number;
    ambiguous_names: string[];
  }>;
}

interface CanonicalIdentity {
  manifestVersion: number;
  trailNames: string[];
  liftNames: string[];
}

Deno.serve(async (req: Request): Promise<Response> => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: CORS_HEADERS });
  }
  if (req.method !== "POST") {
    return jsonError(405, "POST only");
  }

  let body: RefreshRequest = {};
  try {
    body = await req.json();
  } catch {
    // empty body is fine — refresh all resorts
  }

  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!supabaseUrl || !serviceKey) {
    return jsonError(
      500,
      "Edge Function env missing SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY",
    );
  }
  const supabase = createClient(supabaseUrl, serviceKey);

  const targetResorts = await resolveTargetResorts(supabase, body.resort_id);
  if (targetResorts.length === 0) {
    return jsonOk({ status: "no_resorts" });
  }

  const results: Array<{ resort_id: string; ok: boolean; reason?: string }> =
    [];

  const fetchTerrain = createTerrainStatusFetcher();
  for (const resortId of targetResorts) {
    try {
      const identity = await loadCanonicalIdentity(supabase, resortId);
      const blob = await buildLiveStatus(resortId, identity, fetchTerrain);
      await uploadLiveStatus(supabase, resortId, blob);
      results.push({ resort_id: resortId, ok: true });
    } catch (err) {
      results.push({
        resort_id: resortId,
        ok: false,
        reason: (err as Error).message,
      });
    }
  }

  return jsonOk({ status: "done", results });
});

async function resolveTargetResorts(
  supabase: SupabaseClient,
  filter: string | undefined,
): Promise<string[]> {
  if (filter) return [filter];
  const { data, error } = await supabase
    .from("current_resort_canonical_manifest")
    .select("resort_id");
  if (error) {
    throw new Error(`canonical resort lookup failed: ${error.message}`);
  }
  return (data ?? []).map((r) => r.resort_id as string);
}

async function loadCanonicalIdentity(
  supabase: SupabaseClient,
  resortId: string,
): Promise<CanonicalIdentity> {
  const manifestResult = await supabase
    .from("current_resort_canonical_manifest")
    .select("manifest_version, expected_trail_count, expected_lift_count")
    .eq("resort_id", resortId)
    .maybeSingle();
  if (manifestResult.error) {
    throw new Error(
      `canonical manifest lookup failed: ${manifestResult.error.message}`,
    );
  }
  const manifest = manifestResult.data;
  if (!manifest) {
    throw new Error(`no canonical manifest for resort_id=${resortId}`);
  }

  const manifestVersion = Number(manifest.manifest_version);
  const [trailResult, liftResult] = await Promise.all([
    supabase.from("canonical_trail").select("name")
      .eq("resort_id", resortId).eq("manifest_version", manifestVersion),
    supabase.from("canonical_lift").select("name")
      .eq("resort_id", resortId).eq("manifest_version", manifestVersion),
  ]);
  if (trailResult.error) {
    throw new Error(
      `canonical trail lookup failed: ${trailResult.error.message}`,
    );
  }
  if (liftResult.error) {
    throw new Error(
      `canonical lift lookup failed: ${liftResult.error.message}`,
    );
  }

  const trailNames = (trailResult.data ?? []).map((row) => String(row.name));
  const liftNames = (liftResult.data ?? []).map((row) => String(row.name));
  const expectedTrails = Number(manifest.expected_trail_count);
  const expectedLifts = Number(manifest.expected_lift_count);
  if (
    trailNames.length !== expectedTrails || liftNames.length !== expectedLifts
  ) {
    throw new Error(
      `canonical identity count mismatch: expected ${expectedTrails}/${expectedLifts}, ` +
        `loaded ${trailNames.length}/${liftNames.length}`,
    );
  }

  return { manifestVersion, trailNames, liftNames };
}

async function buildLiveStatus(
  resortId: string,
  identity: CanonicalIdentity,
  fetchTerrain: ReturnType<typeof createTerrainStatusFetcher>,
): Promise<LiveStatusBlob> {
  const now = new Date();
  const source = await fetchTerrain(resortId, now);
  // Preserve the alternate provider observation age across repeated refreshes.
  const observationTime = source.source === "mtnpowder"
    ? Date.parse(source.observedAt!) : now.getTime();
  const expires = new Date(Math.min(now.getTime(), observationTime) + LIVE_TTL_HOURS * 3600 * 1000);
  const projection = projectCanonicalStatus(
    source,
    identity.trailNames,
    identity.liftNames,
  );

  // An active vendor feed with no canonical trail match almost certainly
  // means the source or manifest changed. Preserve the previous hourly blob
  // by failing this refresh instead of publishing a misleading empty success.
  if (source.mode === "active" && projection.matchedTrailCount === 0) {
    throw new Error("active terrain feed matched zero canonical trail names");
  }

  return {
    resort_id: resortId,
    manifest_version: identity.manifestVersion,
    built_at: now.toISOString(),
    expires_at: expires.toISOString(),
    status_mode: source.mode,
    segments: {},
    lifts: projection.lifts,
    trails: projection.trails,
    sources: [{
      name: source.source,
      observed_at: source.observedAt,
      fetched_at: source.fetchedAt,
      matched_trails: projection.matchedTrailCount,
      matched_lifts: projection.matchedLiftCount,
      ambiguous_names: projection.ambiguousSourceNames,
    }],
  };
}

async function uploadLiveStatus(
  supabase: SupabaseClient,
  resortId: string,
  blob: LiveStatusBlob,
): Promise<void> {
  // YYYY-MM-DDTHH (UTC); matches get-resort-graph's tryLiveStatusUrl key.
  const key = blob.built_at.slice(0, 13);
  const path = `${resortId}/live-${key}.json`;
  const { error } = await supabase.storage.from(TARGET_BUCKET).upload(
    path,
    new TextEncoder().encode(JSON.stringify(blob)),
    { contentType: "application/json", upsert: true },
  );
  if (error) throw new Error(`live status upload failed: ${error.message}`);
}

function jsonOk(body: Record<string, unknown>): Response {
  return new Response(JSON.stringify(body), {
    status: 200,
    headers: { "Content-Type": "application/json", ...CORS_HEADERS },
  });
}

function jsonError(status: number, message: string): Response {
  return new Response(JSON.stringify({ error: message }), {
    status,
    headers: { "Content-Type": "application/json", ...CORS_HEADERS },
  });
}
