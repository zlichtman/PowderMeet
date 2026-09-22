//
//  MountainGraph+NetworkGeometry.swift
//  PowderMeet
//
//  Snap GPS to the nearest point on open run/lift/traverse geometry so bowl /
//  wide-run placement matches the corridor the skier is in, not just the
//  closest junction node.
//

import Foundation
import CoreLocation

struct NetworkGeometrySnap: Sendable {
    let edge: GraphEdge
    /// Perpendicular distance from the query point to the polyline (meters).
    let distanceToPolylineMeters: Double
    let closestCoordinate: CLLocationCoordinate2D
    /// 0...1 distance along the entire directed edge polyline.
    let fractionAlongEdge: Double
    /// Graph node (edge endpoint) closest to the query — used as routing seed.
    let closerNodeId: String
}

// Inherits `nonisolated` from the primary `MountainGraph` declaration —
// repeated explicitly so methods stay callable from solver compute paths.
nonisolated extension MountainGraph {

    /// Best snap to any **open** edge geometry (runs, lifts, traverses).
    /// When a valid moving course is available, it softly disambiguates
    /// parallel/overlapping corridors without overpowering geographic truth.
    func bestOpenNetworkSnap(
        to coordinate: CLLocationCoordinate2D,
        travelCourseDegrees: CLLocationDirection? = nil,
        altitudeMeters: Double? = nil,
        verticalAccuracyMeters: Double? = nil
    ) -> NetworkGeometrySnap? {
        var bestDist = Double.infinity
        var bestScore = Double.infinity
        var bestEdge: GraphEdge?
        var bestClosest: CLLocationCoordinate2D?
        var bestFractionAlongEdge = 0.0
        var bestSegmentIndex = Int.max
        let distanceEpsilonMeters = 0.01

        for edge in edges {
            guard edge.attributes.isOpen else { continue }
            guard edge.geometry.count >= 2 else { continue }

            let segmentLengths = zip(edge.geometry, edge.geometry.dropFirst()).map {
                CLLocation(latitude: $0.0.latitude, longitude: $0.0.longitude)
                    .distance(from: CLLocation(latitude: $0.1.latitude, longitude: $0.1.longitude))
            }
            let totalLength = segmentLengths.reduce(0, +)
            var distanceBeforeSegment = 0.0
            var i = 0
            while i < edge.geometry.count - 1 {
                let a = edge.geometry[i]
                let b = edge.geometry[i + 1]
                let (d, c, segmentFraction) = Self.pointToSegmentMeters(point: coordinate, a: a, b: b)
                let coursePenalty = Self.courseMismatchPenaltyMeters(
                    courseDegrees: travelCourseDegrees,
                    segmentStart: a,
                    segmentEnd: b
                )
                let overallFraction = totalLength > 0
                    ? (distanceBeforeSegment + segmentLengths[i] * segmentFraction) / totalLength
                    : 0
                let altitudePenalty = Self.altitudeMismatchPenaltyMeters(
                    altitudeMeters: altitudeMeters,
                    verticalAccuracyMeters: verticalAccuracyMeters,
                    edge: edge,
                    graph: self,
                    fractionAlongEdge: overallFraction
                )
                let score = d + coursePenalty + altitudePenalty
                let shouldReplace: Bool
                if score < bestScore - distanceEpsilonMeters {
                    shouldReplace = true
                } else if abs(score - bestScore) <= distanceEpsilonMeters {
                    if let bestEdge {
                        shouldReplace = edge.id < bestEdge.id
                            || (edge.id == bestEdge.id && i < bestSegmentIndex)
                    } else {
                        shouldReplace = true
                    }
                } else {
                    shouldReplace = false
                }
                if shouldReplace {
                    bestDist = d
                    bestScore = score
                    bestEdge = edge
                    bestClosest = c
                    bestSegmentIndex = i
                    bestFractionAlongEdge = overallFraction
                }
                distanceBeforeSegment += segmentLengths[i]
                i += 1
            }
        }

        guard let e = bestEdge, let close = bestClosest else { return nil }
        guard let sNode = nodes[e.sourceID], let tNode = nodes[e.targetID] else { return nil }

        let ls = CLLocation(latitude: sNode.coordinate.latitude, longitude: sNode.coordinate.longitude)
        let lt = CLLocation(latitude: tNode.coordinate.latitude, longitude: tNode.coordinate.longitude)
        let pc = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        let ds = pc.distance(from: ls)
        let dt = pc.distance(from: lt)
        let closer = ds <= dt ? e.sourceID : e.targetID

        return NetworkGeometrySnap(
            edge: e,
            distanceToPolylineMeters: bestDist,
            closestCoordinate: close,
            fractionAlongEdge: max(0, min(1, bestFractionAlongEdge)),
            closerNodeId: closer
        )
    }

    // MARK: - Point ↔ segment (meters)

    /// At most 35 m of soft evidence. That is enough to choose the correctly
    /// directed member of two adjacent/overlapping pistes, but never enough to
    /// snap a skier across a broad bowl to a distant trail merely because its
    /// compass bearing happens to match.
    private static func courseMismatchPenaltyMeters(
        courseDegrees: CLLocationDirection?,
        segmentStart: CLLocationCoordinate2D,
        segmentEnd: CLLocationCoordinate2D
    ) -> Double {
        guard let courseDegrees,
              courseDegrees.isFinite,
              courseDegrees >= 0,
              courseDegrees < 360 else { return 0 }
        let segmentDistance = CLLocation(
            latitude: segmentStart.latitude,
            longitude: segmentStart.longitude
        ).distance(from: CLLocation(
            latitude: segmentEnd.latitude,
            longitude: segmentEnd.longitude
        ))
        guard segmentDistance >= 5 else { return 0 }

        let bearing = initialBearingDegrees(from: segmentStart, to: segmentEnd)
        let rawDifference = abs(courseDegrees - bearing).truncatingRemainder(dividingBy: 360)
        let difference = min(rawDifference, 360 - rawDifference)
        let normalized = difference / 180
        return 35 * normalized * normalized
    }

    /// A soft 3D disambiguator for a gondola over a run or stacked trail
    /// crossings. Only current, reasonably accurate barometric/GPS altitude
    /// reaches this method. Horizontal truth still wins beyond 50 m, so a
    /// noisy elevation cannot pull the skier across a distant drainage.
    private static func altitudeMismatchPenaltyMeters(
        altitudeMeters: Double?,
        verticalAccuracyMeters: Double?,
        edge: GraphEdge,
        graph: MountainGraph,
        fractionAlongEdge: Double
    ) -> Double {
        guard let altitudeMeters,
              altitudeMeters.isFinite,
              let verticalAccuracyMeters,
              verticalAccuracyMeters >= 0,
              verticalAccuracyMeters <= 50,
              let source = graph.nodes[edge.sourceID],
              let target = graph.nodes[edge.targetID],
              source.elevation.isFinite,
              target.elevation.isFinite else { return 0 }
        let fraction = max(0, min(1, fractionAlongEdge))
        let expected = source.elevation
            + (target.elevation - source.elevation) * fraction
        let unexplainedDifference = max(
            0,
            abs(altitudeMeters - expected) - verticalAccuracyMeters
        )
        return min(50, unexplainedDifference * 0.5)
    }

    private static func initialBearingDegrees(
        from start: CLLocationCoordinate2D,
        to end: CLLocationCoordinate2D
    ) -> Double {
        let lat1 = start.latitude * .pi / 180
        let lat2 = end.latitude * .pi / 180
        let deltaLongitude = (end.longitude - start.longitude) * .pi / 180
        let y = sin(deltaLongitude) * cos(lat2)
        let x = cos(lat1) * sin(lat2)
            - sin(lat1) * cos(lat2) * cos(deltaLongitude)
        return (atan2(y, x) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360)
    }

    private static func pointToSegmentMeters(
        point p: CLLocationCoordinate2D,
        a: CLLocationCoordinate2D,
        b: CLLocationCoordinate2D
    ) -> (Double, CLLocationCoordinate2D, Double) {
        let pl = CLLocation(latitude: p.latitude, longitude: p.longitude)
        let al = CLLocation(latitude: a.latitude, longitude: a.longitude)

        // Longitude degrees shrink by cos(latitude). Projecting in raw degrees
        // biased the along-edge fraction on diagonal trails at ski-resort
        // latitudes (Whistler is ~50°N), which then charged the wrong amount
        // of the skier's current run. A local equirectangular scale preserves
        // the correct metric projection over a trail segment.
        let referenceLatitude = (a.latitude + b.latitude + p.latitude) / 3 * .pi / 180
        let longitudeScale = max(0.01, cos(referenceLatitude))
        let dx = (b.longitude - a.longitude) * longitudeScale * .pi / 180
        let dy = (b.latitude - a.latitude) * .pi / 180
        let lenSq = dx * dx + dy * dy

        if lenSq < 1e-18 {
            return (pl.distance(from: al), a, 0)
        }

        let px = (p.longitude - a.longitude) * longitudeScale * .pi / 180
        let py = (p.latitude - a.latitude) * .pi / 180
        var t = (px * dx + py * dy) / lenSq
        t = max(0, min(1, t))

        let cx = a.longitude + t * (b.longitude - a.longitude)
        let cy = a.latitude + t * (b.latitude - a.latitude)
        let c = CLLocationCoordinate2D(latitude: cy, longitude: cx)
        let cl = CLLocation(latitude: cy, longitude: cx)
        return (pl.distance(from: cl), c, t)
    }
}
