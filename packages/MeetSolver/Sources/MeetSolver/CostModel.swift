import Foundation
import MountainCore

/// Status as the solver applies it: a cost, never a change to the graph (I-18).
struct EffectiveStatus: Sendable {
    let freshness: StatusFreshness
    let degraded: Bool
    private let closed: Set<GroupID>
    private let hold: Set<GroupID>
    private let groomed: Set<GroupID>
    private let known: Set<GroupID>
    /// Live queue seconds by lift group; fresh status only, like holds.
    private let waits: [GroupID: Double]
    /// When the live waits were observed.
    let observedAt: Date?

    init(_ status: ResortStatus?, at now: Date) {
        freshness = .of(status, at: now)
        degraded = freshness != .fresh
        switch (freshness, status) {
        case (.fresh, .some(let status)):
            closed = Set(status.groups.filter { $0.value == .closed }.keys)
            hold = Set(status.groups.filter { $0.value == .hold }.keys)
            groomed = Set(status.groomed)
            known = Set(status.groups.filter { $0.value != .scheduled }.keys)
            // A reported 0 is how feeds say "not measured" as often as "no
            // line", so it is no evidence: the modelled queue stands.
            waits = status.waitMinutes.compactMapValues { minutes in
                minutes.isFinite && minutes > 0 ? minutes * 60 : nil
            }
            observedAt = status.observedAt
        case (.stale, .some(let status)):
            // Degraded: every group is "scheduled", but a closure we were told
            // about is still honoured (I-07).
            closed = Set(status.groups.filter { $0.value == .closed }.keys)
            hold = []
            groomed = []
            known = closed
            waits = [:]
            observedAt = nil
        default:
            closed = []
            hold = []
            groomed = []
            known = []
            waits = [:]
            observedAt = nil
        }
    }

    func isClosed(_ group: GroupID?) -> Bool { group.map(closed.contains) ?? false }
    func isOnHold(_ group: GroupID?) -> Bool { group.map(hold.contains) ?? false }
    func isGroomed(_ group: GroupID?) -> Bool { group.map(groomed.contains) ?? false }
    /// False when nothing live says whether this group is open.
    func isKnown(_ group: GroupID?) -> Bool { group.map(known.contains) ?? true }
    var hasClosures: Bool { !closed.isEmpty }
    /// The live queue at this lift when status was observed, in seconds.
    func liveWaitS(_ group: GroupID?) -> Double? { group.flatMap { waits[$0] } }
}

/// The price of one edge for one skier at one moment. One value per solve per
/// skier, built from the inputs; it holds no mutable state and reads no clock.
struct CostModel: Sendable {
    struct Cost {
        let seconds: Double
        let variance: Double
    }

    private struct Weather {
        let tempC: Double
        let windKmh: Double
        let gustKmh: Double
        let visibilityKm: Double
        let cloudPct: Double
        let snowCM: Double
        var windDirDeg: Double?
        var dewPointC: Double?
        var cloudLowPct: Double?
        var temp850C: Double?
        var temp700C: Double?
    }

    /// Usual heights of the 850 and 700 hPa levels. The real ones move a
    /// hundred metres or so with the weather, well inside what the profile is
    /// good for.
    private static let level850M = 1_457.0
    private static let level700M = 3_012.0
    private static let standardLapseCPerM = -6.5 / 1_000

    let graph: Graph
    let solveTime: Date
    let status: EffectiveStatus
    let profile: SkierProfile
    private let pace: PaceModel?
    private let ability: AbilityModel
    private let conditions: Conditions?
    private let latitude: Double
    private let longitude: Double
    private let referenceElevationM: Double
    /// The height the forecast is for, when the conditions row says.
    private let forecastElevationM: Double?
    /// Warmest reading at the forecast height in the day before the solve
    /// (past hours, and forecast hours already behind a later instant), for
    /// whether the snow thawed. Nil when the row carries none.
    private let recentPeakTempC: Double?
    /// Resort-local offset at the solve instant, from the bundle's time zone.
    private let utcOffsetS: Double
    /// The easiest way down: when set, the difficulty gate admits runs up to this
    /// ladder rank (park from black) as well as the skier's own. The skier's
    /// choices (avoid list, pitch limit) stay hard gates. Nil in every normal search.
    private(set) var difficultyCeilingRank: Int?
    /// The weather terms of a run's environment that this model charges. All of
    /// them in every search that routes; fewer only in the plain-weather search
    /// and the per-term pricing behind `WeatherFavour`.
    private(set) var weatherTerms = Set(WeatherFavour.allCases)

    init(input: SolveInput, skier: SkierInput, at: Date? = nil) {
        self.init(
            bundle: input.bundle, status: input.status, conditions: input.conditions,
            profile: skier.profile, pace: skier.pace, at: at ?? input.at
        )
    }

