//
//  SolverConstants.swift
//  PowderMeet
//
//  Centralized tunable constants for the meeting-point solver, traversal-time
//  calculations, and condition scoring. Extracted as pure refactor — values
//  identical to previous inline literals. Changes here affect solver output,
//  so treat every edit as a behavior change and verify determinism.
//

import Foundation

// MARK: - Debug Logging

/// Gated logging for the solver. No-op in Release builds; active under DEBUG.
/// Use an autoclosure so string interpolation is skipped entirely in Release.
nonisolated enum SolverLog {
    static func debug(_ message: @autoclosure () -> String) {
        #if DEBUG
        print(message())
        #endif
    }
}

// MARK: - Solver (routing + scoring + alternates)

nonisolated enum SolverConstants {
    /// Determinism: bounded quantization so two devices compute identical results
    /// without making time-dependent mountain operations materially stale.
    enum Determinism {
        /// Solve time rounded down to one-minute buckets. The previous
        /// quarter-hour bucket could evaluate a 15:59 route as 15:45 and admit
        /// a lift after last chair. One minute preserves useful cache sharing;
        /// the post-meet handoff buffer covers its remaining sub-minute error.
        static let timeBucketSeconds: Double = 60
        /// Temperature rounded to 0.5 °C steps.
        static let tempQuantizationCelsius: Double = 0.5
        /// Elevation rounded to 10 m steps.
        static let elevQuantizationMeters: Double = 10
        /// Wind speed rounded to 5 km/h steps.
        static let windQuantizationKph: Double = 5.0
        /// Visibility rounded to 0.5 km steps.
        static let visQuantizationKm: Double = 0.5
    }

    /// Scoring: ski-specific arrival reliability weights.
    enum Scoring {
        /// Soft wait-time penalty α. A one-minute wait mismatch counts as
        /// 36 seconds of reliability cost: enough to reject a nominally
        /// faster but obviously lopsided meeting without requiring a hard
        /// cutoff that could eliminate the only reachable safe point.
        static let waitPenaltyAlpha: Double = 0.6

        /// Severe cold, wind, and low visibility make arrival imbalance more
        /// consequential at an exposed stopping point. The base objective is
        /// unchanged in ordinary weather; only the hazard portion is scaled by
        /// the rendezvous kind's likely shelter. This remains a soft cost — it
        /// never changes edge eligibility or manufactures a route.
        static func weatherAwareWaitPenaltyAlpha(
            temperatureCelsius: Double,
            windSpeedKmh: Double,
            visibilityKm: Double,
            rendezvousKind: RendezvousPoint.Kind
        ) -> Double {
            func unit(_ value: Double) -> Double { max(0, min(1, value)) }

            // Begin increasing below -8 C, above 20 km/h, and below 2 km.
            // Saturation points represent genuinely uncomfortable exposure,
            // not normal winter weather.
            let coldHazard = unit((-8 - temperatureCelsius) / 17)
            let windHazard = unit((windSpeedKmh - 20) / 45)
            let visibilityHazard = unit((2 - visibilityKm) / 1.5)
            let exposure: Double = switch rendezvousKind {
            case .lodge: 0.15
            case .patrol: 0.30
            case .signedMeetingArea: 0.60
            case .liftBase: 1.00
            case .midStation: 1.10
            }
            let hazardCost = exposure * (
                0.45 * coldHazard
                    + 0.35 * windHazard
                    + 0.15 * visibilityHazard
            )
            return min(1.5, waitPenaltyAlpha + hazardCost)
        }
        /// Risk weight β on joint path standard deviation.
        /// Score = max(tA,tB) + α|tA-tB| + β·sqrt(varA+varB).
        /// 0.5 makes a 60-second combined stddev cost 30 seconds of
        /// "score", comparable to the soft wait-penalty and secondary
        /// factor scales — paths with predictable times pull ahead of
        /// equally-fast paths whose worst case is bad without
        /// overwhelming the deterministic mean.
        static let cvarBeta: Double = 0.5

        /// A poorly identified stop costs up to 90 score-seconds. This makes
        /// two otherwise-close options prefer the point both phones can name
        /// and render confidently, while a meaningfully faster safe point can
        /// still win.
        static let rendezvousConfidencePenaltySeconds: Double = 90

        /// Space, sightline, and recognisability cost up to 120 score-seconds.
        /// At common derived lift bases (quality ≈0.85–0.95), this is only a
        /// 6–18 second nudge; it becomes decisive for an explicitly poor stop.
        static let rendezvousQualityPenaltySeconds: Double = 120

        /// Post-meet shared-lap quality influences at most 45 score-seconds.
        /// Dead-end lift bases pay the full cost; a minimally useful shared run
        /// gets partial credit; a substantial shared lap can erase it. This is
        /// deliberately soft, so a clearly faster safe stop can still win.
        static let sharedContinuationPenaltySeconds: Double = 45

        /// Normal chair access should not make a strong lap look poor. Only
        /// time beyond eight minutes to the first downhill edge reduces shared
        /// continuation utility, ramping to its cap over the next 15 minutes.
        static let sharedDownhillAccessGraceSeconds: Double = 8 * 60
        static let sharedDownhillAccessPenaltyWindowSeconds: Double = 15 * 60
        static let sharedDownhillAccessMaximumUtilityPenalty: Double = 0.25

        /// Once terrain is legal, modeled caution from both profiles,
        /// conditions, learned pace, and selected skis may reduce immediate-lap
        /// utility by at most 0.20. Safety and arrival objectives remain above
        /// this soft preference.
        static let sharedTerrainFitMaximumUtilityPenalty: Double = 0.20

        /// A rendezvous that unlocks several genuinely useful shared descents
        /// is a better ski hub than an otherwise identical one-run dead end.
        /// Keep this below the terrain-fit and access terms: variety is a
        /// tie-breaker, never a reason to accept a materially slower meetup.
        static let sharedRunVarietyMaximumUtilityBonus: Double = 0.08
        static let sharedRunVarietyRelativeUtilityWindow: Double = 0.20
        static let sharedRunOptionMinimumUtility: Double = 0.20
        static let sharedRunOptionMinimumTerrainFit: Double = 0.70

        /// Two people do not identify each other, stop, regroup, and enter a
        /// lift maze at the exact instant the later route ETA reaches zero.
        /// Post-meet continuation feasibility advances the operational clock
        /// by this small handoff interval before checking weather, queues, and
        /// last chair. It is not added to either accepted approach ETA.
        static let sharedMeetupHandoffSeconds: Double = 90

        /// Maximum non-dominated (mean time, time variance) path labels kept
        /// at one graph node. A single shortest-path label can discard a
        /// slightly slower but dramatically more dependable approach before
        /// rendezvous scoring ever sees it. Eight preserves the useful mobile
        /// Pareto frontier on resort graphs while bounding memory and work.
        static let maxParetoLabelsPerNode: Int = 8

        /// A slower path may remain on the Pareto frontier when it buys a
        /// meaningful reduction in ETA uncertainty, but a meetup must never
        /// turn that into a scenic detour merely to consume another skier's
        /// wait. Exact pair selection therefore considers only approaches
        /// within this bounded mean-time window of that skier's fastest
        /// legal path. The larger of 30 seconds or 15% handles both short
        /// pod connections and long cross-mountain routes.
        static let dependablePathMaximumExtraSeconds: Double = 30
        static let dependablePathMaximumExtraFraction: Double = 0.15

        /// Route instructions are actions a skier must recognize at speed.
        /// Prefer fewer canonical trail/lift changes only when the dependable
        /// alternatives are close. This cost never enters displayed ETA and is
        /// capped below a minute so it cannot justify a material time detour.
        static let routeActionTransitionPenaltySeconds: Double = 8
        static let routeSimplicityMaximumPenaltySeconds: Double = 32

        /// Conservative conversion from uncertain along-network position to
        /// ETA uncertainty. Two metres per second approximates cautious skiing
        /// or skating near junctions; it widens confidence without changing the
        /// mean route time.
        static let positionUncertaintySpeedMetersPerSecond: Double = 2

        /// One-sided normal quantile used when a route must meet a hard lift
        /// loading deadline. A lift is eligible only when the skier can clear
        /// its entry gate by last chair at the P90 approach-arrival estimate.
        /// This affects deadline feasibility, not the displayed mean ETA, and
        /// prevents a nominally catchable but statistically fragile lift from
        /// becoming the only route to a meetup.
        static let liftCatchConfidenceZ: Double = 1.2815515655446004
    }

    /// Geographic diversity for alternate meeting points.
    enum Alternates {
        /// Minimum squared coordinate distance (degrees²) between alternates — ~150m at mid-latitude.
        /// Legacy; retained for any callers that still reference the
        /// degrees² heuristic. `pairwiseDistanceLadderMeters` (below)
        /// is the canonical, haversine-based diversity gate now.
        static let minDistSqDegrees: Double = 0.00000203
        /// Maximum alternate count for the two-skier solver. The solver may
        /// return fewer: meaningful spatial/route diversity is more valuable
        /// than padding the carousel with near-duplicate stops.
        static let twoSkierAlternateCount: Int = 4
        /// Count of alternates for the N-skier solver.
        static let nSkierAlternateCount: Int = 3
        /// Progressive minimum-haversine-distance ladder (metres)
        /// between alternates AND between each alternate and the
        /// primary meeting node. `diverseAlternates` walks the ladder
        /// strict-to-loose: try to fill all slots at 350 m apart;
        /// if too few candidates qualify, relax to 200, 100, then 0
        /// (no haversine gate, lift-cluster only). The first rung that
        /// produces two useful choices wins; it never relaxes merely to fill
        /// all four slots. If clustering yields none, the solver exposes at
        /// most one score-ranked fallback instead of a row of duplicate pins.
        /// Lift-zone + 150 m grid clustering stays in place at every rung.
        ///
        /// 350 m is roughly the width of a moderate ski trail
        /// corridor: alternates spaced this far apart will read as
        /// genuinely different spots on the map even without zooming
        /// in. Tune from `SolverAlternateClusteringTests` CSV output.
        static let pairwiseDistanceLadderMeters: [Double] = [350, 200, 100, 0]
    }
}

