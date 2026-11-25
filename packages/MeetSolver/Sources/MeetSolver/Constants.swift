import Foundation
import MountainCore

/// Tunable weights for search and ranking. The ranking weights are reasoned in
/// minutes below. Changing one changes solver output.
enum Scoring {
    /// Weight on the time one skier stands idle at the stop in ordinary weather:
    /// the gap between the two arrivals, less any lap they ski meanwhile. One and
    /// a half: the pair would rather be together three minutes later than have
    /// one of them stand still for two. (0.6 lets "you ride 26 minutes to where
    /// your friend already stands" beat meeting half-way; 1.0 still lets an
    /// eight-minute wait tie with a meet where nobody waits.)
    static let waitPenaltyAlpha = 1.5
    /// Ceiling once cold, wind and poor visibility are added at an exposed stop.
    static let waitPenaltyAlphaMaximum = 2.5
    /// Weight on waiting time spent on a lap (`MeetOption.lapWhileWaiting`). A
    /// skier lapping is skiing, not waiting, so it costs half of standing
    /// still; it is not free, because they ski it alone and against a deadline,
    /// and a meet that has both travelling should still win when one exists.
    static let lapWhileWaitingRate = 0.5
    /// Extra weight on every second of the gap between arrivals beyond
    /// `waitLapMinimumWaitS`, lapped or not. A lap makes a long gap cheap: at
    /// half rate a lapped 24-minute gap cost only about nine minutes more than a
    /// two-minute one, less than the onward cost can swing, so a lift base with a
    /// good run where the friend already laps beat an even stop with a weaker run
    /// on. Past five minutes the pair is apart, not pausing: each further minute
    /// costs another half, so a lapped minute then costs a whole one (as much as
    /// being together a minute later) and a standing minute two. A fully lapped
    /// gap g now costs g − 90 s, so past about 16.5 minutes it outweighs even the
    /// largest onward difference. Short gaps are untouched.
    static let unevenWaitRate = 0.5
    /// The pick's earlier skier arrives this long before the other: the option
    /// says it is uneven but the best there is (`Reason.longWaitUnavoidable`).
    static let longWaitNoticeS = 10.0 * 60
    /// Risk weight β on the joint standard deviation.
    static let cvarBeta = 0.5
    static let rendezvousConfidencePenaltyS = 90.0
    static let rendezvousQualityPenaltyS = 120.0

    // What the pair can do after they meet, in seconds of "together later".
    //
    // A stop that leads straight into a full shared run (1.2 km, 400 m of
    // vertical, comfortable for the weaker skier) costs nothing. One with no
    // shared run at all costs `onwardRunValueS + onwardAccessMaximumS`, twelve
    // minutes: about one lift queue and ride, which is what a pair stranded at a
    // dead end or the bottom spends before their first turns together. So a good
    // mid-mountain stop beats a dead end until it is twelve minutes later, and
    // beats an equally good run that starts with an eight-minute lift by four.
    /// Six minutes for the run itself, scaled by `1 − quality`.
    static let onwardRunValueS = 6.0 * 60
    /// Time between meeting and the first shared turns (walking, queueing,
    /// riding) is charged at half rate: it is time together, but not skiing.
    static let onwardAccessRate = 0.5
    /// Access is charged up to twelve minutes, so at most six.
    static let onwardAccessCapS = 12.0 * 60
    static var onwardAccessMaximumS: Double { onwardAccessRate * onwardAccessCapS }
    static var onwardMaximumS: Double { onwardRunValueS + onwardAccessMaximumS }

    // When stopping is the point: the last minutes of the lift day, or weather
    // nobody wants to stand in. Both ramp a 0...1 factor; the larger wins. At 1 a
    // lodge is forgiven its whole onward cost and credited six more minutes, so
    // the swing is bounded at eighteen minutes and is zero on an ordinary
    // mid-day solve.
    static let lodgeShelterCreditS = 6.0 * 60
    /// Lift time left after meeting: no pull at 45 minutes or more, full at 15
    /// or less (one more lap no longer fits).
    static let lateDayRampStartS = 45.0 * 60
    static let lateDayRampEndS = 15.0 * 60