    init(
        bundle: ResortBundle, status: ResortStatus?, conditions: Conditions?,
        profile: SkierProfile, pace: PaceModel?, at: Date
    ) {
        let solveTime = Quantize.time(at)
        // From the unquantized row: the quantized one keeps only two hours back.
        let dayBefore = solveTime.addingTimeInterval(-24 * 60 * 60)
        recentPeakTempC = conditions.flatMap { row in
            (row.recent.map { ($0.at, $0.tempC) } + row.hourly.map { ($0.at, $0.tempC) })
                .filter { $0.0 >= dayBefore && $0.0 <= solveTime }
                .map { ($0.1 / Quantize.temperatureStepC).rounded() * Quantize.temperatureStepC }.max()
        }
        graph = bundle.graph
        self.solveTime = solveTime
        self.status = EffectiveStatus(status, at: solveTime)
        self.profile = profile
        self.pace = pace
        ability = AbilityModel(profile.ability, prefersGroomed: profile.prefersGroomed)
        let conditions = Quantize.conditions(conditions, at: solveTime)
        self.conditions = conditions
        latitude = bundle.center.lat
        longitude = bundle.center.lon
        referenceElevationM = (bundle.graph.referenceElevationM / Quantize.elevationStepM)
            .rounded() * Quantize.elevationStepM
        forecastElevationM = conditions?.elevationM
        // An unknown zone falls back to mean solar time, never the device zone (I-06).
        utcOffsetS = bundle.timeZone.map { Double($0.secondsFromGMT(for: solveTime)) }
            ?? bundle.center.lon / 15 * 3_600
    }

    // MARK: Weather

    private func weather(atOffset offsetS: Double) -> Weather {
        guard let conditions else {
            // Neutral winter day when there is no reading at all.
            return Weather(tempC: -2, windKmh: 0, gustKmh: 0, visibilityKm: 10, cloudPct: 0, snowCM: 0)
        }
        let s = conditions.sample(at: solveTime.addingTimeInterval(offsetS))
        return Weather(
            tempC: s.tempC, windKmh: s.windMS * 3.6, gustKmh: max(s.gustMS, s.windMS) * 3.6,
            visibilityKm: s.visibilityM / 1_000,
            cloudPct: s.cloudPct, snowCM: s.snow24hCM, windDirDeg: s.windDirDeg,
            dewPointC: s.dewPointC, cloudLowPct: s.cloudLowPct, temp850C: s.temp850C,
            temp700C: s.temp700C
        )
    }

    /// The air temperature at a height. With the forecast's own height and
    /// the temperatures aloft it follows the day's real profile, inversions
    /// included; without them, the standard lapse from the mountain's mean
    /// height. Linear in height and in every reading, so it adds no step.
    private func temperature(_ weather: Weather, atElevation elevationM: Double?) -> Double {
        guard let elevationM else { return weather.tempC }
        guard let ground = forecastElevationM else {
            return weather.tempC + (elevationM - referenceElevationM) * Self.standardLapseCPerM
        }
        // A level at or just above the ground says nothing the reading does not.
        var anchors = [(height: ground, tempC: weather.tempC)]
        for (height, temp) in [(Self.level850M, weather.temp850C), (Self.level700M, weather.temp700C)] {
            if let temp, height > ground + 150 { anchors.append((height, temp)) }
        }
        if elevationM <= ground || anchors.count == 1 {
            return weather.tempC + (elevationM - ground) * Self.standardLapseCPerM
        }
        for (lower, upper) in zip(anchors, anchors.dropFirst()) where elevationM <= upper.height {
            let share = (elevationM - lower.height) / (upper.height - lower.height)
            return lower.tempC + (upper.tempC - lower.tempC) * share
        }
        // Above the highest level: carry its slope on, never steeper than dry
        // air cools and never warming.
        let top = anchors[anchors.count - 1], below = anchors[anchors.count - 2]
        let slope = max(-9.8 / 1_000, min(0, (top.tempC - below.tempC) / (top.height - below.height)))
        return top.tempC + (elevationM - top.height) * slope
    }

    /// How far a skier sees at a height: the resort reading, or less inside low
    /// cloud. The cloud base is estimated from temperature and dew point at the
    /// forecast height; its top is unknown, so everything above the base
    /// counts as in it.
    private func visibilityKm(_ weather: Weather, atElevation elevationM: Double?) -> Double {
        guard let elevationM, let ground = forecastElevationM, let dew = weather.dewPointC,
              let low = weather.cloudLowPct else { return weather.visibilityKm }
        func unit(_ value: Double) -> Double { max(0, min(1, value)) }
        let base = ground + Traversal.Run.cloudBaseMPerSpreadC * max(0, weather.tempC - dew)
        let inCloud = unit((elevationM - base) / Traversal.Run.cloudEntryDepthM) * unit((low - 30) / 40)
        let cloudy = min(weather.visibilityKm, Traversal.Run.inCloudVisibilityKm)
        return weather.visibilityKm + (cloudy - weather.visibilityKm) * inCloud
    }

