// get-resort-graph — Edge Function (canonical graph blob fetcher)
//
// Read-side companion to build-resort-graph. Clients call this on every
// resort load to either (a) confirm their cached graph is still current
// or (b) get a signed URL to a fresh blob.
//
// Inputs:
//   resort_id                   — required
//   cached_manifest_version     — optional; what the client has on disk
//   cached_content_sha256       — optional; exact immutable blob identity
//   graph_version               — optional; exact graph schema for replay
//   content_sha256              — optional; exact historical blob for replay
//   manifest_version            — optional; force-fetch a previously
//                                 published version for cross-version meets
//
// Decision tree:
//   1. Resolve the one active publication for the resort.
//   2. A default request uses that exact tuple. An explicit historical
//      request must resolve to an immutable publication-history row.
//   3. Resolve resort_graph_blob by the publication's full identity.
//   4. If cached manifest + content SHA match → cache_valid.
//      Client keeps its cached dataset; only live status refreshes.
//   5. Else return a signed URL for that exact published graph blob.
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
//   error:       { error }

import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import {
  createClient,
  SupabaseClient,
} from "https://esm.sh/@supabase/supabase-js@2.39.0";
import { parseGraphFetchRequest } from "../_shared/graph_fetch_request.ts";
import {
  parsePublishedGraphIdentity,
  type PublishedGraphIdentity,
} from "../_shared/published_graph.ts";

const GRAPH_VERSION = "v15"; // must match build-resort-graph + Swift
const TARGET_BUCKET = "resort-graphs";
const SIGNED_URL_TTL_SECONDS = 60 * 60;

const ACTIVE_PUBLICATION_FIELDS = {
  manifestVersion: "manifest_version",
  graphVersion: "published_graph_version",
  snapshotDate: "published_snapshot_date",
  contentSHA256: "published_content_sha256",
} as const;

const HISTORY_PUBLICATION_FIELDS = {
  manifestVersion: "manifest_version",
  graphVersion: "graph_version",
  snapshotDate: "snapshot_date",
  contentSHA256: "content_sha256",
} as const;

const CORS_HEADERS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
} as const;

