import Foundation
import MountainCore

/// The one-line headline of an option card: for the pick, why it won; for any
/// other option, what it does better than the pick. Typed so the app owns the
/// wording, like `Reason`. It reads idle time (the wait left after any lap),
/// not the raw arrival spread, so a lap is skiing, not waiting, here as in the
/// ranking.
public enum Tradeoff: Hashable, Sendable {
    // The pick.
    /// Every other option has both skiers together at least 30 s later.
    case fastestTogether
    /// Every other option leaves someone standing at least a minute longer.
    case leastWaiting
    /// Every other option's arrival is markedly less certain.
    case mostPredictable
    /// Every other option reaches harder marked terrain.
    case easiestTerrain
    /// Every other option boards more lifts.
    case fewestLifts
    /// No single measure decided it.
    case bestBalance
    /// Nothing else was offered; not proof that no other stop exists.
    case onlyOption

    // Any other option, against the pick.
    /// The lodge kept on the list for a break.
    case lodgeBreak
    case easierTerrain
    case quickerArrival
    case lessSkating
    case lessWaiting
    case morePredictable
    case fewerLifts
    /// Nothing measurably better than the pick; it is simply another stop.
    case alternative
    /// The place the skier asked for (`SolveOptions.requested`), which the
    /// solver's own list left out.
    case yourPick
}

enum Tradeoffs {
    struct Metrics: Hashable {
        /// Hardest marked run on either route on the green-to-double-black
        /// ladder; nil when any run is unrated or park (not an ordinal rating).
        var terrainRank: Int?
        var latestArrivalS: Double
        /// Minutes the earlier skier stands, after any lap.
        var idleS: Double
        var uncertaintyS: Double
        var liftBoardings: Int
        var connectorM: Double = 0
        /// The card already says the meet is uneven or downhill only: it must
        /// not also boast about speed or waiting.
        var flaggedUneven = false
        var isLodgeAlternative = false
    }

    static func metrics(_ option: MeetOption, graph: Graph) -> Metrics {
        var ranks: [Int?] = []
        var connectorM = 0.0
        for route in [option.routes.0, option.routes.1] {
            for leg in route.legs {
                guard let edge = graph.edge(leg.edgeID) else { continue }
                switch edge.kind {
                case .run: ranks.append(edge.difficulty?.ladderRank)
                case .connection: connectorM += edge.lengthM * (1 - leg.startFraction)
                case .lift: break
                }
            }
        }
        let lap = option.lapWhileWaiting.map { $0.eta.meanS - ($0.legs.first?.enterS ?? $0.eta.meanS) } ?? 0
        let a = option.routes.0.eta, b = option.routes.1.eta
        return Metrics(
            terrainRank: ranks.contains(where: { $0 == nil }) ? nil : (ranks.compactMap { $0 }.max() ?? 0),
            latestArrivalS: max(a.meanS, b.meanS),
            idleS: max(0, option.expectedWaitS - max(0, lap)),
            uncertaintyS: (a.sdS * a.sdS + b.sdS * b.sdS).squareRoot(),
            liftBoardings: option.routes.0.liftCount + option.routes.1.liftCount,
            connectorM: connectorM,
            flaggedUneven: option.reasons.contains {
                switch $0 {
                case .longWaitUnavoidable, .noLiftsRunning: true
                default: false
                }
            },
            isLodgeAlternative: option.reasons.contains(.lodgeAlternative)
        )
    }

    /// Why the pick won, against every option shown after it.
    static func primary(_ pick: Metrics, alternates: [Metrics]) -> Tradeoff {
        guard !alternates.isEmpty else { return .onlyOption }
        if !pick.flaggedUneven {
            if alternates.allSatisfy({ $0.latestArrivalS >= pick.latestArrivalS + 30 }) {
                return .fastestTogether
            }
            if alternates.allSatisfy({ $0.idleS >= pick.idleS + 60 }) { return .leastWaiting }
        }
        if alternates.allSatisfy({
            $0.uncertaintyS >= pick.uncertaintyS + 30 && pick.uncertaintyS <= $0.uncertaintyS * 0.85
        }) {
            return .mostPredictable
        }
        if let rank = pick.terrainRank, alternates.allSatisfy({ ($0.terrainRank ?? -1) > rank }) {
            return .easiestTerrain
        }
        if alternates.allSatisfy({ $0.liftBoardings > pick.liftBoardings }) { return .fewestLifts }
        return .bestBalance
    }

    /// What an option does better than the pick, the most material first.
    static func alternate(_ option: Metrics, against pick: Metrics) -> Tradeoff {
        if option.isLodgeAlternative { return .lodgeBreak }
        if let rank = option.terrainRank, let pickRank = pick.terrainRank, rank < pickRank {
            return .easierTerrain
        }
        if option.latestArrivalS + 30 < pick.latestArrivalS { return .quickerArrival }
        if option.connectorM + 100 < pick.connectorM, option.connectorM <= pick.connectorM * 0.75 {
            return .lessSkating
        }
        if option.idleS + 60 < pick.idleS { return .lessWaiting }
        if option.uncertaintyS + 30 < pick.uncertaintyS, option.uncertaintyS <= pick.uncertaintyS * 0.85 {
            return .morePredictable
        }
        if option.liftBoardings < pick.liftBoardings { return .fewerLifts }
        return .alternative
    }

    /// Labels a finished, ranked list in place.
    static func assign(_ options: inout [MeetOption], graph: Graph) {
        guard let first = options.first else { return }
        let pick = metrics(first, graph: graph)
        let others = options.dropFirst().map { metrics($0, graph: graph) }
        options[0].tradeoff = primary(pick, alternates: others)
        for (offset, other) in others.enumerated() {
            options[offset + 1].tradeoff = alternate(other, against: pick)
        }
    }
}