// MARK: - Traversal time (per-edge cost model)

nonisolated enum TraversalConstants {
    /// Lift-specific constants.
    enum Lift {
        /// Close lifts strictly before this hour (7am).
        static let minSafeHour: Int = 7
        /// Close lifts at or after this hour (9pm).
        static let maxSafeHour: Int = 21
        /// Fallback ride time when edge has no rideTimeSeconds (6 min).
        static let fallbackRideTimeSeconds: Double = 360
        /// Down-lift penalty multiplier (1.2x ride time if riding down).
        static let downRideMultiplier: Double = 1.2

        /// Wind thresholds for progressive lift speed penalties.
        static let windHoldThresholdKph: Double = 80
        static let windReducedSpeedKph: Double = 60
        static let windSlightSlowKph: Double = 40

        /// High-capacity lifts (pph >= threshold) get shorter waits.
        static let highCapacityThreshold: Int = 6
        static let highCapacityWaitMultiplier: Double = 0.7
        static let mediumCapacityThreshold: Int = 4
        static let mediumCapacityWaitMultiplier: Double = 0.85

        /// Weekend wait multiplier (Saturday + Sunday).
        static let weekendWaitMultiplier: Double = 1.4
        /// Upper bound on wait time (seconds; 10 min).
        static let waitTimeCap: Double = 600

        enum BaseWaitSeconds {
            static let gondola: Double = 180
            static let chairLift: Double = 90
            static let tBar: Double = 45
            static let dragLift: Double = 30
            static let magicCarpet: Double = 15
            static let defaultLift: Double = 90
        }

        /// Time-of-day wait multipliers (by hour of day).
        enum TimeOfDayMultiplier {
            static let firstChair8am: Double = 0.5
            static let earlyMorning9am: Double = 0.8
            static let peakMorning10to11am: Double = 1.5
            static let lunch12pm: Double = 1.2
            static let earlyAfternoon1to2pm: Double = 1.3
            static let lateAfternoon3pm: Double = 0.9
            static let defaultMultiplier: Double = 1.0
        }
    }

    /// Run-specific constants (downhill skiing segments).
    enum Run {
        /// Fallback speed when profile has no speed for this difficulty (m/s).
        static let fallbackSpeedMs: Double = 1.5
        /// Below this base speed, skier is cautious → reduce condition penalties.
        static let skillDampenThresholdMs: Double = 5.0
        /// Dampening factor applied when base speed below threshold (0.7 = 30% reduction).
        static let skillDampenFactor: Double = 0.7
        /// Temperature above which ice-condition penalties don't apply (warm enough).
        static let iceConditionThresholdC: Double = -3
        /// Skier's ice ability baseline (if conditionIcy flag unset).
        static let iceAbilityBaseline: Double = 0.7
        /// Ice ability scale factor (how much conditionIcy coefficient matters).
        static let iceAbilityScaleFactor: Double = 0.3
        /// Minimum viable effective speed (m/s) — below this, edge traversal fails.
        static let minViableSpeedMs: Double = 0.1

        /// Penalty floors (hierarchical): higher = less severe maximum slowdown.
        /// Terrain-only penalty can't slow skier more than 65% (floor 0.35).
        static let trailModifierFloor: Double = 0.35
        /// Weather-only penalty can't slow skier more than 40% (floor 0.60).
        static let envModifierFloor: Double = 0.60
        /// Combined penalty can't slow skier more than 4x (floor 0.25).
        static let combinedModifierFloor: Double = 0.25

        /// Gradient penalty denominator: overage (degrees above skill cap) ÷ denom.
        static let gradientPenaltyDenom: Double = 90.0
        /// Gradient penalty floor (minimum speed factor from steepness).
        static let gradientPenaltyMin: Double = 0.3

        enum Gradient {
            static let beginnerMaxDegrees: Double = 15
            static let intermediateMaxDegrees: Double = 25
            static let advancedMaxDegrees: Double = 35
            static let expertMaxDegrees: Double = 45
            static let beginnerPenaltyWeight: Double = 0.8
            static let intermediatePenaltyWeight: Double = 0.6
            static let advancedPenaltyWeight: Double = 0.4
            static let expertPenaltyWeight: Double = 0.2
        }

        enum Wind {
            /// Skier wind exposure starts at 30 km/h.
            static let exposedThresholdKph: Double = 30
            /// Wind penalty coefficient per km/h above threshold.
            static let penaltyCoefficientPerKph: Double = 0.01
        }

        enum Visibility {
            /// Visibility penalty starts below 5 km.
            static let penaltyThresholdKm: Double = 5
            /// Above this gradient, visibility penalty is doubled.
            static let steepGradientDegrees: Double = 25
            /// Multiplier for steep-run visibility penalty.
            static let steepMultiplier: Double = 1.5
            /// Penalty coefficient per km below threshold.
            static let penaltyCoefficientPerKm: Double = 0.05
        }

        enum FreshSnow {
            /// Fresh snow threshold for ungroomed-run penalty (cm).
            static let ungroomedThresholdCm: Double = 5
            /// Per-cm penalty coefficient, by skill level.
            static let expertPenaltyPerCm: Double = 0.005
            static let advancedPenaltyPerCm: Double = 0.012
            static let intermediatePenaltyPerCm: Double = 0.025
            static let beginnerPenaltyPerCm: Double = 0.04
            /// Groomed-run bonus: coefficient per cm 24h snow.
            static let groomedBonusPerCm: Double = 0.002
            /// Cap on groomed-run bonus (6% max speedup).
            static let groomedBonusCap: Double = 1.06
        }

        enum Ice {
            /// Very cold: -15°C or colder → 0.80x speed.
            static let veryColdThresholdC: Double = -15
            static let veryColdSpeedFactor: Double = 0.80
            /// Cold: -8°C or colder → 0.85x speed.
            static let coldThresholdC: Double = -8
            static let coldSpeedFactor: Double = 0.85
            /// Cool: -3°C or colder → 0.95x speed.
            static let coolThresholdC: Double = -3
            static let coolSpeedFactor: Double = 0.95

            /// Linear cold-snow glide curve through the established anchors.
            /// The prior bucket comparisons jumped by 5–10% at exact forecast
            /// temperatures and could violate time-dependent FIFO routing.
            static func speedFactor(at temperatureC: Double) -> Double {
                func interpolate(
                    _ value: Double,
                    lower: Double,
                    upper: Double,
                    lowerFactor: Double,
                    upperFactor: Double
                ) -> Double {
                    let fraction = max(0, min(1, (value - lower) / (upper - lower)))
                    return lowerFactor + (upperFactor - lowerFactor) * fraction
                }

                if temperatureC <= veryColdThresholdC { return veryColdSpeedFactor }
                if temperatureC <= coldThresholdC {
                    return interpolate(
                        temperatureC,
                        lower: veryColdThresholdC,
                        upper: coldThresholdC,
                        lowerFactor: veryColdSpeedFactor,
                        upperFactor: coldSpeedFactor
                    )
                }
                if temperatureC <= coolThresholdC {
                    return interpolate(
                        temperatureC,
                        lower: coldThresholdC,
                        upper: coolThresholdC,
                        lowerFactor: coldSpeedFactor,
                        upperFactor: coolSpeedFactor
                    )
                }
                return interpolate(
                    temperatureC,
                    lower: coolThresholdC,
                    upper: 0,
                    lowerFactor: coolSpeedFactor,
                    upperFactor: 1
                )
            }
        }
    }

    /// Traverse-specific constants (flat connector segments walked/skated).
    enum Traverse {
        /// Below this amount a packed connector retains its baseline speed.
        static let freshSnowPenaltyStartCm: Double = 5
        /// At this amount the old full skating/poling penalty is reached.
        static let freshSnowPenaltyFullCm: Double = 25
        static let freshSnowMinimumSpeedFactor: Double = 0.7
        /// Traverse baseline speed (m/s).
        static let baseSpeedMs: Double = 1.5
        /// Uphill cost coefficient (seconds per vertical meter).
        static let uphillCostSecondsPerMeter: Double = 6.0

        static func speedFactor(freshSnowCm: Double) -> Double {
            let span = freshSnowPenaltyFullCm - freshSnowPenaltyStartCm
            let progress = max(0, min(
                1,
                (freshSnowCm - freshSnowPenaltyStartCm) / span
            ))
            return 1 - progress * (1 - freshSnowMinimumSpeedFactor)
        }
    }
}

