// snapshot-resort — Edge Function (chunked-elevation builder)
//
// Builds a deterministic, shared resort graph snapshot. Two devices that
// hit this function for the same resort within the cache TTL get back
// signed URLs to the *same* OSM + elevation blobs, so their on-device
// graph builders produce identical fingerprints — required for the
// cross-device meeting-point solver to converge.
//
// Why chunked: big resorts (Whistler, Vail, Beaver Creek, Palisades) hit
// 5K+ unique coords. Open-Meteo elevation rate-limits per-IP at ~6-10
// batches before 429s with 60-120s recovery. A naive "build everything
// in one invocation" loop blows past Supabase's 150s gateway wall-clock
// AND its WORKER_RESOURCE_LIMIT (HTTP 546). The chunked path splits a
// resort across multiple invocations, persisting partial elevation in a
// checkpoint blob so each call only has to process ~1200 coords.
//
// State machine (per resort × per pinned date):
//
//   ┌─────────────┐
//   │  Final blob │  osm-{date}.json + elev-{date}.json exist
//   │  cached     │  → return signed URLs (status: "ready", cached: true)
//   └──────┬──────┘
//          │ no
//          ▼
//   ┌─────────────┐
//   │ Checkpoint  │  checkpoint-{date}.json exists in Storage
//   │ continue    │  → process next ~1200 coords; merge into checkpoint;
//   │             │    if all done, write final elev blob and DELETE
//   │             │    checkpoint (return ready); else write updated
//   │             │    checkpoint (return elevation_pending with progress)
//   └──────┬──────┘
//          │ no
//          ▼
//   ┌─────────────┐
//   │ Stage 0:    │  Fetch Overpass; collect unique coords; upload
//   │ initial     │  osm-{date}.json; write checkpoint with {coords,
//   │ build       │  elevations: {}, processed: 0}; return
//   │             │  elevation_pending so client immediately re-calls.
//   └─────────────┘
//
// Response shape (matches Swift `SnapshotResponse`):
//   - ready:     { status, snapshot_date, osm_url, elevation_url, cached }
//   - pending:   { status, snapshot_date, elevation_progress: {processed, total} }
//
// Storage layout per (resort_id, date):
//   {resort_id}/osm-{date}.json         — final OSM blob (written stage 0, immutable)
//   {resort_id}/elev-{date}.json        — final elevation blob (written when last chunk merges)
//   {resort_id}/checkpoint-{date}.json  — { coords[], processed, elevations{} }; deleted on completion
//
// Storage requirements:
//   - Private bucket named `resort-snapshots` must exist.
//   - Edge Function env: SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY.

import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient, SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2.39.0";

// ── Tunables ────────────────────────────────────────────────────────────────

const TTL_HOURS = 24;
const ELEVATION_BATCH = 100;

/// How many elevation batches we'll attempt in a single invocation.
/// Was 12 (= 1200 coords). Realistic Open-Meteo latency under load
/// pushed each invocation to 18-23s of elevation work, which left
/// zero margin under Supabase's edge timeout. Big resorts (Whistler
/// especially) were hitting 502 timeouts on most invocations,
/// each costing the client ~27s of perceived lag before the next
/// retry tick. Halving the slice (6 × 100 = 600 coords) finishes
/// elevation in ~9-12s under realistic conditions and roughly
/// doubles the round-trip count for a cold build — net much faster
/// end-to-end because nothing times out.
const BATCHES_PER_INVOCATION = 6;
const COORDS_PER_INVOCATION = BATCHES_PER_INVOCATION * ELEVATION_BATCH;

const SIGNED_URL_TTL_SECONDS = 60 * 60; // 1h
const BUCKET = "resort-snapshots";

const CORS_HEADERS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
} as const;

// ── Types ───────────────────────────────────────────────────────────────────

