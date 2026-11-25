// Open-Meteo conditions. One request per resort per hour, made only by the
// conditions worker; phones never call Open-Meteo. Output shape:
// specs/02-DOMAIN.md section 4.

const FIELDS = [
  "temperature_2m",
  "wind_speed_10m",
  "wind_gusts_10m",
  "visibility",
  "cloud_cover",
  "precipitation",
  "snowfall",
  "weather_code",
] as const;

// Hourly only, and optional: a model run without one of these still gives a
// usable row. Temperatures aloft are the anchors for the weather at a run's own
// height (06-SOLVER section 2).
const HOURLY_EXTRAS = [
  "wind_direction_10m",
  "dew_point_2m",
  "cloud_cover_low",
  "temperature_850hPa",
  "temperature_700hPa",
  "snow_depth",
] as const;

// Past days asked for: three, for the 72-hour snow total.
const PAST_DAYS = 3;

export const CONDITIONS_TTL_MS = 90 * 60_000;

export interface ConditionsSample {
  at: string;
  temp_c: number | null;
  wind_ms: number | null;
  gust_ms: number | null;
  visibility_m: number | null;
  cloud_pct: number | null;
  snow_24h_cm: number | null;
  precip_mmh: number | null;
  weather_code: number | null;
  wind_dir_deg?: number;
  dew_point_c?: number;
  cloud_low_pct?: number;
  temp_850_c?: number;
  temp_700_c?: number;
  snow_depth_cm?: number;
  snow_72h_cm?: number;
}

/** One past hour, for whether the snow thawed and refroze. */
export interface RecentSample {
  at: string;
  temp_c: number;
  cloud_pct: number | null;
}

export interface ConditionsRow {
  observed_at: string;
  expires_at: string;
  source: "open-meteo";
  /** Metres above sea level the forecast is for, when Open-Meteo says. */
  elevation_m: number | null;
  current: ConditionsSample;
  hourly: ConditionsSample[];
  /** The 24 hours before now, oldest first. */
  recent: RecentSample[];
}

