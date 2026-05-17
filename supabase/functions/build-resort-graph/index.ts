// build-resort-graph — Edge Function (canonical graph blob builder)
//
// Produces the immutable, server-authoritative graph blob that
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
import { createClient, SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2.39.0";
import { deflateSync } from "https://esm.sh/fflate@0.8.2";
import { buildGraph, type ResortData, type ResortDataTrail, type ResortDataLift } from "./graph_builder.ts";
import { applyCuratedOverlay } from "./curated_overlay.ts";
import { encodeGraph } from "./graph_types.ts";

const GRAPH_VERSION = "v8";
const SOURCE_BUCKET = "resort-snapshots";
const TARGET_BUCKET = "resort-graphs";
const SIGNED_URL_TTL_SECONDS = 60 * 60;

const CORS_HEADERS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
} as const;

interface BuildRequest {
  resort_id: string;
  manifest_version?: number;
  snapshot_date?: string;
  graph_version?: string;
}

Deno.serve(async (req: Request): Promise<Response> => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: CORS_HEADERS });
  }
  if (req.method !== "POST") {
    return jsonError(405, "POST only");
  }
  let body: BuildRequest;
  try {
    body = await req.json();
  } catch {
    return jsonError(400, "invalid JSON body");
  }
  if (!body.resort_id || typeof body.resort_id !== "string") {
    return jsonError(400, "missing required field: resort_id");
  }
  if (body.snapshot_date && !/^\d{4}-\d{2}-\d{2}$/.test(body.snapshot_date)) {
    return jsonError(400, "snapshot_date must be YYYY-MM-DD");
  }

  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!supabaseUrl || !serviceKey) {
    return jsonError(500, "Edge Function env missing SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY");
  }
  const supabase = createClient(supabaseUrl, serviceKey);
  const graphVersion = body.graph_version ?? GRAPH_VERSION;

  // 1. Resolve manifest version
  const manifest = await resolveManifest(supabase, body.resort_id, body.manifest_version);
  if (!manifest) {
    return jsonError(404, `no canonical manifest for resort_id=${body.resort_id}`);
  }

  // 2. Resolve snapshot date
  const snapshotDate = body.snapshot_date ?? await resolveSnapshotDate(supabase, body.resort_id);
  if (!snapshotDate) {
    return jsonError(404, `no resort_snapshot_pin for resort_id=${body.resort_id}`);
  }

  // 3. Idempotency: existing blob?
  const existing = await findExistingBlob(supabase, body.resort_id, manifest.manifest_version, snapshotDate, graphVersion);
  if (existing) {
    const signed = await supabase.storage.from(TARGET_BUCKET)
      .createSignedUrl(existing.blob_storage_path, SIGNED_URL_TTL_SECONDS);
    if (signed.error || !signed.data) {
      return jsonError(500, `createSignedUrl failed for existing blob: ${signed.error?.message}`);
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
  const osmBlob = await downloadStorageJson(supabase, SOURCE_BUCKET, `${body.resort_id}/osm-${snapshotDate}.json`);
  const elevBlob = await downloadStorageJson<Record<string, number>>(supabase, SOURCE_BUCKET, `${body.resort_id}/elev-${snapshotDate}.json`);
  if (!osmBlob || !elevBlob) {
    return jsonOk({
      status: "snapshot_pending",
      snapshot_date: snapshotDate,
    });
  }

  // 5. Convert OSM payload to ResortData
  const resortData = osmToResortData(osmBlob, elevBlob);

  // 6. Build graph
  let graph = buildGraph(resortData, body.resort_id);

  // 7. Apply canonical overlay
  const trails = await loadCanonicalTrails(supabase, body.resort_id, manifest.manifest_version);
  const lifts = await loadCanonicalLifts(supabase, body.resort_id, manifest.manifest_version);
  const overrides = await loadGeometryOverrides(supabase, body.resort_id);
  const trailWhitelist = trails.map((t) => t.name);
  const liftWhitelist = lifts.map((l) => l.name);

  graph = applyCuratedOverlay(graph, {
    trails: trails as any,
    lifts: lifts as any,
    trailWhitelist,
    liftWhitelist,
  });

  // 8. Apply geometry overrides — substitute geometry where the manifest
  //    has hand-traced canonical lines that should win over OSM.
  if (overrides.length > 0) {
    const overrideByKey = new Map<string, string>();
    for (const o of overrides) overrideByKey.set(`${o.target_kind}|${o.target_name.toLowerCase()}`, o.geometry);
    for (let i = 0; i < graph.edges.length; i++) {
      const e = graph.edges[i];
      const name = e.attributes.trailName;
      if (!name) continue;
      const kindKey = e.kind === "lift" ? "lift" : "trail";
      const geomText = overrideByKey.get(`${kindKey}|${name.toLowerCase()}`);
      if (!geomText) continue;
      try {
        const parsed = JSON.parse(geomText);
        if (parsed?.type === "LineString" && Array.isArray(parsed.coordinates)) {
          graph.edges[i] = {
            ...e,
            geometry: parsed.coordinates.map((c: number[]) => [c[0], c[1]] as [number, number]),
          };
        }
      } catch {
        // ignore malformed override
      }
    }
  }

  // 9. Encode + compress + upload
  const wire = encodeGraph(graph);
  const json = JSON.stringify(wire);
  const encoded = new TextEncoder().encode(json);
  const compressed = deflateSync(encoded);
  const sha256 = await sha256Hex(compressed);
  const path = `${body.resort_id}/${manifest.manifest_version}-${snapshotDate}-${graphVersion}.json.gz`;

  const { error: upErr } = await supabase.storage.from(TARGET_BUCKET).upload(
    path, compressed, { contentType: "application/gzip", upsert: true },
  );
  if (upErr) return jsonError(500, `blob upload failed: ${upErr.message}`);

  await supabase.from("resort_graph_blob").upsert({
    resort_id: body.resort_id,
    manifest_version: manifest.manifest_version,
    snapshot_date: snapshotDate,
    graph_version: graphVersion,
    blob_storage_path: path,
    sha256,
  });

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
    cached: false,
  });
});

