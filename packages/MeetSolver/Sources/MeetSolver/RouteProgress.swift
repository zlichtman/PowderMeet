import Foundation
import MountainCore

/// Where a skier is along their route, as decided by geometry. A value: each fix
/// produces the next one from the last, so there is no tracker object to keep in
/// step with the route.
public struct Progress: Hashable, Sendable {
    /// `arrived` means the route's geometry is used up: the skier is within
    /// `RouteProgress.nearlyThereRadiusM` of the meeting point. That is "nearly
    /// there" for drawing the route, not the meet's arrival, which the phone
    /// decides on its own stricter rule (`MeetSession`, protocol section 4).
    public enum State: Hashable, Sendable { case onRoute, offRoute, arrived }

    /// Index into `Route.legs` of the leg being travelled.
    public var legIndex: Int
    /// 0...1 along that leg's edge; never decreases within a leg.
    public var fractionAlongLeg: Double
    public var state: State
    public var remainingM: Double
    /// Distance from the last fix to the remaining route.
    public var deviationM: Double
    public var lastFixAt: Date?

    // Debounce memory carried between fixes.
    var deviationStartedAt: Date?
    var consecutiveOnRouteFixes = 0
    var laterLegCandidate: Int?
    var laterLegCandidateStartedAt: Date?
    var laterLegCandidateFixes = 0

    public init(legIndex: Int = 0, fractionAlongLeg: Double = 0, state: State = .onRoute,
                remainingM: Double = 0, deviationM: Double = 0, lastFixAt: Date? = nil) {
        self.legIndex = legIndex
        self.fractionAlongLeg = fractionAlongLeg
        self.state = state
        self.remainingM = remainingM
        self.deviationM = deviationM
        self.lastFixAt = lastFixAt
    }
}

public enum RouteProgress {
    /// A leg's end counts as reached within this radius of its node.
    public static let arrivalRadiusM = 80.0
    /// A fix inside this corridor is on the route.
    public static let routeCorridorM = 65.0
    /// The final node must be this close before the route completes. Loose on
    /// purpose, so sparse geometry still finishes; never the meet's arrival.
    public static let nearlyThereRadiusM = 110.0
    /// Off-route is declared only after this long, this far from the route.
    public static let deviationPersistenceS = 20.0
    public static let deviationDistanceM = 150.0
    static let stickyOnRouteFixes = 3
    static let laterLegConfirmationFixes = 3
    static let laterLegConfirmationS = 4.0
    static let laterLegMaximumDistanceM = 45.0
    static let laterLegSeparationMarginM = 20.0

    /// Progress at the start of a route, honouring a part-travelled first leg.
    public static func start(_ route: Route, in bundle: ResortBundle) -> Progress {
        var progress = Progress(fractionAlongLeg: route.legs.first?.startFraction ?? 0)
        progress.remainingM = remainingM(
            edges: edges(of: route, in: bundle), legIndex: 0, fraction: progress.fractionAlongLeg
        )
        return progress
    }

