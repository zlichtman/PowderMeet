// build-resort-graph — Edge Function (canonical graph blob builder)
//
// Produces an immutable, staged graph blob that becomes client-visible only
// after publish_canonical_manifest atomically activates its exact identity.
// CanonicalGraphFetcher.swift consumes on the client. Replaces the
// on-device GraphBuilder.buildGraph + CuratedResortLoader.applyOverlay
// + ResortDataEnricher pipeline with a single deterministic build run
// keyed by (resort_id, manifest_version, snapshot_date, graph_version).
//
// Pipeline:
//   1. Resolve manifest_version + snapshot_date from request or DB defaults.
//   2. Check resort_graph_blob for existing build of this exact tuple —
//      return signed URL immediately if present (idempotent).
//   3. Verify resort-snapshots/{resort_id}/{osm,elev}-{date}.json exist.
//      If not, return 409 snapshot_pending so the caller drives
//      snapshot-resort to completion first.
//   4. Download OSM + elevation blobs.
//   5. Build the graph via _shared/graph_builder.ts (TS port of Swift).
//   6. Apply canonical overlay from canonical_trail / canonical_lift
//      via _shared/curated_overlay.ts.
//   7. Apply canonical_geometry_override substitution where present.
//   8. Compute fingerprint, deflate (raw zlib for client COMPRESSION_ZLIB),
//      upload to resort-graphs bucket, insert resort_graph_blob row,
//      return signed URL.

import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import {
  createClient,
  SupabaseClient,
} from "https://esm.sh/@supabase/supabase-js@2.39.0";
import { deflateSync } from "https://esm.sh/fflate@0.8.2";
import {
  buildGraph,
  type ResortData,
} from "../_shared/graph_builder.ts";
import { MountainSourceError, osmToResortData } from "../_shared/osm_snapshot.ts";
import { applyCuratedOverlay } from "../_shared/curated_overlay.ts";
import {
  applyGeometryOverrides,
  type CanonicalGeometryOverride,
} from "../_shared/geometry_overrides.ts";
import { validateCanonicalGraph } from "../_shared/graph_integrity.ts";
import { encodeGraph } from "../_shared/graph_types.ts";
import {
  buildRendezvousCatalog,
  type CanonicalRendezvousRow,
  overlayCuratedRendezvous,
} from "../_shared/rendezvous_catalog.ts";
import {
  bearerRole,
  manifestCountFailure,
  parseGraphBuildRequest,
} from "../_shared/graph_build_request.ts";