interface SnapshotRequest {
  resort_id: string;
  south: number;
  west: number;
  north: number;
  east: number;
  /// YYYY-MM-DD; bypasses TTL search and looks up exact filename.
  pinned_snapshot_date?: string;
  /// When true, this is a continuation call — skip the OSM fetch and
  /// just process the next chunk of elevation coords from the existing
  /// checkpoint. Required to keep stage-0 atomic across very-large
  /// Overpass responses.
  continue?: boolean;
}

interface OverpassElement {
  type: "way" | "node" | "relation";
  id: number;
  lat?: number;
  lon?: number;
  nodes?: number[];
  tags?: Record<string, string>;
}

interface OverpassResponse {
  elements: OverpassElement[];
}

interface CheckpointBlob {
  coords: string[];
  /// processed = next index to consume from `coords`. coords[0..processed]
  /// have entries in `elevations` (assuming Open-Meteo answered).
  processed: number;
  elevations: Record<string, number>;
  /// Bbox kept so this checkpoint is self-contained — a continuation
  /// call doesn't have to re-trust the request body's bbox.
  bbox: { south: number; west: number; north: number; east: number };
}

// ── Handler ─────────────────────────────────────────────────────────────────

Deno.serve(async (req: Request): Promise<Response> => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: CORS_HEADERS });
  }
  if (req.method !== "POST") {
    return jsonError(405, "POST only");
  }

  let body: SnapshotRequest;
  try {
    body = await req.json();
  } catch {
    return jsonError(400, "invalid JSON body");
  }
  const { resort_id, south, west, north, east, pinned_snapshot_date } = body;
  if (
    !resort_id ||
    typeof south !== "number" ||
    typeof west !== "number" ||
    typeof north !== "number" ||
    typeof east !== "number"
  ) {
    return jsonError(400, "missing field — need resort_id, south, west, north, east");
  }
  if (pinned_snapshot_date && !/^\d{4}-\d{2}-\d{2}$/.test(pinned_snapshot_date)) {
    return jsonError(400, "pinned_snapshot_date must be YYYY-MM-DD");
  }

  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!supabaseUrl || !serviceKey) {
    return jsonError(500, "Edge Function env missing SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY");
  }
  const supabase = createClient(supabaseUrl, serviceKey);

  const stamp = pinned_snapshot_date ?? new Date().toISOString().split("T")[0];

  // ── 1. Final-blob cache hit ──
  // Pinned: exact filename, no TTL. Unpinned: legacy "any < TTL old" search.

  if (pinned_snapshot_date) {
    const finalReady = await tryPinnedSnapshot(supabase, resort_id, pinned_snapshot_date);
    if (finalReady) return jsonOk(finalReady);
  } else {
    const cached = await tryCachedSnapshot(supabase, resort_id);
    if (cached) return jsonOk(cached);
  }

  // ── 2. Checkpoint continuation (or initial creation) ──

  const checkpointPath = `${resort_id}/checkpoint-${stamp}.json`;
  let checkpoint: CheckpointBlob | null = await readCheckpoint(supabase, checkpointPath);

  if (!checkpoint) {
    // Stage 0: initial build. Fetch Overpass, write OSM blob, write
    // checkpoint with empty elevations. We DON'T process any coords on
    // stage 0 — Overpass alone can take 30-60s on big resorts and we'd
    // rather start the elevation loop in a fresh invocation that's
    // guaranteed budget headroom.
    let osmData: OverpassResponse;
    try {
      osmData = await fetchOverpass(south, west, north, east);
    } catch (err) {
      return jsonError(502, `Overpass fetch failed: ${(err as Error).message}`);
    }

    // OSM upload is idempotent — if a previous invocation got this far
    // and crashed, we overwrite. The Storage upsert flag handles the case.
    const osmPath = `${resort_id}/osm-${stamp}.json`;
    const osmUpload = await supabase.storage.from(BUCKET).upload(
      osmPath,
      new TextEncoder().encode(JSON.stringify(osmData)),
      { contentType: "application/json", upsert: true },
    );
    if (osmUpload.error) {
      return jsonError(500, `OSM upload failed: ${osmUpload.error.message}`);
    }

    const coords = collectUniqueCoords(osmData);
    checkpoint = {
      coords,
      processed: 0,
      elevations: {},
      bbox: { south, west, north, east },
    };
    await writeCheckpoint(supabase, checkpointPath, checkpoint);

    // Empty resort short-circuit: 0 coords means the checkpoint is
    // already "complete." Write a final empty elevation blob and return
    // ready immediately so the client doesn't get stuck calling back
    // forever. (Coming-soon resorts hit this; client UI filters them
    // out anyway, but safety belt for any catalog miss.)
    if (coords.length === 0) {
      return await finalizeAndReturn(supabase, resort_id, stamp, checkpoint, checkpointPath);
    }

    return jsonOk({
      status: "elevation_pending",
      snapshot_date: stamp,
      elevation_progress: { processed: 0, total: coords.length },
    });
  }

  // Stage 1: process the next chunk of elevation coords.
  const remaining = checkpoint.coords.slice(checkpoint.processed);
  const slice = remaining.slice(0, COORDS_PER_INVOCATION);

  let elevations: Record<string, number>;
  try {
    elevations = await fetchElevations(slice);
  } catch (err) {
    // Don't blow away the checkpoint on a partial elevation fetch —
    // the next call will retry the same slice. Surface as 502 so the
    // client retries with backoff.
    return jsonError(502, `Elevation fetch failed: ${(err as Error).message}`);
  }
  Object.assign(checkpoint.elevations, elevations);
  checkpoint.processed += slice.length;

  if (checkpoint.processed >= checkpoint.coords.length) {
    // Last chunk — merge final elevation blob, delete checkpoint, return ready.
    return await finalizeAndReturn(supabase, resort_id, stamp, checkpoint, checkpointPath);
  }

  // Still pending — persist updated checkpoint and tell the client to come back.
  await writeCheckpoint(supabase, checkpointPath, checkpoint);
  return jsonOk({
    status: "elevation_pending",
    snapshot_date: stamp,
    elevation_progress: {
      processed: checkpoint.processed,
      total: checkpoint.coords.length,
    },
  });
});

