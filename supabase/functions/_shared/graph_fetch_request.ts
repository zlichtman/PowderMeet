export interface GraphFetchRequest {
  resort_id: string;
  cached_manifest_version?: number;
  cached_content_sha256?: string;
  manifest_version?: number;
  graph_version: string;
  content_sha256?: string;
}

export type GraphFetchRequestResult =
  | { ok: true; value: GraphFetchRequest }
  | { ok: false; error: string };

const RESORT_ID = /^[a-z0-9][a-z0-9_-]{0,99}$/i;
const GRAPH_VERSION = /^v[0-9]+(?:-s[0-9]+)?$/;
const SHA256 = /^[0-9a-f]{64}$/;

/** Runtime validation for untrusted JSON before it reaches database filters. */
export function parseGraphFetchRequest(
  input: unknown,
  defaultGraphVersion: string,
): GraphFetchRequestResult {
  if (
    input == null ||
    typeof input !== "object" ||
    Array.isArray(input)
  ) {
    return { ok: false, error: "request body must be an object" };
  }
  const body = input as Record<string, unknown>;
  if (typeof body.resort_id !== "string" || !RESORT_ID.test(body.resort_id)) {
    return { ok: false, error: "invalid or missing resort_id" };
  }
  const cachedManifest = optionalPositiveInteger(body.cached_manifest_version);
  if (!cachedManifest.ok) {
    return { ok: false, error: "invalid cached_manifest_version" };
  }
  const manifest = optionalPositiveInteger(body.manifest_version);
  if (!manifest.ok) {
    return { ok: false, error: "invalid manifest_version" };
  }
  const cachedSHA = optionalSHA(body.cached_content_sha256);
  if (!cachedSHA.ok) {
    return { ok: false, error: "invalid cached_content_sha256" };
  }
  const contentSHA = optionalSHA(body.content_sha256);
  if (!contentSHA.ok) {
    return { ok: false, error: "invalid content_sha256" };
  }
  const graphVersion = body.graph_version ?? defaultGraphVersion;
  if (typeof graphVersion !== "string" || !GRAPH_VERSION.test(graphVersion)) {
    return { ok: false, error: "invalid graph_version" };
  }
  if (
    manifest.value == null &&
    (body.graph_version != null || contentSHA.value != null)
  ) {
    return {
      ok: false,
      error: "exact graph identity requires manifest_version",
    };
  }

  return {
    ok: true,
    value: {
      resort_id: body.resort_id,
      cached_manifest_version: cachedManifest.value,
      cached_content_sha256: cachedSHA.value,
      manifest_version: manifest.value,
      graph_version: graphVersion,
      content_sha256: contentSHA.value,
    },
  };
}

function optionalPositiveInteger(
  value: unknown,
): { ok: true; value?: number } | { ok: false } {
  if (value == null) return { ok: true };
  return Number.isInteger(value) && (value as number) > 0
    ? { ok: true, value: value as number }
    : { ok: false };
}

function optionalSHA(
  value: unknown,
): { ok: true; value?: string } | { ok: false } {
  if (value == null) return { ok: true };
  return typeof value === "string" && SHA256.test(value)
    ? { ok: true, value }
    : { ok: false };
}