const GRAPH_VERSION = "v15";
const SOURCE_BUCKET = "resort-snapshots";
const TARGET_BUCKET = "resort-graphs";
const SIGNED_URL_TTL_SECONDS = 60 * 60;

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
  const parsedBody = parseGraphBuildRequest(rawBody, GRAPH_VERSION);
  if (!parsedBody.ok) {
    return jsonError(400, parsedBody.error);
  }
  const body = parsedBody.value;

  // Builds write staged blobs and metadata with the service role. The gateway
  // verifies the JWT signature; only an operator's service-role token may
  // start one (the app never calls this function).
  if (bearerRole(req) !== "service_role") {
    return jsonError(403, "build-resort-graph requires the service role");
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
  const graphVersion = body.graph_version;

  // 1. Resolve manifest version
  const manifest = await resolveManifest(
    supabase,
    body.resort_id,
    body.manifest_version,
  );
  if (!manifest) {
    return jsonError(
      404,
      `no canonical manifest for resort_id=${body.resort_id}`,
    );
  }

  // 2. Resolve snapshot date
  const snapshotDate = body.snapshot_date ??
    await resolveSnapshotDate(supabase, body.resort_id);
  if (!snapshotDate) {
    return jsonError(
      404,
      `no resort_snapshot_pin for resort_id=${body.resort_id}`,
    );
  }

  // 3. Idempotency: existing blob?
  const existingLookup = await findExistingBlob(
    supabase,
    body.resort_id,
    manifest.manifest_version,
    snapshotDate,
    graphVersion,
  );
  if (existingLookup.error) {
    return jsonError(
      500,
      `existing graph lookup failed: ${existingLookup.error}`,
    );
  }
  const existing = existingLookup.data;
  if (existing) {
    if (
      typeof existing.blob_storage_path !== "string" ||
      existing.blob_storage_path.trim() === "" ||
      !/^[0-9a-f]{64}$/.test(existing.sha256)
    ) {
      return jsonError(500, "existing graph metadata is invalid");
    }
    const signed = await supabase.storage.from(TARGET_BUCKET)
      .createSignedUrl(existing.blob_storage_path, SIGNED_URL_TTL_SECONDS);
    if (signed.error || !signed.data) {
      return jsonError(
        500,
        `createSignedUrl failed for existing blob: ${signed.error?.message}`,
      );
    }
    return jsonOk({
      status: "ready",
      blob_url: signed.data.signedUrl,
      manifest_version: manifest.manifest_version,
      snapshot_date: snapshotDate,
      graph_version: graphVersion,
      sha256: existing.sha256,
      cached: true,
    });
  }

  // 4. Verify snapshot blobs exist
  const osmBlob = await downloadStorageJson(
    supabase,
    SOURCE_BUCKET,
    `${body.resort_id}/osm-${snapshotDate}.json`,
  );
  const elevBlob = await downloadStorageJson<Record<string, number>>(
    supabase,
    SOURCE_BUCKET,
    `${body.resort_id}/elev-${snapshotDate}.json`,
  );
  if (!osmBlob || !elevBlob) {
    return jsonOk({
      status: "snapshot_pending",
      snapshot_date: snapshotDate,
    });
  }

  // 5. Convert OSM payload to ResortData
  let resortData: ResortData;
  try {
    resortData = osmToResortData(osmBlob, elevBlob);
  } catch (error) {
    if (error instanceof MountainSourceError) return jsonError(422, error.message);
    throw error;
  }

  // 6. Build graph
  let graph = buildGraph(resortData, body.resort_id);

  // 7. Apply canonical overlay. Every lookup fails closed: an unreadable or
  //    short manifest must never produce a graph with no canonical authority
  //    (every source trail left open) that publish would then accept.
  const trailLookup = await loadCanonicalTrails(
    supabase,
    body.resort_id,
    manifest.manifest_version,
  );
  if (trailLookup.error) return jsonError(500, trailLookup.error);
  const liftLookup = await loadCanonicalLifts(
    supabase,
    body.resort_id,
    manifest.manifest_version,
  );
  if (liftLookup.error) return jsonError(500, liftLookup.error);
  const overrideLookup = await loadGeometryOverrides(
    supabase,
    body.resort_id,
  );
  if (overrideLookup.error) return jsonError(500, overrideLookup.error);
  const trails = trailLookup.data;
  const lifts = liftLookup.data;
  const overrides = overrideLookup.data;
  const countFailure = manifestCountFailure(manifest, trails.length, lifts.length);
  if (countFailure) return jsonError(422, countFailure);
  const overlayResult = applyCuratedOverlay(graph, {
    trails: trails as any,
    lifts: lifts as any,
  });
  if (overlayResult.failures.length > 0) {
    return jsonError(
      422,
      `canonical manifest reconciliation failed: ${
        JSON.stringify(overlayResult.failures)
      }`,
    );
  }
  if (
    overlayResult.appliedTrailIdentities !== trails.length ||
    overlayResult.appliedLiftIdentities !== lifts.length
  ) {
    return jsonError(
      422,
      "canonical manifest reconciliation applied " +
        `${overlayResult.appliedTrailIdentities}/${trails.length} trails and ` +
        `${overlayResult.appliedLiftIdentities}/${lifts.length} lifts`,
    );
  }
  graph = overlayResult.graph;

  // 8. Geometry overrides are atomic and fail closed. Name-level overrides
  //    are safe only for a single graph edge; fragmented trails retain their
  //    source geometry until the authoring schema can target individual ways.
  const geometryResult = applyGeometryOverrides(graph, overrides);
  if (geometryResult.failures.length > 0) {
    return jsonError(
      422,
      `canonical geometry override validation failed: ${
        JSON.stringify(geometryResult.failures)
      }`,
    );
  }
  graph = geometryResult.graph;

  // 9. Never stage a graph that fails referential, physical, semantic,
  //    or fingerprint validation.
  const integrityFailures = validateCanonicalGraph(graph, body.resort_id);
  if (integrityFailures.length > 0) {
    return jsonError(
      422,
      "canonical graph integrity validation failed: " +
        JSON.stringify(integrityFailures),
    );
  }

  // 10. Encode + compress + upload
  const wire = encodeGraph(graph);
  const curatedRendezvousLookup = await loadCanonicalRendezvous(
    supabase,
    body.resort_id,
    manifest.manifest_version,
  );
  if (curatedRendezvousLookup.error) {
    return jsonError(500, curatedRendezvousLookup.error);
  }
  const rendezvousResult = overlayCuratedRendezvous(
    graph,
    buildRendezvousCatalog(graph),
    curatedRendezvousLookup.data,
  );
  if (rendezvousResult.failures.length > 0) {
    return jsonError(
      422,
      `canonical rendezvous reconciliation failed: ${
        JSON.stringify(rendezvousResult.failures)
      }`,
    );
  }
  wire.rendezvousCatalog = rendezvousResult.catalog;
  if (wire.rendezvousCatalog.points.length === 0) {
    return jsonError(422, "canonical graph has no safe rendezvous points");
  }
  const json = JSON.stringify(wire);
  const encoded = new TextEncoder().encode(json);
  const compressed = deflateSync(encoded);
  const sha256 = await sha256Hex(compressed);
  const path =
    `${body.resort_id}/${manifest.manifest_version}-${snapshotDate}-${graphVersion}.json.gz`;

  const { error: upErr } = await supabase.storage.from(TARGET_BUCKET).upload(
    path,
    compressed,
    { contentType: "application/gzip", upsert: true },
  );
  if (upErr) return jsonError(500, `blob upload failed: ${upErr.message}`);

  const { error: blobRowError } = await supabase.from("resort_graph_blob")
    .upsert({
      resort_id: body.resort_id,
      manifest_version: manifest.manifest_version,
      snapshot_date: snapshotDate,
      graph_version: graphVersion,
      blob_storage_path: path,
      sha256,
    });
  if (blobRowError) {
    return jsonError(
      500,
      `graph metadata write failed: ${blobRowError.message}`,
    );
  }

  const signed = await supabase.storage.from(TARGET_BUCKET)
    .createSignedUrl(path, SIGNED_URL_TTL_SECONDS);
  if (signed.error || !signed.data) {
    return jsonError(500, `createSignedUrl failed: ${signed.error?.message}`);
  }

  return jsonOk({
    status: "ready",
    blob_url: signed.data.signedUrl,
    manifest_version: manifest.manifest_version,
    snapshot_date: snapshotDate,
    graph_version: graphVersion,
    sha256,
    fingerprint: graph.fingerprint,
    nodes: Object.keys(wire.nodes).length,
    edges: wire.edges.length,
    rendezvous_points: wire.rendezvousCatalog.points.length,
    cached: false,
  });
});