// ── Finalisation ────────────────────────────────────────────────────────────

async function finalizeAndReturn(
  supabase: SupabaseClient,
  resortId: string,
  stamp: string,
  checkpoint: CheckpointBlob,
  checkpointPath: string,
): Promise<Response> {
  const elevPath = `${resortId}/elev-${stamp}.json`;
  const elevUpload = await supabase.storage.from(BUCKET).upload(
    elevPath,
    new TextEncoder().encode(JSON.stringify(checkpoint.elevations)),
    { contentType: "application/json", upsert: true },
  );
  if (elevUpload.error) {
    return jsonError(500, `Elevation upload failed: ${elevUpload.error.message}`);
  }

  // Best-effort checkpoint delete — leaving it behind is harmless
  // (the final blob takes precedence on next call) but the cleanup
  // keeps Storage tidy.
  await supabase.storage.from(BUCKET).remove([checkpointPath]).catch(() => {});

  const osmSigned = await supabase.storage.from(BUCKET)
    .createSignedUrl(`${resortId}/osm-${stamp}.json`, SIGNED_URL_TTL_SECONDS);
  const elevSigned = await supabase.storage.from(BUCKET)
    .createSignedUrl(elevPath, SIGNED_URL_TTL_SECONDS);
  if (osmSigned.error || !osmSigned.data || elevSigned.error || !elevSigned.data) {
    return jsonError(500, "createSignedUrl failed");
  }

  return jsonOk({
    status: "ready",
    snapshot_date: stamp,
    osm_url: osmSigned.data.signedUrl,
    elevation_url: elevSigned.data.signedUrl,
    cached: false,
  });
}

// ── Pinned cache lookup ─────────────────────────────────────────────────────

