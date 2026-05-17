//
//  ConditionsService.swift
//  PowderMeet
//
//  Fetches live weather from Open-Meteo (free, no key required).
//  Two-stage fetch — `currentConditions` is the fast path (~200ms,
//  current block only). `hourlyConditions` is the slower follow-up
//  that backfills the timeline scrubber + 24/72h snowfall totals.
//  Caches the merged result per resort for 30 minutes.
//
//  API: https://api.open-meteo.com/v1/forecast
//  Elevation is auto-derived from Open-Meteo's 90m DEM — no need to supply it.
//

import Foundation

actor ConditionsService {
    static let shared = ConditionsService()
    private init() {}

    private var cache: [String: (conditions: ResortConditions, fetchedAt: Date)] = [:]
    private let cacheLifetime: TimeInterval = 30 * 60 // 30 min

    /// Age in seconds of the cached conditions for `entry`, or nil if nothing
    /// is cached. Callers use this to decide whether to re-fetch on
    /// scene-activation after the app sat in the background long enough for
    /// the weather to actually change.
    func cacheAgeSeconds(for entry: ResortEntry) -> TimeInterval? {
        guard let hit = cache[entry.id] else { return nil }
        return Date().timeIntervalSince(hit.fetchedAt)
    }

    /// Drop the cache for a resort so the next `currentConditions` call hits
    /// the network. Used by the scenePhase refresh path when the cache is
    /// older than `cacheLifetime`.
    func invalidateCache(for entry: ResortEntry) {
        cache.removeValue(forKey: entry.id)
    }

    /// Network timeout — Open-Meteo's median latency is ~150ms. Anything past
    /// 10s is a flaky link, not a slow server, so fail fast and let the UI
    /// keep its fallback values rather than hanging on URLSession's 60s default.
    private let networkTimeout: TimeInterval = 10

    // MARK: - Public API

    /// Fast path: returns just the `current` block (temp, wind, snowfall rate,
    /// visibility, cloud cover) for immediate UI render. Hourly arrays remain
    /// empty until `hourlyConditions(for:)` resolves and merges.
    func currentConditions(for entry: ResortEntry) async -> ResortConditions? {
        let now = Date()
        if let hit = cache[entry.id], now.timeIntervalSince(hit.fetchedAt) < cacheLifetime {
            return hit.conditions
        }
        guard var fresh = await fetchCurrent(entry: entry) else { return nil }
        // If mergeHourly already populated the cache for this resort (call
        // order isn't guaranteed), preserve its hourly arrays + snowfall
        // totals — overwriting them here would discard already-merged data.
        if let existing = cache[entry.id]?.conditions {
            fresh.hourlyForecast    = existing.hourlyForecast
            fresh.snowfallLast24hCm = existing.snowfallLast24hCm
            fresh.snowfallLast72hCm = existing.snowfallLast72hCm
        }
        cache[entry.id] = (fresh, now)
        return fresh
    }

    /// Slow path: hourly samples for the timeline scrubber (±12h) plus the
    /// 24h / 72h snowfall totals. `past_days=3` is the minimum that satisfies
    /// the 72h powder-quality calc; `forecast_days=1` covers the +12h scrubber
    /// window. Merges into the cached `currentConditions` result.
    @discardableResult
    func mergeHourly(for entry: ResortEntry) async -> ResortConditions? {
        guard let hourly = await fetchHourly(entry: entry) else {
            return cache[entry.id]?.conditions
        }
        // If current hasn't populated the cache yet (e.g. caller reordered
        // calls, or current failed while hourly succeeded), stash the
        // hourly data into a placeholder keyed on sensible defaults so the
        // timeline scrubber still has data to render. The next
        // `currentConditions` call will merge real live fields in.
        var merged = cache[entry.id]?.conditions ?? Self.placeholder(for: entry)
        merged.hourlyForecast = hourly.samples
        merged.snowfallLast24hCm = hourly.last24
        merged.snowfallLast72hCm = hourly.last72
        cache[entry.id] = (merged, Date())
        return merged
    }

    /// Empty-ish conditions so `TimelineView.conditions` can render hourly
    /// data even when the current-snapshot fetch hasn't landed yet. The
    /// live fields will be overwritten by the next `currentConditions`
    /// merge; until then they read as 0 / calm / clear.
    private static func placeholder(for entry: ResortEntry) -> ResortConditions {
        ResortConditions(
            resortId:          entry.id,
            temperatureC:      0,
            windSpeedKph:      0,
            windGustsKph:      0,
            snowfallLast24hCm: 0,
            snowfallLast72hCm: 0,
            snowDepthCm:       0,
            weatherCode:       0,
            visibilityKm:      10,
            cloudCoverPercent: 0,
            windDirectionDeg:  0,
            stationElevationM: 0,
            fetchedAt:         Date()
        )
    }

    // MARK: - Open-Meteo Fetch — Current Only

    private func fetchCurrent(entry: ResortEntry) async -> ResortConditions? {
        let lat = (entry.bounds.minLat + entry.bounds.maxLat) / 2
        let lon = (entry.bounds.minLon + entry.bounds.maxLon) / 2

        var comps = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        comps.queryItems = [
            URLQueryItem(name: "latitude",      value: String(format: "%.5f", lat)),
            URLQueryItem(name: "longitude",     value: String(format: "%.5f", lon)),
            URLQueryItem(name: "current",       value: [
                "temperature_2m", "snowfall", "wind_speed_10m",
                "wind_gusts_10m", "weather_code", "snow_depth",
                "visibility", "cloud_cover", "wind_direction_10m"
            ].joined(separator: ",")),
            URLQueryItem(name: "wind_speed_unit", value: "kmh"),
            URLQueryItem(name: "timezone",        value: "auto"),
        ]
        guard let url = comps.url else { return nil }

        do {
            let (data, _) = try await URLSession.shared.data(for: timedRequest(url))
            let raw = try JSONDecoder().decode(OpenMeteoResponse.self, from: data)

            return ResortConditions(
                resortId:          entry.id,
                temperatureC:      raw.current.temperature2m,
                windSpeedKph:      raw.current.windSpeed10m,
                windGustsKph:      raw.current.windGusts10m,
                snowfallLast24hCm: 0,                            // backfilled by mergeHourly
                snowfallLast72hCm: 0,                            // backfilled by mergeHourly
                snowDepthCm:       raw.current.snowDepth * 100,  // m → cm
                weatherCode:       raw.current.weatherCode,
                visibilityKm:      raw.current.visibility / 1000,
                cloudCoverPercent: raw.current.cloudCover,
                windDirectionDeg:  raw.current.windDirection,
                stationElevationM: raw.elevation,
                fetchedAt:         Date()
            )
        } catch {
            print("[ConditionsService] current fetch error for \(entry.name): \(error)")
            return nil
        }
    }

    // MARK: - Open-Meteo Fetch — Hourly Backfill

    private struct HourlyBackfill {
        let samples: [HourlyCondition]
        let last24: Double
        let last72: Double
    }

    private func fetchHourly(entry: ResortEntry) async -> HourlyBackfill? {
        let lat = (entry.bounds.minLat + entry.bounds.maxLat) / 2
        let lon = (entry.bounds.minLon + entry.bounds.maxLon) / 2

        var comps = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        comps.queryItems = [
            URLQueryItem(name: "latitude",      value: String(format: "%.5f", lat)),
            URLQueryItem(name: "longitude",     value: String(format: "%.5f", lon)),
            URLQueryItem(name: "hourly",        value: [
                "temperature_2m", "snowfall", "cloud_cover",
                "weather_code", "wind_speed_10m", "visibility"
            ].joined(separator: ",")),
            // 3 past days is the minimum that satisfies snowfallLast72hCm.
            // 1 forecast day covers the timeline scrubber's +12h window.
            URLQueryItem(name: "past_days",       value: "3"),
            URLQueryItem(name: "forecast_days",   value: "1"),
            URLQueryItem(name: "wind_speed_unit", value: "kmh"),
            URLQueryItem(name: "timezone",        value: "auto"),
        ]
        guard let url = comps.url else { return nil }

        do {
            let (data, _) = try await URLSession.shared.data(for: timedRequest(url))
            let raw = try JSONDecoder().decode(OpenMeteoResponse.self, from: data)

            let snowfallHourly = raw.hourly.snowfall
            let last24 = snowfallHourly.suffix(24).reduce(0, +)
            let last72 = snowfallHourly.suffix(72).reduce(0, +)
            return HourlyBackfill(
                samples: Self.zipHourly(raw.hourly),
                last24:  last24,
                last72:  last72
            )
        } catch {
            print("[ConditionsService] hourly fetch error for \(entry.name): \(error)")
            return nil
        }
    }

    private func timedRequest(_ url: URL) -> URLRequest {
        var req = URLRequest(url: url)
        req.timeoutInterval = networkTimeout
        return req
    }

    // MARK: - Historical Archive

    /// Fetches hourly weather from Open-Meteo's historical archive for the
    /// given date window. Uses the ERA5-derived `past_days` / `start_date`
    /// params — up to ~3 months back. Caches per-resort-and-window to avoid
    /// repeat fetches during timeline scrubbing. FIFO-capped so long sessions
    /// scrubbing across many windows/resorts don't grow unbounded.
    private let maxHistoryCacheEntries = 48
    private var historyCache: [String: [HourlyCondition]] = [:]
    private var historyCacheOrder: [String] = []

    func historicalConditions(
        entry: ResortEntry,
        startDate: Date,
        endDate: Date
    ) async -> [HourlyCondition] {
        let df = ISO8601DateFormatter()
        df.formatOptions = [.withFullDate]
        let key = "\(entry.id)|\(df.string(from: startDate))|\(df.string(from: endDate))"
        if let cached = historyCache[key] { return cached }

        let lat = (entry.bounds.minLat + entry.bounds.maxLat) / 2
        let lon = (entry.bounds.minLon + entry.bounds.maxLon) / 2

        var comps = URLComponents(string: "https://archive-api.open-meteo.com/v1/archive")!
        comps.queryItems = [
            URLQueryItem(name: "latitude",   value: String(format: "%.5f", lat)),
            URLQueryItem(name: "longitude",  value: String(format: "%.5f", lon)),
            URLQueryItem(name: "start_date", value: df.string(from: startDate)),
            URLQueryItem(name: "end_date",   value: df.string(from: endDate)),
            URLQueryItem(name: "hourly",     value: [
                "temperature_2m", "snowfall", "cloud_cover",
                "weather_code", "wind_speed_10m", "visibility"
            ].joined(separator: ",")),
            URLQueryItem(name: "wind_speed_unit", value: "kmh"),
            URLQueryItem(name: "timezone",        value: "auto"),
        ]
        guard let url = comps.url else { return [] }

        do {
            let (data, _) = try await URLSession.shared.data(for: timedRequest(url))
            let raw = try JSONDecoder().decode(OpenMeteoResponse.self, from: data)
            let samples = Self.zipHourly(raw.hourly)
            historyCache[key] = samples
            historyCacheOrder.append(key)
            if historyCacheOrder.count > maxHistoryCacheEntries {
                let oldest = historyCacheOrder.removeFirst()
                historyCache.removeValue(forKey: oldest)
            }
            return samples
        } catch {
            print("[ConditionsService] historical fetch error for \(entry.name): \(error)")
            return []
        }
    }

    private static func zipHourly(_ hourly: OpenMeteoResponse.HourlyWeather) -> [HourlyCondition] {
        let count = min(
            hourly.time.count,
            hourly.temperature2m.count,
            hourly.snowfall.count,
            hourly.cloudCover.count,
            hourly.weatherCode.count,
            hourly.windSpeed10m.count,
            hourly.visibility.count
        )
        var result: [HourlyCondition] = []
        result.reserveCapacity(count)
        for i in 0..<count {
            result.append(HourlyCondition(
                time: hourly.time[i],
                temperatureC: hourly.temperature2m[i],
                snowfallCm: hourly.snowfall[i],
                cloudCoverPercent: hourly.cloudCover[i],
                weatherCode: hourly.weatherCode[i],
                windSpeedKph: hourly.windSpeed10m[i],
                visibilityKm: hourly.visibility[i] / 1000
            ))
        }
        return result
    }
}