    /// 0...1: how much of a thawed-and-refrozen crust a run carries. The day's
    /// warmest hour, moved to the run's height, must have been above freezing
    /// and the run must be below it now; new snow covers it.
    private func refrozen(_ weather: Weather, edgeTempC: Double) -> Double {
        guard let peak = recentPeakTempC else { return 0 }
        func unit(_ value: Double) -> Double { max(0, min(1, value)) }
        let peakAtEdge = peak + (edgeTempC - weather.tempC)
        return unit(peakAtEdge / 2) * unit((-edgeTempC - 1) / 2) * (1 - unit(weather.snowCM / 5))
    }

    /// How much windier (or calmer) it is at `elevationM` than at the height the
    /// forecast is for. Linear in height, so it adds no step to any cost.
    private func windHeightFactor(atElevation elevationM: Double?) -> Double {
        guard let elevationM else { return 1 }
        let range = Traversal.Run.windHeightFactorRange
        let factor = 1 + (elevationM - (forecastElevationM ?? referenceElevationM)) / 1_000
            * Traversal.Run.windGainPerKm
        return max(range.lowerBound, min(range.upperBound, factor))
    }

    /// The wind a skier feels on a run at this height: the mean wind plus a
    /// share of the gusts.
    private func feltWindKmh(
        _ weather: Weather, atElevation elevationM: Double?, aspectDeg: Double? = nil
    ) -> Double {
        var wind = (weather.windKmh + (weather.gustKmh - weather.windKmh) * Traversal.Run.gustShare)
            * windHeightFactor(atElevation: elevationM)
        // Windward slopes take it, lee slopes are sheltered.
        if let aspectDeg, let from = weather.windDirDeg {
            wind *= 1 + Traversal.Run.windAspectShare * cos((aspectDeg - from) * .pi / 180)
        }
        return wind
    }

    /// How likely a lift boarded `offsetS` into the route is to be on a wind
    /// hold, 0...1, from the gusts at its top station. Zero when live status
    /// already speaks for the lift: a report beats a guess.
    func windHoldLikelihood(_ edge: Edge, atOffset offsetS: Double) -> Double {
        guard edge.kind == .lift, let lift = edge.lift else { return 0 }
        if edge.group != nil, status.isKnown(edge.group) { return 0 }
        guard status.liveWaitS(edge.group) == nil else { return 0 }
        let gust = weather(atOffset: offsetS).gustKmh
            * windHeightFactor(atElevation: graph.nodes[edge.to]?.eleM)
        let start = Traversal.Lift.windHoldStartKmh(lift.type)
        return max(0, min(1, (gust - start) / Traversal.Lift.windHoldSpanKmh))
    }

    /// Weather-dependent wait-imbalance weight for a stop reached at `offsetS`.
    func waitPenaltyAlpha(for point: Rendezvous, arrivalOffsetS: Double) -> Double {
        let w = weather(atOffset: arrivalOffsetS)
        let exposure: Double = switch point.kind {
        case .lodge: point.isIndoor ? 0.15 : 0.30
        case .landmark: 0.60
        case .liftBase: 1.00
        case .liftTop, .junction: 1.10
        }
        let elevation = graph.nodes[point.nodeID]?.eleM
        return Scoring.waitPenaltyAlpha(
            temperatureC: temperature(w, atElevation: elevation),
            windKmh: w.windKmh, visibilityKm: visibilityKm(w, atElevation: elevation), exposure: exposure
        )
    }

    /// How unpleasant it is to be outside at this stop at `offsetS`, 0...0.95.
    func weatherHazard(at point: Rendezvous, arrivalOffsetS: Double) -> Double {
        let w = weather(atOffset: arrivalOffsetS)
        let elevation = graph.nodes[point.nodeID]?.eleM
        return Scoring.weatherHazard(
            temperatureC: temperature(w, atElevation: elevation),
            windKmh: w.windKmh, visibilityKm: visibilityKm(w, atElevation: elevation)
        )
    }

