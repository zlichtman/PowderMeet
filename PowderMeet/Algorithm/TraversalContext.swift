//
//  TraversalContext.swift
//  PowderMeet
//
//  Environmental-conditions bundle for the solver's edge weight function.
//  Extracted from MeetingPointSolver.swift — standalone `nonisolated` value
//  type. Construct one ONLY via `MeetingPointSolver.makeContext(for:)`; see
//  the canonical-context invariant in the project AGENTS.md.
//

import Foundation

// MARK: - Traversal Context

/// Bundles all environmental conditions for the weight function.
/// Built once per solve, passed to every `traverseTime()` call.
/// Values are pre-normalized for cross-device determinism.
nonisolated struct TraversalContext: Sendable {
    struct WeatherSample: Sendable, Equatable {
        let time: Date
        let temperatureCelsius: Double
        let windSpeedKmh: Double
        let visibilityKm: Double
        let cloudCoverPercent: Int
        /// Open-Meteo's snowfall value is the sum over the preceding hour.
        /// Keeping that interval meaning intact lets the solver accumulate
        /// only the portion expected before a skier reaches an edge.
        let snowfallCm: Double

        init(
            time: Date,
            temperatureCelsius: Double,
            windSpeedKmh: Double,
            visibilityKm: Double,
            cloudCoverPercent: Int,
            snowfallCm: Double = 0
        ) {
            self.time = time
            self.temperatureCelsius = temperatureCelsius
            self.windSpeedKmh = windSpeedKmh
            self.visibilityKm = visibilityKm
            self.cloudCoverPercent = cloudCoverPercent
            self.snowfallCm = max(0, snowfallCm)
        }
    }

    struct WeatherSnapshot: Sendable, Equatable {
        let temperatureCelsius: Double
        let windSpeedKmh: Double
        let visibilityKm: Double
        let cloudCoverPercent: Int
    }

    enum LearnedConditionsMatch: Sendable, Equatable {
        /// Observation was recorded in the same coarse weather + surface
        /// bucket as this solve. Its measured speed already contains those
        /// effects and must not receive the synthetic environment model again.
        case exact
        /// Observation has no trustworthy weather provenance. Its per-edge
        /// pace still contains static terrain effects, but current weather may
        /// be applied once as a conservative adjustment.
        case unattributed
    }

    struct LearnedPace: Sendable {
        let observation: PerEdgeSpeed
        let conditionsMatch: LearnedConditionsMatch
    }

    let solveTime: Date?
    let latitude: Double?
    let longitude: Double?
    /// Resort-local UTC offset for this weather snapshot, including DST.
    /// Longitude remains a deterministic fallback for legacy contexts.
    let utcOffsetSeconds: Int?
    /// Conservative resort-wide lift window used for future-arrival gating.
    /// Canonical live status answers whether a lift is open now; these hours
    /// prevent a route from depending on it after the resort's known close.
    let liftOpenHour: Int
    let liftCloseHour: Int
    let temperatureCelsius: Double
    let stationElevationM: Double     // DEM elevation of weather station
    let windSpeedKmh: Double
    let visibilityKm: Double
    let freshSnowCm: Double
    let cloudCoverPercent: Int
    /// Quantized hourly forecast surrounding the solve. Edge costs interpolate
    /// this timeline at predicted arrival time so a route reaching exposed
    /// terrain later is evaluated against the conditions expected then. Empty
    /// means the current scalar snapshot remains authoritative.
    let hourlyWeather: [WeatherSample]
    /// Per-edge rolling-average speed history loaded from
    /// `profile_edge_speeds`. Outer key is `edge_id`; inner key is the
    /// row's stable dataset/equipment/conditions compound key. Selection
    /// prefers the current ski's cohort, then neutral observations whose
    /// source did not identify equipment. It never borrows another ski's
    /// cohort. Empty dict = no history available.
    let edgeSpeedHistory: [String: [String: PerEdgeSpeed]]
    /// Dataset identity for the graph being routed. Observations from a
    /// different immutable topology are never applied to coincident IDs.
    let datasetVersion: String?
    /// Selected ski at solve time. Affects conservative ETA weighting only;
    /// all safety and ability gates run independently before this modifier.
    let equipment: SkiPerformanceProfile?

    /// Minimum observations before we trust the rolling per-edge speed
    /// over the bucketed median. One run is signal but not enough to
    /// commit; three is a reasonable confidence floor while still being
    /// reachable on a normal weekend.
    static let edgeHistoryMinObservations = 3

    init(
        solveTime: Date?,
        latitude: Double?,
        longitude: Double?,
        utcOffsetSeconds: Int? = nil,
        liftOpenHour: Int = TraversalConstants.Lift.minSafeHour,
        liftCloseHour: Int = TraversalConstants.Lift.maxSafeHour,
        temperatureCelsius: Double,
        stationElevationM: Double,
        windSpeedKmh: Double,
        visibilityKm: Double,
        freshSnowCm: Double,
        cloudCoverPercent: Int,
        hourlyWeather: [WeatherSample] = [],
        edgeSpeedHistory: [String: [String: PerEdgeSpeed]] = [:],
        datasetVersion: String? = nil,
        equipment: SkiPerformanceProfile? = nil
    ) {
        self.solveTime = solveTime
        self.latitude = latitude
        self.longitude = longitude
        self.utcOffsetSeconds = utcOffsetSeconds
        self.liftOpenHour = max(0, min(23, liftOpenHour))
        self.liftCloseHour = max(self.liftOpenHour + 1, min(24, liftCloseHour))
        self.temperatureCelsius = temperatureCelsius
        self.stationElevationM = stationElevationM
        self.windSpeedKmh = windSpeedKmh
        self.visibilityKm = visibilityKm
        self.freshSnowCm = freshSnowCm
        self.cloudCoverPercent = cloudCoverPercent
        self.hourlyWeather = hourlyWeather.sorted {
            if $0.time != $1.time { return $0.time < $1.time }
            if $0.temperatureCelsius != $1.temperatureCelsius {
                return $0.temperatureCelsius < $1.temperatureCelsius
            }
            return $0.windSpeedKmh < $1.windSpeedKmh
        }
        self.edgeSpeedHistory = edgeSpeedHistory
        self.datasetVersion = datasetVersion
        self.equipment = equipment
    }

    /// Re-anchor time-dependent lift-hour and hourly-weather evaluation while
    /// preserving the exact environment, equipment, and learned-pace inputs
    /// that were validated for the active route.
    func rebased(to solveTime: Date) -> TraversalContext {
        let currentWeather = weather(at: solveTime)
        return TraversalContext(
            solveTime: solveTime,
            latitude: latitude,
            longitude: longitude,
            utcOffsetSeconds: utcOffsetSeconds,
            liftOpenHour: liftOpenHour,
            liftCloseHour: liftCloseHour,
            temperatureCelsius: currentWeather.temperatureCelsius,
            stationElevationM: stationElevationM,
            windSpeedKmh: currentWeather.windSpeedKmh,
            visibilityKm: currentWeather.visibilityKm,
            freshSnowCm: effectiveFreshSnowCm(at: solveTime),
            cloudCoverPercent: currentWeather.cloudCoverPercent,
            hourlyWeather: hourlyWeather,
            edgeSpeedHistory: edgeSpeedHistory,
            datasetVersion: datasetVersion,
            equipment: equipment
        )
    }

    /// Look up the trusted measured pace that best matches the current
    /// equipment and conditions for `edge`. Within each equipment cohort it
    /// accepts exact live conditions, then the explicit `default` bucket.
    /// A selected ski may fall back to neutral history, but never to a
    /// different ski or an unrelated weather bucket. Rows below the confidence
    /// floor are skipped so a well-supported neutral cohort can win over one
    /// untrusted current-ski sample.
    func learnedPace(for edge: GraphEdge, at date: Date? = nil) -> LearnedPace? {
        guard edge.kind == .run,
              let perEdge = edgeSpeedHistory[edge.id], !perEdge.isEmpty else {
            return nil
        }
        let surface = ConditionsFingerprint.SurfaceFlags(
            hasMoguls: edge.attributes.hasMoguls,
            isUngroomed: edge.attributes.isGroomed == false,
            isGladed: edge.attributes.isGladed
        )
        let weather = weather(at: date)
        let liveFp = ConditionsFingerprint.fingerprint(
            temperatureC: weather.temperatureCelsius,
            windSpeedKph: weather.windSpeedKmh,
            snowfallLast24hCm: effectiveFreshSnowCm(at: date),
            visibilityKm: weather.visibilityKm,
            cloudCoverPercent: weather.cloudCoverPercent,
            surface: surface
        )
        func belongsToCurrentDataset(_ row: PerEdgeSpeed) -> Bool {
            switch (datasetVersion, row.datasetVersion) {
            case let (.some(current), .some(observed)): return current == observed
            case (.none, _): return true
            case (.some, .none): return false
            }
        }
        let requestedEquipmentKey = equipment?.observationEquipmentKey
        let equipmentPriority = requestedEquipmentKey.map {
            [$0, PerEdgeSpeed.neutralEquipmentKey]
        } ?? [PerEdgeSpeed.neutralEquipmentKey]

        func trustedRows(for equipmentKey: String) -> [PerEdgeSpeed] {
            perEdge.values.filter {
                $0.equipmentKey == equipmentKey
                    && $0.edgeId == edge.id
                    && belongsToCurrentDataset($0)
                    && $0.observationCount >= Self.edgeHistoryMinObservations
                    && $0.hasPlausibleRoutingMetrics
            }
        }

        func best(_ rows: [PerEdgeSpeed]) -> PerEdgeSpeed? {
            rows.sorted {
                if $0.observationCount != $1.observationCount {
                    return $0.observationCount > $1.observationCount
                }
                if $0.conditionsFp != $1.conditionsFp {
                    return $0.conditionsFp < $1.conditionsFp
                }
                if ($0.datasetVersion ?? "") != ($1.datasetVersion ?? "") {
                    return ($0.datasetVersion ?? "") < ($1.datasetVersion ?? "")
                }
                return $0.historyKey < $1.historyKey
            }.first
        }

        for equipmentKey in equipmentPriority {
            let rows = trustedRows(for: equipmentKey)
            if let exact = best(rows.filter { $0.conditionsFp == liveFp }) {
                return LearnedPace(observation: exact, conditionsMatch: .exact)
            }
            if let fallback = best(rows.filter {
                $0.conditionsFp == ConditionsFingerprint.defaultBucket
            }) {
                return LearnedPace(
                    observation: fallback,
                    conditionsMatch: .unattributed
                )
            }
        }
        return nil
    }

    /// Compatibility accessor for uncertainty/scoring code that needs the row
    /// but not its condition provenance. Selection remains centralized above.
    func observation(for edge: GraphEdge, at date: Date? = nil) -> PerEdgeSpeed? {
        learnedPace(for: edge, at: date)?.observation
    }

    /// Environmental snapshot at predicted edge arrival. Open-Meteo samples
    /// are hourly, so linear interpolation avoids route-cost cliffs at the top
    /// of each hour. A distant or incomplete timeline never overrides the
    /// fresh current reading.
    func weather(at date: Date?) -> WeatherSnapshot {
        let fallback = WeatherSnapshot(
            temperatureCelsius: temperatureCelsius,
            windSpeedKmh: windSpeedKmh,
            visibilityKm: visibilityKm,
            cloudCoverPercent: cloudCoverPercent
        )
        guard let date, !hourlyWeather.isEmpty else { return fallback }

        var lower: WeatherSample?
        var upper: WeatherSample?
        for sample in hourlyWeather {
            if sample.time <= date { lower = sample }
            if sample.time >= date {
                upper = sample
                break
            }
        }

        // Missing-feed policy: hold a nearby hourly reading for one hour,
        // fade it into the fresh current fallback over the next 30 minutes,
        // then use fallback. This avoids both false long extrapolation and an
        // instantaneous cost cliff at the former 90-minute cutoff.
        let holdDistance: TimeInterval = 60 * 60
        let fadeDistance: TimeInterval = 30 * 60
        let maximumUsefulDistance = holdDistance + fadeDistance
        func blend(
            _ from: WeatherSnapshot,
            _ to: WeatherSnapshot,
            fraction: Double
        ) -> WeatherSnapshot {
            let t = max(0, min(1, fraction))
            func lerp(_ a: Double, _ b: Double) -> Double { a + (b - a) * t }
            return WeatherSnapshot(
                temperatureCelsius: lerp(from.temperatureCelsius, to.temperatureCelsius),
                windSpeedKmh: lerp(from.windSpeedKmh, to.windSpeedKmh),
                visibilityKm: lerp(from.visibilityKm, to.visibilityKm),
                cloudCoverPercent: Int(lerp(
                    Double(from.cloudCoverPercent),
                    Double(to.cloudCoverPercent)
                ).rounded())
            )
        }
        func decayedSample(
            _ sample: WeatherSample,
            distance: TimeInterval,
            approaching: Bool
        ) -> WeatherSnapshot? {
            guard distance <= maximumUsefulDistance else { return nil }
            let snapshot = Self.snapshot(from: sample)
            guard distance > holdDistance else { return snapshot }
            let fade = (distance - holdDistance) / fadeDistance
            return approaching
                ? blend(fallback, snapshot, fraction: 1 - fade)
                : blend(snapshot, fallback, fraction: fade)
        }
        if let lower, let upper {
            let gap = upper.time.timeIntervalSince(lower.time)
            guard gap >= 0 else { return fallback }
            if gap == 0 { return Self.snapshot(from: lower) }
            if gap > 2 * 60 * 60 {
                let lowerDistance = date.timeIntervalSince(lower.time)
                let upperDistance = upper.time.timeIntervalSince(date)
                if lowerDistance <= upperDistance,
                   let decayed = decayedSample(
                    lower,
                    distance: lowerDistance,
                    approaching: false
                   ) {
                    return decayed
                }
                if let approaching = decayedSample(
                    upper,
                    distance: upperDistance,
                    approaching: true
                ) {
                    return approaching
                }
                return fallback
            }
            let fraction = max(0, min(1, date.timeIntervalSince(lower.time) / gap))
            return blend(
                Self.snapshot(from: lower),
                Self.snapshot(from: upper),
                fraction: fraction
            )
        }
        if let lower,
           let decayed = decayedSample(
            lower,
            distance: date.timeIntervalSince(lower.time),
            approaching: false
           ) {
            return decayed
        }
        if let upper,
           let approaching = decayedSample(
            upper,
            distance: upper.time.timeIntervalSince(date),
            approaching: true
           ) {
            return approaching
        }
        return fallback
    }

    /// Current 24-hour snow plus the forecast snow expected to land between
    /// solve time and edge arrival. Each hourly sample represents `(t-1h, t]`,
    /// so partial-hour arrivals receive only their overlapping fraction.
    /// Missing forecast intervals contribute zero rather than extrapolating a
    /// storm indefinitely.
    func effectiveFreshSnowCm(at date: Date?) -> Double {
        guard let solveTime, let date, date > solveTime else {
            return freshSnowCm
        }
        let hour: TimeInterval = 60 * 60
        let forecastAddition = hourlyWeather.reduce(0.0) { total, sample in
            let intervalEnd = sample.time
            let intervalStart = intervalEnd.addingTimeInterval(-hour)
            let overlapStart = max(solveTime, intervalStart)
            let overlapEnd = min(date, intervalEnd)
            let overlap = overlapEnd.timeIntervalSince(overlapStart)
            guard overlap > 0 else { return total }
            return total + sample.snowfallCm * min(1, overlap / hour)
        }
        return freshSnowCm + forecastAddition
    }

    private static func snapshot(from sample: WeatherSample) -> WeatherSnapshot {
        WeatherSnapshot(
            temperatureCelsius: sample.temperatureCelsius,
            windSpeedKmh: sample.windSpeedKmh,
            visibilityKm: sample.visibilityKm,
            cloudCoverPercent: sample.cloudCoverPercent
        )
    }

    /// Lapse-rate adjusted temperature at a given elevation.
    func temperatureAt(elevationM: Double, at date: Date? = nil) -> Double {
        let deltaM = elevationM - stationElevationM
        return weather(at: date).temperatureCelsius + deltaM * (-6.5 / 1000.0)
    }
}
