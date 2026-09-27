//
//  UserProfile+Traversal.swift
//  PowderMeet
//
//  Routing physics for one skier profile. Keeping path-cost policy separate
//  from profile persistence, coding, and onboarding presets makes both halves
//  easier to audit without changing the public UserProfile contract.
//

import Foundation

nonisolated extension UserProfile {
    /// Single source of truth for hard run eligibility. The solver's relaxed
    /// pass calls the same function to explain a failure, so user copy cannot
    /// drift from the gates that actually rejected an edge.
    func capabilityBlockers(for edge: GraphEdge) -> [RunCapabilityBlocker] {
        guard edge.kind == .run else { return [] }
        var blockers: [RunCapabilityBlocker] = []
        let difficulty = edge.attributes.difficulty ?? .blue
        if !canTraverseRun(difficulty) {
            blockers.append(.markedDifficulty(difficulty))
        }
        if edge.attributes.hasMoguls,
           (mogulTolerance ?? conditionMoguls) <= 0 {
            blockers.append(.mogulsAvoided)
        }
        if edge.attributes.isGroomed == false, conditionUngroomed <= 0 {
            blockers.append(.ungroomedAvoided)
        }
        if edge.attributes.isGladed, conditionGladed <= 0 {
            blockers.append(.gladesAvoided)
        }
        if let explicitCap = maxComfortableGradientDegrees {
            let gradient = edge.attributes.maxGradient
            if validatedExplicitGradientLimit == nil {
                blockers.append(.invalidGradientLimit)
            } else if !gradient.isFinite || gradient <= 0 || gradient > 90 {
                // The legacy wire value 0 means either flat or unmeasured.
                // Without evidence to distinguish them it cannot satisfy an
                // explicit hard limit. This does not add a limit when unset.
                blockers.append(.gradientDataUnverified)
            } else if gradient > explicitCap {
                blockers.append(.gradientLimit(maxDegrees: Int(explicitCap.rounded())))
            }
        }
        return blockers
    }

    private var validatedExplicitGradientLimit: Double? {
        guard let cap = maxComfortableGradientDegrees,
              cap.isFinite, (0...90).contains(cap) else { return nil }
        return cap
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
    /// Deterministic local hour-of-day at the resort. The weather feed's UTC
    /// offset is authoritative because it includes daylight saving time;
    /// longitude/15 remains a deterministic legacy fallback. Neither path may
    /// read the phone's own `TimeZone.current`.
    private static func resortLocalTime(
        _ time: Date,
        utcOffsetSeconds: Int?,
        longitude: Double?
    ) -> Date {
        if let utcOffsetSeconds {
            return time.addingTimeInterval(TimeInterval(utcOffsetSeconds))
        }
        if let longitude {
            return time.addingTimeInterval(longitude / 15.0 * 3_600)
        }
        return time
    }

    private static func resortLocalHour(
        at time: Date,
        utcOffsetSeconds: Int?,
        longitude: Double?
    ) -> Int {
        utcCalendar.component(.hour, from: resortLocalTime(
            time,
            utcOffsetSeconds: utcOffsetSeconds,
            longitude: longitude
        ))
    }

    /// Fractional resort-local clock hour used for continuous queue curves.
    /// Integer-only buckets made the modeled wait drop abruptly at noon/3pm;
    /// a skier arriving one second later could then be predicted to finish the
    /// lift tens of seconds earlier, violating the FIFO assumption required by
    /// time-dependent Dijkstra. Longitude-based shifting preserves the same
    /// cross-device determinism contract as `resortLocalHour`.
    private static func resortLocalHourFraction(
        at time: Date,
        utcOffsetSeconds: Int?,
        longitude: Double?
    ) -> Double {
        let localTime = resortLocalTime(
            time,
            utcOffsetSeconds: utcOffsetSeconds,
            longitude: longitude
        )
        let components = utcCalendar.dateComponents(
            [.hour, .minute, .second, .nanosecond],
            from: localTime
        )
        let hour = Double(components.hour ?? 0)
        let minute = Double(components.minute ?? 0) / 60
        let second = Double(components.second ?? 0) / 3_600
        let nanosecond = Double(components.nanosecond ?? 0) / 3_600_000_000_000
        return hour + minute + second + nanosecond
    }

    private static func hourlyWaitMultiplier(at hour: Int) -> Double {
        switch (hour % 24 + 24) % 24 {
        case 8:       return TraversalConstants.Lift.TimeOfDayMultiplier.firstChair8am
        case 9:       return TraversalConstants.Lift.TimeOfDayMultiplier.earlyMorning9am
        case 10, 11:  return TraversalConstants.Lift.TimeOfDayMultiplier.peakMorning10to11am
        case 12:      return TraversalConstants.Lift.TimeOfDayMultiplier.lunch12pm
        case 13, 14:  return TraversalConstants.Lift.TimeOfDayMultiplier.earlyAfternoon1to2pm
        case 15:      return TraversalConstants.Lift.TimeOfDayMultiplier.lateAfternoon3pm
        default:      return TraversalConstants.Lift.TimeOfDayMultiplier.defaultMultiplier
        }
    }

    /// Linear interpolation between the existing hourly anchor values. The
    /// steepest modeled queue decline is 0.5×base over one hour; even for the
    /// capped ten-minute wait this changes by only 0.083 seconds per elapsed
    /// second, so arrival + wait remains strictly increasing (FIFO-safe).
    private static func timeOfDayWaitMultiplier(
        at time: Date,
        utcOffsetSeconds: Int?,
        longitude: Double?
    ) -> Double {
        let fractionalHour = resortLocalHourFraction(
            at: time,
            utcOffsetSeconds: utcOffsetSeconds,
            longitude: longitude
        )
        let currentHour = Int(floor(fractionalHour))
        let progress = fractionalHour - Double(currentHour)
        let current = hourlyWaitMultiplier(at: currentHour)
        let next = hourlyWaitMultiplier(at: currentHour + 1)
        return current + (next - current) * progress
    }

    /// Continuous weather slowdown for the moving lift, not its queue. The
    /// previous threshold jumps changed a six-minute ride by minutes when the
    /// forecast crossed 60/80 km/h by a fraction, violating the FIFO contract
    /// used by time-dependent Dijkstra. Operational feeds still close a lift;
    /// this curve only models slower running while it remains open.
    private static func liftWindRideMultiplier(windSpeedKmh: Double) -> Double {
        let wind = max(0, windSpeedKmh)
        let slight = TraversalConstants.Lift.windSlightSlowKph
        let reduced = TraversalConstants.Lift.windReducedSpeedKph
        let hold = TraversalConstants.Lift.windHoldThresholdKph

        func interpolate(
            _ value: Double,
            from lower: Double,
            to upper: Double,
            lowerMultiplier: Double,
            upperMultiplier: Double
        ) -> Double {
            let fraction = max(0, min(1, (value - lower) / (upper - lower)))
            return lowerMultiplier + (upperMultiplier - lowerMultiplier) * fraction
        }

        if wind <= slight { return 1 }
        if wind <= reduced {
            return interpolate(
                wind,
                from: slight,
                to: reduced,
                lowerMultiplier: 1,
                upperMultiplier: 1.2
            )
        }
        if wind <= hold {
            return interpolate(
                wind,
                from: reduced,
                to: hold,
                lowerMultiplier: 1.2,
                upperMultiplier: 1.5
            )
        }
        return interpolate(
            wind,
            from: hold,
            to: hold + 40,
            lowerMultiplier: 1.5,
            upperMultiplier: 3
        )
    }

    /// Same approach for weekday (1=Sunday, 7=Saturday).
    private static func resortLocalWeekday(
        at time: Date,
        utcOffsetSeconds: Int?,
        longitude: Double?
    ) -> Int {
        utcCalendar.component(.weekday, from: resortLocalTime(
            time,
            utcOffsetSeconds: utcOffsetSeconds,
            longitude: longitude
        ))
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
    /// When `ignoreSkillGates` is true, marked difficulty, explicit terrain
    /// AVOID choices, and the personal gradient cap are skipped (open/closed
    /// status is still respected, gradient still penalizes via cost).
    /// Used by the solver to detect when a "no path" failure was
    /// purely skill-gated, so the user gets the right
    /// `SolveFailureReason.skillGatedPath` copy instead of a generic
    /// "no path" message.
    ///
    /// `arrivalTimeOffsetSeconds` lets Dijkstra pass the cumulative path time
    /// so time-dependent costs are evaluated when the skier reaches this edge,
    /// not when the solve began. This drives lift hours/queues and aspect-based
    /// sun/slush exposure from one consistent arrival clock.
    /// Default 0 preserves the prior behaviour for callers that don't
    /// need time-dependent wait (currently only the route-narrative
    /// path; the solver passes the real cumulative offset).
    func traverseTime(
        for edge: GraphEdge,
        context: TraversalContext,
        ignoreSkillGates: Bool = false,
        arrivalTimeOffsetSeconds: Double = 0,
        remainingFraction: Double = 1,
        previousEdge: GraphEdge? = nil
    ) -> Double? {
        let routeFraction = max(0, min(1, remainingFraction))
        // A fully completed prefix is no longer part of the route. Evaluate
        // it before closure, ability, or lift-hour gates so a status change
        // behind the skier cannot invalidate the still-actionable suffix.
        if routeFraction == 0 { return 0 }
        let edgeArrivalTime = context.solveTime.map {
            $0.addingTimeInterval(arrivalTimeOffsetSeconds)
        }
        let edgeWeather = context.weather(at: edgeArrivalTime)
        switch edge.kind {
        case .lift:
            guard edge.attributes.isOpen else { return nil }
            let continuingRide = LiftRideContinuation.isContinuation(from: previousEdge, to: edge)

            // Lift hours gating: only close lifts during clearly off-hours.
            // Most resorts operate 8:30am–4pm but some run until 9pm (night skiing).
            // Use a conservative window so we never accidentally block all lifts.
            // Time-dependent: use the *arrival* time (solveTime + cumulative
            // path traverse time so far). A lift you'll reach in 14 minutes
            // and 5pm closes 3 minutes from now should not be considered
            // open just because it's open right now.
            if routeFraction >= 1, !continuingRide, let time = edgeArrivalTime {
                let hour = Self.resortLocalHourFraction(
                    at: time,
                    utcOffsetSeconds: context.utcOffsetSeconds,
                    longitude: context.longitude
                )
                if hour < Double(context.liftOpenHour)
                    || hour >= Double(context.liftCloseHour) {
                    return nil
                }
            }

            let rideTime = edge.attributes.rideTimeSeconds ?? TraversalConstants.Lift.fallbackRideTimeSeconds

            // Use real wait time from live data, then the canonical queue
            // baseline for the resort-local arrival day, then the heuristic.
            // `waitTimeMinutes` has no capture-time stamp in EdgeAttributes,
            // so treating it as truth leaves us exposed to stale feeds
            // (cached snapshot from hours ago). Two guards:
            //   1. Sanity-clamp: any value outside [0, 60] is almost
            //      certainly a malformed or stale sample — fall back.
            //   2. Heuristic backstop: if the heuristic disagrees by more
            //      than a factor of 3 AND we're inside peak hours, blend
            //      toward heuristic so a stale 0-min reading at 11am
            //      doesn't silently erase the real queue.
            let chargesQueue = edge.attributes.chargesLiftWait != false
            let waitTime: Double
            // Heuristic uses the *arrival time*, not solve time, so
            // a lift you'll reach during the 10-11am peak is costed
            // as peak even when the solve runs at 9:50am, and
            // mid-afternoon arrivals get the correct lower-traffic
            // multiplier even when the solve runs at noon.
            let heuristicWait = chargesQueue
                ? Self.estimatedWaitTime(
                    liftType: edge.attributes.liftType,
                    capacity: edge.attributes.liftCapacity,
                    solveTime: edgeArrivalTime,
                    utcOffsetSeconds: context.utcOffsetSeconds,
                    longitude: context.longitude
                )
                : 0
            let canonicalWaitMinutes: Double? = {
                guard let time = edgeArrivalTime else {
                    return edge.attributes.weekdayWaitMinutes
                        ?? edge.attributes.weekendWaitMinutes
                }
                let weekday = Self.resortLocalWeekday(
                    at: time,
                    utcOffsetSeconds: context.utcOffsetSeconds,
                    longitude: context.longitude
                )
                let isWeekend = weekday == 1 || weekday == 7
                return isWeekend
                    ? (edge.attributes.weekendWaitMinutes
                        ?? edge.attributes.weekdayWaitMinutes)
                    : (edge.attributes.weekdayWaitMinutes
                        ?? edge.attributes.weekendWaitMinutes)
            }()
            let reportedWaitMinutes: Double? = {
                if let live = edge.attributes.waitTimeMinutes,
                   live >= 0, live <= 60 {
                    return live
                }
                if let canonical = canonicalWaitMinutes,
                   canonical >= 0, canonical <= 60 {
                    return canonical
                }
                return nil
            }()
            if !chargesQueue {
                waitTime = 0
            } else if let reportedWaitMinutes {
                let reportedSeconds = reportedWaitMinutes * 60
                if heuristicWait > 0,
                   (reportedSeconds * 3 < heuristicWait
                    || reportedSeconds > heuristicWait * 3) {
                    waitTime = 0.7 * reportedSeconds + 0.3 * heuristicWait
                } else {
                    waitTime = reportedSeconds
                }
            } else {
                waitTime = heuristicWait
            }

            // Resort close is a last-loading deadline, not a requirement that
            // every chair already be back at the terminal. A skier may finish
            // riding after close, but must be through the entry queue before
            // it. This also keeps a nominal 15:59 arrival with a five-minute
            // wait from becoming an impossible 16:04 boarding.
            if routeFraction >= 1,
               chargesQueue,
               waitTime > 0,
               let time = edgeArrivalTime {
                let boardingHour = Self.resortLocalHourFraction(
                    at: time.addingTimeInterval(waitTime),
                    utcOffsetSeconds: context.utcOffsetSeconds,
                    longitude: context.longitude
                )
                if boardingHour >= Double(context.liftCloseHour) {
                    return nil
                }
            }

            let liftWindFactor = Self.liftWindRideMultiplier(
                windSpeedKmh: edgeWeather.windSpeedKmh
            )

            // A skier already on a lift paid its queue before the current GPS
            // fix. Fractional routing charges only the remaining ride; a
            // node-origin route still charges the full queue and ride.
            let applicableWait = routeFraction < 1 ? 0 : waitTime
            return rideTime * routeFraction * liftWindFactor + applicableWait

        case .run:
            guard edge.attributes.isOpen else { return nil }
            let difficulty = edge.attributes.difficulty ?? .blue

            // Eligibility is explicit rather than inferred from enum ordering.
            // Terrain parks are a parallel marked-terrain category, not
            // "harder than double black"; the former Comparable gate therefore
            // blocked Advanced skiers from parks while allowing them onto
            // double blacks. A missing per-category speed also means the skier
            // has not said they can/will ski that terrain — never invent one.
            if !ignoreSkillGates, !capabilityBlockers(for: edge).isEmpty {
                return nil
            }

            // Speed: trusted measured per-edge pace wins over broad difficulty
            // defaults. `context.learnedPace(for:)` first isolates the current
            // ski (with an honest neutral fallback), then accepts the current
            // condition bucket or the explicit `default` bucket. Selection is
            // intentionally anchored to observed now: a forecast bucket change
            // must adjust the learned baseline, not discard personalization.
            let learnedPace = context.learnedPace(for: edge)
            let learnedObservation = learnedPace?.observation
            let baseSpeed: Double
            if let observation = learnedObservation {
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

            // Canonical graphs carry a distinct 0...1 obstacle-density signal
            // for rocks, trees, cornices, and other technical features. It was
            // previously validated and fingerprinted but never consumed, so a
            // clean blue and a rock-studded blue could receive the same cost.
            // Reuse the skier's existing technical-terrain preferences rather
            // than inventing a non-persisted slider: ungroomed confidence is
            // the strongest signal, glade comfort captures object proximity,
            // and exposure tolerance captures consequence sensitivity.
            if let density = edge.attributes.obstacleDensity, density > 0 {
                let exposureComfort = exposureTolerance
                    ?? (conditionUngroomed + conditionGladed) / 2
                let technicalComfort = max(0, min(1,
                    0.45 * conditionUngroomed
                    + 0.35 * conditionGladed
                    + 0.20 * exposureComfort
                ))
                let obstacleFactor = 1 - density * (1 - technicalComfort)
                trailPenalties.append(dampen(obstacleFactor))
            }
            // Only apply icy-condition penalty when temperature actually
            // indicates ice. Gate on edgeTemp < -3 (same threshold as the
            // environmental ice penalty below). Without this gate the penalty
            // fires on every run for every non-expert skier, even on warm days.
            let edgeTempForIce: Double = {
                let midEle = edge.attributes.midpointElevation
                guard let ele = midEle, ele > 0 else { return edgeWeather.temperatureCelsius }
                return context.temperatureAt(elevationM: ele, at: edgeArrivalTime)
            }()
            let iceLikelihood = max(0, min(
                1,
                (TraversalConstants.Run.iceConditionThresholdC - edgeTempForIce) / 4
            ))
            if conditionIcy < 1.0 && iceLikelihood > 0 {
                let icyAbility = TraversalConstants.Run.iceAbilityBaseline
                    + TraversalConstants.Run.iceAbilityScaleFactor * conditionIcy
                let fullPenalty = dampen(icyAbility)
                trailPenalties.append(1 - iceLikelihood * (1 - fullPenalty))
            }

            // Gradient penalty — continuous ramp starting at 90% of the
            // skier's comfort cap. If `maxComfortableGradientDegrees` is
            // set (calibrated per-user) it takes priority over the bucketed
            // level cap. Below the ramp start, no penalty. At the cap,
            // penalty is at full strength; beyond, it keeps scaling linearly.
            let gradient = edge.attributes.maxGradient
            let comfortCap = validatedExplicitGradientLimit ?? maxGradientForLevel
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

            let arrivalSnow = context.effectiveFreshSnowCm(at: edgeArrivalTime)

            // Refrozen crust — chunky/hard surface. Mapped from either the
            // explicit surface estimate or cold-after-fresh-snow conditions.
            let crustLikelihood: Double = {
                if edge.attributes.estimatedSurfaceCondition == "crust" { return 1 }
                guard arrivalSnow > 2,
                      edge.attributes.isGroomed != true else { return 0 }
                return max(0, min(1, (-3 - edgeTempForIce) / 4))
            }()
            if crustLikelihood > 0, let tol = crustConditionTolerance {
                let fullPenalty = dampen(tol)
                trailPenalties.append(1 - crustLikelihood * (1 - fullPenalty))
            }

            // A measured per-edge pace already contains this edge's static
            // terrain and the skier's response to it. Apply the synthetic
            // terrain model only when routing from a broad difficulty preset;
            // otherwise moguls/gradient/etc. would be counted twice.
            let trailModifier = learnedPace == nil
                ? max(
                    TraversalConstants.Run.trailModifierFloor,
                    Self.combinedModifier(trailPenalties)
                )
                : 1.0

            /// Synthetic weather multiplier for one instant. Learned exact-
            /// condition pace uses the ratio arrival/current; unattributed
            /// pace and broad difficulty presets use the arrival value once.
            /// Keeping this calculation centralized prevents the forecast path
            /// from double-counting conditions already present in measured pace.
            func environmentalSpeedMultiplier(
                weather: TraversalContext.WeatherSnapshot,
                at time: Date?
            ) -> Double {
                var penalties: [Double] = []
                let snow = context.effectiveFreshSnowCm(at: time)
                let edgeTemp: Double = {
                    let midEle = edge.attributes.midpointElevation
                    guard let ele = midEle, ele > 0 else {
                        return weather.temperatureCelsius
                    }
                    let deltaM = ele - context.stationElevationM
                    return weather.temperatureCelsius + deltaM * (-6.5 / 1_000)
                }()

                if let time, let lat = context.latitude {
                    let exposure = SunExposureCalculator.exposure(
                        for: edge,
                        at: time,
                        resortLatitude: lat,
                        resortLongitude: context.longitude,
                        temperatureC: edgeTemp,
                        cloudCoverPercent: weather.cloudCoverPercent
                    )
                    let factor = SunExposureCalculator.routingSpeedMultiplier(
                        exposure: exposure,
                        temperatureC: edgeTemp
                    )
                    if factor < 1 { penalties.append(factor) }
                }

                if !edge.attributes.isGladed {
                    let threshold = TraversalConstants.Run.Wind.exposedThresholdKph
                    if weather.windSpeedKmh > threshold {
                        penalties.append(1 / (1 + (weather.windSpeedKmh - threshold)
                            * TraversalConstants.Run.Wind.penaltyCoefficientPerKph))
                    }
                }

                let visibilityThreshold = TraversalConstants.Run.Visibility.penaltyThresholdKm
                if weather.visibilityKm < visibilityThreshold {
                    let steepMultiplier = gradient
                        > TraversalConstants.Run.Visibility.steepGradientDegrees
                        ? TraversalConstants.Run.Visibility.steepMultiplier
                        : 1
                    penalties.append(1 / (1 + (visibilityThreshold - weather.visibilityKm)
                        * TraversalConstants.Run.Visibility.penaltyCoefficientPerKm
                        * steepMultiplier))
                }

                if snow > TraversalConstants.Run.FreshSnow.ungroomedThresholdCm,
                   edge.attributes.isGroomed != true {
                    let penaltyPerCm: Double
                    switch skillLevel {
                    case "expert": penaltyPerCm = TraversalConstants.Run.FreshSnow.expertPenaltyPerCm
                    case "advanced": penaltyPerCm = TraversalConstants.Run.FreshSnow.advancedPenaltyPerCm
                    case "intermediate": penaltyPerCm = TraversalConstants.Run.FreshSnow.intermediatePenaltyPerCm
                    default: penaltyPerCm = TraversalConstants.Run.FreshSnow.beginnerPenaltyPerCm
                    }
                    let uncertainty = edge.attributes.isGroomed == nil ? 0.5 : 1
                    penalties.append(1 / (1 + snow * penaltyPerCm * uncertainty))
                }

                let iceFactor = TraversalConstants.Run.Ice.speedFactor(at: edgeTemp)
                if iceFactor < 1 { penalties.append(iceFactor) }

                var multiplier = max(
                    TraversalConstants.Run.envModifierFloor,
                    Self.combinedModifier(penalties)
                )
                if edge.attributes.isGroomed == true, snow > 0 {
                    multiplier *= min(
                        1 + snow * TraversalConstants.Run.FreshSnow.groomedBonusPerCm,
                        TraversalConstants.Run.FreshSnow.groomedBonusCap
                    )
                }
                return multiplier
            }

            let arrivalEnvironment = environmentalSpeedMultiplier(
                weather: edgeWeather,
                at: edgeArrivalTime
            )
            let envModifier: Double
            switch learnedPace?.conditionsMatch {
            case .exact:
                let currentEnvironment = environmentalSpeedMultiplier(
                    weather: context.weather(at: nil),
                    at: context.solveTime
                )
                envModifier = currentEnvironment > 0
                    ? arrivalEnvironment / currentEnvironment
                    : 1
            case .unattributed, .none:
                envModifier = arrivalEnvironment
            }

            // ── Final effective speed ──
            var effectiveSpeed = baseSpeed * trailModifier * envModifier

            // Equipment is an ETA-only modifier. Every closure, ability,
            // glade, and lift-hours guard above has already run, so a ski
            // choice can never turn ineligible terrain into a valid edge.
            if let equipment = context.equipment {
                let arrivalEquipment = equipment.speedMultiplier(
                    for: edge,
                    freshSnowCm: arrivalSnow
                )
                if learnedObservation?.equipmentKey != equipment.observationEquipmentKey {
                    effectiveSpeed *= arrivalEquipment
                } else if learnedPace?.conditionsMatch == .exact {
                    // Current-condition measured pace already includes these
                    // skis. Apply only their modeled response to accumulating
                    // snow, anchored to the same instant as the weather ratio.
                    let currentEquipment = equipment.speedMultiplier(
                        for: edge,
                        freshSnowCm: context.effectiveFreshSnowCm(at: nil)
                    )
                    effectiveSpeed *= arrivalEquipment / currentEquipment
                }
                // Unattributed same-ski history has no observed snow baseline;
                // do not invent one or reapply an absolute equipment bonus.
            }

            guard effectiveSpeed > TraversalConstants.Run.minViableSpeedMs else { return nil }
            return edge.attributes.lengthMeters * routeFraction / effectiveSpeed

        case .traverse:
            guard edge.attributes.isOpen else { return nil }
            let arrivalSnow = context.effectiveFreshSnowCm(at: edgeArrivalTime)
            let snowPenalty = TraversalConstants.Traverse.speedFactor(
                freshSnowCm: arrivalSnow
            )
            let baseTime = edge.attributes.lengthMeters * routeFraction
                / (TraversalConstants.Traverse.baseSpeedMs * snowPenalty)
            let uphillPenalty = max(0, edge.attributes.verticalDrop) * routeFraction
                * TraversalConstants.Traverse.uphillCostSecondsPerMeter
            return baseTime + uphillPenalty
        }
    }


    /// Estimated lift queue wait time based on lift type and capacity.
    /// `longitude` lets us derive a deterministic resort-local hour/weekday
    /// rather than depending on the device's own timezone.
    private static func estimatedWaitTime(
        liftType: LiftType?,
        capacity: Int?,
        solveTime: Date? = nil,
        utcOffsetSeconds: Int? = nil,
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
            wait *= timeOfDayWaitMultiplier(
                at: time,
                utcOffsetSeconds: utcOffsetSeconds,
                longitude: longitude
            )

            // Weekend multiplier (1=Sunday, 7=Saturday) — using the same
            // deterministic resort-local-time basis.
            let weekday = resortLocalWeekday(
                at: time,
                utcOffsetSeconds: utcOffsetSeconds,
                longitude: longitude
            )
            if weekday == 1 || weekday == 7 {
                wait *= TraversalConstants.Lift.weekendWaitMultiplier
            }
        }

        return min(wait, TraversalConstants.Lift.waitTimeCap)
    }

}