// ── Helpers ─────────────────────────────────────────────────────────

interface CanonicalManifest {
  resort_id: string;
  manifest_version: number;
  expected_trail_count: number;
  expected_lift_count: number;
}

async function resolveManifest(
  supabase: SupabaseClient,
  resortId: string,
  requestedVersion: number | undefined,
): Promise<CanonicalManifest | null> {
  if (requestedVersion != null) {
    const { data } = await supabase
      .from("resort_canonical_manifest")
      .select(
        "resort_id, manifest_version, expected_trail_count, expected_lift_count",
      )
      .eq("resort_id", resortId)
      .eq("manifest_version", requestedVersion)
      .maybeSingle();
    return data;
  }
  const { data } = await supabase
    .from("current_resort_canonical_manifest")
    .select(
      "resort_id, manifest_version, expected_trail_count, expected_lift_count",
    )
    .eq("resort_id", resortId)
    .maybeSingle();
  return data;
}

async function resolveSnapshotDate(
  supabase: SupabaseClient,
  resortId: string,
): Promise<string | null> {
  const { data: per } = await supabase
    .from("resort_snapshot_pins")
    .select("snapshot_date")
    .eq("resort_id", resortId)
    .maybeSingle();
  if (per?.snapshot_date) return per.snapshot_date;
  const { data: cat } = await supabase
    .from("resort_snapshot_pins")
    .select("snapshot_date")
    .eq("resort_id", "__catalog__")
    .maybeSingle();
  return cat?.snapshot_date ?? null;
}