Deno.serve(async (req: Request): Promise<Response> => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: CORS_HEADERS });
  }
  if (req.method !== "POST") {
    return jsonError(405, "POST only");
  }

  let rawBody: unknown;
  try {
    rawBody = await req.json();
  } catch {
    return jsonError(400, "invalid JSON body");
  }
  const parsedBody = parseGraphFetchRequest(rawBody, GRAPH_VERSION);
  if (!parsedBody.ok) {
    return jsonError(400, parsedBody.error);
  }
  const body = parsedBody.value;

  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!supabaseUrl || !serviceKey) {
    return jsonError(
      500,
      "Edge Function env missing SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY",
    );
  }
  const supabase = createClient(supabaseUrl, serviceKey);

  // ── 1. Resolve the active, fully-published dataset ──
  const { data: current, error: currentError } = await supabase
    .from("current_resort_canonical_manifest")
    .select(
      "manifest_version,published_graph_version," +
        "published_snapshot_date,published_content_sha256",
    )
    .eq("resort_id", body.resort_id)
    .maybeSingle();
  if (currentError) {
    return jsonError(500, `active publication lookup failed: ${currentError.message}`);
  }
  if (!current) {
    return jsonError(
      404,
      `no published canonical dataset for resort_id=${body.resort_id}`,
    );
  }
  const parsedCurrent = parsePublishedGraphIdentity(
    current,
    ACTIVE_PUBLICATION_FIELDS,
  );
  if (!parsedCurrent.ok) {
    return jsonError(500, `active publication is invalid: ${parsedCurrent.error}`);
  }
  const activePublication = parsedCurrent.value;
  const currentManifestVersion = activePublication.manifestVersion;

  let publication: PublishedGraphIdentity;
  if (body.manifest_version == null) {
    if (body.graph_version !== activePublication.graphVersion) {
      return jsonError(
        409,
        `active graph version is ${activePublication.graphVersion}; ` +
          `requested ${body.graph_version}`,
      );
    }
    publication = activePublication;
  } else {
    let publicationQuery = supabase
      .from("resort_canonical_publication")
      .select("manifest_version,graph_version,snapshot_date,content_sha256")
      .eq("resort_id", body.resort_id)
      .eq("manifest_version", body.manifest_version)
      .eq("graph_version", body.graph_version);
    if (body.content_sha256 != null) {
      publicationQuery = publicationQuery.eq(
        "content_sha256",
        body.content_sha256,
      );
    }
    const { data: historical, error: historicalError } = await publicationQuery
      .order("published_at", { ascending: false })
      .limit(1)
      .maybeSingle();
    if (historicalError) {
      return jsonError(
        500,
        `publication history lookup failed: ${historicalError.message}`,
      );
    }
    if (!historical) {
      return jsonError(404, "requested canonical dataset was never published");
    }
    const parsedHistorical = parsePublishedGraphIdentity(
      historical,
      HISTORY_PUBLICATION_FIELDS,
    );
    if (!parsedHistorical.ok) {
      return jsonError(
        500,
        `publication history is invalid: ${parsedHistorical.error}`,
      );
    }
    publication = parsedHistorical.value;
  }

  // ── 2. Live status sidecar (best-effort) ──
  const liveStatusUrl = await tryLiveStatusUrl(supabase, body.resort_id);

  // ── 3. Look up only the exact blob authorized by publication history ──
  const { data: blob, error: blobError } = await supabase
    .from("resort_graph_blob")
    .select("blob_storage_path, sha256, snapshot_date")
    .eq("resort_id", body.resort_id)
    .eq("manifest_version", publication.manifestVersion)
    .eq("graph_version", publication.graphVersion)
    .eq("snapshot_date", publication.snapshotDate)
    .eq("sha256", publication.contentSHA256)
    .maybeSingle();
  if (blobError) {
    return jsonError(500, `published graph lookup failed: ${blobError.message}`);
  }
  if (
    !blob || typeof blob.blob_storage_path !== "string" ||
    blob.blob_storage_path.trim() === "" ||
    blob.sha256 !== publication.contentSHA256 ||
    blob.snapshot_date !== publication.snapshotDate
  ) {
    return jsonError(500, "published graph metadata is missing or inconsistent");
  }

  // ── 4. Exact cache hit? ──
  if (
    body.cached_manifest_version != null &&
    body.cached_manifest_version === publication.manifestVersion &&
    body.cached_content_sha256 != null &&
    body.cached_content_sha256 === publication.contentSHA256
  ) {
    return jsonOk({
      status: "cache_valid",
      manifest_version: publication.manifestVersion,
      current_manifest_version: currentManifestVersion,
      graph_version: publication.graphVersion,
      sha256: publication.contentSHA256,
      snapshot_date: publication.snapshotDate,
      live_status_url: liveStatusUrl,
    });
  }

  // ── 5. Return exact immutable dataset blob ──
  const signed = await supabase.storage.from(TARGET_BUCKET)
    .createSignedUrl(blob.blob_storage_path, SIGNED_URL_TTL_SECONDS);
  if (signed.error || !signed.data) {
    return jsonError(500, `createSignedUrl failed: ${signed.error?.message}`);
  }

  return jsonOk({
    status: "fetch",
    blob_url: signed.data.signedUrl,
    manifest_version: publication.manifestVersion,
    current_manifest_version: currentManifestVersion,
    graph_version: publication.graphVersion,
    sha256: publication.contentSHA256,
    snapshot_date: publication.snapshotDate,
    live_status_url: liveStatusUrl,
  });
});

async function tryLiveStatusUrl(
  supabase: SupabaseClient,
  resortId: string,
): Promise<string | null> {
  // The hourly refresh need not run exactly at :00. During the short gap
  // after an hour boundary, the previous hour's blob can still be within its
  // embedded expires_at. The client validates that expiry before applying it.
  const currentHour = new Date();
  currentHour.setUTCMinutes(0, 0, 0);
  for (const hourOffset of [0, -1]) {
    const candidate = new Date(currentHour.getTime() + hourOffset * 3_600_000);
    const key = candidate.toISOString().slice(0, 13); // YYYY-MM-DDTHH
    const path = `${resortId}/live-${key}.json`;
    const { data, error } = await supabase.storage.from(TARGET_BUCKET)
      .createSignedUrl(path, SIGNED_URL_TTL_SECONDS);
    if (!error && data) return data.signedUrl;
  }
  return null;
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