    /// A wait at least this long earns a lap suggestion for the skier waiting,
    /// and past it the gap is charged `unevenWaitRate` as well.
    static let waitLapMinimumWaitS = 5.0 * 60
    /// Less skiing than this is not a lap worth suggesting.
    static let waitLapMinimumRunLengthM = 400.0
    /// A lap must be back this long before the partner's expected arrival.
    static let waitLapReturnMarginS = 60.0
    /// A weather term counts as why a route was chosen when the plain-weather
    /// way would have lost at least this much more to it: the same 30 s a
    /// `Tradeoff` needs before it calls an arrival quicker.
    static let weatherFavourMinimumS = 30.0
    /// A stop counts as "ski on together" when shared turns begin this soon.
    static let skiOnTogetherMaximumAccessS = 2.0 * 60
    static let skiOnTogetherMinimumQuality = 0.20

    static let sharedDownhillAccessGraceS = 8.0 * 60
    static let sharedDownhillAccessPenaltyWindowS = 15.0 * 60
    static let sharedDownhillAccessMaximumUtilityPenalty = 0.25
    static let sharedTerrainFitMaximumUtilityPenalty = 0.20
    static let sharedRunVarietyMaximumUtilityBonus = 0.08
    static let sharedRunVarietyRelativeUtilityWindow = 0.20
    static let sharedRunOptionMinimumUtility = 0.20
    static let sharedRunOptionMinimumTerrainFit = 0.70
    /// Two people do not regroup and enter a lift maze at the instant the later
    /// ETA reaches zero; continuation feasibility is checked this much later.
    static let sharedMeetupHandoffS = 90.0
    /// An approach may be slower than the skier's fastest by at most the larger
    /// of these, so fairness can pick a stop but never a detour (I-02).
    static let dependablePathMaximumExtraS = 30.0
    static let dependablePathMaximumExtraFraction = 0.15
    static let routeActionTransitionPenaltyS = 8.0
    static let routeSimplicityMaximumPenaltyS = 32.0
    /// Converts position uncertainty in metres to ETA uncertainty in seconds.
    static let positionUncertaintySpeedMS = 2.0
    /// One-sided P90: a lift counts only if its gate can be cleared by last chair
    /// at this quantile of the approach arrival.
    static let liftCatchConfidenceZ = 1.2815515655446004
    static let pairwiseDistanceLadderM: [Double] = [350, 200, 100, 0]
    /// An alternate may leave someone waiting this much longer than the pick
    /// does, and no more, unless it brings the two together sooner. A
    /// different place is only a choice when it is not plainly worse.
    static let alternateExtraWaitS = 5.0 * 60
    static let alternateSoonerS = 60.0
    /// Stops within both of these of one another, chained stop to stop, are one
    /// area: a base village whose lifts start a hundred metres apart, or a
    /// mid-mountain hub. The height bound keeps a chain from climbing a slope.
    static let alternateAreaHorizontalM = 300.0
    static let alternateAreaVerticalM = 40.0
    /// How much worse than the pick, in score seconds, a stop in an area not yet
    /// shown may be and still take a place ahead of a second stop in a shown
    /// area: the larger of five minutes (the extra wait an alternate may already
    /// ask for) and a quarter of the pick's score, so a long solve is not held to
    /// a short solve's margin. Beyond it, rank order decides again.
    static let alternateElsewhereMaximumExtraS = 5.0 * 60
    static let alternateElsewhereMaximumExtraFraction = 0.25

    /// How unpleasant it is to stand outside, 0...0.95: cold from −8 to −25 °C,
    /// wind from 20 to 65 km/h, visibility from 2 km down to 0.5 km.
    static func weatherHazard(temperatureC: Double, windKmh: Double, visibilityKm: Double)
        -> Double {
        func unit(_ value: Double) -> Double { max(0, min(1, value)) }
        let cold = unit((-8 - temperatureC) / 17)
        let wind = unit((windKmh - 20) / 45)
        let visibility = unit((2 - visibilityKm) / 1.5)
        return 0.45 * cold + 0.35 * wind + 0.15 * visibility
    }

    /// Cold, wind and poor visibility make a timing mismatch cost more at an
    /// exposed stop. Soft cost only: it never changes eligibility.
    static func waitPenaltyAlpha(
        temperatureC: Double, windKmh: Double, visibilityKm: Double, exposure: Double
    ) -> Double {
        let hazard = exposure * weatherHazard(
            temperatureC: temperatureC, windKmh: windKmh, visibilityKm: visibilityKm
        )
        return min(waitPenaltyAlphaMaximum, waitPenaltyAlpha + hazard)
    }