async function findExistingBlob(
  supabase: SupabaseClient,
  resortId: string,
  manifestVersion: number,
  snapshotDate: string,
  graphVersion: string,
): Promise<{
  data: { blob_storage_path: string; sha256: string } | null;
  error: string | null;
}> {
  const { data, error } = await supabase
    .from("resort_graph_blob")
    .select("blob_storage_path, sha256")
    .eq("resort_id", resortId)
    .eq("manifest_version", manifestVersion)
    .eq("snapshot_date", snapshotDate)
    .eq("graph_version", graphVersion)
    .maybeSingle();
  return { data, error: error?.message ?? null };
}

async function downloadStorageJson<T = unknown>(
  supabase: SupabaseClient,
  bucket: string,
  path: string,
): Promise<T | null> {
  const { data, error } = await supabase.storage.from(bucket).download(path);
  if (error || !data) return null;
  try {
    return JSON.parse(await data.text()) as T;
  } catch {
    return null;
  }
}

async function loadCanonicalTrails(
  supabase: SupabaseClient,
  resortId: string,
  manifestVersion: number,
): Promise<{ data: any[]; error: string | null }> {
  const { data, error } = await supabase.rpc("canonical_trails_with_geom", {
    p_resort_id: resortId,
    p_manifest_version: manifestVersion,
  });
  if (error) {
    return { data: [], error: `canonical trail lookup failed: ${error.message}` };
  }
  return { data: data ?? [], error: null };
}

async function loadCanonicalLifts(
  supabase: SupabaseClient,
  resortId: string,
  manifestVersion: number,
): Promise<{ data: any[]; error: string | null }> {
  const { data, error } = await supabase.rpc("canonical_lifts_with_geom", {
    p_resort_id: resortId,
    p_manifest_version: manifestVersion,
  });
  if (error) {
    return { data: [], error: `canonical lift lookup failed: ${error.message}` };
  }
  return { data: data ?? [], error: null };
}

async function loadCanonicalRendezvous(
  supabase: SupabaseClient,
  resortId: string,
  manifestVersion: number,
): Promise<{ data: CanonicalRendezvousRow[]; error: string | null }> {
  const { data, error } = await supabase
    .from("canonical_rendezvous_point")
    .select("anchor_osm_node_id, kind, display_name, confidence, quality")
    .eq("resort_id", resortId)
    .eq("manifest_version", manifestVersion);
  if (error) {
    return {
      data: [],
      error: `canonical rendezvous lookup failed: ${error.message}`,
    };
  }
  return { data: data ?? [], error: null };
}

async function loadGeometryOverrides(
  supabase: SupabaseClient,
  resortId: string,
): Promise<{ data: CanonicalGeometryOverride[]; error: string | null }> {
  const { data, error } = await supabase.rpc("latest_geometry_overrides", {
    p_resort_id: resortId,
  });
  if (error) {
    return {
      data: [],
      error: `canonical geometry override lookup failed: ${error.message}`,
    };
  }
  return { data: data ?? [], error: null };
}

async function sha256Hex(buf: Uint8Array): Promise<string> {
  const hash = await crypto.subtle.digest(
    "SHA-256",
    buf as unknown as BufferSource,
  );
  return [...new Uint8Array(hash)].map((b) => b.toString(16).padStart(2, "0"))
    .join("");
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