// ── Helpers ─────────────────────────────────────────────────────────

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

function osmToResortData(osm: any, elevations: Record<string, number>): ResortData {
  const data = osm as OverpassResponse;
  const nodeMap = new Map<number, { lat: number; lon: number; ele?: number | null }>();
  let south = 90, west = 180, north = -90, east = -180;
  for (const el of data.elements) {
    if (el.type === "node" && el.lat != null && el.lon != null) {
      const key = `${el.lat.toFixed(6)},${el.lon.toFixed(6)}`;
      const ele = elevations[key];
      nodeMap.set(el.id, { lat: el.lat, lon: el.lon, ele: ele ?? null });
      if (el.lat < south) south = el.lat;
      if (el.lat > north) north = el.lat;
      if (el.lon < west)  west  = el.lon;
      if (el.lon > east)  east  = el.lon;
    }
  }

  const trails: ResortDataTrail[] = [];
  const lifts: ResortDataLift[] = [];

  for (const el of data.elements) {
    if (el.type !== "way" || !el.nodes || !el.tags) continue;
    const tags = el.tags;
    const coords: Array<{ lat: number; lon: number; ele?: number | null }> = [];
    for (const ref of el.nodes) {
      const c = nodeMap.get(ref);
      if (c) coords.push(c);
    }
    if (coords.length < 2) continue;

    if (tags["aerialway"]) {
      lifts.push({
        id: String(el.id),
        name: tags["name"] ?? null,
        type: mapAerialwayType(tags["aerialway"]),
        capacity: tags["aerialway:capacity"] ? parseInt(tags["aerialway:capacity"], 10) : null,
        coordinates: coords,
        isOpen: true,
      });
    } else if (tags["piste:type"] === "downhill") {
      trails.push({
        id: String(el.id),
        name: tags["name"] ?? tags["piste:name"] ?? null,
        displayName: tags["piste:name"] ?? tags["name"] ?? null,
        difficulty: mapPisteDifficulty(tags["piste:difficulty"]),
        coordinates: coords,
        lengthMeters: polyLen(coords),
        grooming: tags["piste:grooming"] ?? null,
        isOpen: true,
      });
    }
  }

  // Diagonal in meters
  const dlat = (north - south) * Math.PI / 180;
  const dlon = (east - west) * Math.PI / 180;
  const meanLat = (north + south) / 2 * Math.PI / 180;
  const dx = 6371000 * dlon * Math.cos(meanLat);
  const dy = 6371000 * dlat;
  const diagonalMeters = Math.sqrt(dx * dx + dy * dy);

  return { trails, lifts, bounds: { diagonalMeters } };
}