    /// 0 with plenty of lift time left after the pair meets, 1 when a lap no
    /// longer fits.
    static func lateDayFactor(liftTimeLeftS: Double) -> Double {
        max(0, min(1, (lateDayRampStartS - liftTimeLeftS) / (lateDayRampStartS - lateDayRampEndS)))
    }
}

enum Traversal {
    enum Lift {
        /// Conservative hours for a lift whose bundle entry lists none.
        static let fallbackOpenMinute = 7 * 60
        static let fallbackCloseMinute = 21 * 60
        static let windSlightSlowKmh = 40.0
        static let windReducedSpeedKmh = 60.0
        static let windHoldKmh = 80.0
        /// Hourly throughput at or above which the queue clears faster.
        static let highCapacityPPH = 3_000
        static let highCapacityWaitMultiplier = 0.7
        static let mediumCapacityPPH = 2_000
        static let mediumCapacityWaitMultiplier = 0.85
        static let weekendWaitMultiplier = 1.4
        static let waitCapS = 600.0
        /// A live wait is taken as it is for arrivals up to this long after it
        /// was observed (about one status refresh)...
        static let liveWaitHoldS = 30.0 * 60
        /// ...then fades linearly to the modelled queue over this long.
        static let liveWaitFadeS = 60.0 * 60
        /// Longest live wait believed. Above the modelled cap on purpose: a real
        /// 25-minute line is the point of having live data.
        static let liveWaitCapS = 45.0 * 60
        /// A lift on hold is expected to reopen, at a price.
        static let holdExtraWaitS = 15.0 * 60

        /// Gust at the top station where wind holds begin for this kind of
        /// lift, and the span over which a hold becomes near certain. Rough
        /// public operating figures, not a rule any one lift follows: gondola
        /// cabins catch the most wind, surface lifts the least.
        static func windHoldStartKmh(_ type: LiftType) -> Double {
            switch type {
            case .gondola: 50
            case .chair: 55
            case .cableCar: 60
            case .tbar, .ropeTow, .magicCarpet: 80
            }
        }
        static let windHoldSpanKmh = 30.0
        /// From this likelihood the option card says a hold is likely.
        static let windHoldNoticeLikelihood = 0.5

        static func baseWaitS(_ type: LiftType) -> Double {
            switch type {
            case .gondola, .cableCar: 180
            case .chair: 90
            case .tbar: 45
            case .ropeTow: 30
            case .magicCarpet: 15
            }
        }

        /// Queue multiplier at each local hour; the curve between is linear.
        static func hourlyWaitMultiplier(_ hour: Int) -> Double {
            switch (hour % 24 + 24) % 24 {
            case 8: 0.5
            case 9: 0.8
            case 10, 11: 1.5
            case 12: 1.2
            case 13, 14: 1.3
            case 15: 0.9
            default: 1.0
            }
        }
    }

    enum Run {
        static let fallbackSpeedMS = 1.5
        static let skillDampenThresholdMS = 5.0
        static let skillDampenFactor = 0.7
        static let iceConditionThresholdC = -3.0
        static let iceAbilityBaseline = 0.7
        static let iceAbilityScaleFactor = 0.3
        static let minViableSpeedMS = 0.1
        static let trailModifierFloor = 0.35
        static let envModifierFloor = 0.60
        static let combinedModifierFloor = 0.25
        static let gradientPenaltyDenom = 90.0
        static let gradientPenaltyMin = 0.3
        static let windExposedThresholdKmh = 30.0
        /// Share of the gap between mean wind and gusts a skier feels on a run.
        static let gustShare = 0.3
        /// Wind grows with height: this much per 1,000 m above the height the
        /// forecast is for, within the bounds below. A judgement, not a
        /// measurement: forecasts are for open ground at one height, and
        /// ridges above it are windier, valleys below it calmer.
        static let windGainPerKm = 0.25
        static let windHeightFactorRange = 0.8...1.3
        static let windPenaltyPerKmh = 0.01
        static let visibilityPenaltyThresholdKm = 5.0
        /// How far you see inside the cloud, and the height over which a run
        /// climbing into it loses the view. Low cloud counts from 30 % cover,
        /// fully from 70 %.
        static let inCloudVisibilityKm = 0.5
        static let cloudEntryDepthM = 100.0
        /// Cloud base above the forecast height per °C between temperature
        /// and dew point (the lifting condensation level rule of thumb).
        static let cloudBaseMPerSpreadC = 125.0
        /// A slope turned into the wind feels this much more of it, one in
        /// the lee this much less. A judgement.
        static let windAspectShare = 0.15
        /// Speed lost on a surface that thawed in the last day and has
        /// refrozen, where no groomer has reset it; a groomed run keeps a
        /// share of it. A judgement: direction and bounds are tested, not
        /// the value.
        static let refrozenCrustPenalty = 0.15
        static let refrozenGroomedShare = 0.4
        static let visibilitySteepGradientDeg = 25.0
        static let visibilitySteepMultiplier = 1.5
        static let visibilityPenaltyPerKm = 0.05
        static let freshSnowUngroomedThresholdCM = 5.0
        static let groomedBonusPerCM = 0.002
        static let groomedBonusCap = 1.06
        /// Default stop model when no learned pace exists: stops per kilometre and
        /// seconds per stop.
        static let defaultStopsPerKm = 0.4
        static let stopSeconds = 20.0

