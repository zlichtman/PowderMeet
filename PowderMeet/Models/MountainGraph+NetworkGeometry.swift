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
    /// Graph node (edge endpoint) closest to the query — used as routing seed.
    let closerNodeId: String
}

// Inherits `nonisolated` from the primary `MountainGraph` declaration —
// repeated explicitly so methods stay callable from solver compute paths.
nonisolated extension MountainGraph {

    /// Best snap to any **open** edge geometry (runs, lifts, traverses).
    func bestOpenNetworkSnap(to coordinate: CLLocationCoordinate2D) -> NetworkGeometrySnap? {
        var bestDist = Double.infinity
        var bestEdge: GraphEdge?
        var bestClosest: CLLocationCoordinate2D?

        for edge in edges {
            guard edge.attributes.isOpen else { continue }
            guard edge.geometry.count >= 2 else { continue }

            var i = 0
            while i < edge.geometry.count - 1 {
                let a = edge.geometry[i]
                let b = edge.geometry[i + 1]
                let (d, c) = Self.pointToSegmentMeters(point: coordinate, a: a, b: b)
                if d < bestDist {
                    bestDist = d
                    bestEdge = edge
                    bestClosest = c
                }
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
            closerNodeId: closer
        )
    }

    // MARK: - Point ↔ segment (meters)

    private static func pointToSegmentMeters(
        point p: CLLocationCoordinate2D,
        a: CLLocationCoordinate2D,
        b: CLLocationCoordinate2D
    ) -> (Double, CLLocationCoordinate2D) {
        let pl = CLLocation(latitude: p.latitude, longitude: p.longitude)
        let al = CLLocation(latitude: a.latitude, longitude: a.longitude)

        let dx = (b.longitude - a.longitude) * .pi / 180
        let dy = (b.latitude - a.latitude) * .pi / 180
        let lenSq = dx * dx + dy * dy

        if lenSq < 1e-18 {
            return (pl.distance(from: al), a)
        }

        let px = (p.longitude - a.longitude) * .pi / 180
        let py = (p.latitude - a.latitude) * .pi / 180
        var t = (px * dx + py * dy) / lenSq
        t = max(0, min(1, t))

        let cx = a.longitude + t * (b.longitude - a.longitude)
        let cy = a.latitude + t * (b.latitude - a.latitude)
        let c = CLLocationCoordinate2D(latitude: cy, longitude: cx)
        let cl = CLLocation(latitude: cy, longitude: cx)
        return (pl.distance(from: cl), c)
    }
}
