//
//  UserProfile.swift
//  PowderMeet
//
//  Codable model mapping to the Supabase `profiles` table.
//  Also contains the pathfinding weight function (traverseTime).
//

import Foundation

// `nonisolated` — `traverseTime(for:context:ignoreSkillGates:)` is the
// hot inner loop of Dijkstra and must run from the solver's detached
// task without an actor hop. Project default isolation is MainActor;
// opt out. Pure value type; all members are Sendable.
nonisolated struct UserProfile: Codable, Identifiable, Sendable {
    let id: UUID
    var displayName: String
    var avatarUrl: String?
    var currentResortId: String?
    var skillLevel: String
    var speedGreen: Double?
    var speedBlue: Double?
    var speedBlack: Double?
    var speedDoubleBlack: Double?
    var speedTerrainPark: Double?
    var conditionMoguls: Double
    var conditionUngroomed: Double
    var conditionIcy: Double
    var conditionGladed: Double

    // MARK: - Continuous skill fields
    //
    // Finer-grained than the bucketed skill level / condition sliders.
    // The bucketed gradient cap (`maxGradientForLevel`) blocks routes, which
    // is too coarse — a strong intermediate can ski a 32° pitch if it's
    // groomed, but the current code blocks everything above the level's cap.
    // These fields let the solver ramp penalties instead of hard-blocking.
    //
    // Defaults mirror the bucketed behaviour; onboarding / calibration can
    // refine them. `Double?` so we can tell "user never set this" from "user
    // explicitly chose 0".
    var maxComfortableGradientDegrees: Double?   // hard block above this + ramp below
    var mogulTolerance: Double?                  // 0..1
    var narrowTrailTolerance: Double?            // 0..1
    var exposureTolerance: Double?               // 0..1 — fall-line exposure
    var crustConditionTolerance: Double?         // 0..1 — refrozen crust

    // MARK: - Live recording feature gate
    //
    // When true (default), `LiveRunRecorder` passively segments incoming
    // GPS fixes into runs while the app is open and persists each
    // completed run to `imported_runs` (source = "live"). Toggling this
    // off in the Profile › ACTIVITY tab stops the recorder immediately —
    // useful for users who want full control over what data lands in
    // the algorithm's per-edge skill memory.
    var liveRecordingEnabled: Bool

    var onboardingCompleted: Bool
    let createdAt: Date?
    var updatedAt: Date?

    // MARK: - Memberwise Init

    init(
        id: UUID,
        displayName: String,
        avatarUrl: String? = nil,
        currentResortId: String? = nil,
        skillLevel: String,
        speedGreen: Double? = nil,
        speedBlue: Double? = nil,
        speedBlack: Double? = nil,
        speedDoubleBlack: Double? = nil,
        speedTerrainPark: Double? = nil,
        conditionMoguls: Double,
        conditionUngroomed: Double,
        conditionIcy: Double,
        conditionGladed: Double,
        maxComfortableGradientDegrees: Double? = nil,
        mogulTolerance: Double? = nil,
        narrowTrailTolerance: Double? = nil,
        exposureTolerance: Double? = nil,
        crustConditionTolerance: Double? = nil,
        liveRecordingEnabled: Bool = true,
        onboardingCompleted: Bool,
        createdAt: Date? = nil,
        updatedAt: Date? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.avatarUrl = avatarUrl
        self.currentResortId = currentResortId
        self.skillLevel = skillLevel
        self.speedGreen = speedGreen
        self.speedBlue = speedBlue
        self.speedBlack = speedBlack
        self.speedDoubleBlack = speedDoubleBlack
        self.speedTerrainPark = speedTerrainPark
        self.conditionMoguls = conditionMoguls
        self.conditionUngroomed = conditionUngroomed
        self.conditionIcy = conditionIcy
        self.conditionGladed = conditionGladed
        self.maxComfortableGradientDegrees = maxComfortableGradientDegrees
        self.mogulTolerance = mogulTolerance
        self.narrowTrailTolerance = narrowTrailTolerance
        self.exposureTolerance = exposureTolerance
        self.crustConditionTolerance = crustConditionTolerance
        self.liveRecordingEnabled = liveRecordingEnabled
        self.onboardingCompleted = onboardingCompleted
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    // MARK: - Decoding (backward compat for new fields)

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        displayName = try c.decode(String.self, forKey: .displayName)
        avatarUrl = try c.decodeIfPresent(String.self, forKey: .avatarUrl)
        currentResortId = try c.decodeIfPresent(String.self, forKey: .currentResortId)
        skillLevel = try c.decode(String.self, forKey: .skillLevel)
        speedGreen = try c.decodeIfPresent(Double.self, forKey: .speedGreen)
        speedBlue = try c.decodeIfPresent(Double.self, forKey: .speedBlue)
        speedBlack = try c.decodeIfPresent(Double.self, forKey: .speedBlack)
        speedDoubleBlack = try c.decodeIfPresent(Double.self, forKey: .speedDoubleBlack)
        speedTerrainPark = try c.decodeIfPresent(Double.self, forKey: .speedTerrainPark)
        conditionMoguls = try c.decode(Double.self, forKey: .conditionMoguls)
        conditionUngroomed = try c.decode(Double.self, forKey: .conditionUngroomed)
        conditionIcy = try c.decode(Double.self, forKey: .conditionIcy)
        conditionGladed = try c.decode(Double.self, forKey: .conditionGladed)
        maxComfortableGradientDegrees = try c.decodeIfPresent(Double.self, forKey: .maxComfortableGradientDegrees)
        mogulTolerance = try c.decodeIfPresent(Double.self, forKey: .mogulTolerance)
        narrowTrailTolerance = try c.decodeIfPresent(Double.self, forKey: .narrowTrailTolerance)
        exposureTolerance = try c.decodeIfPresent(Double.self, forKey: .exposureTolerance)
        crustConditionTolerance = try c.decodeIfPresent(Double.self, forKey: .crustConditionTolerance)
        // Default to true so existing accounts (column missing on a stale
        // profile JSON, or older app build that wrote the row before this
        // column shipped) get live recording on by default. Toggling it
        // off is a deliberate user action; never silently disabled.
        liveRecordingEnabled = try c.decodeIfPresent(Bool.self, forKey: .liveRecordingEnabled) ?? true
        onboardingCompleted = try c.decode(Bool.self, forKey: .onboardingCompleted)
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt)
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt)
    }

    // MARK: - Helpers

    /// Speed in m/s for a given difficulty, nil = can't/won't ski it.
    func speed(for difficulty: RunDifficulty) -> Double? {
        switch difficulty {
        case .green:       return speedGreen
        case .blue:        return speedBlue
        case .black:       return speedBlack
        case .doubleBlack: return speedDoubleBlack
        case .terrainPark: return speedTerrainPark
        }
    }

    // MARK: - Traverse Time (for pathfinding)

    /// Combines multiple speed penalty factors using diminishing returns.
    /// Worst penalty applies at full strength, second at sqrt, third at cbrt.
    /// This prevents catastrophic compounding (e.g., 12 factors of 0.8x = 0.07x)
    /// while still making multi-challenge terrain slower than single-challenge.
    /// Shared UTC-anchored gregorian calendar. Built once instead of per
    /// resortLocalHour/Weekday call — those run inside Dijkstra's hot path
    /// (per-edge), so allocating a Calendar+TimeZone each time was costing
    /// 1000+ allocations per solve on a 500-edge graph.
    private static let utcCalendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        return c
    }()

    /// Result is clamped to a floor so no edge is ever slower than 4x base speed.
    /// Deterministic local hour-of-day at the resort. Longitude/15 gives the
    /// approximate UTC offset in hours; two devices at the same mountain share
    /// `context.longitude`, so they agree on the result regardless of either
    /// phone's own `TimeZone.current`. Falls back to a gregorian/UTC calendar
    /// when longitude is unavailable (never `Calendar.current` — that's the
    /// determinism hole we're closing).
    private static func resortLocalHour(at time: Date, longitude: Double?) -> Int {
        if let lon = longitude {
            let shifted = time.addingTimeInterval(lon / 15.0 * 3600)
            return utcCalendar.component(.hour, from: shifted)
        }
        return utcCalendar.component(.hour, from: time)
    }

    /// Same approach for weekday (1=Sunday, 7=Saturday).
    private static func resortLocalWeekday(at time: Date, longitude: Double?) -> Int {
        if let lon = longitude {
            let shifted = time.addingTimeInterval(lon / 15.0 * 3600)
            return utcCalendar.component(.weekday, from: shifted)
        }
        return utcCalendar.component(.weekday, from: time)
    }

    private static func combinedModifier(_ factors: [Double]) -> Double {
        let penalties = factors.filter { $0 < 1.0 }.sorted()  // smallest (worst) first
        guard !penalties.isEmpty else { return 1.0 }

        // Diminishing-return chain: the i-th worst factor contributes at
        // 1/(i+1)-power. Prior implementation capped at 3 factors which
        // silently dropped any 4th+ penalty — e.g. a run that's moguled
        // AND ungroomed AND gladed AND icy only paid for the first three.
        // The pow(·, 1/(i+1)) tail approaches 1 fast enough that extra
        // factors still attenuate gracefully; the floor keeps runaway
        // compounding in check.
        var combined = 1.0
        for (i, p) in penalties.enumerated() {
            combined *= pow(p, 1.0 / Double(i + 1))
        }

        return max(TraversalConstants.Run.combinedModifierFloor, combined)
    }

    /// Estimated traverse time in seconds for a graph edge. nil = can't/won't take this edge.
    ///
    /// When `ignoreSkillGates` is true, the difficulty hard-block and
    /// the no-glade-tolerance hard-block are skipped (open/closed
    /// status is still respected, gradient still penalizes via cost).
    /// Used by the solver to detect when a "no path" failure was
    /// purely skill-gated, so the user gets the right
    /// `SolveFailureReason.skillGatedPath` copy instead of a generic
    /// "no path" message.
    func traverseTime(
        for edge: GraphEdge,
        context: TraversalContext,
        ignoreSkillGates: Bool = false
    ) -> Double? {
        switch edge.kind {
        case .lift:
            guard edge.attributes.isOpen else { return nil }

            // Lift hours gating: only close lifts during clearly off-hours.
            // Most resorts operate 8:30am–4pm but some run until 9pm (night skiing).
            // Use a conservative window so we never accidentally block all lifts.
            if let time = context.solveTime {
                let hour = Self.resortLocalHour(at: time, longitude: context.longitude)
                if hour < TraversalConstants.Lift.minSafeHour || hour >= TraversalConstants.Lift.maxSafeHour {
                    return nil
                }
            }

            let rideTime = edge.attributes.rideTimeSeconds ?? TraversalConstants.Lift.fallbackRideTimeSeconds

            // Use real wait time from live data, fall back to heuristic.
            // `waitTimeMinutes` has no capture-time stamp in EdgeAttributes,
            // so treating it as truth leaves us exposed to stale feeds
            // (cached snapshot from hours ago). Two guards:
            //   1. Sanity-clamp: any value outside [0, 60] is almost
            //      certainly a malformed or stale sample — fall back.
            //   2. Heuristic backstop: if the heuristic disagrees by more
            //      than a factor of 3 AND we're inside peak hours, blend
            //      toward heuristic so a stale 0-min reading at 11am
            //      doesn't silently erase the real queue.
            let waitTime: Double
            let heuristicWait = Self.estimatedWaitTime(
                liftType: edge.attributes.liftType,
                capacity: edge.attributes.liftCapacity,
                solveTime: context.solveTime,
                longitude: context.longitude
            )
            if let liveWait = edge.attributes.waitTimeMinutes,
               liveWait >= 0, liveWait <= 60 {
                let liveSec = liveWait * 60
                if heuristicWait > 0, liveSec * 3 < heuristicWait || liveSec > heuristicWait * 3 {
                    waitTime = 0.7 * liveSec + 0.3 * heuristicWait
                } else {
                    waitTime = liveSec
                }
            } else {
                waitTime = heuristicWait
            }

            // Wind penalty for lifts: high wind slows or stops lifts
            let liftWindFactor: Double = {
                let wind = context.windSpeedKmh
                if wind > TraversalConstants.Lift.windHoldThresholdKph { return 3.0 }
                if wind > TraversalConstants.Lift.windReducedSpeedKph  { return 1.5 }
                if wind > TraversalConstants.Lift.windSlightSlowKph    { return 1.2 }
                return 1.0
            }()

            return (rideTime + waitTime) * liftWindFactor

        case .run:
            guard edge.attributes.isOpen else { return nil }
            let difficulty = edge.attributes.difficulty ?? .blue

            // Eligibility gating: hard-block runs above max skill level
            if !ignoreSkillGates, difficulty > maxRunDifficulty { return nil }

            // Speed: per-edge history wins when we have enough observations
            // (Phase 2 — same run + same conditions + faster previous =
            // faster prediction, no smoothing through unrelated edges of
            // the same difficulty). `context.observation(for:)` picks
            // the conditions_fp bucket that matches the current weather +
            // edge surface, falling back to the legacy `default` bucket
            // and then to the highest-observation bucket on miss. Falls
            // back to the bucketed-difficulty profile speed if no
            // history at all.
            let baseSpeed: Double
            if let observation = context.observation(for: edge),
               observation.observationCount >= TraversalContext.edgeHistoryMinObservations,
               observation.rollingSpeedMs > 0 {
                baseSpeed = observation.rollingSpeedMs
            } else if let profileSpeed = speed(for: difficulty), profileSpeed > 0 {
                baseSpeed = profileSpeed
            } else {
                baseSpeed = TraversalConstants.Run.fallbackSpeedMs
            }

            // ── Skill dampening: below the threshold speed, the skier is already
            // cautious — reduce condition-penalty severity to avoid double-counting.
            let skillDamp: Double = baseSpeed < TraversalConstants.Run.skillDampenThresholdMs
                ? TraversalConstants.Run.skillDampenFactor
                : 1.0
            func dampen(_ factor: Double) -> Double {
                1.0 - (1.0 - factor) * skillDamp
            }

            // Hard-block gladed terrain if skier can't handle it at all
            if !ignoreSkillGates, edge.attributes.isGladed && conditionGladed == 0 { return nil }

            // ── Collect trail condition penalties (terrain-specific) ──
            var trailPenalties: [Double] = []

            if edge.attributes.hasMoguls {
                // Prefer the calibrated continuous slider when set —
                // mirrors the same pattern as narrowTrailTolerance,
                // exposureTolerance, and crustConditionTolerance
                // below. Falls back to the bucketed conditionMoguls
                // when the user hasn't moved the slider. Without
                // this, mogulTolerance was fingerprinted in
                // profileFingerprint (cache key) but never read in
                // traverseTime — slider moves invalidated the cache
                // for no behavior change.
                let mogulAbility = mogulTolerance ?? conditionMoguls
                trailPenalties.append(dampen(mogulAbility))
            }
            switch edge.attributes.isGroomed {
            case .some(true):
                break
            case .some(false):
                trailPenalties.append(dampen(conditionUngroomed))
            case .none:
                // Grooming unknown — apply a half-weight ungroomed penalty
                // (midway between groomed and ungroomed) so the solver
                // slightly prefers trails with known-groomed status.
                trailPenalties.append(dampen((conditionUngroomed + 1.0) / 2.0))
            }
            if edge.attributes.isGladed {
                trailPenalties.append(dampen(conditionGladed))
            }
            // Only apply icy-condition penalty when temperature actually
            // indicates ice. Gate on edgeTemp < -3 (same threshold as the
            // environmental ice penalty below). Without this gate the penalty
            // fires on every run for every non-expert skier, even on warm days.
            let edgeTempForIce: Double = {
                let midEle = edge.attributes.midpointElevation
                guard let ele = midEle, ele > 0 else { return context.temperatureCelsius }
                return context.temperatureAt(elevationM: ele)
            }()
            if conditionIcy < 1.0 && edgeTempForIce < TraversalConstants.Run.iceConditionThresholdC {
                let icyAbility = TraversalConstants.Run.iceAbilityBaseline
                    + TraversalConstants.Run.iceAbilityScaleFactor * conditionIcy
                trailPenalties.append(dampen(icyAbility))
            }

            // Gradient penalty — continuous ramp starting at 90% of the
            // skier's comfort cap. If `maxComfortableGradientDegrees` is
            // set (calibrated per-user) it takes priority over the bucketed
            // level cap. Below the ramp start, no penalty. At the cap,
            // penalty is at full strength; beyond, it keeps scaling linearly.
            let gradient = edge.attributes.maxGradient
            let comfortCap = maxComfortableGradientDegrees ?? maxGradientForLevel
            let rampStart = comfortCap * 0.9
            if gradient > rampStart {
                let rampRange = max(comfortCap - rampStart, 1.0)
                let overage = gradient - rampStart
                let rampProgress = min(overage / rampRange, 1.0)
                let beyondCap = max(0, gradient - comfortCap)
                let penalty = max(
                    TraversalConstants.Run.gradientPenaltyMin,
                    1.0 - (rampProgress + beyondCap / TraversalConstants.Run.gradientPenaltyDenom) * steepPenaltyForLevel
                )
                trailPenalties.append(penalty)
            }

            // Trail-width penalty — narrower corridors need confidence. Only
            // applies when we know the width (enrichment populated it) and
            // the skier has a tolerance set. `narrowTrailTolerance` is 0..1
            // (1 = totally comfortable, 0 = needs wide runs).
            if let width = edge.attributes.estimatedTrailWidthMeters,
               let tol = narrowTrailTolerance, width < 20 {
                // 20m = comfortable groomed intermediate trail; 8m = narrow cat-track.
                let narrowness = max(0, min(1, (20 - width) / 12))
                let ability = 1.0 - (1.0 - tol) * narrowness
                trailPenalties.append(dampen(ability))
            }

            // Fall-line exposure — steep, straight fall-line routes punish
            // mistakes; skiers with low `exposureTolerance` pay more.
            if let exposure = edge.attributes.fallLineExposure,
               let tol = exposureTolerance, exposure > 0.5 {
                let ability = 1.0 - (1.0 - tol) * (exposure - 0.5) * 2.0
                trailPenalties.append(dampen(ability))
            }

            // Refrozen crust — chunky/hard surface. Mapped from either the
            // explicit surface estimate or cold-after-fresh-snow conditions.
            let crustLikely: Bool = {
                if edge.attributes.estimatedSurfaceCondition == "crust" { return true }
                return edgeTempForIce < -3 && context.freshSnowCm > 2 && edge.attributes.isGroomed != true
            }()
            if crustLikely, let tol = crustConditionTolerance {
                trailPenalties.append(dampen(tol))
            }

            // Combined trail condition modifier (capped: max 65% slowdown from terrain)
            let trailModifier = max(TraversalConstants.Run.trailModifierFloor, Self.combinedModifier(trailPenalties))

            // ── Collect environmental penalties (weather-based) ──
            var envPenalties: [Double] = []

            // Per-edge temperature via lapse rate
            let edgeTemp: Double = {
                let midEle = edge.attributes.midpointElevation
                guard let ele = midEle, ele > 0 else { return context.temperatureCelsius }
                return context.temperatureAt(elevationM: ele)
            }()

            // Sun exposure: time-of-day affects snow conditions per aspect
            if let time = context.solveTime, let lat = context.latitude {
                let exposure = SunExposureCalculator.exposure(
                    for: edge, at: time, resortLatitude: lat,
                    resortLongitude: context.longitude,
                    temperatureC: edgeTemp,
                    cloudCoverPercent: context.cloudCoverPercent
                )
                let sunFactor = SunExposureCalculator.speedMultiplier(for: exposure.snowCondition)
                if sunFactor < 1.0 { envPenalties.append(sunFactor) }
            }

            // Wind penalty: exposed runs slow down in high wind
            if !edge.attributes.isGladed {
                let wind = context.windSpeedKmh
                let windThreshold = TraversalConstants.Run.Wind.exposedThresholdKph
                if wind > windThreshold {
                    let windFactor = 1.0 / (1.0 + (wind - windThreshold) * TraversalConstants.Run.Wind.penaltyCoefficientPerKph)
                    envPenalties.append(windFactor)
                }
            }

            // Visibility penalty
            let vis = context.visibilityKm
            let visThreshold = TraversalConstants.Run.Visibility.penaltyThresholdKm
            if vis < visThreshold {
                let steepMult = gradient > TraversalConstants.Run.Visibility.steepGradientDegrees
                    ? TraversalConstants.Run.Visibility.steepMultiplier
                    : 1.0
                let visFactor = 1.0 / (1.0 + (visThreshold - vis) * TraversalConstants.Run.Visibility.penaltyCoefficientPerKm * steepMult)
                envPenalties.append(visFactor)
            }

            // Fresh snow: skill-scaled impact
            let snow = context.freshSnowCm
            if snow > TraversalConstants.Run.FreshSnow.ungroomedThresholdCm {
                if edge.attributes.isGroomed == true {
                    // Groomed fresh snow bonus is applied after penalty calc
                    // (values >= 1.0 are filtered out by combinedModifier)
                } else {
                    let penaltyPerCm: Double
                    switch skillLevel {
                    case "expert":       penaltyPerCm = TraversalConstants.Run.FreshSnow.expertPenaltyPerCm
                    case "advanced":     penaltyPerCm = TraversalConstants.Run.FreshSnow.advancedPenaltyPerCm
                    case "intermediate": penaltyPerCm = TraversalConstants.Run.FreshSnow.intermediatePenaltyPerCm
                    default:             penaltyPerCm = TraversalConstants.Run.FreshSnow.beginnerPenaltyPerCm
                    }
                    // Unknown grooming → half the fresh-snow penalty.
                    let uncertaintyFactor: Double = edge.attributes.isGroomed == nil ? 0.5 : 1.0
                    envPenalties.append(1.0 / (1.0 + snow * penaltyPerCm * uncertaintyFactor))
                }
            }

            // Temperature-based ice penalty
            let iceFactor: Double = {
                if edgeTemp < TraversalConstants.Run.Ice.veryColdThresholdC { return TraversalConstants.Run.Ice.veryColdSpeedFactor }
                if edgeTemp < TraversalConstants.Run.Ice.coldThresholdC     { return TraversalConstants.Run.Ice.coldSpeedFactor }
                if edgeTemp < TraversalConstants.Run.Ice.coolThresholdC     { return TraversalConstants.Run.Ice.coolSpeedFactor }
                return 1.0
            }()
            if iceFactor < 1.0 { envPenalties.append(iceFactor) }

            // Combined environmental modifier (capped: max 40% slowdown from weather)
            let envModifier = max(TraversalConstants.Run.envModifierFloor, Self.combinedModifier(envPenalties))

            // ── Final effective speed ──
            var effectiveSpeed = baseSpeed * trailModifier * envModifier

            // Groomed fresh-snow speed bonus: fresh corduroy is slightly faster.
            // Applied as a direct multiplier since combinedModifier filters out
            // values >= 1.0 (which made the old envPenalties.append dead code).
            if edge.attributes.isGroomed == true && snow > 0 {
                let groomedBonus = 1.0 + snow * TraversalConstants.Run.FreshSnow.groomedBonusPerCm
                effectiveSpeed *= min(groomedBonus, TraversalConstants.Run.FreshSnow.groomedBonusCap)
            }

            guard effectiveSpeed > TraversalConstants.Run.minViableSpeedMs else { return nil }
            return edge.attributes.lengthMeters / effectiveSpeed

        case .traverse:
            guard edge.attributes.isOpen else { return nil }
            let snowPenalty = context.freshSnowCm > TraversalConstants.Traverse.freshSnowPenaltyThresholdCm
                ? TraversalConstants.Traverse.freshSnowPenaltyMultiplier
                : 1.0
            let baseTime = edge.attributes.lengthMeters / (TraversalConstants.Traverse.baseSpeedMs * snowPenalty)
            let uphillPenalty = max(0, edge.attributes.verticalDrop) * TraversalConstants.Traverse.uphillCostSecondsPerMeter
            return baseTime + uphillPenalty
        }
    }

    // MARK: - Derived skill values

    /// Maximum run difficulty the solver will route through.
    /// Runs above this are hard-blocked (return nil from traverseTime).
    var maxRunDifficulty: RunDifficulty {
        switch skillLevel {
        case "beginner":     return .green
        case "intermediate": return .blue
        case "advanced":     return .doubleBlack
        case "expert":       return .doubleBlack
        default:             return .blue
        }
    }

    var steepPenaltyForLevel: Double {
        switch skillLevel {
        case "beginner":     return TraversalConstants.Run.Gradient.beginnerPenaltyWeight
        case "intermediate": return TraversalConstants.Run.Gradient.intermediatePenaltyWeight
        case "advanced":     return TraversalConstants.Run.Gradient.advancedPenaltyWeight
        case "expert":       return TraversalConstants.Run.Gradient.expertPenaltyWeight
        default:             return TraversalConstants.Run.Gradient.intermediatePenaltyWeight
        }
    }

    var maxGradientForLevel: Double {
        switch skillLevel {
        case "beginner":     return TraversalConstants.Run.Gradient.beginnerMaxDegrees
        case "intermediate": return TraversalConstants.Run.Gradient.intermediateMaxDegrees
        case "advanced":     return TraversalConstants.Run.Gradient.advancedMaxDegrees
        case "expert":       return TraversalConstants.Run.Gradient.expertMaxDegrees
        default:             return TraversalConstants.Run.Gradient.intermediateMaxDegrees
        }
    }

    /// Estimated lift queue wait time based on lift type and capacity.
    /// `longitude` lets us derive a deterministic resort-local hour/weekday
    /// rather than depending on the device's own timezone.
    private static func estimatedWaitTime(
        liftType: LiftType?,
        capacity: Int?,
        solveTime: Date? = nil,
        longitude: Double? = nil
    ) -> Double {
        let baseWait: Double
        switch liftType {
        case .gondola, .cableCar, .funicular: baseWait = TraversalConstants.Lift.BaseWaitSeconds.gondola
        case .chairLift:                      baseWait = TraversalConstants.Lift.BaseWaitSeconds.chairLift
        case .tBar, .platter, .jBar:          baseWait = TraversalConstants.Lift.BaseWaitSeconds.tBar
        case .dragLift, .ropeTow:             baseWait = TraversalConstants.Lift.BaseWaitSeconds.dragLift
        case .magicCarpet:                    baseWait = TraversalConstants.Lift.BaseWaitSeconds.magicCarpet
        default:                              baseWait = TraversalConstants.Lift.BaseWaitSeconds.defaultLift
        }

        // High-capacity lifts process the line faster
        var wait = baseWait
        if let cap = capacity, cap >= TraversalConstants.Lift.highCapacityThreshold {
            wait *= TraversalConstants.Lift.highCapacityWaitMultiplier
        } else if let cap = capacity, cap >= TraversalConstants.Lift.mediumCapacityThreshold {
            wait *= TraversalConstants.Lift.mediumCapacityWaitMultiplier
        }

        // Time-of-day multiplier: peak hours get longer waits
        if let time = solveTime {
            let hour = resortLocalHour(at: time, longitude: longitude)
            let todMultiplier: Double
            switch hour {
            case 8:       todMultiplier = TraversalConstants.Lift.TimeOfDayMultiplier.firstChair8am
            case 9:       todMultiplier = TraversalConstants.Lift.TimeOfDayMultiplier.earlyMorning9am
            case 10, 11:  todMultiplier = TraversalConstants.Lift.TimeOfDayMultiplier.peakMorning10to11am
            case 12:      todMultiplier = TraversalConstants.Lift.TimeOfDayMultiplier.lunch12pm
            case 13, 14:  todMultiplier = TraversalConstants.Lift.TimeOfDayMultiplier.earlyAfternoon1to2pm
            case 15:      todMultiplier = TraversalConstants.Lift.TimeOfDayMultiplier.lateAfternoon3pm
            default:      todMultiplier = TraversalConstants.Lift.TimeOfDayMultiplier.defaultMultiplier
            }
            wait *= todMultiplier

            // Weekend multiplier (1=Sunday, 7=Saturday) — using the same
            // deterministic resort-local-time basis.
            let weekday = resortLocalWeekday(at: time, longitude: longitude)
            if weekday == 1 || weekday == 7 {
                wait *= TraversalConstants.Lift.weekendWaitMultiplier
            }
        }

        return min(wait, TraversalConstants.Lift.waitTimeCap)
    }

    // MARK: - Presets (for onboarding defaults)

    static func defaultProfile(id: UUID) -> UserProfile {
        UserProfile(
            id: id,
            displayName: "",
            avatarUrl: nil,
            currentResortId: nil,
            skillLevel: "intermediate",
            speedGreen: 5.0,
            speedBlue: 8.0,
            speedBlack: 3.0,
            speedDoubleBlack: nil,
            speedTerrainPark: 4.0,
            conditionMoguls: 0.5,
            conditionUngroomed: 0.6,
            conditionIcy: 0.5,
            conditionGladed: 0.4,
            onboardingCompleted: false,
            createdAt: nil,
            updatedAt: nil
        )
    }

    mutating func applyPreset(_ level: String) {
        skillLevel = level
        switch level {
        case "beginner":
            speedGreen = 4.0; speedBlue = 2.0; speedBlack = nil; speedDoubleBlack = nil; speedTerrainPark = nil
            conditionMoguls = 0.2; conditionUngroomed = 0.3; conditionIcy = 0.3; conditionGladed = 0.0
        case "intermediate":
            // Ladder: greens are faster than blues across all tiers
            // (steeper terrain → more turns / more caution). The earlier
            // (5, 8) values inverted that on intermediate only and
            // disagreed with both the DB default and
            // `OnboardingView.presetSpeeds`. Aligned to (7, 5) to match.
            speedGreen = 7.0; speedBlue = 5.0; speedBlack = 3.0; speedDoubleBlack = nil; speedTerrainPark = 4.0
            conditionMoguls = 0.5; conditionUngroomed = 0.6; conditionIcy = 0.5; conditionGladed = 0.4
        case "advanced":
            speedGreen = 10.0; speedBlue = 8.0; speedBlack = 6.0; speedDoubleBlack = 4.0; speedTerrainPark = 6.0
            conditionMoguls = 0.8; conditionUngroomed = 0.8; conditionIcy = 0.7; conditionGladed = 0.7
        case "expert":
            speedGreen = 12.0; speedBlue = 10.0; speedBlack = 9.0; speedDoubleBlack = 7.0; speedTerrainPark = 8.0
            conditionMoguls = 1.0; conditionUngroomed = 1.0; conditionIcy = 0.85; conditionGladed = 0.9
        default: break
        }
    }

    // MARK: - CodingKeys (snake_case DB columns)

    enum CodingKeys: String, CodingKey {
        case id
        case displayName = "display_name"
        case avatarUrl = "avatar_url"
        case currentResortId = "current_resort_id"
        case skillLevel = "skill_level"
        case speedGreen = "speed_green"
        case speedBlue = "speed_blue"
        case speedBlack = "speed_black"
        case speedDoubleBlack = "speed_double_black"
        case speedTerrainPark = "speed_terrain_park"
        case conditionMoguls = "condition_moguls"
        case conditionUngroomed = "condition_ungroomed"
        case conditionIcy = "condition_icy"
        case conditionGladed = "condition_gladed"
        case maxComfortableGradientDegrees = "max_comfortable_gradient_degrees"
        case mogulTolerance = "mogul_tolerance"
        case narrowTrailTolerance = "narrow_trail_tolerance"
        case exposureTolerance = "exposure_tolerance"
        case crustConditionTolerance = "crust_condition_tolerance"
        case liveRecordingEnabled = "live_recording_enabled"
        case onboardingCompleted = "onboarding_completed"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    // MARK: - Update Payload (excludes server-managed columns)

    /// Encodable payload that omits `id`, `created_at`, and `updated_at`
    /// so we never send read-only fields to Supabase on UPDATE.
    var updatePayload: ProfileUpdatePayload {
        ProfileUpdatePayload(
            displayName: displayName,
            avatarUrl: avatarUrl,
            currentResortId: currentResortId,
            skillLevel: skillLevel,
            speedGreen: speedGreen,
            speedBlue: speedBlue,
            speedBlack: speedBlack,
            speedDoubleBlack: speedDoubleBlack,
            speedTerrainPark: speedTerrainPark,
            conditionMoguls: conditionMoguls,
            conditionUngroomed: conditionUngroomed,
            conditionIcy: conditionIcy,
            conditionGladed: conditionGladed,
            maxComfortableGradientDegrees: maxComfortableGradientDegrees,
            mogulTolerance: mogulTolerance,
            narrowTrailTolerance: narrowTrailTolerance,
            exposureTolerance: exposureTolerance,
            crustConditionTolerance: crustConditionTolerance,
            liveRecordingEnabled: liveRecordingEnabled,
            onboardingCompleted: onboardingCompleted
        )
    }
}

