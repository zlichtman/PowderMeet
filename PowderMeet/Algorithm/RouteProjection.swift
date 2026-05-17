//
//  RouteProjection.swift
//  PowderMeet
//
//  Projects a skier's position along a solved route at an arbitrary
//  point in time. Used by the timeline scrubber to draw ghost dots
//  showing where each skier is expected to be at the scrubbed instant.
//
//  Walks the path edge-by-edge, accumulating `profile.traverseTime(...)`,
//  and interpolates linearly within the current edge's polyline geometry
//  once the cumulative time overshoots the query.
//

import Foundation
import CoreLocation

enum RouteProjection {

    /// Returns the interpolated coordinate and current edge at
    /// `secondsFromStart` into the route, or nil if:
    ///   • path is empty
    ///   • a traverse time is missing (e.g., skill-gated beyond the path)
    ///   • the request is beyond the total route time (past the meeting point).
    static func skierPosition(
        at secondsFromStart: Double,
        path: [GraphEdge],
        profile: UserProfile,
        context: TraversalContext,
        graph: MountainGraph
    ) -> (coordinate: CLLocationCoordinate2D, currentEdge: GraphEdge?)? {
        guard !path.isEmpty else { return nil }
        guard secondsFromStart >= 0 else { return (path[0].geometry.first ?? .init(), path.first) }

        var accumulated: Double = 0
        for edge in path {
            let t = profile.traverseTime(for: edge, context: context) ?? fallbackTime(for: edge)
            // Zero-duration edges (e.g., degenerate lift entries, malformed
            // enrichment) can't host a scrub position — advance past them
            // rather than pinning the ghost dot to their entry vertex.
            guard t > 0 else { accumulated += t; continue }
            if accumulated + t >= secondsFromStart {
                // The scrub point falls inside this edge — interpolate along geometry.
                let fraction = min(1.0, max(0.0, (secondsFromStart - accumulated) / t))
                guard let coord = interpolate(along: edge.geometry, fraction: fraction) else {
                    return (edge.geometry.first ?? .init(), edge)
                }
                return (coord, edge)
            }
            accumulated += t
        }

        // Past the end of the route — return the final coordinate.
        return (path.last?.geometry.last ?? .init(), path.last)
    }

    /// Total estimated traverse time for a path in seconds.
    static func totalTime(
        for path: [GraphEdge],
        profile: UserProfile,
        context: TraversalContext
    ) -> Double {
        path.reduce(into: 0.0) { total, edge in
            total += profile.traverseTime(for: edge, context: context) ?? fallbackTime(for: edge)
        }
    }

    // MARK: - Internals

    private static func fallbackTime(for edge: GraphEdge) -> Double {
        switch edge.kind {
        case .run:      return edge.attributes.lengthMeters / 5.0
        case .lift:     return (edge.attributes.rideTimeSeconds ?? 360) + 90
        case .traverse: return edge.attributes.lengthMeters / 1.5
        }
    }

    /// Linear interpolation along a polyline by fraction of arc length.
    /// Distance-aware so fraction 0.5 lands at the geometric midpoint even
    /// when polyline segments are uneven.
    private static func interpolate(
        along geometry: [CLLocationCoordinate2D],
        fraction: Double
    ) -> CLLocationCoordinate2D? {
        guard let first = geometry.first else { return nil }
        guard geometry.count > 1, fraction > 0 else { return first }
        if fraction >= 1, let last = geometry.last { return last }

        // Cumulative arc length per vertex
        var segLengths: [Double] = []
        segLengths.reserveCapacity(geometry.count - 1)
        var total: Double = 0
        for i in 1..<geometry.count {
            let a = CLLocation(latitude: geometry[i-1].latitude, longitude: geometry[i-1].longitude)
            let b = CLLocation(latitude: geometry[i].latitude, longitude: geometry[i].longitude)
            let d = a.distance(from: b)
            segLengths.append(d)
            total += d
        }
        guard total > 0 else { return first }

        let target = total * fraction
        var acc: Double = 0
        for (i, seg) in segLengths.enumerated() where seg > 0 {
            if acc + seg >= target {
                let t = (target - acc) / seg
                let a = geometry[i]
                let b = geometry[i + 1]
                return CLLocationCoordinate2D(
                    latitude: a.latitude + (b.latitude - a.latitude) * t,
                    longitude: a.longitude + (b.longitude - a.longitude) * t
                )
            }
            acc += seg
        }
        return geometry.last ?? first
    }
}
