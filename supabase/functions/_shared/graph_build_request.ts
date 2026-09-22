export interface GraphBuildRequest {
  resort_id: string;
  manifest_version?: number;
  snapshot_date?: string;
  graph_version: string;
}

export type GraphBuildRequestResult =
  | { ok: true; value: GraphBuildRequest }
  | { ok: false; error: string };

const RESORT_ID = /^[a-z0-9][a-z0-9_-]{0,99}$/i;
const SNAPSHOT_DATE = /^\d{4}-\d{2}-\d{2}$/;

/** Runtime validation for the operator-facing graph builder. */
export function parseGraphBuildRequest(
  input: unknown,
  graphVersion: string,
): GraphBuildRequestResult {
  if (input == null || typeof input !== "object" || Array.isArray(input)) {
    return { ok: false, error: "request body must be an object" };
  }
  const body = input as Record<string, unknown>;
  if (typeof body.resort_id !== "string" || !RESORT_ID.test(body.resort_id)) {
    return { ok: false, error: "invalid or missing resort_id" };
  }
  if (
    body.manifest_version != null &&
    (!Number.isInteger(body.manifest_version) ||
      (body.manifest_version as number) <= 0)
  ) {
    return { ok: false, error: "manifest_version must be a positive integer" };
  }
  if (
    body.snapshot_date != null &&
    (typeof body.snapshot_date !== "string" ||
      !isCalendarDate(body.snapshot_date))
  ) {
    return { ok: false, error: "snapshot_date must be YYYY-MM-DD" };
  }
  if (body.graph_version != null && body.graph_version !== graphVersion) {
    return {
      ok: false,
      error:
        `graph_version must be ${graphVersion}; the builder cannot emit old algorithm versions`,
    };
  }
  return {
    ok: true,
    value: {
      resort_id: body.resort_id,
      manifest_version: body.manifest_version as number | undefined,
      snapshot_date: body.snapshot_date as string | undefined,
      graph_version: graphVersion,
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