// MARK: - Open-Meteo Response Types
//
// Decodable conformances are placed in extensions with `nonisolated init(from:)`
// so the synthesised code is not inferred as @MainActor. This silences the Swift 6
// "Main actor-isolated conformance … cannot be used in actor-isolated context" warning.

private struct OpenMeteoResponse: Sendable {
    let elevation: Double       // DEM elevation of the query point (meters)
    let current: CurrentWeather
    let hourly:  HourlyWeather

    struct CurrentWeather: Sendable {
        let temperature2m: Double
        let snowfall:      Double
        let windSpeed10m:  Double
        let windGusts10m:  Double
        let weatherCode:   Int
        let snowDepth:     Double
        let visibility:    Double  // meters
        let cloudCover:    Int     // 0-100 %
        let windDirection: Int     // degrees
    }

    struct HourlyWeather: Sendable {
        let time: [Date]
        let temperature2m: [Double]
        let snowfall: [Double]
        let cloudCover: [Int]
        let weatherCode: [Int]
        let windSpeed10m: [Double]
        let visibility: [Double]
    }
}

extension OpenMeteoResponse: Decodable {
    private enum CodingKeys: String, CodingKey { case elevation, current, hourly }
    nonisolated init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        elevation = try c.decodeIfPresent(Double.self, forKey: .elevation) ?? 0
        // Either block may be missing depending on which call we made (current-only
        // vs hourly-only). Decode optionally and substitute zeroed defaults so the
        // call site doesn't need to know which fields are populated.
        current   = try c.decodeIfPresent(CurrentWeather.self, forKey: .current) ?? .empty
        hourly    = try c.decodeIfPresent(HourlyWeather.self,  forKey: .hourly)  ?? .empty
    }
}