    /// The weather on these edges (one run or lift) `offsetS` after the model's
    /// instant, as the costs above read it, weighted by length.
    func localConditions(_ edges: [Edge], atOffset offsetS: Double = 0) -> LocalConditions? {
        let total = edges.reduce(0) { $0 + $1.lengthM }
        guard conditions != nil, total > 0 else { return nil }
        let w = weather(atOffset: offsetS)
        var temp = 0.0, wind = 0.0, visibility = 0.0, sun = 0.0, crust = 0.0
        for edge in edges {
            let share = edge.lengthM / total
            let edgeTemp = temperature(w, atElevation: edge.midpointElevationM)
            temp += share * edgeTemp
            wind += share * feltWindKmh(w, atElevation: edge.midpointElevationM, aspectDeg: edge.aspectDeg)
            visibility += share * visibilityKm(w, atElevation: edge.midpointElevationM)
            sun += share * SunExposure.exposure(
                aspectDeg: edge.aspectDeg, at: solveTime.addingTimeInterval(offsetS),
                latitude: latitude, longitude: longitude, cloudPct: w.cloudPct
            )
            crust += share * refrozen(w, edgeTempC: edgeTemp)
        }
        return LocalConditions(
            tempC: temp, windKmh: wind, visibilityKm: visibility, sunExposure: sun,
            inCloud: visibility < w.visibilityKm - 0.25 && visibility <= 1,
            refrozen: crust >= 0.5
        )
    }

    // MARK: Mountain clock

    /// Local minute of day (fractional) and ISO weekday at an offset into the route.
    private func localClock(atOffset offsetS: Double) -> (minute: Double, weekday: Int) {
        let local = solveTime.timeIntervalSinceReferenceDate + offsetS + utcOffsetS
        let day = (local / 86_400).rounded(.down)
        // 2001-01-01 was a Monday.
        let weekday = ((Int(day) % 7) + 7) % 7 + 1
        return ((local - day * 86_400) / 60, weekday)
    }

    /// The operating window containing `clock`, as its closing minute.
    private func closingMinute(_ lift: LiftInfo, clock: (minute: Double, weekday: Int)) -> Double? {
        guard !lift.operatingHours.isEmpty else {
            let open = Double(Traversal.Lift.fallbackOpenMinute)
            let close = Double(Traversal.Lift.fallbackCloseMinute)
            return clock.minute >= open && clock.minute < close ? close : nil
        }
        for hours in lift.operatingHours where hours.days.contains(clock.weekday) {
            if clock.minute >= Double(hours.openMinute), clock.minute < Double(hours.closeMinute) {
                return Double(hours.closeMinute)
            }
        }
        return nil
    }

    /// Seconds from `offsetS` until this lift stops loading, or nil when it is
    /// not running then (closed by status, or outside its hours).
    func secondsUntilLastChair(_ edge: Edge, atOffset offsetS: Double) -> Double? {
        guard edge.kind == .lift, let lift = edge.lift, !status.isClosed(edge.group) else {
            return nil
        }
        let clock = localClock(atOffset: offsetS)
        return closingMinute(lift, clock: clock).map { ($0 - clock.minute) * 60 }
    }

    /// The queue at a lift reached `offsetS` into the route. A live wait
    /// replaces the modelled one for an arrival soon after it was observed and
    /// hands back to the model linearly as the observation ages. The handover
    /// moves the wait by at most `liveWaitCapS / liveWaitFadeS` (0.75) seconds
    /// per second of delay, so arrival + wait still never decreases (I-04).
    private func queueWaitS(
        _ lift: LiftInfo, group: GroupID?, offsetS: Double, clock: (minute: Double, weekday: Int)
    ) -> Double {
        let modelled = modelledQueueWaitS(lift, clock: clock)
        guard let live = status.liveWaitS(group), let observedAt = status.observedAt else {
            return modelled
        }
        let age = solveTime.addingTimeInterval(offsetS).timeIntervalSince(observedAt)
        let weight = max(0, min(1, 1 - (age - Traversal.Lift.liveWaitHoldS) / Traversal.Lift.liveWaitFadeS))
        return weight * min(live, Traversal.Lift.liveWaitCapS) + (1 - weight) * modelled
    }

    private func modelledQueueWaitS(_ lift: LiftInfo, clock: (minute: Double, weekday: Int)) -> Double {
        var wait = Traversal.Lift.baseWaitS(lift.type)
        if let capacity = lift.capacityPPH {
            if capacity >= Traversal.Lift.highCapacityPPH {
                wait *= Traversal.Lift.highCapacityWaitMultiplier
            } else if capacity >= Traversal.Lift.mediumCapacityPPH {
                wait *= Traversal.Lift.mediumCapacityWaitMultiplier
            }
        }
        // Linear between hourly anchors: the steepest decline is far shallower
        // than one second of wait per second of delay, so arrival + wait keeps
        // increasing (FIFO, I-04).
        let hour = clock.minute / 60
        let whole = Int(hour.rounded(.down))
        let current = Traversal.Lift.hourlyWaitMultiplier(whole)
        let next = Traversal.Lift.hourlyWaitMultiplier(whole + 1)
        wait *= current + (next - current) * (hour - Double(whole))
        if clock.weekday >= 6 { wait *= Traversal.Lift.weekendWaitMultiplier }
        return min(wait, Traversal.Lift.waitCapS)
    }

