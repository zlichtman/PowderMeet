// get-resort-3d-pack — Edge Function (photoreal 3D resort pack fetcher)
//
// Read-side companion to the offline bake (tools/bake_resort3d). The
// client calls this only when it has no bundled/cached pack; we return
// a signed URL to the latest .usdz for (resort_id, pack_version) plus
// its sha256 so the client can verify + disk-cache it for offline use.
// Structural sibling of get-resort-graph (resort-graphs bucket).

import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.39.0";

const BUCKET = "resort-3d-packs";
const SIGNED_URL_TTL_SECONDS = 60 * 60;

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
} as const;

function json(status: number, body: unknown): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS, "Content-Type": "application/json" },
  });
}

Deno.serve(async (req: Request): Promise<Response> => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return json(405, { error: "POST only" });

  let body: { resort_id?: string; pack_version?: string };
  try {
    body = await req.json();
  } catch {
    return json(400, { error: "bad json" });
  }
  const resortId = body.resort_id;
  const packVersion = body.pack_version;
  if (!resortId || !packVersion) {
    return json(400, { error: "resort_id and pack_version required" });
  }

  const supabase = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  );

  const { data, error } = await supabase
    .from("resort_3d_pack")
    .select("storage_path, sha256, manifest_version, snapshot_date")
    .eq("resort_id", resortId)
    .eq("pack_version", packVersion)
    .order("built_at", { ascending: false })
    .limit(1)
    .maybeSingle();

  if (error) return json(500, { error: error.message });
  if (!data) return json(200, { status: "not_built" });

  const signed = await supabase.storage
    .from(BUCKET)
    .createSignedUrl(data.storage_path, SIGNED_URL_TTL_SECONDS);
  if (signed.error || !signed.data) {
    return json(500, { error: signed.error?.message ?? "sign failed" });
  }

  return json(200, {
    status: "fetch",
    pack_url: signed.data.signedUrl,
    sha256: data.sha256,
    manifest_version: data.manifest_version,
    snapshot_date: data.snapshot_date,
  });
});