extension OpenMeteoResponse.CurrentWeather {
    fileprivate nonisolated static let empty = OpenMeteoResponse.CurrentWeather(
        temperature2m: 0, snowfall: 0, windSpeed10m: 0, windGusts10m: 0,
        weatherCode: 0, snowDepth: 0, visibility: 10000, cloudCover: 0, windDirection: 0
    )
}

extension OpenMeteoResponse.HourlyWeather {
    fileprivate nonisolated static let empty = OpenMeteoResponse.HourlyWeather(
        time: [], temperature2m: [], snowfall: [], cloudCover: [],
        weatherCode: [], windSpeed10m: [], visibility: []
    )
}

extension OpenMeteoResponse.CurrentWeather: Decodable {
    private enum CodingKeys: String, CodingKey {
        case temperature2m = "temperature_2m"
        case snowfall
        case windSpeed10m  = "wind_speed_10m"
        case windGusts10m  = "wind_gusts_10m"
        case weatherCode   = "weather_code"
        case snowDepth     = "snow_depth"
        case visibility
        case cloudCover    = "cloud_cover"
        case windDirection = "wind_direction_10m"
    }
    nonisolated init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        temperature2m = try c.decode(Double.self, forKey: .temperature2m)
        snowfall      = try c.decode(Double.self, forKey: .snowfall)
        windSpeed10m  = try c.decode(Double.self, forKey: .windSpeed10m)
        windGusts10m  = try c.decode(Double.self, forKey: .windGusts10m)
        weatherCode   = try c.decode(Int.self,    forKey: .weatherCode)
        snowDepth     = try c.decode(Double.self, forKey: .snowDepth)
        visibility    = try c.decodeIfPresent(Double.self, forKey: .visibility) ?? 10000
        cloudCover    = try c.decodeIfPresent(Int.self,    forKey: .cloudCover) ?? 0
        windDirection = try c.decodeIfPresent(Int.self,    forKey: .windDirection) ?? 0
    }
}