    /// Wind slows the ride only, through a continuous curve; it never multiplies
    /// time already spent queueing (I-04).
    private static func liftWindRideMultiplier(windKmh: Double) -> Double {
        let wind = max(0, windKmh)
        func interpolate(_ lo: Double, _ hi: Double, _ a: Double, _ b: Double) -> Double {
            a + (b - a) * max(0, min(1, (wind - lo) / (hi - lo)))
        }
        let slight = Traversal.Lift.windSlightSlowKmh
        let reduced = Traversal.Lift.windReducedSpeedKmh
        let hold = Traversal.Lift.windHoldKmh
        if wind <= slight { return 1 }
        if wind <= reduced { return interpolate(slight, reduced, 1, 1.2) }
        if wind <= hold { return interpolate(reduced, hold, 1.2, 1.5) }
        return interpolate(hold, hold + 40, 1.5, 3)
    }

    // MARK: Ability

    /// The difficulty an edge is gated and paced as. An `unknown` edge with a
    /// measured pitch reads as the rating that pitch usually carries (these are
    /// mostly short unnamed links at lift stations); one without reads as the
    /// resort's hardest marked difficulty. Never harder than the hardest marked.
    func effectiveDifficulty(_ edge: Edge) -> Difficulty {
        let difficulty = edge.difficulty ?? .blue
        guard difficulty == .unknown else { return difficulty }
        let hardest = graph.hardestMarkedDifficulty
        guard let pitch = edge.gradeMaxDeg else { return hardest }
        let byPitch: Difficulty = switch pitch {
        case ...Self.unknownGreenMaxDeg: .green
        case ...Self.unknownBlueMaxDeg: .blue
        case ...Self.unknownBlackMaxDeg: .black
        default: hardest
        }
        guard let rank = byPitch.ladderRank, let cap = hardest.ladderRank else { return hardest }
        return rank <= cap ? byPitch : hardest
    }

    /// Steepest pitch an unrated edge may have and still read as each rating:
    /// the 90th-percentile pitch of marked runs of that rating at Whistler.
    static let unknownGreenMaxDeg = 17.0
    static let unknownBlueMaxDeg = 23.0
    static let unknownBlackMaxDeg = 33.0

    /// The hard ability gate: within the skier's marked-difficulty limit and a
    /// pace on file for the category. Park is a parallel category open from
    /// `black` up.
    private func isWithinDifficulty(_ edge: Edge) -> Bool {
        if isWithinLevel(edge) { return true }
        guard let ceiling = difficultyCeilingRank, let rank = Self.hardnessRank(effectiveDifficulty(edge))
        else { return false }
        return rank <= ceiling
    }

    /// The same model with the difficulty gate raised to `rank`, for the easiest
    /// way down (06-SOLVER section 1).
    func relaxed(toRank rank: Int) -> CostModel {
        var model = self
        model.difficultyCeilingRank = rank
        return model
    }

    /// The same model charging only `terms` of the run weather `WeatherFavour`
    /// names.
    func charging(_ terms: Set<WeatherFavour>) -> CostModel {
        var model = self
        model.weatherTerms = terms
        return model
    }

    /// Whether there is any weather reading to price at all.
    var hasConditions: Bool { conditions != nil }

    /// How hard a run is for the easiest-way-down order: the ladder rank, with
    /// park counted as black (it opens from black up). Nil for anything else.
    static func hardnessRank(_ difficulty: Difficulty) -> Int? {
        difficulty.ladderRank ?? (difficulty == .park ? Difficulty.black.ladderRank : nil)
    }

    /// The skier's own difficulty limit, never relaxed: within the marked
    /// limit and a pace on file for the category.
    func isWithinLevel(_ edge: Edge) -> Bool {
        guard edge.kind == .run else { return true }
        let difficulty = effectiveDifficulty(edge)
        guard let speed = profile.baselineSpeedMS[difficulty], speed.isFinite, speed > 0 else {
            return false
        }
        let limit = profile.maxDifficulty.ladderRank ?? Difficulty.blue.ladderRank ?? 1
        if let rank = difficulty.ladderRank { return rank <= limit }
        return limit >= (Difficulty.black.ladderRank ?? 2)   // park
    }

    /// Average pitch of a run, from its drop and length.
    private static func meanPitchDeg(_ edge: Edge) -> Double {
        guard edge.lengthM > 0 else { return 0 }
        return atan(abs(edge.verticalM) / edge.lengthM) * 180 / .pi
    }

