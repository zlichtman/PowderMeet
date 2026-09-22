/** Fetch one documented (at most 100 coordinate) elevation batch. Never store
 * missing values as zero, and retry transient upstream failures within a deadline. */
export async function fetchElevationBatch(
  keys: string[],
  fetcher: typeof fetch = fetch,
  pause: (ms: number) => Promise<void> = ms => new Promise(resolve => setTimeout(resolve, ms)),
  deadline = Date.now() + 90_000,
): Promise<number[]> {
  if (keys.length === 0) return [];
  if (keys.length > 100) throw new Error("Elevation batch exceeds 100 coordinates");
  const latitude = keys.map(k => k.split(",")[0]).join(",");
  const longitude = keys.map(k => k.split(",")[1]).join(",");
  const url = `https://api.open-meteo.com/v1/elevation?latitude=${latitude}&longitude=${longitude}`;
  for (let attempt = 0; attempt < 3; attempt++) {
    const remaining = deadline - Date.now();
    if (remaining <= 0) throw new Error("Elevation request deadline exceeded");
    let response: Response;
    try {
      response = await fetcher(url, { signal: AbortSignal.timeout(Math.min(12_000, remaining)) });
    } catch (error) {
      if (attempt === 2) throw error;
      await pause(Math.min(1_000 * 2 ** attempt, Math.max(0, deadline - Date.now())));
      continue;
    }
    if (!response.ok) {
      const retryable = response.status === 429 || response.status >= 500;
      const retryAfter = Number(response.headers.get("Retry-After"));
      await response.body?.cancel();
      if (!retryable || attempt === 2) throw new Error(`Elevation HTTP ${response.status}`);
      const delay = Number.isFinite(retryAfter) && retryAfter > 0
        ? Math.min(20_000, retryAfter * 1_000) : 1_000 * 2 ** attempt;
      await pause(Math.min(delay, Math.max(0, deadline - Date.now())));
      continue;
    }
    const body = await response.json();
    if (!Array.isArray(body.elevation) || body.elevation.length !== keys.length ||
        !body.elevation.every((value: unknown) => typeof value === "number" && Number.isFinite(value))) {
      throw new Error("Elevation response contains missing or invalid samples");
    }
    return body.elevation;
  }
  throw new Error("Elevation retries exhausted");
}