    /// Projects a fix onto the remaining route (invariant I-11). Within-leg
    /// progress never moves backwards; joining a later leg needs repeated,
    /// clearly separated matches; off-route needs persistent, distant deviation.
    /// Fixes are ordered by capture time, so a replayed fix changes nothing.
    public static func project(
        fix: Fix, onto route: Route, in bundle: ResortBundle, after previous: Progress
    ) -> Progress {
        guard previous.state != .arrived, fix.coordinate.isValid,
              fix.capturedAt.timeIntervalSinceReferenceDate.isFinite else { return previous }
        if let last = previous.lastFixAt, fix.capturedAt <= last { return previous }
        let legs = edges(of: route, in: bundle)
        guard legs.count == route.legs.count, !legs.isEmpty, previous.legIndex < legs.count,
              let meeting = bundle.graph.nodes[legs[legs.count - 1].to] else { return previous }

        var p = previous
        p.lastFixAt = fix.capturedAt
        let now = fix.capturedAt
        let point = fix.coordinate
        let nodes = bundle.graph.nodes
        func distance(toNode id: NodeID) -> Double {
            nodes[id].map { Geo.haversineM(point, $0.coordinate) } ?? .infinity
        }
        let nearMeeting = Geo.haversineM(point, meeting.coordinate) <= nearlyThereRadiusM

        func settle(legIndex: Int, fraction: Double) -> Progress {
            p.legIndex = legIndex
            p.fractionAlongLeg = fraction
            p.state = legIndex >= legs.count ? .arrived : .onRoute
            p.deviationStartedAt = nil
            p.consecutiveOnRouteFixes = 0
            resetCandidate(&p)
            p.remainingM = remainingM(edges: legs, legIndex: legIndex, fraction: fraction)
            p.deviationM = 0
            return p
        }
        func onRoute() -> Progress {
            p.consecutiveOnRouteFixes += 1
            // One stray on-route fix between two clearly off ones must not reset
            // the deviation timer.
            if p.consecutiveOnRouteFixes >= stickyOnRouteFixes { p.deviationStartedAt = nil }
            p.state = .onRoute
            p.remainingM = remainingM(edges: legs, legIndex: p.legIndex, fraction: p.fractionAlongLeg)
            return p
        }

        let projections = (p.legIndex..<legs.count).map { index in
            (index, Geo.project(point, onto: legs[index].coordinates))
        }
        let current = projections[0].1
        // Earlier legs win ties so progress does not jump where lines overlap.
        let nearest = projections.reduce(nil as (index: Int, at: PolylineProjection)?) { best, item in
            guard let projection = item.1 else { return best }
            if let best, projection.distanceM >= best.at.distanceM - 0.01 { return best }
            return (item.0, projection)
        }
        p.deviationM = nearest?.at.distanceM ?? .infinity

        // 1. The current leg's end is reached: physically close to its node and
        //    past the leg's midpoint or already on a later leg.
        let currentEdge = legs[p.legIndex]
        let pastMidpoint = (current?.fraction ?? 0) >= 0.5 || (nearest?.index ?? p.legIndex) > p.legIndex
        if distance(toNode: currentEdge.to) <= arrivalRadiusM, pastMidpoint {
            let finishes = p.legIndex + 1 >= legs.count
            if finishes, !nearMeeting {
                p.state = .onRoute
                p.deviationStartedAt = nil
                return p
            }
            return settle(legIndex: p.legIndex + 1, fraction: 0)
        }

        // 2. A later leg's end is the closest remaining junction: strong evidence
        //    of a shortcut, but only after sustained confirmation.
        if p.legIndex + 1 < legs.count {
            let ends = (p.legIndex..<legs.count).map { ($0, distance(toNode: legs[$0].to)) }
            if let closest = ends.min(by: { $0.1 < $1.1 }), closest.0 > p.legIndex,
               closest.1 <= arrivalRadiusM, closest.0 + 1 < legs.count || nearMeeting {
                guard confirmCandidate(&p, leg: closest.0, at: now) else { return onRoute() }
                return settle(legIndex: closest.0 + 1, fraction: 0)
            }
        }

        // 3. The remaining route's actual geometry.
        if let nearest, nearest.at.distanceM <= routeCorridorM {
            if nearest.index == p.legIndex {
                resetCandidate(&p)
                p.fractionAlongLeg = max(p.fractionAlongLeg, nearest.at.fraction)
            } else {
                // A later leg must be materially closer than the current one, not
                // merely win a tie where the lines meet.
                let separated = current.map {
                    $0.distanceM >= nearest.at.distanceM + laterLegSeparationMarginM
                } ?? true
                if separated, nearest.at.distanceM <= laterLegMaximumDistanceM {
                    if confirmCandidate(&p, leg: nearest.index, at: now) {
                        return settle(legIndex: nearest.index, fraction: nearest.at.fraction)
                    }
                } else {
                    resetCandidate(&p)
                }
            }
            return onRoute()
        }
        resetCandidate(&p)

        // 4. Sparse geometry: a route junction counts only when the fix is
        //    physically near it. Node identity alone is never enough.
        let nearestJunction = legs[p.legIndex...].flatMap { [$0.from, $0.to] }
            .map(distance(toNode:)).min() ?? .infinity
        if nearestJunction <= arrivalRadiusM * 1.5 { return onRoute() }

        // 5. Off the route: declared only once it has lasted and is far enough.
        p.consecutiveOnRouteFixes = 0
        let startedAt = p.deviationStartedAt ?? now
        p.deviationStartedAt = startedAt
        if now.timeIntervalSince(startedAt) >= deviationPersistenceS,
           p.deviationM >= deviationDistanceM {
            p.state = .offRoute
        }
        return p
    }

    private static func edges(of route: Route, in bundle: ResortBundle) -> [Edge] {
        route.legs.compactMap { bundle.graph.edge($0.edgeID) }
    }

    private static func remainingM(edges: [Edge], legIndex: Int, fraction: Double) -> Double {
        guard legIndex < edges.count else { return 0 }
        return edges[legIndex].lengthM * (1 - max(0, min(1, fraction)))
            + edges[(legIndex + 1)...].reduce(0) { $0 + $1.lengthM }
    }

    private static func resetCandidate(_ p: inout Progress) {
        p.laterLegCandidate = nil
        p.laterLegCandidateStartedAt = nil
        p.laterLegCandidateFixes = 0
    }

    private static func confirmCandidate(_ p: inout Progress, leg: Int, at now: Date) -> Bool {
        if p.laterLegCandidate == leg {
            p.laterLegCandidateFixes += 1
        } else {
            p.laterLegCandidate = leg
            p.laterLegCandidateStartedAt = now
            p.laterLegCandidateFixes = 1
        }
        return p.laterLegCandidateFixes >= laterLegConfirmationFixes
            && now.timeIntervalSince(p.laterLegCandidateStartedAt ?? now) >= laterLegConfirmationS
    }
}