    /// The pitch a run is held to the skier's limit by: measured, or the usual
    /// steepest pitch of its rating when the bundle has none or what it has is
    /// not a pitch (zero, negative, over 90° or not a number).
    private func limitPitchDeg(_ edge: Edge) -> Double {
        if let pitch = edge.gradeMaxDeg, pitch.isFinite, pitch > 0, pitch <= 90 { return pitch }
        return switch effectiveDifficulty(edge) {
        case .green: Self.unknownGreenMaxDeg
        case .blue: Self.unknownBlueMaxDeg
        case .black: Self.unknownBlackMaxDeg
        default: 45
        }
    }

    /// The skier's own choices: terrain and lifts they have said never to be
    /// routed onto, and their steepest pitch. Hard gates, like difficulty.
    private func isWithinChoices(_ edge: Edge) -> Bool {
        switch edge.kind {
        case .connection:
            return true
        case .lift:
            guard profile.avoid.contains(.surfaceLifts), let type = edge.lift?.type else {
                return true
            }
            return !(type == .tbar || type == .ropeTow || type == .magicCarpet)
        case .run:
            let avoid = profile.avoid
            if avoid.contains(.park), effectiveDifficulty(edge) == .park { return false }
            if avoid.contains(.ungroomed), isGroomed(edge) == false { return false }
            if avoid.contains(.flats), edge.lengthM >= Traversal.Run.flatMinLengthM,
               Self.meanPitchDeg(edge) < Traversal.Run.flatPitchDeg { return false }
            if let limit = profile.maxPitchDeg {
                // A limit that is not an angle never switches the gate off: it
                // blocks every run until the skier sets it again.
                guard limit.isFinite, limit > 0, limit <= 90 else { return false }
                if limitPitchDeg(edge) > limit { return false }
            }
            return true
        }
    }

    /// Everything the skier's profile rules out: difficulty, avoid choices and
    /// the pitch limit.
    func isWithinAbility(_ edge: Edge) -> Bool {
        isWithinLevel(edge) && isWithinChoices(edge)
    }

    /// Speed multiplier from what the skier rides and their build, 0.90...1.06.
    private func gearFactor(_ edge: Edge, groomed: Bool?, snowCM: Double, gradient: Double) -> Double {
        var factor = 1.0
        func lerp(_ a: Double, _ b: Double, _ t: Double) -> Double { a + (b - a) * max(0, min(1, t)) }
        // 0 at 3 cm of fresh snow, 1 at 8 cm.
        let powder = max(0, min(1, (snowCM - 3) / 5))
        let meanPitch = Self.meanPitchDeg(edge)

        if let gear = profile.equipment {
            let waist = Double(gear.waistMM ?? {
                switch gear.type {
                case .carving: 72
                case .allMountain: 88
                case .park: 92
                case .freeride: 106
                }
            }())
            let float = max(-1, min(1, (waist - 90) / 30))
            factor *= groomed == true ? 1 - 0.015 * float : 1 + lerp(0.01, 0.03, powder) * float

            switch gear.type {
            case .carving: if groomed == true { factor *= 1.01 }
            case .freeride: if groomed != true { factor *= 1 + 0.01 * powder }
            case .park: if effectiveDifficulty(edge) == .park { factor *= 1.02 }
            case .allMountain: break
            }

            if let length = gear.lengthCM, let height = profile.heightCM, height > 0 {
                let long = max(-1, min(1, (Double(length) / Double(height) - 0.95) / 0.08))
                if groomed == true, gradient < 25 {
                    factor *= 1 + 0.02 * long
                } else if groomed == false || gradient >= 30 {
                    factor *= 1 - 0.03 * long
                }
            }
        }
        if let weight = profile.weightKG, weight > 0 {
            let glide = pow(Double(weight) / Traversal.Run.weightReferenceKG, 1.0 / 6)
            let share = 1 - (meanPitch - Traversal.Run.flatPitchDeg)
                / (Traversal.Run.weightFadeDeg - Traversal.Run.flatPitchDeg)
            factor *= lerp(1, glide, share)
        }
        return max(Traversal.Run.gearFloor, min(Traversal.Run.gearCeiling, factor))
    }

    // MARK: Traversal