async function tryPinnedSnapshot(
  supabase: SupabaseClient,
  resortId: string,
  date: string,
): Promise<
  | { status: "ready"; snapshot_date: string; osm_url: string; elevation_url: string; cached: true }
  | null
> {
  const osmPath = `${resortId}/osm-${date}.json`;
  const elevPath = `${resortId}/elev-${date}.json`;

  const osmSigned = await supabase.storage.from(BUCKET)
    .createSignedUrl(osmPath, SIGNED_URL_TTL_SECONDS);
  if (osmSigned.error || !osmSigned.data) return null;

  const elevSigned = await supabase.storage.from(BUCKET)
    .createSignedUrl(elevPath, SIGNED_URL_TTL_SECONDS);
  if (elevSigned.error || !elevSigned.data) return null;

  return {
    status: "ready",
    snapshot_date: date,
    osm_url: osmSigned.data.signedUrl,
    elevation_url: elevSigned.data.signedUrl,
    cached: true,
  };
}

// ── Legacy unpinned cache lookup ────────────────────────────────────────────

async function tryCachedSnapshot(
  supabase: SupabaseClient,
  resortId: string,
): Promise<
  | { status: "ready"; snapshot_date: string; osm_url: string; elevation_url: string; cached: true }
  | null
> {
  const { data: files, error } = await supabase.storage.from(BUCKET).list(resortId, {
    limit: 100,
    sortBy: { column: "created_at", order: "desc" },
  });
  if (error || !files) return null;

  const cutoff = Date.now() - TTL_HOURS * 60 * 60 * 1000;
  const osmFiles = files.filter(f => f.name.startsWith("osm-") && f.name.endsWith(".json"));
  for (const osm of osmFiles) {
    const created = osm.created_at ? Date.parse(osm.created_at) : 0;
    if (created < cutoff) continue;
    const date = osm.name.replace(/^osm-|\.json$/g, "");
    const matchingElev = files.find(f => f.name === `elev-${date}.json`);
    if (!matchingElev) continue;

    const osmSigned = await supabase.storage.from(BUCKET)
      .createSignedUrl(`${resortId}/${osm.name}`, SIGNED_URL_TTL_SECONDS);
    const elevSigned = await supabase.storage.from(BUCKET)
      .createSignedUrl(`${resortId}/${matchingElev.name}`, SIGNED_URL_TTL_SECONDS);
    if (osmSigned.error || !osmSigned.data || elevSigned.error || !elevSigned.data) continue;

    return {
      status: "ready",
      snapshot_date: date,
      osm_url: osmSigned.data.signedUrl,
      elevation_url: elevSigned.data.signedUrl,
      cached: true,
    };
  }
  return null;
}

// ── Checkpoint I/O ──────────────────────────────────────────────────────────

async function readCheckpoint(
  supabase: SupabaseClient,
  path: string,
): Promise<CheckpointBlob | null> {
  const { data, error } = await supabase.storage.from(BUCKET).download(path);
  if (error || !data) return null;
  try {
    const text = await data.text();
    return JSON.parse(text) as CheckpointBlob;
  } catch {
    return null;
  }
}

async function writeCheckpoint(
  supabase: SupabaseClient,
  path: string,
  blob: CheckpointBlob,
): Promise<void> {
  await supabase.storage.from(BUCKET).upload(
    path,
    new TextEncoder().encode(JSON.stringify(blob)),
    { contentType: "application/json", upsert: true },
  );
}

// ── Overpass fetch ──────────────────────────────────────────────────────────

async function fetchOverpass(
  south: number, west: number, north: number, east: number,
): Promise<OverpassResponse> {
  const bbox = `${south},${west},${north},${east}`;
  const query = `
[out:json][timeout:90];
(
  way["piste:type"="downhill"](${bbox});
  way["aerialway"](${bbox});
  node["aerialway"="station"](${bbox});
);
out body;
>;
out qt;
`.trim();

  const resp = await fetch("https://overpass-api.de/api/interpreter", {
    method: "POST",
    headers: {
      "Content-Type": "application/x-www-form-urlencoded",
      "User-Agent": "PowderMeet-snapshot-resort/1.0 (https://github.com/zlichtman/PowderMeet)",
      "Accept": "application/json",
    },
    body: `data=${encodeURIComponent(query)}`,
  });
  if (!resp.ok) {
    const detail = await resp.text().catch(() => "(no body)");
    throw new Error(`Overpass HTTP ${resp.status}: ${detail.slice(0, 200)}`);
  }
  return await resp.json() as OverpassResponse;
}

