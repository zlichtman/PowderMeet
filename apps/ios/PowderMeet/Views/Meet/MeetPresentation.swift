import AppCore
import Foundation
import MeetSolver
import MountainCore
import PowderMeetAPI

// Wording the PowderMeet tab's cards share. Pure functions of projection
// values.
nonisolated enum MeetPresentation {
    static func kindLabel(_ kind: RendezvousKind?) -> String {
        switch kind {
        case .lodge: "Lodge"
        case .liftBase: "Lift base"
        case .liftTop: "Lift top"
        case .junction: "Trail junction"
        case .landmark: "Landmark"
        case nil: "Designated meeting point"
        }
    }

    static func kindIcon(_ kind: RendezvousKind?) -> String {
        switch kind {
        case .lodge: "house.fill"
        case .liftBase: "cablecar.fill"
        case .liftTop: "mountain.2.fill"
        case .junction: "arrow.triangle.branch"
        case .landmark: "mappin.and.ellipse"
        case nil: "mappin.circle.fill"
        }
    }

    static func elevationM(of id: RendezvousID, in bundle: ResortBundle?) -> Double? {
        guard let bundle, let nodeID = bundle.rendezvous(id)?.nodeID else { return nil }
        return bundle.graph.nodes[nodeID]?.eleM
    }

    /// "Lift base · 3,353 ft": short enough for one line beside the card's buttons.
    static func placeLine(_ id: RendezvousID, in bundle: ResortBundle?) -> String {
        let kind = kindLabel(bundle?.rendezvous(id)?.kind)
        guard let elevation = elevationM(of: id, in: bundle) else { return kind }
        return "\(kind) · \(UnitFormatter.elevation(elevation))"
    }

    /// A step's name, or for an unnamed one `TerrainName`'s words and, off a
    /// lift, its length so the skier can tell when it ends: "Unnamed blue run ·
    /// 350 m", "Connector · 40 m", "Unnamed lift". `withLength` false drops the
    /// length, for a one-line "Then" that must not cut off.
    static func stepName(_ maneuver: Maneuver, withLength: Bool = true) -> String {
        if let name = TerrainName.named(maneuver.name) { return name }
        let kind = switch maneuver.action {
        case .ski: TerrainName.run(nil, difficulty: maneuver.difficulty)
        case .ride: TerrainName.lift(nil, type: nil)
        case .connect: TerrainName.connector(nil)
        }
        guard withLength, maneuver.action != .ride, maneuver.lengthM > 0 else { return kind }
        return "\(kind) · \(UnitFormatter.distance(maneuver.lengthM))"
    }

    static func stepIcon(_ action: Maneuver.Action) -> String {
        switch action {
        case .ski: "arrow.down"
        case .ride: "arrow.up"
        case .connect: "arrow.right"
        }
    }

    /// The route profile line: hardest terrain, lift boardings, distance, and
    /// the weather that steered the route when any did ("Sunny side").
    static func facts(_ route: Route, maneuvers: [Maneuver]) -> String? {
        var parts: [String] = []
        // `hardestDifficulty` reads green on a route with no runs; say nothing then.
        if maneuvers.contains(where: { $0.action == .ski }) {
            switch route.hardestDifficulty {
            case .unknown: parts.append("Unrated sections")
            case .park: parts.append("Park features")
            default: parts.append("\(route.hardestDifficulty.displayName) max")
            }
        }
        if route.liftCount > 0 {
            parts.append("\(route.liftCount) \(route.liftCount == 1 ? "lift" : "lifts")")
        }
        if route.lengthM > 0 {
            parts.append(UnitFormatter.distance(route.lengthM))
        }
        if let favour = route.weatherFavours.first {
            parts.append(Wording.weatherFavour(favour))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// The later of the two arrivals, with its uncertainty.
    static func together(_ option: MeetOption) -> String {
        let mine = option.routes.0.eta, theirs = option.routes.1.eta
        return Wording.eta(mine.meanS >= theirs.meanS ? mine : theirs)
    }

    /// "EXPECTED WAIT · YOU ~4m": the balance line.
    static func balance(_ option: MeetOption, partnerName: String) -> String {
        let wait = option.expectedWaitS
        guard wait > 30 else { return "Similar estimated arrivals" }
        let who = option.routes.0.eta.meanS < option.routes.1.eta.meanS
            ? "You" : partnerName
        let amount = wait >= 60 ? Wording.minutes(wait) : "\(Int(wait.rounded()))s"
        return "Expected wait · \(who) ~\(amount)"
    }

    /// Compares P10–P90 ranges (mean ± 1.28 sd) to say whether either may wait.
    static func arrivalDetail(_ option: MeetOption) -> String {
        let mine = option.routes.0.eta, theirs = option.routes.1.eta
        let overlap = abs(mine.meanS - theirs.meanS) <= 1.28 * (mine.sdS + theirs.sdS)
        return overlap
            ? "Arrival ranges overlap · Either skier may wait"
            : "Wait may change with pace, lifts & conditions"
    }

    // MARK: Spoken prompts

    /// The prompt for the step the skier is now on: short, the action and the
    /// name ("Ride Peak Express", "Ski Franz's Run, blue").
    static func spokenInstruction(_ maneuver: Maneuver) -> String {
        let name = maneuver.name.flatMap { $0.isEmpty ? nil : $0 }
        switch maneuver.action {
        case .ride:
            return name.map { "Ride \($0)" } ?? "Ride the lift"
        case .connect:
            return name.map { "Take \($0)" } ?? "Take the connector"
        case .ski:
            let rating = maneuver.difficulty.flatMap { difficulty -> String? in
                switch difficulty {
                case .unknown: nil
                default: difficulty.displayName.lowercased()
                }
            }
            let run = name.map { "Ski \($0)" } ?? "Ski on"
            return rating.map { "\(run), \($0)" } ?? run
        }
    }

    // MARK: Weather notice

    /// The caveat over the meeting options when the weather the solver used is
    /// missing or past its expiry. The solver prices stale conditions as they
    /// are (the last reading, at the solve instant), so the notice says so.
    static func weatherNotice(_ conditions: Conditions?, now: Date) -> String? {
        guard let conditions else { return "No live weather · Routes use terrain and closures" }
        guard now >= conditions.expiresAt else { return nil }
        return "Weather is stale · Last reading \(Wording.age(since: conditions.observedAt, now: now)) "
            + "· Routes use it until it refreshes"
    }

    /// The note for a card whose route was priced on scheduled hours because
    /// lift and trail status is stale or missing: the same test the solver uses
    /// for an option's `degraded`. Nil when status is fresh.
    static func statusNote(_ status: ResortStatus?, now: Date) -> String? {
        StatusFreshness.of(status, at: now) == .fresh ? nil : Wording.reason(.statusUnknown, partnerName: "")
    }

    /// Whether the viewer ended the meet, from the row's `ended_by`; nil when
    /// the server did or does not say, so the wording falls back to a guess.
    static func endedByViewer(_ meet: Meet?, partnerID: UUID) -> Bool? {
        meet?.endedBy.map { $0 != partnerID }
    }

    /// A failed call's message. A rate limit on proposing has its own words.
    static func failureMessage(_ failure: PowderMeetError) -> String {
        if case .network(.server(let status)) = failure, status == 429 {
            return "Too many invitations. Try again in a little while."
        }
        return failure.userMessage
    }

    // MARK: Headline

    /// An option card's headline: for the pick, why it won; for the others, what
    /// each does better than the pick. Without a tradeoff (an option the solver
    /// did not label) the card reads TOP MATCH, then OPTION n.
    static func headline(_ tradeoff: Tradeoff?, index: Int) -> String {
        switch tradeoff {
        case .fastestTogether: "Fastest Together"
        case .leastWaiting: "Least Waiting"
        // "Predictable" said nothing to a skier: it means the arrival times
        // are the least likely to slip (fewer queues and long runs in doubt).
        case .mostPredictable: "Steadiest Timing"
        case .easiestTerrain: "Easiest Terrain"
        case .fewestLifts: "Fewest Lifts"
        case .bestBalance: "Best Balance"
        case .onlyOption: "Recommended Stop"
        case .lodgeBreak: "Lodge Break"
        case .easierTerrain: "Easier Terrain"
        case .quickerArrival: "Quicker Arrival"
        case .lessSkating: "Less Skating"
        case .lessWaiting: "Less Waiting"
        case .morePredictable: "Steadier Timing"
        case .fewerLifts: "Fewer Lifts"
        case .yourPick: "Your Pick"
        case .alternative, nil: index == 0 ? "Top Match" : "Option \(index + 1)"
        }
    }

    /// The headline's symbol: the pick wears the star, every other option
    /// the symbol of what it offers instead.
    static func headlineIcon(_ tradeoff: Tradeoff?, index: Int) -> String {
        if index == 0 { return "star.fill" }
        return switch tradeoff {
        case .yourPick: "magnifyingglass"
        case .lodgeBreak: "cup.and.saucer.fill"
        case .leastWaiting, .lessWaiting: "hourglass"
        case .mostPredictable, .morePredictable: "metronome.fill"
        case .easiestTerrain, .easierTerrain: "figure.skiing.downhill"
        case .fewestLifts, .fewerLifts: "cablecar.fill"
        case .quickerArrival, .fastestTogether: "bolt.fill"
        case .lessSkating: "arrow.down.right"
        case .bestBalance, .onlyOption, .alternative, nil: "mappin.circle.fill"
        }
    }

    // MARK: Why this option

    /// One line of an option card's WHY list.
    struct WhyLine: Hashable {
        enum Tone { case good, neutral, caution }

        var icon: String
        var text: String
        /// Smaller supporting copy under the line.
        var detail: String?
        var tone: Tone
    }

    /// The solver's reasons for an option, in plain words and in reading order:
    /// what happens after you meet, who is already there, what kind of stop it
    /// is, then the rest. The status caveat and the lap have their own places
    /// on the card and are left out here.
    static func why(_ option: MeetOption, partnerName: String) -> [WhyLine] {
        let me = option.routes.0.skierID
        let reasons = option.reasons
        func text(_ reason: Reason) -> String {
            Wording.reason(reason, partnerName: partnerName, me: me)
        }
        var lines: [WhyLine] = []

        // What you can do together next: the solver's reason when it gave one,
        // otherwise the shared lift or run it found.
        let onwardDetail = option.sharedContinuation.map(continuationDetail)
        if let together = reasons.first(where: { if case .skiOnTogether = $0 { true } else { false } }) {
            lines.append(WhyLine(
                icon: "figure.skiing.downhill", text: text(together), detail: onwardDetail, tone: .good
            ))
        } else if let continuation = option.sharedContinuation,
                  let title = continuationTitle(continuation) {
            lines.append(WhyLine(
                icon: continuationIcon(continuation.kind), text: title, detail: onwardDetail, tone: .good
            ))
        }

        let stuck = reasons.compactMap { reason -> UUID? in
            if case .noOnwardRouteFor(let skier) = reason { skier } else { nil }
        }
        if stuck.count > 1 {
            lines.append(WhyLine(
                icon: "exclamationmark.triangle.fill", text: "Nobody can ski on from here",
                detail: nil, tone: .caution
            ))
        }

        let isLodgeOption = reasons.contains(.lodgeAlternative)
        for reason in reasons {
            switch reason {
            case .skiOnTogether, .statusUnknown, .lapWhileWaitingFor:
                continue
            case .noOnwardRouteFor:
                if stuck.count > 1 { continue }
                lines.append(WhyLine(
                    icon: "exclamationmark.triangle.fill", text: text(reason), detail: nil, tone: .caution
                ))
            case .longWaitUnavoidable:
                lines.append(WhyLine(icon: "hourglass", text: text(reason), detail: nil, tone: .caution))
            case .noLiftsRunning:
                lines.append(WhyLine(icon: "moon.zzz.fill", text: text(reason), detail: nil, tone: .caution))
            case .alreadyThere:
                lines.append(WhyLine(icon: "mappin.and.ellipse", text: text(reason), detail: nil, tone: .good))
            case .lodgeAlternative:
                lines.append(WhyLine(icon: "cup.and.saucer.fill", text: text(reason), detail: nil, tone: .neutral))
            case .indoor:
                // The lodge line already says it is inside.
                if isLodgeOption { continue }
                lines.append(WhyLine(icon: "house.fill", text: text(reason), detail: nil, tone: .neutral))
            case .onlyOptionUnderClosures:
                lines.append(WhyLine(icon: "nosign", text: text(reason), detail: nil, tone: .caution))
            case .closerForYou:
                lines.append(WhyLine(icon: "location.fill", text: text(reason), detail: nil, tone: .neutral))
            case .lessWaitFor:
                lines.append(WhyLine(icon: "hourglass", text: text(reason), detail: nil, tone: .neutral))
            case .avoidsBlackFor:
                lines.append(WhyLine(icon: "shield.fill", text: text(reason), detail: nil, tone: .neutral))
            case .easiestWayDownFor:
                // First on the card, below.
                continue
            case .windHoldLikelyFor:
                lines.append(WhyLine(icon: "wind", text: text(reason), detail: nil, tone: .caution))
            }
        }
        // Someone has no way down within their level: said before anything else.
        let easiest = [option.routes.0, option.routes.1].compactMap { route -> WhyLine? in
            guard let summary = easiestWayDown(route, me: me, partnerName: partnerName) else { return nil }
            return WhyLine(
                icon: "exclamationmark.triangle.fill", text: summary.title, detail: summary.detail,
                tone: .caution
            )
        }
        return easiest + lines
    }

    /// The label for a route that is the easiest way down for a skier with no
    /// way down within their level: "Easiest way down for Dev 1" and "One blue
    /// run is above their level." Nil for any other route.
    static func easiestWayDown(
        _ route: Route?, me: UUID, partnerName: String
    ) -> (title: String, detail: String)? {
        guard let route, let easiest = route.easiestWayDown else { return nil }
        let isYou = route.skierID == me
        return (
            Wording.reason(.easiestWayDownFor(route.skierID), partnerName: partnerName, me: me),
            Wording.easiestWayDownSummary(easiest, isYou: isYou)
        )
    }

    /// The same label as one line, for a card's note: "Easiest way down for
    /// you · One blue run is above your level."
    static func easiestWayDownNote(_ route: Route?, me: UUID, partnerName: String) -> String? {
        easiestWayDown(route, me: me, partnerName: partnerName).map { "\($0.title) · \($0.detail)" }
    }

    /// What a skier needs before choosing, said on the collapsed option card:
    /// a route above someone's level, then unknown lift status. `me` is the
    /// skier of `option.routes.0`.
    static func collapsedCautions(_ option: MeetOption, degraded: Bool, partnerName: String) -> [String] {
        let easiest = [option.routes.0, option.routes.1].compactMap {
            easiestWayDownNote($0, me: option.routes.0.skierID, partnerName: partnerName)
        }
        return easiest + (degraded ? [Wording.reason(.statusUnknown, partnerName: partnerName)] : [])
    }

    // MARK: A lap while waiting

    /// The optional lap for the skier who would otherwise wait, in words.
    struct LapSummary: Hashable {
        var title: String
        /// "RIDE MAGIC CHAIR · SKI SHORTHORN, GREEN LINE".
        var path: String
        /// "~19m LAP · BACK ~3m BEFORE ALEX".
        var detail: String
    }

    /// How long the lap takes, from leaving the meeting point to being back.
    static func lapDurationS(_ lap: Route, waiterArrivalS: Double) -> Double {
        max(0, lap.eta.meanS - (lap.legs.first?.enterS ?? waiterArrivalS))
    }

    /// The lifts and runs of a lap by name, in the order they are taken.
    static func lapPath(_ maneuvers: [Maneuver]) -> String {
        func names(_ action: Maneuver.Action) -> [String] {
            var seen: [String] = []
            for maneuver in maneuvers where maneuver.action == action {
                guard let name = maneuver.name, !name.isEmpty, !seen.contains(name) else {
                    continue
                }
                seen.append(name)
            }
            return seen
        }
        func list(_ all: [String]) -> String {
            let shown = all.prefix(2).joined(separator: ", ")
            return all.count > 2 ? "\(shown) +\(all.count - 2)" : shown
        }
        var parts: [String] = []
        let lifts = names(.ride), runs = names(.ski)
        if !lifts.isEmpty { parts.append("Ride \(list(lifts))") }
        if !runs.isEmpty { parts.append("Ski \(list(runs))") }
        return parts.isEmpty ? "A lift and a run from the meeting point" : parts.joined(separator: " · ")
    }

    /// The lap on an option card. `isMine` says whose lap it is.
    static func lap(_ option: MeetOption, partnerName: String, bundle: ResortBundle?) -> LapSummary? {
        guard let lap = option.lapWhileWaiting else { return nil }
        let isMine = lap.skierID == option.routes.0.skierID
        let waiter = isMine ? option.routes.0 : option.routes.1
        let other = isMine ? option.routes.1 : option.routes.0
        let partner = partnerName
        let duration = lapDurationS(lap, waiterArrivalS: waiter.eta.meanS)
        let margin = other.eta.meanS - lap.eta.meanS
        return LapSummary(
            title: isMine ? "Optional · A lap while you wait" : "Optional · \(partner) can lap while waiting",
            path: lapPath(bundle.map { Maneuvers.build(for: lap, in: $0) } ?? []),
            detail: "~\(Wording.minutes(duration)) lap · Back ~\(Wording.minutes(margin)) before "
                + (isMine ? "\(partner) arrives" : "You arrive")
        )
    }

    static func continuationTitle(_ continuation: SharedContinuation) -> String? {
        guard let name = continuation.name, !name.isEmpty else { return nil }
        let action = switch continuation.kind {
        case .ski: "Ski"
        case .ride: "Ride"
        case .connect: "Take"
        }
        return "Both can \(action) \(name) next"
    }

    static func continuationDetail(_ continuation: SharedContinuation) -> String {
        let distance = UnitFormatter.distance(continuation.sharedRunLengthM)
        let vertical = UnitFormatter.verticalDrop(continuation.sharedVerticalDropM)
        if continuation.downhillAccessS >= 60 {
            let minutes = max(1, Int((continuation.downhillAccessS / 60).rounded()))
            return "\(minutes)m to run · \(distance) · \(vertical) vert"
        }
        if continuation.sharedRunOptionCount > 1 {
            return "\(continuation.sharedRunOptionCount) run options · \(distance) · \(vertical) vert"
        }
        return "\(distance) shared · \(vertical) vert"
    }

    static func continuationIcon(_ kind: SharedContinuation.Kind) -> String {
        switch kind {
        case .ski: "figure.skiing.downhill"
        case .ride: "cablecar.fill"
        case .connect: "arrow.right"
        }
    }

    /// "4:32" until `date`.
    static func countdown(to date: Date, now: Date) -> String {
        let seconds = max(0, Int(date.timeIntervalSince(now).rounded(.up)))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