        // Limits and equipment (specs/06-SOLVER.md section 2).
        /// A run this long or longer, averaging under `flatPitchDeg`, is a flat.
        static let flatMinLengthM = 100.0
        static let flatPitchDeg = 3.0
        static let weightReferenceKG = 75.0
        static let weightFadeDeg = 10.0
        static let gearFloor = 0.90
        static let gearCeiling = 1.06

        /// Linear cold-snow glide curve through −15, −8, −3 and 0 °C.
        static func iceSpeedFactor(at temperatureC: Double) -> Double {
            func interpolate(_ v: Double, _ lo: Double, _ hi: Double, _ a: Double, _ b: Double)
                -> Double {
                a + (b - a) * max(0, min(1, (v - lo) / (hi - lo)))
            }
            if temperatureC <= -15 { return 0.80 }
            if temperatureC <= -8 { return interpolate(temperatureC, -15, -8, 0.80, 0.85) }
            if temperatureC <= -3 { return interpolate(temperatureC, -8, -3, 0.85, 0.95) }
            return interpolate(temperatureC, -3, 0, 0.95, 1)
        }
    }

    enum Connection {
        static let baseSpeedMS = 1.5
        static let uphillCostSPerM = 6.0
        static let freshSnowPenaltyStartCM = 5.0
        static let freshSnowPenaltyFullCM = 25.0
        static let freshSnowMinimumSpeedFactor = 0.7

        static func speedFactor(freshSnowCM: Double) -> Double {
            let span = freshSnowPenaltyFullCM - freshSnowPenaltyStartCM
            let progress = max(0, min(1, (freshSnowCM - freshSnowPenaltyStartCM) / span))
            return 1 - progress * (1 - freshSnowMinimumSpeedFactor)
        }
    }

    /// Coefficient of variation of traversal time by edge kind.
    static func timeCV(_ kind: EdgeKind) -> Double {
        switch kind {
        case .lift: 0.30
        case .run: 0.15
        case .connection: 0.10
        }
    }
}

/// What each ability tier implies for terrain the bundle describes. Values are the
/// onboarding presets.
struct AbilityModel {
    let ungroomedComfort: Double
    let icyComfort: Double
    let maxGradientDeg: Double
    let steepPenaltyWeight: Double
    let freshSnowPenaltyPerCM: Double

    init(_ ability: Ability, prefersGroomed: Bool) {
        let ungroomed: Double
        switch ability {
        case .beginner:
            (ungroomed, icyComfort, maxGradientDeg) = (0.3, 0.3, 15)
            (steepPenaltyWeight, freshSnowPenaltyPerCM) = (0.8, 0.04)
        case .intermediate:
            (ungroomed, icyComfort, maxGradientDeg) = (0.6, 0.5, 25)
            (steepPenaltyWeight, freshSnowPenaltyPerCM) = (0.6, 0.025)
        case .advanced:
            (ungroomed, icyComfort, maxGradientDeg) = (0.8, 0.7, 35)
            (steepPenaltyWeight, freshSnowPenaltyPerCM) = (0.4, 0.012)
        case .expert:
            (ungroomed, icyComfort, maxGradientDeg) = (1.0, 0.85, 45)
            (steepPenaltyWeight, freshSnowPenaltyPerCM) = (0.2, 0.005)
        }
        // A stated preference for groomers reads as one tier less comfortable off them.
        ungroomedComfort = prefersGroomed ? max(0.1, ungroomed - 0.2) : ungroomed
    }
}
