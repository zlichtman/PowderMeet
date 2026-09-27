// Runtime validation for rows that authorize client-visible graph blobs.

export interface PublishedGraphIdentity {
  manifestVersion: number;
  graphVersion: string;
  snapshotDate: string;
  contentSHA256: string;
}

export type PublishedGraphIdentityResult =
  | { ok: true; value: PublishedGraphIdentity }
  | { ok: false; error: string };

const GRAPH_VERSION = /^v[0-9]+(?:-s[0-9]+)?$/;
const SNAPSHOT_DATE = /^\d{4}-\d{2}-\d{2}$/;
const SHA256 = /^[0-9a-f]{64}$/;

export function parsePublishedGraphIdentity(
  row: unknown,
  fields: {
    manifestVersion: string;
    graphVersion: string;
    snapshotDate: string;
    contentSHA256: string;
  },
): PublishedGraphIdentityResult {
  if (row == null || typeof row !== "object" || Array.isArray(row)) {
    return { ok: false, error: "published graph row must be an object" };
  }
  const value = row as Record<string, unknown>;
  const manifestVersion = value[fields.manifestVersion];
  const graphVersion = value[fields.graphVersion];
  const snapshotDate = value[fields.snapshotDate];
  const contentSHA256 = value[fields.contentSHA256];
  if (!Number.isInteger(manifestVersion) || (manifestVersion as number) <= 0) {
    return { ok: false, error: "invalid published manifest version" };
  }
  if (typeof graphVersion !== "string" || !GRAPH_VERSION.test(graphVersion)) {
    return { ok: false, error: "invalid published graph version" };
  }
  if (typeof snapshotDate !== "string" || !isCalendarDate(snapshotDate)) {
    return { ok: false, error: "invalid published snapshot date" };
  }
  if (typeof contentSHA256 !== "string" || !SHA256.test(contentSHA256)) {
    return { ok: false, error: "invalid published content SHA-256" };
  }
  return {
    ok: true,
    value: {
      manifestVersion: manifestVersion as number,
      graphVersion,
      snapshotDate,
      contentSHA256,
    },
  };
}

function isCalendarDate(value: string): boolean {
  if (!SNAPSHOT_DATE.test(value)) return false;
  const [year, month, day] = value.split("-").map(Number);
  const parsed = new Date(Date.UTC(year, month - 1, day));
  return parsed.getUTCFullYear() === year &&
    parsed.getUTCMonth() === month - 1 &&
    parsed.getUTCDate() === day;
}
