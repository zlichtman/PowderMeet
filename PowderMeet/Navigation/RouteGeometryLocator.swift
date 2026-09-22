//
//  RouteGeometryLocator.swift
//  PowderMeet
//
//  Projects a live GPS fix onto a solved route's actual polylines. This keeps
//  progress and deviation decisions truthful between sparse graph junctions.
//

import CoreLocation
import Foundation

nonisolated struct RouteGeometryLocation: Sendable, Equatable {
    let edgeIndex: Int
    let fractionAlongEdge: Double
    let distanceToRouteMeters: Double
    let closestCoordinate: CLLocationCoordinate2D
}

nonisolated enum RouteGeometryLocator {
    /// Finds the closest point on the remaining directed route.
    ///
    /// Ties prefer the earlier edge, then the earlier point on that edge. That
    /// makes crossings deterministic and avoids jumping progress forward when
    /// two route polylines overlap at a junction.
    static func nearest(
        to point: CLLocationCoordinate2D,
        in path: [GraphEdge],
        startingAt startIndex: Int
    ) -> RouteGeometryLocation? {
        guard path.indices.contains(startIndex) else { return nil }

        var best: RouteGeometryLocation?
        let distanceEpsilon = 0.01

        for edgeIndex in startIndex..<path.count {
            let geometry = normalizedGeometry(for: path[edgeIndex])
            guard geometry.count >= 2 else { continue }

            var segmentLengths: [Double] = []
            segmentLengths.reserveCapacity(geometry.count - 1)
            var totalLength = 0.0
            for index in 0..<(geometry.count - 1) {
                let length = meters(from: geometry[index], to: geometry[index + 1])
                segmentLengths.append(length)
                totalLength += length
            }

            var lengthBeforeSegment = 0.0
            for index in 0..<(geometry.count - 1) {
                let projection = project(point, onto: geometry[index], geometry[index + 1])
                let along = lengthBeforeSegment + segmentLengths[index] * projection.fraction
                let fraction = totalLength > 0 ? along / totalLength : 0
                let candidate = RouteGeometryLocation(
                    edgeIndex: edgeIndex,
                    fractionAlongEdge: max(0, min(1, fraction)),
                    distanceToRouteMeters: projection.distanceMeters,
                    closestCoordinate: projection.coordinate
                )

                let shouldReplace: Bool
                if let best {
                    if candidate.distanceToRouteMeters < best.distanceToRouteMeters - distanceEpsilon {
                        shouldReplace = true
                    } else if abs(candidate.distanceToRouteMeters - best.distanceToRouteMeters) <= distanceEpsilon {
                        shouldReplace = candidate.edgeIndex < best.edgeIndex
                            || (candidate.edgeIndex == best.edgeIndex
                                && candidate.fractionAlongEdge < best.fractionAlongEdge)
                    } else {
                        shouldReplace = false
                    }
                } else {
                    shouldReplace = true
                }

                if shouldReplace { best = candidate }
                lengthBeforeSegment += segmentLengths[index]
            }
        }

        return best
    }

    private static func normalizedGeometry(for edge: GraphEdge) -> [CLLocationCoordinate2D] {
        if edge.geometry.count >= 2 { return edge.geometry }
        if let coordinate = edge.geometry.first { return [coordinate, coordinate] }
        return []
    }

    /// Local equirectangular projection is stable and more than accurate
    /// enough over a trail segment. CLLocation provides the final distance.
    private static func project(
        _ point: CLLocationCoordinate2D,
        onto a: CLLocationCoordinate2D,
        _ b: CLLocationCoordinate2D
    ) -> (coordinate: CLLocationCoordinate2D, fraction: Double, distanceMeters: Double) {
        let referenceLatitude = (a.latitude + b.latitude + point.latitude) / 3 * .pi / 180
        let longitudeScale = max(0.01, cos(referenceLatitude))
        let ax = a.longitude * longitudeScale
        let ay = a.latitude
        let bx = b.longitude * longitudeScale
        let by = b.latitude
        let px = point.longitude * longitudeScale
        let py = point.latitude

        let dx = bx - ax
        let dy = by - ay
        let lengthSquared = dx * dx + dy * dy
        let fraction: Double
        if lengthSquared <= 1e-18 {
            fraction = 0
        } else {
            fraction = max(0, min(1, ((px - ax) * dx + (py - ay) * dy) / lengthSquared))
        }

        let coordinate = CLLocationCoordinate2D(
            latitude: a.latitude + (b.latitude - a.latitude) * fraction,
            longitude: a.longitude + (b.longitude - a.longitude) * fraction
        )
        return (coordinate, fraction, meters(from: point, to: coordinate))
    }

    private static func meters(
        from a: CLLocationCoordinate2D,
        to b: CLLocationCoordinate2D
    ) -> Double {
        CLLocation(latitude: a.latitude, longitude: a.longitude).distance(
            from: CLLocation(latitude: b.latitude, longitude: b.longitude)
        )
    }
}
