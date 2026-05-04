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
    /// Determinism: coarse quantization so two devices compute identical results.
    enum Determinism {
        /// Solve time rounded to 15-minute buckets (900s).
        static let timeBucketSeconds: Double = 900
        /// Temperature rounded to 0.5 °C steps.
        static let tempQuantizationCelsius: Double = 0.5
        /// Elevation rounded to 10 m steps.
        static let elevQuantizationMeters: Double = 10
        /// Wind speed rounded to 5 km/h steps.
        static let windQuantizationKph: Double = 5.0
        /// Visibility rounded to 0.5 km steps.
        static let visQuantizationKm: Double = 0.5
    }

    /// Scoring: multi-factor blending weights and caps.
    enum Scoring {
        /// Maximum acceptable wait-time imbalance between skiers (seconds).
        static let maxImbalanceSeconds: Double = 300
        /// Soft wait-time penalty α — adds α·|tA−tB| to the `.fastest` score so
        /// ties at the same max(tA,tB) prefer balanced meets. 0.3 means a 60s
        /// imbalance costs the same as 18s of total time, well below the hard
        /// 300s reject threshold.
        static let waitPenaltyAlpha: Double = 0.3
        /// Minimum secondary factor scale (seconds).
        static let secondaryFactorMinSeconds: Double = 5.0
        /// Maximum secondary factor scale (seconds).
        static let secondaryFactorMaxSeconds: Double = 30.0
        /// Secondary scale as a fraction of the time range (5%).
        static let secondaryFactorScalePercent: Double = 0.05
        /// Hub-bonus divisor: bonus caps when normalized hub count reaches this.
        static let hubBonusDivisor: Double = 6.0
        /// Elevation penalty coefficient at the base area (normalized < threshold).
        static let elevPenaltyBaseArea: Double = 3.0
        /// Elevation penalty coefficient at the summit (normalized > threshold).
        static let elevPenaltySummit: Double = 0.5
        /// Fraction of range considered "base" (below 15%).
        static let elevPenaltyBaseThreshold: Double = 0.15
        /// Fraction of range considered "summit" (above 85%).
        static let elevPenaltySummitThreshold: Double = 0.85
        /// Landmark bonus as a fraction of the secondary scale.
        static let landmarkBonusScale: Double = 0.5
    }

    /// Geographic diversity for alternate meeting points.
    enum Alternates {
        /// Minimum squared coordinate distance (degrees²) between alternates — ~150m at mid-latitude.
        static let minDistSqDegrees: Double = 0.00000203
        /// Count of alternates for the two-skier solver.
        static let twoSkierAlternateCount: Int = 3
        /// Count of alternates for the N-skier solver.
        static let nSkierAlternateCount: Int = 3
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
        }
    }

    /// Traverse-specific constants (flat connector segments walked/skated).
    enum Traverse {
        /// Fresh-snow penalty threshold for traverses (cm).
        static let freshSnowPenaltyThresholdCm: Double = 20
        /// Traverse speed multiplier above threshold.
        static let freshSnowPenaltyMultiplier: Double = 0.7
        /// Traverse baseline speed (m/s).
        static let baseSpeedMs: Double = 1.5
        /// Uphill cost coefficient (seconds per vertical meter).
        static let uphillCostSecondsPerMeter: Double = 6.0
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
