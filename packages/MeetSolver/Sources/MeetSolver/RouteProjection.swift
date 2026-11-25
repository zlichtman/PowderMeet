import Foundation
import MountainCore

/// A solved route with its geometry, to ask where the skier will be at a
/// route time (seconds from the route's start). The leg times are the
/// solver's own, so a projection uses the same pace, conditions, status and
/// lift waits the route was solved with. Within a leg the skier moves evenly
/// along the edge; a lift leg's time includes its wait, so on a lift the
/// position is an even share of wait and ride.
///
/// Built once per route; `position(atRouteTime:)` is a binary search and one
/// interpolation, cheap enough to call on every frame of a scrub.
public struct RouteProjection: Sendable, Hashable {
    public struct Position: Sendable, Hashable {
        public var coordinate: Coordinate
        public var legIndex: Int
        /// Share of the leg's edge behind the skier.
        public var fractionAlongLeg: Double
        /// At or past the end of the route.
        public var arrived: Bool
    }

    public let route: Route
    /// Each leg's edge geometry, from→to.
    let lines: [[Coordinate]]

    /// Nil when a leg's edge is not in this graph (a route from another bundle).
    public init?(route: Route, graph: Graph) {
        var lines: [[Coordinate]] = []
        lines.reserveCapacity(route.legs.count)
        for leg in route.legs {
            guard let edge = graph.edge(leg.edgeID), !edge.coordinates.isEmpty else { return nil }
            lines.append(edge.coordinates)
        }
        guard !lines.isEmpty else { return nil }
        self.route = route
        self.lines = lines
    }

    /// The route's whole duration.
    public var durationS: Double { route.legs.last?.exitS ?? 0 }

    /// The route time at a point on it: the inverse of `position`. Progress
    /// (`RouteProgress`) gives the leg and the share of its edge behind the skier.
    public func routeTime(legIndex: Int, fraction: Double) -> Double {
        guard let last = route.legs.indices.last else { return 0 }
        guard legIndex <= last else { return durationS }
        let leg = route.legs[max(0, legIndex)]
        let span = 1 - leg.startFraction
        let share = span > 0 ? min(max((fraction - leg.startFraction) / span, 0), 1) : 1
        return leg.enterS + (leg.exitS - leg.enterS) * share
    }

    /// Where the skier is `seconds` after the route's start; the start before
    /// it begins and the rendezvous once it has ended.
    public func position(atRouteTime seconds: Double) -> Position {
        let legs = route.legs
        let t = seconds.isFinite ? seconds : 0
        if t >= durationS {
            let last = legs.count - 1
            return Position(
                coordinate: lines[last].last ?? lines[last][0], legIndex: last, fractionAlongLeg: 1, arrived: true
            )
        }
        // The first leg whose exit is after t.
        var low = 0, high = legs.count - 1
        while low < high {
            let mid = (low + high) / 2
            if legs[mid].exitS <= t { low = mid + 1 } else { high = mid }
        }
        let leg = legs[low]
        let length = leg.exitS - leg.enterS
        let share = length > 0 ? min(max((t - leg.enterS) / length, 0), 1) : 0
        let fraction = leg.startFraction + (1 - leg.startFraction) * share
        return Position(
            coordinate: Geo.interpolate(along: lines[low], fraction: fraction) ?? lines[low][0],
            legIndex: low, fractionAlongLeg: fraction, arrived: false
        )
    }
}