// MARK: - Condition scoring (weather-driven UX score for UI)

enum ConditionScoreConstants {
    enum Snow {
        enum Freshness {
            /// 24h fresh snow thresholds.
            static let maxThresholdCm: Double = 10
            static let highThresholdCm: Double = 3
            /// 72h fresh snow thresholds.
            static let moderate72hCm: Double = 15
            static let low72hCm: Double = 5
            /// Snow depth thresholds (for off-season base coverage).
            static let depthHighCm: Double = 100
            static let depthLowCm: Double = 50
        }

        enum Grooming {
            /// Groomed-trail baseline score (before fresh-snow bonus).
            static let baseScoreIfGroomed: Double = 0.85
            /// Cap on groomed-trail score.
            static let maxScoreIfGroomed: Double = 1.0
            /// Fresh snow bonus coefficient per cm of 24h snowfall.
            static let freshBonusPerCm: Double = 0.015
            /// Cap on fresh-snow bonus.
            static let freshBonusMax: Double = 0.15
        }
    }

    enum Moguls {
        /// Base mogul score if hasMoguls flag is set.
        static let baseIfFlagged: Double = 0.6
        /// Base mogul score otherwise.
        static let baseIfNotFlagged: Double = 0.15
        /// Gradient factor cap.
        static let gradientFactorCap: Double = 0.25
        /// Gradient factor denominator.
        static let gradientFactorDenom: Double = 120.0