// ── Coord collection ────────────────────────────────────────────────────────

function collectUniqueCoords(data: OverpassResponse): string[] {
  const seen = new Set<string>();
  for (const el of data.elements ?? []) {
    if (el.type === "node" && typeof el.lat === "number" && typeof el.lon === "number") {
      seen.add(`${el.lat.toFixed(6)},${el.lon.toFixed(6)}`);
    }
  }
  return Array.from(seen);
}

// ── Elevation batch fetch (chunk-scoped) ────────────────────────────────────

async function fetchElevations(coordKeys: string[]): Promise<Record<string, number>> {
  const result: Record<string, number> = {};
  if (coordKeys.length === 0) return result;

  const interBatchDelayMs = 350;
  const maxAttempts = 4;
  const maxBackoffMs = 20_000;

  for (let i = 0; i < coordKeys.length; i += ELEVATION_BATCH) {
    const batch = coordKeys.slice(i, i + ELEVATION_BATCH);
    const latitudes = batch.map(k => k.split(",")[0]).join(",");
    const longitudes = batch.map(k => k.split(",")[1]).join(",");
    const url = `https://api.open-meteo.com/v1/elevation?latitude=${latitudes}&longitude=${longitudes}`;

    let resp: Response | null = null;
    for (let attempt = 0; attempt < maxAttempts; attempt++) {
      try {
        resp = await fetch(url);
      } catch (err) {
        if (attempt === maxAttempts - 1) throw err;
        await sleep(Math.min(maxBackoffMs, 1000 * Math.pow(2, attempt)));
        continue;
      }
      if (resp.status !== 429 && resp.ok) break;
      if (!resp.ok && resp.status !== 429) {
        throw new Error(`Elevation HTTP ${resp.status} for batch ${i}/${coordKeys.length} (non-retryable)`);
      }
      const retryAfter = parseInt(resp.headers.get("Retry-After") ?? "", 10);
      const delay = Number.isFinite(retryAfter) && retryAfter > 0
        ? Math.min(retryAfter * 1000, maxBackoffMs)
        : Math.min(maxBackoffMs, 1500 * Math.pow(2, attempt));
      await sleep(delay);
    }
    if (!resp || !resp.ok) {
      throw new Error(`Elevation HTTP ${resp?.status ?? "?"} for batch ${i}/${coordKeys.length} after ${maxAttempts} attempts`);
    }
    const json = await resp.json() as { elevation: number[] };
    if (!Array.isArray(json.elevation) || json.elevation.length !== batch.length) {
      throw new Error(
        `Elevation response shape mismatch (got ${json.elevation?.length ?? "nil"}, want ${batch.length})`,
      );
    }
    batch.forEach((key, idx) => {
      result[key] = json.elevation[idx];
    });

    if (i + ELEVATION_BATCH < coordKeys.length) {
      await sleep(interBatchDelayMs);
    }
  }
  return result;
}

function sleep(ms: number): Promise<void> {
  return new Promise(resolve => setTimeout(resolve, ms));
}

// ── Response helpers ────────────────────────────────────────────────────────

function jsonOk(body: unknown): Response {
  return new Response(JSON.stringify(body), {
    status: 200,
    headers: { ...CORS_HEADERS, "Content-Type": "application/json" },
  });
}

function jsonError(status: number, message: string): Response {
  return new Response(JSON.stringify({ error: message }), {
    status,
    headers: { ...CORS_HEADERS, "Content-Type": "application/json" },
  });
}