function polyLen(coords: Array<{ lat: number; lon: number }>): number {
  let total = 0;
  for (let i = 1; i < coords.length; i++) {
    const a = coords[i - 1], b = coords[i];
    const dLat = (b.lat - a.lat) * Math.PI / 180;
    const dLon = (b.lon - a.lon) * Math.PI / 180;
    const lat1 = a.lat * Math.PI / 180;
    const lat2 = b.lat * Math.PI / 180;
    const h = Math.sin(dLat / 2) ** 2 + Math.cos(lat1) * Math.cos(lat2) * Math.sin(dLon / 2) ** 2;
    total += 2 * 6371000 * Math.asin(Math.sqrt(h));
  }
  return total;
}

function mapAerialwayType(raw: string): any {
  switch (raw) {
    case "gondola": return "gondola";
    case "chair_lift":
    case "chairlift": return "chairlift";
    case "funicular": return "funicular";
    case "t-bar": return "tBar";
    case "platter": return "platter";
    case "magic_carpet": return "magicCarpet";
    case "rope_tow": return "rope";
    case "cable_car": return "cableCar";
    default: return "chairlift";
  }
}

function mapPisteDifficulty(raw: string | undefined): any {
  if (!raw) return null;
  const s = raw.toLowerCase();
  if (s === "novice" || s === "easy") return "green";
  if (s === "intermediate") return "blue";
  if (s === "advanced") return "black";
  if (s === "expert" || s === "freeride" || s === "extreme") return "doubleBlack";
  return null;
}

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
      .select("resort_id, manifest_version, expected_trail_count, expected_lift_count")
      .eq("resort_id", resortId)
      .eq("manifest_version", requestedVersion)
      .maybeSingle();
    return data;
  }
  const { data } = await supabase
    .from("current_resort_canonical_manifest")
    .select("resort_id, manifest_version, expected_trail_count, expected_lift_count")
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
): Promise<{ blob_storage_path: string; sha256: string } | null> {
  const { data } = await supabase
    .from("resort_graph_blob")
    .select("blob_storage_path, sha256")
    .eq("resort_id", resortId)
    .eq("manifest_version", manifestVersion)
    .eq("snapshot_date", snapshotDate)
    .eq("graph_version", graphVersion)
    .maybeSingle();
  return data;
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
): Promise<any[]> {
  const { data } = await supabase.rpc("canonical_trails_with_geom", {
    p_resort_id: resortId,
    p_manifest_version: manifestVersion,
  });
  return data ?? [];
}

async function loadCanonicalLifts(
  supabase: SupabaseClient,
  resortId: string,
  manifestVersion: number,
): Promise<any[]> {
  const { data } = await supabase.rpc("canonical_lifts_with_geom", {
    p_resort_id: resortId,
    p_manifest_version: manifestVersion,
  });
  return data ?? [];
}

async function loadGeometryOverrides(
  supabase: SupabaseClient,
  resortId: string,
): Promise<Array<{ target_kind: string; target_name: string; geometry: string }>> {
  const { data } = await supabase.rpc("latest_geometry_overrides", {
    p_resort_id: resortId,
  });
  return data ?? [];
}

async function sha256Hex(buf: Uint8Array): Promise<string> {
  const hash = await crypto.subtle.digest("SHA-256", buf as unknown as BufferSource);
  return [...new Uint8Array(hash)].map((b) => b.toString(16).padStart(2, "0")).join("");
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