        /// Fresh-snow smoothing reduces mogul sharpness.
        enum FreshSnowSmoothing {
            static let heavyThresholdCm: Double = 15
            static let heavyFactor: Double = -0.3
            static let moderateThresholdCm: Double = 5
            static let moderateFactor: Double = -0.15
        }

        /// Freeze-thaw hardens moguls (temp hovering around 0°C).
        enum FreezeThaw {
            static let minTempC: Double = -2
            static let maxTempC: Double = 2
            static let hardeningFactor: Double = 0.1
        }
    }

    enum Glide {
        enum Temperature {
            /// Optimal glide range: -7 to -3°C.
            static let optimalRangeMinC: Double = -7
            static let optimalRangeMaxC: Double = -3
            /// Warm conditions: above 0°C.
            static let warmBoundaryC: Double = 0
            static let warmDenom: Double = 6.0
            /// Very cold: below -15°C.
            static let veryColdBoundaryC: Double = -15
            static let veryColdDenom: Double = 12.0
            /// Cool transition (-3 to 0°C).
            static let coolTransitionC: Double = -3
            static let coolBaseline: Double = 0.7
            static let coolRange: Double = 0.3
            static let coldDenom: Double = 8.0
        }

        enum Sun {
            /// Degrees per aspect offset for south-facing sun calc (pi-relative).
            static let aspectOffsetDegrees: Double = 180.0
            /// Sun penalty scale factor.
            static let penaltyScale: Double = 0.20
            /// Default sun penalty when aspect unknown.
            static let unknownAspectPenalty: Double = 0.10
        }

        enum Scoring {
            /// Composite weights (sum to 1.0).
            static let freshnessWeight: Double = 0.50
            static let temperatureWeight: Double = 0.35
            static let sunExposureWeight: Double = 0.15
            /// Default glide score when no conditions data available.
            static let defaultNoConditions: Double = 0.5
        }
    }

    enum Elevation {
        /// Environmental lapse rate (°C per 1000m).
        static let lapseRateCelsiusPerKm: Double = -6.5
        /// Altitude divisor for lapse rate computation.
        static let altitudeDivisorMeters: Double = 1000.0
    }
}
