// get-resort-graph — Edge Function (canonical graph blob fetcher)
//
// Read-side companion to build-resort-graph. Clients call this on every
// resort load to either (a) confirm their cached graph is still current
// or (b) get a signed URL to a fresh blob.
//
// Inputs:
//   resort_id                   — required
//   cached_manifest_version     — optional; what the client has on disk
//   manifest_version            — optional; force-fetch this exact version
//                                 (used for cross-version meet requests:
//                                 receiver on v3 can fetch sender's v2 to
//                                 solve the same graph the sender did)
//
// Decision tree:
//   1. Resolve current_resort_canonical_manifest.manifest_version (= cur).
//   2. target = manifest_version ?? cur.
//   3. If cached_manifest_version == target → cache_valid.
//      Client keeps its cached graph; only the live-status sidecar refreshes.
//   4. Else look up resort_graph_blob (resort_id, target, latest snapshot,
//      GRAPH_VERSION) and return a signed URL.
//
// Live status sidecar:
//   The current hour's live blob lives at
//   `resort-graphs/{resort_id}/live-{YYYY-MM-DDTHH}.json`, written by
//   refresh-live-status (cron). Always returned so the client can merge
//   open/closed flags after applying the structural graph. Never blocks
//   the structural response — if the live blob is missing, returns null.
//
// Response shape (matches Swift `GraphFetchResponse`):
//   cache_valid: { status, current_manifest_version, live_status_url? }
//   fetch:       { status, blob_url, manifest_version,
//                  current_manifest_version, sha256, live_status_url? }
//   not_built:   { status, manifest_version, current_manifest_version }
//                — manifest exists but no graph blob has been built yet;
//                  client should call build-resort-graph
//   error:       { error }

import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient, SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2.39.0";

const GRAPH_VERSION = "v8"; // must match build-resort-graph + Swift
const TARGET_BUCKET = "resort-graphs";
const SIGNED_URL_TTL_SECONDS = 60 * 60;

const CORS_HEADERS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
} as const;

interface FetchRequest {
  resort_id: string;
  cached_manifest_version?: number;
  manifest_version?: number;
}

Deno.serve(async (req: Request): Promise<Response> => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: CORS_HEADERS });
  }
  if (req.method !== "POST") {
    return jsonError(405, "POST only");
  }

  let body: FetchRequest;
  try {
    body = await req.json();
  } catch {
    return jsonError(400, "invalid JSON body");
  }
  if (!body.resort_id || typeof body.resort_id !== "string") {
    return jsonError(400, "missing required field: resort_id");
  }

  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!supabaseUrl || !serviceKey) {
    return jsonError(500, "Edge Function env missing SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY");
  }
  const supabase = createClient(supabaseUrl, serviceKey);

  // ── 1. Current canonical version ──
  const { data: current } = await supabase
    .from("current_resort_canonical_manifest")
    .select("manifest_version")
    .eq("resort_id", body.resort_id)
    .maybeSingle();
  if (!current?.manifest_version) {
    return jsonError(404, `no canonical manifest for resort_id=${body.resort_id}`);
  }
  const currentManifestVersion = current.manifest_version as number;
  const target = body.manifest_version ?? currentManifestVersion;

  // ── 2. Live status sidecar (best-effort) ──
  const liveStatusUrl = await tryLiveStatusUrl(supabase, body.resort_id);

  // ── 3. Cache hit? ──
  if (
    body.cached_manifest_version != null &&
    body.cached_manifest_version === target
  ) {
    return jsonOk({
      status: "cache_valid",
      current_manifest_version: currentManifestVersion,
      live_status_url: liveStatusUrl,
    });
  }

  // ── 4. Look up the latest blob for the target manifest version ──
  // We pick the most recent snapshot_date so a later snapshot pin bump
  // for the same manifest_version is picked up automatically.
  const { data: blob } = await supabase
    .from("resort_graph_blob")
    .select("blob_storage_path, sha256, snapshot_date")
    .eq("resort_id", body.resort_id)
    .eq("manifest_version", target)
    .eq("graph_version", GRAPH_VERSION)
    .order("snapshot_date", { ascending: false })
    .limit(1)
    .maybeSingle();

  if (!blob) {
    return jsonOk({
      status: "not_built",
      manifest_version: target,
      current_manifest_version: currentManifestVersion,
    });
  }

  const signed = await supabase.storage.from(TARGET_BUCKET)
    .createSignedUrl(blob.blob_storage_path, SIGNED_URL_TTL_SECONDS);
  if (signed.error || !signed.data) {
    return jsonError(500, `createSignedUrl failed: ${signed.error?.message}`);
  }

  return jsonOk({
    status: "fetch",
    blob_url: signed.data.signedUrl,
    manifest_version: target,
    current_manifest_version: currentManifestVersion,
    sha256: blob.sha256,
    snapshot_date: blob.snapshot_date,
    live_status_url: liveStatusUrl,
  });
});

async function tryLiveStatusUrl(
  supabase: SupabaseClient,
  resortId: string,
): Promise<string | null> {
  // Hourly key. UTC to keep server + client consistent without TZ logic.
  const now = new Date();
  const key = `${now.toISOString().slice(0, 13)}`; // YYYY-MM-DDTHH
  const path = `${resortId}/live-${key}.json`;
  const { data, error } = await supabase.storage.from(TARGET_BUCKET)
    .createSignedUrl(path, SIGNED_URL_TTL_SECONDS);
  if (error || !data) return null;
  return data.signedUrl;
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
