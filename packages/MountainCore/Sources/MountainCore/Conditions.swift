import Foundation

public struct ConditionsSample: Hashable, Sendable, Codable {
    public var at: Date
    public var tempC: Double
    public var windMS: Double
    public var gustMS: Double
    public var visibilityM: Double
    public var cloudPct: Double
    public var snow24hCM: Double
    public var precipMMH: Double
    public var weatherCode: Int
    // What follows came later and is absent from older rows: nil means "not
    // told", and every reader falls back to the resort-wide reading.
    /// Where the wind comes from, degrees from north.
    public var windDirDeg: Double?
    public var dewPointC: Double?
    public var cloudLowPct: Double?
    /// Air temperature at the 850 and 700 hPa levels (about 1,460 m and 3,010 m).
    public var temp850C: Double?
    public var temp700C: Double?
    public var snowDepthCM: Double?
    public var snow72hCM: Double?

    public init(
        at: Date, tempC: Double, windMS: Double, gustMS: Double = 0, visibilityM: Double,
        cloudPct: Double, snow24hCM: Double = 0, precipMMH: Double = 0, weatherCode: Int = 0,
        windDirDeg: Double? = nil, dewPointC: Double? = nil, cloudLowPct: Double? = nil,
        temp850C: Double? = nil, temp700C: Double? = nil, snowDepthCM: Double? = nil,
        snow72hCM: Double? = nil
    ) {
        self.windDirDeg = windDirDeg
        self.dewPointC = dewPointC
        self.cloudLowPct = cloudLowPct
        self.temp850C = temp850C
        self.temp700C = temp700C
        self.snowDepthCM = snowDepthCM
        self.snow72hCM = snow72hCM
        self.at = at
        self.tempC = tempC
        self.windMS = windMS
        self.gustMS = gustMS
        self.visibilityM = visibilityM
        self.cloudPct = cloudPct
        self.snow24hCM = snow24hCM
        self.precipMMH = precipMMH
        self.weatherCode = weatherCode
    }

    private enum CodingKeys: String, CodingKey {
        case at
        case tempC = "temp_c"
        case windMS = "wind_ms"
        case gustMS = "gust_ms"
        case visibilityM = "visibility_m"
        case cloudPct = "cloud_pct"
        case snow24hCM = "snow_24h_cm"
        case precipMMH = "precip_mmh"
        case weatherCode = "weather_code"
        case windDirDeg = "wind_dir_deg"
        case dewPointC = "dew_point_c"
        case cloudLowPct = "cloud_low_pct"
        case temp850C = "temp_850_c"
        case temp700C = "temp_700_c"
        case snowDepthCM = "snow_depth_cm"
        case snow72hCM = "snow_72h_cm"
    }
}

/// One past hour of a resort's weather, kept to tell whether the snow thawed
/// and refroze.
public struct RecentConditions: Hashable, Sendable, Codable {
    public var at: Date
    public var tempC: Double
    public var cloudPct: Double?

    public init(at: Date, tempC: Double, cloudPct: Double? = nil) {
        self.at = at
        self.tempC = tempC
        self.cloudPct = cloudPct
    }

    private enum CodingKeys: String, CodingKey {
        case at
        case tempC = "temp_c"
        case cloudPct = "cloud_pct"
    }
}

/// Weather for one resort: a current reading, the next 24 hourly samples and,
/// from newer rows, the height the forecast is for and the last day's hours.
public struct Conditions: Hashable, Sendable, Codable {
    public var resortID: String
    public var observedAt: Date
    public var expiresAt: Date
    public var source: String
    public var current: ConditionsSample
    public var hourly: [ConditionsSample]
    /// Metres above sea level the forecast is for; nil on older rows.
    public var elevationM: Double?
    /// The 24 hours before `observedAt`, oldest first; empty on older rows.
    public var recent: [RecentConditions]

    public init(
        resortID: String, observedAt: Date, expiresAt: Date, source: String = "open-meteo",
        current: ConditionsSample, hourly: [ConditionsSample] = [], elevationM: Double? = nil,
        recent: [RecentConditions] = []
    ) {
        self.elevationM = elevationM
        self.recent = recent
        self.resortID = resortID
        self.observedAt = observedAt
        self.expiresAt = expiresAt
        self.source = source
        self.current = current
        self.hourly = hourly
    }

    private enum CodingKeys: String, CodingKey {
        case source, current, hourly
        case resortID = "resort_id"
        case observedAt = "observed_at"
        case expiresAt = "expires_at"
        case elevationM = "elevation_m"
        case recent
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        resortID = try c.decode(String.self, forKey: .resortID)
        observedAt = try c.decode(Date.self, forKey: .observedAt)
        expiresAt = try c.decode(Date.self, forKey: .expiresAt)
        source = try c.decode(String.self, forKey: .source)
        current = try c.decode(ConditionsSample.self, forKey: .current)
        hourly = try c.decode([ConditionsSample].self, forKey: .hourly)
        // Rows written before these existed, and copies cached from them.
        elevationM = try c.decodeIfPresent(Double.self, forKey: .elevationM)
        recent = try c.decodeIfPresent([RecentConditions].self, forKey: .recent) ?? []
    }

