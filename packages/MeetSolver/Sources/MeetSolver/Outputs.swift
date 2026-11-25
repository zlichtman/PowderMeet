import Foundation
import MountainCore

public struct ETA: Hashable, Sendable {
    public var meanS: Double
    public var sdS: Double

    public init(meanS: Double, sdS: Double) {
        self.meanS = meanS
        self.sdS = sdS
    }
}

public struct RouteLeg: Hashable, Sendable {
    public var edgeID: EdgeID
    /// Seconds from the route's start.
    public var enterS: Double
    public var exitS: Double
    /// Share of the edge already behind the skier when the route began; non-zero
    /// only on the first leg of a route that started part-way along an edge.
    public var startFraction: Double

    public init(edgeID: EdgeID, enterS: Double, exitS: Double, startFraction: Double = 0) {
        self.edgeID = edgeID
        self.enterS = enterS
        self.exitS = exitS
        self.startFraction = startFraction
    }
}

/// What an easiest-way-down route asks of a skier who has no way down within
/// their level: the runs on it above that level. Set only on such a route.
public struct EasiestWayDown: Hashable, Sendable {
    /// The hardest run on the route, above the skier's level.
    public var hardest: Difficulty
    /// Runs above the level by difficulty; a run split into several edges
    /// counts once.
    public var runsAboveLevel: [Difficulty: Int]
    /// Metres of run above the level.
    public var metresAboveLevel: Double
    /// The legs above the level, which `recost` allows on this route only.
    public var edgeIDs: [EdgeID]

    public init(
        hardest: Difficulty, runsAboveLevel: [Difficulty: Int], metresAboveLevel: Double,
        edgeIDs: [EdgeID]
    ) {
        self.hardest = hardest
        self.runsAboveLevel = runsAboveLevel
        self.metresAboveLevel = metresAboveLevel
        self.edgeIDs = edgeIDs
    }

    /// How many runs above the level in all.
    public var runCount: Int { runsAboveLevel.values.reduce(0, +) }
}

public struct Route: Hashable, Sendable {
    public var skierID: UUID
    public var legs: [RouteLeg]
    public var eta: ETA
    public var hardestDifficulty: Difficulty
    /// Physical boardings: a lift split into several edges counts once.
    public var liftCount: Int
    public var lengthM: Double
    /// Set when this skier has no way down within their level and the route is
    /// the easiest one there is (06-SOLVER section 1).
    public var easiestWayDown: EasiestWayDown?
    /// The weather that steered this route off the plain-weather way, most
    /// material first; empty when none did (06-SOLVER section 3). Set by
    /// `solve` and `route`, never on an easiest way down or a lap.
    public var weatherFavours: [WeatherFavour]

    public init(
        skierID: UUID, legs: [RouteLeg], eta: ETA, hardestDifficulty: Difficulty,
        liftCount: Int, lengthM: Double, easiestWayDown: EasiestWayDown? = nil,
        weatherFavours: [WeatherFavour] = []
    ) {
        self.easiestWayDown = easiestWayDown
        self.weatherFavours = weatherFavours
        self.skierID = skierID
        self.legs = legs
        self.eta = eta
        self.hardestDifficulty = hardestDifficulty
        self.liftCount = liftCount
        self.lengthM = lengthM
    }
}

/// Why an option is worth showing. Typed so the app owns the wording.
public enum Reason: Hashable, Sendable {
    case closerForYou
    case lessWaitFor(UUID)
    case indoor
    case avoidsBlackFor(UUID)
    case onlyOptionUnderClosures
    case statusUnknown
    /// Shared turns start at the stop; the name is the first run both can ski.
    case skiOnTogether(run: String?)
    /// This skier is already standing at the stop.
    case alreadyThere(UUID)
    /// The lodge kept in the list for when stopping is the point.
    case lodgeAlternative
    /// This skier has no way on from the stop within their limits. Appears only
    /// when every reachable stop has that problem for someone.
    case noOnwardRouteFor(UUID)
    /// This skier arrives early enough to ski a lap and be back in time; the lap
    /// is `MeetOption.lapWhileWaiting`.
    case lapWhileWaitingFor(UUID)
    /// On the first option only: this skier reaches the stop ten minutes or more
    /// before the other, and no eligible stop ranked better. The meet is uneven
    /// because of where the two are, not by mistake.
    case longWaitUnavoidable(UUID)
    /// Neither skier can board a lift from anywhere they can get to (outside
    /// operating hours, or everything closed): every route is downhill only.
    case noLiftsRunning
    /// This skier has no way down within their level, so their route is the
    /// easiest there is; the route's `easiestWayDown` says what is above it.
    case easiestWayDownFor(UUID)
    /// A lift on this skier's route is likely to be on a wind hold when they
    /// reach it, and no live status says otherwise; its expected wait is
    /// already in their arrival time.
    case windHoldLikelyFor(UUID)
}

