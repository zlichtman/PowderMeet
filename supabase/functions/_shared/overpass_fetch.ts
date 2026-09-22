/** Fetch a complete source response without turning upstream errors into empty maps.
 * Use providers whose published policies support app workloads. The main
 * public endpoint rejects these edge-runtime requests (HTTP 406).
 * Retry the same query using GET, then the independent public mirror.
 * The response retains osm3s timestamps for source review; this is not live status.
 */
export async function fetchOverpassSource(
  query: string,
  fetcher: typeof fetch = fetch,
): Promise<{ elements: unknown[]; [key: string]: unknown }> {
  const attempts = [
    { endpoint: "https://overpass.private.coffee/api/interpreter", method: "POST", timeout: 35_000 },
    { endpoint: "https://overpass.private.coffee/api/interpreter", method: "GET", timeout: 15_000 },
    { endpoint: "https://maps.mail.ru/osm/tools/overpass/api/interpreter", method: "POST", timeout: 75_000 },
  ];
  const failures: string[] = [];
  for (const { endpoint, method, timeout } of attempts) {
    try {
      const data = `data=${encodeURIComponent(query)}`;
      const response = await fetcher(method === "GET" ? `${endpoint}?${data}` : endpoint, {
        method,
        headers: {
          "Accept": "application/json",
          ...(method === "POST" ? { "Content-Type": "application/x-www-form-urlencoded" } : {}),
          "User-Agent": "PowderMeet-snapshot-resort/1.0 (https://github.com/zlichtman/PowderMeet)",
        },
        ...(method === "POST" ? { body: data } : {}),
        signal: AbortSignal.timeout(timeout),
      });
      if (!response.ok) {
        await response.body?.cancel();
        throw new Error(`HTTP ${response.status}`);
      }
      const result = await response.json();
      if (!result || !Array.isArray(result.elements) || result.remark) {
        throw new Error("Incomplete Overpass response");
      }
      return result;
    } catch (error) {
      failures.push(`${new URL(endpoint).host} ${method}: ${error instanceof Error ? error.message.slice(0, 120) : "error"}`);
    }
  }
  throw new Error(`No complete Overpass source: ${failures.join("; ")}`);
}

/** Include explicit piste connections; omitting these breaks valid lift/run links. */
export function resortSourceQuery(south: number, west: number, north: number, east: number): string {
  if (![south, west, north, east].every(Number.isFinite) ||
      !(south >= -90 && south < north && north <= 90 && west >= -180 && west < east && east <= 180)) {
    throw new Error("Invalid resort bounds");
  }
  const bbox = `${south},${west},${north},${east}`;
  return `[out:json][timeout:90];
(
  way["piste:type"="downhill"](${bbox});
  way["piste:type"="connection"](${bbox});
  way["aerialway"](${bbox});
  node["aerialway"="station"](${bbox});
);
out body;
>;
out qt;`;
}
