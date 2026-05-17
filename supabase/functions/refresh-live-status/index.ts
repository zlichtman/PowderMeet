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
//     "built_at": "2026-05-08T14:00:00Z",
//     "expires_at": "2026-05-08T15:00:00Z",
//     "lifts":  { "Riva Bahn": { "is_open": true,  "wait_minutes": 4 }, ... },
//     "trails": { "Riva Ridge": { "is_open": true                    }, ... }
//   }
//
// Status sources (priority order, first non-null wins per name):
//   1. Epic terrain feed (Vail Resorts / Whistler / Beaver Creek / ...)
//   2. MtnPowder
//   3. Liftie (community-curated)
//
// Naming: keys MUST match the canonical manifest's `name` field exactly
// (case + punctuation). The client merge step at read time joins by name.
//
// Schedule: invoke from a Supabase pg_cron entry every hour (during
// ski season — adjust to coarser cadence in shoulder months). See
// migrations for the cron registration once this function ships.

import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient, SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2.39.0";

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
  built_at: string;
  expires_at: string;
  lifts: Record<string, { is_open: boolean; wait_minutes?: number | null }>;
  trails: Record<string, { is_open: boolean }>;
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
    return jsonError(500, "Edge Function env missing SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY");
  }
  const supabase = createClient(supabaseUrl, serviceKey);

  const targetResorts = await resolveTargetResorts(supabase, body.resort_id);
  if (targetResorts.length === 0) {
    return jsonOk({ status: "no_resorts" });
  }

  const results: Array<{ resort_id: string; ok: boolean; reason?: string }> = [];

  for (const resortId of targetResorts) {
    try {
      const blob = await buildLiveStatus(resortId);
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
  const { data } = await supabase
    .from("current_resort_canonical_manifest")
    .select("resort_id");
  return (data ?? []).map((r) => r.resort_id as string);
}

async function buildLiveStatus(resortId: string): Promise<LiveStatusBlob> {
  // TODO(canonical-pipeline): port the source-fetch logic from the
  // existing Swift services:
  //   - Services/EpicTerrainScraper.swift
  //   - Services/MtnPowderService.swift
  //   - Services/LiftieService.swift
  //
  // Each one resolves a vendor-specific URL per resort_id, fetches JSON,
  // and produces (lift_name → is_open + wait_minutes). The merge logic
  // in Services/ResortDataEnricher.swift:enrich is the spec for source
  // priority and name-matching tolerance.
  //
  // Until the port lands, this stub returns an empty status payload so
  // refresh-live-status invocations succeed (live blob exists, just
  // empty) and clients fall back to the structural graph's defaults.
  const now = new Date();
  const expires = new Date(now.getTime() + LIVE_TTL_HOURS * 3600 * 1000);

  return {
    resort_id: resortId,
    built_at: now.toISOString(),
    expires_at: expires.toISOString(),
    lifts: {},
    trails: {},
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