/// Evidence that both skiers have a useful legal move after they meet: the first
/// edge of the best shared lap from the rendezvous (ski from it, or ride one lift
/// and ski). Ranking evidence only; it is never appended to either route.
public struct SharedContinuation: Hashable, Sendable {
    public enum Kind: Hashable, Sendable { case ski, ride, connect }

    public var edgeID: EdgeID
    public var name: String?
    public var kind: Kind
    /// The first run of the lap; differs from `name` when the lap starts on a
    /// lift or connector.
    public var firstRunName: String?
    public var sharedRunLengthM: Double
    public var sharedVerticalDropM: Double
    /// Group time from being ready to leave the rendezvous until the first shared
    /// run begins, including queue and ride.
    public var downhillAccessS: Double
    /// Length-weighted pace fit of the less comfortable skier, 0...1.
    public var jointTerrainFit: Double
    /// Distinct shared first runs whose utility is close to the best.
    public var sharedRunOptionCount: Int
    /// Capped 0...1 utility used by the ranking.
    public var quality: Double
}

public struct MeetOption: Hashable, Sendable {
    public var rendezvous: RendezvousID
    public var routes: (Route, Route)
    /// Reliability score in seconds; lower is better.
    public var score: Double
    /// |tA − tB|.
    public var expectedWaitS: Double
    public var reasons: [Reason]
    public var sharedContinuation: SharedContinuation?
    /// A suggestion for the skier who would otherwise wait five minutes or
    /// more: a loop from the rendezvous back to it, within their limits. Its
    /// `skierID` says whose it is, its legs start when that skier's route ends
    /// (times run on from the solve instant) and its `eta` is when they are back,
    /// at least a minute before the partner is expected. Neither route changes
    /// whether or not it is skied, but the ranking counts the time on it as
    /// skiing rather than waiting, so `score` already reflects it.
    public var lapWhileWaiting: Route?
    /// The card's headline, against the other options of the same solve. Set
    /// by `solve`; nil on an option built any other way.
    public var tradeoff: Tradeoff?

    public init(
        rendezvous: RendezvousID, routes: (Route, Route), score: Double,
        expectedWaitS: Double, reasons: [Reason], sharedContinuation: SharedContinuation? = nil,
        lapWhileWaiting: Route? = nil, tradeoff: Tradeoff? = nil
    ) {
        self.rendezvous = rendezvous
        self.routes = routes
        self.score = score
        self.expectedWaitS = expectedWaitS
        self.reasons = reasons
        self.sharedContinuation = sharedContinuation
        self.lapWhileWaiting = lapWhileWaiting
        self.tradeoff = tradeoff
    }

    public static func == (lhs: MeetOption, rhs: MeetOption) -> Bool {
        lhs.rendezvous == rhs.rendezvous && lhs.routes.0 == rhs.routes.0
            && lhs.routes.1 == rhs.routes.1 && lhs.score == rhs.score
            && lhs.expectedWaitS == rhs.expectedWaitS && lhs.reasons == rhs.reasons
            && lhs.sharedContinuation == rhs.sharedContinuation
            && lhs.lapWhileWaiting == rhs.lapWhileWaiting && lhs.tradeoff == rhs.tradeoff
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(rendezvous)
        hasher.combine(routes.0)
        hasher.combine(routes.1)
        hasher.combine(score)
    }
}

public struct MeetOptions: Hashable, Sendable {
    /// Best first.
    public var options: [MeetOption]
    public var statusFreshness: StatusFreshness
    /// True when the solve ran on operating hours instead of fresh status; the
    /// app badges every card.
    public var degraded: Bool

    public init(options: [MeetOption], statusFreshness: StatusFreshness, degraded: Bool) {
        self.options = options
        self.statusFreshness = statusFreshness
        self.degraded = degraded
    }
}

public enum SolveFailure: Error, Hashable, Sendable {
    /// The origin does not exist in the bundle, or nothing leads away from it.
    case originNotOnGraph(UUID)
    /// No catalog rendezvous is reachable for this skier under the gates.
    case noRendezvousReachable(UUID)
    /// Only under `.strict`.
    case statusExpired
    case bundleUnusable(String)
    /// A route exists but only over terrain this skier's limits exclude.
    case abilityBlocksAll(UUID)
    /// The only shared routes depend on a lift too close to last chair to catch
    /// reliably.
    case liftDeadlineRisk
    case lostAll
}