extension OpenMeteoResponse.HourlyWeather: Decodable {
    private enum CodingKeys: String, CodingKey {
        case time
        case temperature2m = "temperature_2m"
        case snowfall
        case cloudCover = "cloud_cover"
        case weatherCode = "weather_code"
        case windSpeed10m = "wind_speed_10m"
        case visibility
    }
    nonisolated init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Open-Meteo hourly times come as "2026-04-15T00:00" (no timezone
        // suffix). Parse with a permissive formatter and fall back to
        // ISO8601 for historical archive responses that include zones.
        let timeStrings = try c.decodeIfPresent([String].self, forKey: .time) ?? []
        let df = DateFormatter()
        df.calendar = Calendar(identifier: .gregorian)
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "yyyy-MM-dd'T'HH:mm"
        let iso = ISO8601DateFormatter()
        time = timeStrings.map { df.date(from: $0) ?? iso.date(from: $0) ?? Date() }

        temperature2m = try c.decodeIfPresent([Double].self, forKey: .temperature2m) ?? []
        snowfall      = try c.decode([Double].self, forKey: .snowfall)
        cloudCover    = try c.decodeIfPresent([Int].self,    forKey: .cloudCover) ?? []
        weatherCode   = try c.decodeIfPresent([Int].self,    forKey: .weatherCode) ?? []
        windSpeed10m  = try c.decodeIfPresent([Double].self, forKey: .windSpeed10m) ?? []
        visibility    = try c.decodeIfPresent([Double].self, forKey: .visibility) ?? []
    }
}