    /// Seconds to cover `remainingFraction` of an edge entered `elapsedS` after the
    /// solve instant, or nil when the edge cannot be taken.
    func traverseTime(
        _ edge: Edge, elapsedS: Double = 0, remainingFraction: Double = 1,
        previous: Edge? = nil, ignoreAbility: Bool = false
    ) -> Double? {
        let fraction = max(0, min(1, remainingFraction))
        // A finished prefix is no longer part of the route: a closure behind the
        // skier must not invalidate what is still ahead.
        if fraction == 0 { return 0 }
        guard !status.isClosed(edge.group) else { return nil }

        switch edge.kind {
        case .lift:
            guard let lift = edge.lift else { return nil }
            let continuing = LiftRideContinuation.isContinuation(from: previous, to: edge)
            let boards = fraction >= 1 && !continuing
            var queue = 0.0
            if boards {
                if !ignoreAbility, !isWithinChoices(edge) { return nil }
                // A lift reached at or after its close is untraversable (I-08).
                let clock = localClock(atOffset: elapsedS)
                guard let close = closingMinute(lift, clock: clock) else { return nil }
                queue = queueWaitS(lift, group: edge.group, offsetS: elapsedS, clock: clock)
                if status.isOnHold(edge.group) { queue += Traversal.Lift.holdExtraWaitS }
                // A likely wind hold costs its expected wait. Gusts change far
                // slower than a second of wait per second of delay (I-04).
                queue += windHoldLikelihood(edge, atOffset: elapsedS) * Traversal.Lift.holdExtraWaitS
                // Close is a last-loading deadline: the skier must be through the
                // queue before it, though the ride may finish after.
                if queue > 0, clock.minute + queue / 60 >= close { return nil }
                queue += max(0, profile.liftBoardingPenaltyS)
            }
            let wind = Self.liftWindRideMultiplier(windKmh: weather(atOffset: elapsedS).windKmh)
            return lift.rideS * fraction * wind + queue

        case .run:
            // Someone already part-way down a run finishes it whatever they
            // chose to avoid; difficulty gets no such exemption.
            if !ignoreAbility {
                guard isWithinDifficulty(edge), fraction < 1 || isWithinChoices(edge) else {
                    return nil
                }
            }
            guard let speed = runSpeed(edge, elapsedS: elapsedS) else { return nil }
            let lengthM = edge.lengthM * fraction
            let stops = (pace?.stopsPerKm ?? Traversal.Run.defaultStopsPerKm)
                * lengthM / 1_000 * Traversal.Run.stopSeconds
            return lengthM / speed + max(0, stops)

        case .connection:
            let snow = weather(atOffset: elapsedS).snowCM
            let speed = Traversal.Connection.baseSpeedMS
                * Traversal.Connection.speedFactor(freshSnowCM: snow)
            return edge.lengthM * fraction / speed
                + max(0, edge.verticalM) * fraction * Traversal.Connection.uphillCostSPerM
        }
    }

    private func isGroomed(_ edge: Edge) -> Bool? {
        status.isGroomed(edge.group) ? true : edge.groomedDefault
    }

