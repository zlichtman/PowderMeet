// Reads what the status worker needs from a published resort bundle: the
// provider name aliases and the lift and trail group ids. The bundle is where
// these come from (specs/02-DOMAIN.md section 2); `resort_bundles.status_meta`
// keeps the worker's reading of it (specs/04-SCHEMA.md section 7).

import type { BundleStatusMeta } from "./status.ts";
import { type Db, errorMessage } from "../worker.ts";

const MAX_BUNDLE_BYTES = 64 * 1024 * 1024;
const cache = new Map<string, BundleStatusMeta>();

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

export function parseBundleStatusMeta(bundle: unknown): BundleStatusMeta {
  if (!isRecord(bundle) || !Array.isArray(bundle.groups)) {
    throw new Error("bundle has no groups array");
  }
  const liftGroups: string[] = [];
  const trailGroups: string[] = [];
  for (const group of bundle.groups) {
    if (!isRecord(group) || typeof group.id !== "string") {
      throw new Error("bundle has a malformed group");
    }
    if (group.kind === "lift") liftGroups.push(group.id);
    else if (group.kind === "trail") trailGroups.push(group.id);
  }
  const aliases: Record<string, Record<string, string>> = {};
  if (isRecord(bundle.status_aliases)) {
    for (const [provider, names] of Object.entries(bundle.status_aliases)) {
      if (!isRecord(names)) continue;
      aliases[provider] = {};
      for (const [name, groupId] of Object.entries(names)) {
        if (typeof groupId === "string") aliases[provider][name] = groupId;
      }
    }
  }
  return { aliases, liftGroups, trailGroups };
}

async function sha256Hex(bytes: Uint8Array): Promise<string> {
  const digest = new Uint8Array(await crypto.subtle.digest("SHA-256", bytes as BufferSource));
  return [...digest].map((b) => b.toString(16).padStart(2, "0")).join("");
}

export async function gunzip(bytes: Uint8Array): Promise<Uint8Array> {
  const stream = new Blob([bytes as BlobPart]).stream().pipeThrough(new DecompressionStream("gzip"));
  return new Uint8Array(await new Response(stream).arrayBuffer());
}

function isStringArray(value: unknown): value is string[] {
  return Array.isArray(value) && value.every((v) => typeof v === "string");
}

/**
 * The stored form of a bundle's status meta (`resort_bundles.status_meta`),
 * or null when nothing usable is stored, so the bundle is read again.
 */
export function parseStoredStatusMeta(stored: unknown): BundleStatusMeta | null {
  if (!isRecord(stored) || !isRecord(stored.aliases)) return null;
  if (!isStringArray(stored.lift_groups) || !isStringArray(stored.trail_groups)) return null;
  const aliases: Record<string, Record<string, string>> = {};
  for (const [provider, names] of Object.entries(stored.aliases)) {
    if (!isRecord(names)) return null;
    aliases[provider] = {};
    for (const [name, groupId] of Object.entries(names)) {
      if (typeof groupId !== "string") return null;
      aliases[provider][name] = groupId;
    }
  }
  return { aliases, liftGroups: stored.lift_groups, trailGroups: stored.trail_groups };
}

/**
 * Downloads `resort-bundles/<resort_id>/<bundle_id>.json.gz` from public
 * storage. The bundle's identity is the SHA-256 of its bytes (I-17): bytes
 * that do not hash to `bundleId` are refused before they are decoded.
 */
async function readBundle(
  baseUrl: string,
  resortId: string,
  bundleId: string,
  fetcher: typeof fetch,
): Promise<BundleStatusMeta> {
  const url = `${baseUrl}/storage/v1/object/public/resort-bundles/${encodeURIComponent(resortId)}/${bundleId}.json.gz`;
  const response = await fetcher(url, { signal: AbortSignal.timeout(20_000) });
  if (!response.ok) throw new Error(`bundle download returned HTTP ${response.status}`);
  const bytes = new Uint8Array(await response.arrayBuffer());
  if (bytes.length > MAX_BUNDLE_BYTES) throw new Error("bundle is larger than 64 MB");
  if (await sha256Hex(bytes) !== bundleId) throw new Error("bundle bytes do not match bundle_id");

  const decoded = await gunzip(bytes);
  if (decoded.length > MAX_BUNDLE_BYTES) throw new Error("bundle decompresses to more than 64 MB");
  return parseBundleStatusMeta(JSON.parse(new TextDecoder().decode(decoded)));
}

/**
 * The status meta of a published bundle. A bundle id names fixed bytes, so
 * what is derived from them once holds for good: it is kept on the bundle's
 * `resort_bundles` row and read from there by every later job, which keeps a
 * whole bundle (up to 64 MB, decoded) out of the worker's memory on nearly
 * every run. Only the first job for a bundle downloads it.
 */
export async function loadBundleStatusMeta(
  db: Db,
  resortId: string,
  bundleId: string,
  fetcher: typeof fetch,
): Promise<BundleStatusMeta> {
  const cached = cache.get(bundleId);
  if (cached) return cached;

  const id = encodeURIComponent(bundleId);
  const [row] = await db.select<{ status_meta: unknown }>(`resort_bundles?bundle_id=eq.${id}&select=status_meta`);
  let meta = parseStoredStatusMeta(row?.status_meta);
  if (!meta) {
    meta = await readBundle(db.baseUrl, resortId, bundleId, fetcher);
    try {
      await db.update(`resort_bundles?bundle_id=eq.${id}`, {
        status_meta: { aliases: meta.aliases, lift_groups: meta.liftGroups, trail_groups: meta.trailGroups },
      });
    } catch (error) {
      // The status row can still be written from what was just read; the next
      // job downloads the bundle again and retries the store.
      console.error(`status meta for bundle ${bundleId} not stored: ${errorMessage(error)}`);
    }
  }

  if (cache.size >= 8) cache.clear();
  cache.set(bundleId, meta);
  return meta;
}