/// Encodable struct with only the mutable profile columns.
struct ProfileUpdatePayload: Encodable {
    var displayName: String
    var avatarUrl: String?
    var currentResortId: String?
    var skillLevel: String
    var speedGreen: Double?
    var speedBlue: Double?
    var speedBlack: Double?
    var speedDoubleBlack: Double?
    var speedTerrainPark: Double?
    var conditionMoguls: Double
    var conditionUngroomed: Double
    var conditionIcy: Double
    var conditionGladed: Double
    var maxComfortableGradientDegrees: Double?
    var mogulTolerance: Double?
    var narrowTrailTolerance: Double?
    var exposureTolerance: Double?
    var crustConditionTolerance: Double?
    var liveRecordingEnabled: Bool
    var onboardingCompleted: Bool

    enum CodingKeys: String, CodingKey {
        case displayName = "display_name"
        case avatarUrl = "avatar_url"
        case currentResortId = "current_resort_id"
        case skillLevel = "skill_level"
        case speedGreen = "speed_green"
        case speedBlue = "speed_blue"
        case speedBlack = "speed_black"
        case speedDoubleBlack = "speed_double_black"
        case speedTerrainPark = "speed_terrain_park"
        case conditionMoguls = "condition_moguls"
        case conditionUngroomed = "condition_ungroomed"
        case conditionIcy = "condition_icy"
        case conditionGladed = "condition_gladed"
        case maxComfortableGradientDegrees = "max_comfortable_gradient_degrees"
        case mogulTolerance = "mogul_tolerance"
        case narrowTrailTolerance = "narrow_trail_tolerance"
        case exposureTolerance = "exposure_tolerance"
        case crustConditionTolerance = "crust_condition_tolerance"
        case liveRecordingEnabled = "live_recording_enabled"
        case onboardingCompleted = "onboarding_completed"
    }
}