export function openMeteoURL(lon: number, lat: number): string {
  const params = new URLSearchParams({
    latitude: lat.toFixed(4),
    longitude: lon.toFixed(4),
    current: FIELDS.join(","),
    hourly: [...FIELDS, ...HOURLY_EXTRAS].join(","),
    wind_speed_unit: "ms",
    timeformat: "unixtime",
    timezone: "UTC",
    past_days: String(PAST_DAYS),
    forecast_days: "2",
  });
  return `https://api.open-meteo.com/v1/forecast?${params}`;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function num(value: unknown): number | null {
  return typeof value === "number" && Number.isFinite(value) ? value : null;
}

function round1(value: number): number {
  return Math.round(value * 10) / 10;
}

/** Fails closed: a response missing a series is an error, not an empty row. */
export function parseOpenMeteo(body: unknown, now: Date): ConditionsRow {
  if (!isRecord(body) || !isRecord(body.hourly) || !isRecord(body.current)) {
    throw new Error("Open-Meteo response has no hourly or current block");
  }
  const hourly = body.hourly;
  const times = hourly.time;
  if (!Array.isArray(times) || times.length === 0 || !times.every((t) => typeof t === "number")) {
    throw new Error("Open-Meteo response has no hourly time series");
  }
  const series: Record<string, unknown[]> = {};
  for (const field of FIELDS) {
    const values = hourly[field];
    if (!Array.isArray(values) || values.length !== times.length) {
      throw new Error(`Open-Meteo response is missing hourly ${field}`);
    }
    series[field] = values;
  }

  const extras: Partial<Record<(typeof HOURLY_EXTRAS)[number], unknown[]>> = {};
  for (const field of HOURLY_EXTRAS) {
    const values = hourly[field];
    if (Array.isArray(values) && values.length === times.length) extras[field] = values;
  }
  const extra = (field: (typeof HOURLY_EXTRAS)[number], i: number): number | undefined =>
    num(extras[field]?.[i]) ?? undefined;

  // Snow that fell in the `hours` up to and including hour i.
  const snowOver = (hours: number, i: number): number | null => {
    let sum = 0;
    let seen = false;
    for (let j = Math.max(0, i - (hours - 1)); j <= i; j += 1) {
      const value = num(series.snowfall[j]);
      if (value != null) {
        sum += value;
        seen = true;
      }
    }
    return seen ? round1(sum) : null;
  };
  const snow24 = (i: number): number | null => snowOver(24, i);
  // Open-Meteo gives depth in metres.
  const depthCM = (i: number): number | undefined => {
    const metres = extra("snow_depth", i);
    return metres == null ? undefined : Math.round(metres * 100);
  };
  const sample = (i: number): ConditionsSample => ({
    at: new Date((times[i] as number) * 1000).toISOString(),
    temp_c: num(series.temperature_2m[i]),
    wind_ms: num(series.wind_speed_10m[i]),
    gust_ms: num(series.wind_gusts_10m[i]),
    visibility_m: num(series.visibility[i]),
    cloud_pct: num(series.cloud_cover[i]),
    snow_24h_cm: snow24(i),
    precip_mmh: num(series.precipitation[i]),
    weather_code: num(series.weather_code[i]),
    wind_dir_deg: extra("wind_direction_10m", i),
    dew_point_c: extra("dew_point_2m", i),
    cloud_low_pct: extra("cloud_cover_low", i),
    temp_850_c: extra("temperature_850hPa", i),
    temp_700_c: extra("temperature_700hPa", i),
    snow_depth_cm: depthCM(i),
    // Only with all 72 hours behind it; a shorter sum would read as less snow.
    snow_72h_cm: i >= 71 ? snowOver(72, i) ?? undefined : undefined,
  });

  const nowSeconds = now.getTime() / 1000;
  // The hour that contains `now`.
  let currentIndex = -1;
  for (let i = 0; i < times.length; i += 1) {
    if ((times[i] as number) <= nowSeconds) currentIndex = i;
  }
  if (currentIndex < 0) throw new Error("Open-Meteo hourly series starts in the future");

  const c = body.current;
  const base = sample(currentIndex);
  const current: ConditionsSample = {
    ...base,
    at: now.toISOString(),
    temp_c: num(c.temperature_2m) ?? base.temp_c,
    wind_ms: num(c.wind_speed_10m) ?? base.wind_ms,
    gust_ms: num(c.wind_gusts_10m) ?? base.gust_ms,
    visibility_m: num(c.visibility) ?? base.visibility_m,
    cloud_pct: num(c.cloud_cover) ?? base.cloud_pct,
    snow_24h_cm: base.snow_24h_cm,
    precip_mmh: base.precip_mmh,
    weather_code: num(c.weather_code) ?? base.weather_code,
  };

  const next: ConditionsSample[] = [];
  for (let i = currentIndex + 1; i < times.length && next.length < 24; i += 1) next.push(sample(i));
  if (next.length === 0) throw new Error("Open-Meteo response has no forecast hours");

  const recent: RecentSample[] = [];
  for (let i = Math.max(0, currentIndex - 24); i < currentIndex; i += 1) {
    const temp = num(series.temperature_2m[i]);
    if (temp == null) continue;
    recent.push({
      at: new Date((times[i] as number) * 1000).toISOString(),
      temp_c: temp,
      cloud_pct: num(series.cloud_cover[i]),
    });
  }

  return {
    observed_at: now.toISOString(),
    expires_at: new Date(now.getTime() + CONDITIONS_TTL_MS).toISOString(),
    source: "open-meteo",
    elevation_m: num(body.elevation),
    current,
    hourly: next,
    recent,
  };
}

export async function fetchOpenMeteo(
  lon: number,
  lat: number,
  fetcher: typeof fetch,
  now: Date,
): Promise<ConditionsRow> {
  const response = await fetcher(openMeteoURL(lon, lat), {
    headers: { Accept: "application/json", "User-Agent": "PowderMeet-Conditions/2.0" },
    signal: AbortSignal.timeout(15_000),
  });
  if (!response.ok) throw new Error(`Open-Meteo returned HTTP ${response.status}`);
  return parseOpenMeteo(await response.json(), now);
}