    public static func decode(_ json: Data) throws -> Conditions {
        try BundleCoding.decoder().decode(Conditions.self, from: json)
    }

    static let holdDistance: TimeInterval = 60 * 60
    static let fadeDistance: TimeInterval = 30 * 60
    static let normalGap: TimeInterval = 2 * 60 * 60

    /// The reading expected at `date` (invariant I-05): linear between two samples
    /// a normal gap apart; at an edge or across a missing interval the nearest
    /// sample is held for one hour, fades to `current` over the next 30 minutes,
    /// and `current` applies after that.
    public func sample(at date: Date) -> ConditionsSample {
        var fallback = current
        fallback.at = date
        guard !hourly.isEmpty else { return fallback }

        // Callers on a hot path pass an already ordered series; only sort otherwise.
        let isOrdered = zip(hourly, hourly.dropFirst()).allSatisfy { $0.at <= $1.at }
        let ordered = isOrdered ? hourly : hourly.sorted { $0.at < $1.at }
        var lower: ConditionsSample?
        var upper: ConditionsSample?
        for sample in ordered {
            if sample.at <= date { lower = sample }
            if sample.at >= date {
                upper = sample
                break
            }
        }

        func decayed(_ sample: ConditionsSample, distance: TimeInterval, approaching: Bool)
            -> ConditionsSample? {
            guard distance <= Self.holdDistance + Self.fadeDistance else { return nil }
            guard distance > Self.holdDistance else { return Self.at(date, sample) }
            let fade = (distance - Self.holdDistance) / Self.fadeDistance
            return approaching
                ? Self.blend(fallback, sample, fraction: 1 - fade, at: date)
                : Self.blend(sample, fallback, fraction: fade, at: date)
        }

        if let lower, let upper {
            let gap = upper.at.timeIntervalSince(lower.at)
            if gap == 0 { return Self.at(date, lower) }
            if gap > Self.normalGap {
                let lowerDistance = date.timeIntervalSince(lower.at)
                let upperDistance = upper.at.timeIntervalSince(date)
                if lowerDistance <= upperDistance,
                   let held = decayed(lower, distance: lowerDistance, approaching: false) {
                    return held
                }
                return decayed(upper, distance: upperDistance, approaching: true) ?? fallback
            }
            return Self.blend(
                lower, upper, fraction: date.timeIntervalSince(lower.at) / gap, at: date
            )
        }
        if let lower,
           let held = decayed(lower, distance: date.timeIntervalSince(lower.at), approaching: false) {
            return held
        }
        if let upper,
           let held = decayed(upper, distance: upper.at.timeIntervalSince(date), approaching: true) {
            return held
        }
        return fallback
    }

    private static func at(_ date: Date, _ sample: ConditionsSample) -> ConditionsSample {
        var copy = sample
        copy.at = date
        return copy
    }

    private static func blend(
        _ from: ConditionsSample, _ to: ConditionsSample, fraction: Double, at date: Date
    ) -> ConditionsSample {
        let t = max(0, min(1, fraction))
        func lerp(_ a: Double, _ b: Double) -> Double { a + (b - a) * t }
        // A value only one side has is held, not dropped.
        func lerp(_ a: Double?, _ b: Double?) -> Double? {
            guard let a, let b else { return a ?? b }
            return lerp(a, b)
        }
        // The short way round the compass.
        func bearing(_ a: Double?, _ b: Double?) -> Double? {
            guard let a, let b else { return a ?? b }
            let turn = (b - a + 540).truncatingRemainder(dividingBy: 360) - 180
            return (a + turn * t + 360).truncatingRemainder(dividingBy: 360)
        }
        return ConditionsSample(
            at: date,
            tempC: lerp(from.tempC, to.tempC),
            windMS: lerp(from.windMS, to.windMS),
            gustMS: lerp(from.gustMS, to.gustMS),
            visibilityM: lerp(from.visibilityM, to.visibilityM),
            cloudPct: lerp(from.cloudPct, to.cloudPct).rounded(),
            snow24hCM: lerp(from.snow24hCM, to.snow24hCM),
            precipMMH: lerp(from.precipMMH, to.precipMMH),
            weatherCode: t < 0.5 ? from.weatherCode : to.weatherCode,
            windDirDeg: bearing(from.windDirDeg, to.windDirDeg),
            dewPointC: lerp(from.dewPointC, to.dewPointC),
            cloudLowPct: lerp(from.cloudLowPct, to.cloudLowPct),
            temp850C: lerp(from.temp850C, to.temp850C),
            temp700C: lerp(from.temp700C, to.temp700C),
            snowDepthCM: lerp(from.snowDepthCM, to.snowDepthCM),
            snow72hCM: lerp(from.snow72hCM, to.snow72hCM)
        )
    }
}