    private func runSpeed(_ edge: Edge, elapsedS: Double) -> Double? {
        let difficulty = effectiveDifficulty(edge)
        let learnedEdgeFactor = pace?.edgeFactor[edge.id.stored]
        let baseSpeed = (profile.baselineSpeedMS[difficulty].flatMap { $0 > 0 ? $0 : nil }
            ?? Traversal.Run.fallbackSpeedMS)
            * (pace?.difficultyFactor[difficulty] ?? 1) * (learnedEdgeFactor ?? 1)

        // Below the threshold the skier is already cautious; soften the terrain
        // penalties so caution is not counted twice.
        let damp = baseSpeed < Traversal.Run.skillDampenThresholdMS
            ? Traversal.Run.skillDampenFactor : 1.0
        func dampen(_ factor: Double) -> Double { 1 - (1 - factor) * damp }

        let weather = weather(atOffset: elapsedS)
        let edgeTemp = temperature(weather, atElevation: edge.midpointElevationM)
        let groomed = isGroomed(edge)
        let gradient = edge.gradeMaxDeg ?? 0

        var trail: [Double] = []
        switch groomed {
        case .some(true): break
        case .some(false): trail.append(dampen(ability.ungroomedComfort))
        // Unknown grooming sits half-way between groomed and ungroomed.
        case .none: trail.append(dampen((ability.ungroomedComfort + 1) / 2))
        }
        let iceLikelihood = max(0, min(1, (Traversal.Run.iceConditionThresholdC - edgeTemp) / 4))
        if ability.icyComfort < 1, iceLikelihood > 0 {
            let full = dampen(Traversal.Run.iceAbilityBaseline
                + Traversal.Run.iceAbilityScaleFactor * ability.icyComfort)
            trail.append(1 - iceLikelihood * (1 - full))
        }
        let rampStart = ability.maxGradientDeg * 0.9
        if gradient > rampStart {
            let progress = min((gradient - rampStart) / max(ability.maxGradientDeg - rampStart, 1), 1)
            let beyond = max(0, gradient - ability.maxGradientDeg)
            trail.append(max(
                Traversal.Run.gradientPenaltyMin,
                1 - (progress + beyond / Traversal.Run.gradientPenaltyDenom)
                    * ability.steepPenaltyWeight
            ))
        }
        // A learned per-edge pace already contains this edge's terrain and the
        // gear it was ridden on.
        let trailModifier = learnedEdgeFactor == nil
            ? max(Traversal.Run.trailModifierFloor, Self.combined(trail)) : 1.0
        let gearModifier = learnedEdgeFactor == nil
            ? gearFactor(edge, groomed: groomed, snowCM: weather.snowCM, gradient: gradient) : 1.0

        var environment: [Double] = []
        let sun = SunExposure.speedMultiplier(
            exposure: SunExposure.exposure(
                aspectDeg: edge.aspectDeg, at: solveTime.addingTimeInterval(elapsedS),
                latitude: latitude, longitude: longitude, cloudPct: weather.cloudPct
            ),
            temperatureC: edgeTemp,
            hardPack: weatherTerms.contains(.sunnySide), slush: weatherTerms.contains(.shadySide)
        )
        if sun < 1 { environment.append(sun) }
        let feltWind = feltWindKmh(
            weather, atElevation: edge.midpointElevationM, aspectDeg: edge.aspectDeg
        )
        if weatherTerms.contains(.outOfTheWind), feltWind > Traversal.Run.windExposedThresholdKmh {
            environment.append(1 / (1 + (feltWind - Traversal.Run.windExposedThresholdKmh)
                * Traversal.Run.windPenaltyPerKmh))
        }
        let visibility = visibilityKm(weather, atElevation: edge.midpointElevationM)
        if weatherTerms.contains(.clearerView), visibility < Traversal.Run.visibilityPenaltyThresholdKm {
            let steep = gradient > Traversal.Run.visibilitySteepGradientDeg
                ? Traversal.Run.visibilitySteepMultiplier : 1
            environment.append(1 / (1
                + (Traversal.Run.visibilityPenaltyThresholdKm - visibility)
                * Traversal.Run.visibilityPenaltyPerKm * steep))
        }
        if weather.snowCM > Traversal.Run.freshSnowUngroomedThresholdCM, groomed != true {
            let uncertainty = groomed == nil ? 0.5 : 1
            environment.append(1 / (1 + weather.snowCM * ability.freshSnowPenaltyPerCM * uncertainty))
        }
        let ice = Traversal.Run.iceSpeedFactor(at: edgeTemp)
        if ice < 1 { environment.append(ice) }
        let crust = refrozen(weather, edgeTempC: edgeTemp)
        if crust > 0 {
            let share = groomed == true ? Traversal.Run.refrozenGroomedShare : 1
            environment.append(1 - Traversal.Run.refrozenCrustPenalty * crust * share)
        }
        var environmentModifier = max(Traversal.Run.envModifierFloor, Self.combined(environment))
        if groomed == true, weather.snowCM > 0 {
            environmentModifier *= min(
                1 + weather.snowCM * Traversal.Run.groomedBonusPerCM, Traversal.Run.groomedBonusCap
            )
        }

        let speed = baseSpeed * trailModifier * gearModifier * environmentModifier
        return speed > Traversal.Run.minViableSpeedMS ? speed : nil
    }

    /// Diminishing returns: the worst factor applies in full, the next at its
    /// square root, the next at its cube root, with a floor on the product.
    private static func combined(_ factors: [Double]) -> Double {
        let penalties = factors.filter { $0 < 1 }.sorted()
        guard !penalties.isEmpty else { return 1 }
        var product = 1.0
        for (i, p) in penalties.enumerated() { product *= pow(p, 1 / Double(i + 1)) }
        return max(Traversal.Run.combinedModifierFloor, product)
    }

    /// Mean time and variance for one edge, shared by search, stored-route
    /// re-costing and live ETA. A lift must also be catchable at the conservative
    /// (P90) arrival, so a statistically fragile last chair is not relied on.
    func evaluate(
        _ edge: Edge, elapsedS: Double, approachVariance: Double, remainingFraction: Double = 1,
        previous: Edge? = nil, ignoreAbility: Bool = false, ignoreLiftDeadlineRisk: Bool = false
    ) -> Cost? {
        guard let seconds = traverseTime(
            edge, elapsedS: elapsedS, remainingFraction: remainingFraction,
            previous: previous, ignoreAbility: ignoreAbility
        ) else { return nil }

        if edge.kind == .lift, remainingFraction >= 1, !ignoreLiftDeadlineRisk, approachVariance > 0,
           !LiftRideContinuation.isContinuation(from: previous, to: edge) {
            let conservative = elapsedS + Scoring.liftCatchConfidenceZ * approachVariance.squareRoot()
            guard traverseTime(
                edge, elapsedS: conservative, remainingFraction: remainingFraction,
                previous: previous, ignoreAbility: ignoreAbility
            ) != nil else { return nil }
        }

        let std = seconds * Traversal.timeCV(edge.kind)
        return Cost(seconds: seconds, variance: seconds > 0 ? std * std : 0)
    }
}
