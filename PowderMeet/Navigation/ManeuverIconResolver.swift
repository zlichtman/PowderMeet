//
//  ManeuverIconResolver.swift
//  PowderMeet
//
//  Pure static lookup from the current edge (and optional next edge) to the
//  SF Symbol that represents the upcoming maneuver. No view dependencies so
//  unit tests don't need SwiftUI.
//

import Foundation
import CoreLocation

nonisolated enum ManeuverIconResolver {
    enum TurnDirection: Equatable {
        case left
        case straight
        case right
    }

    static func symbolName(for current: GraphEdge, next: GraphEdge?) -> String {
        switch (current.kind, next?.kind) {
        case (.lift, _):                         return "arrow.up.right.circle.fill"
        case (.traverse, _):                     return "figure.skiing.crosscountry"
        case (.run, .lift?):                     return "arrow.up.right.circle"
        case (.run, .traverse?):                 return "figure.skiing.crosscountry"
        case (.run, .run?):
            // Compare `trailGroupId` not `trailName`. A single trail
            // chain often has multiple segments with identical OSM
            // names ("Riva Ridge" → "Riva Ridge" → "Riva Ridge") that
            // string-compare equal but are distinct edges in the
            // graph; conversely the graph builder occasionally splits
            // a chain into segments whose OSM names drift slightly
            // ("Olympic Lower Green" vs "Olympic Lower"). `trailGroupId`
            // is the canonical identity of a chain on this graph,
            // computed at build time, so it's the right axis for
            // "am I still on the same trail or turning onto a new
            // one?" Both nullable: when either is unknown, fall back
            // to name comparison so we don't lose the maneuver cue.
            let curGroup = current.attributes.trailGroupId
            let nextGroup = next?.attributes.trailGroupId
            let sameTrail: Bool
            if let curGroup, let nextGroup {
                sameTrail = curGroup == nextGroup
            } else {
                sameTrail = current.attributes.trailName == next?.attributes.trailName
            }
            guard !sameTrail else { return "arrow.down" }
            switch turnDirection(from: current, to: next) {
            case .left: return "arrow.turn.down.left"
            case .straight: return "arrow.down"
            case .right: return "arrow.turn.down.right"
            }
        case (.run, nil):                        return "flag.checkered"
        }
    }

    static func verb(for current: GraphEdge) -> String {
        switch current.kind {
        case .run:      return "SKI"
        case .lift:     return "RIDE"
        case .traverse: return "TRAVERSE"
        }
    }

    /// Geometry-derived transition direction. Bearings increase clockwise,
    /// so a positive signed delta is a right turn and a negative delta left.
    /// Small changes stay straight so noisy OSM vertices don't create false
    /// turn cues at every trail fragment.
    static func turnDirection(from current: GraphEdge, to next: GraphEdge?) -> TurnDirection {
        guard let next,
              let incoming = terminalBearing(of: current.geometry),
              let outgoing = initialBearing(of: next.geometry) else {
            return .straight
        }
        var delta = outgoing - incoming
        while delta > 180 { delta -= 360 }
        while delta < -180 { delta += 360 }
        if delta < -25 { return .left }
        if delta > 25 { return .right }
        return .straight
    }

    private static func initialBearing(
        of geometry: [CLLocationCoordinate2D]
    ) -> CLLocationDirection? {
        guard let first = geometry.first else { return nil }
        for candidate in geometry.dropFirst()
        where distanceSquared(first, candidate) > 1e-16 {
            return bearing(from: first, to: candidate)
        }
        return nil
    }

    private static func terminalBearing(
        of geometry: [CLLocationCoordinate2D]
    ) -> CLLocationDirection? {
        guard let last = geometry.last else { return nil }
        for candidate in geometry.dropLast().reversed()
        where distanceSquared(candidate, last) > 1e-16 {
            return bearing(from: candidate, to: last)
        }
        return nil
    }

    private static func bearing(
        from a: CLLocationCoordinate2D,
        to b: CLLocationCoordinate2D
    ) -> CLLocationDirection {
        let lat1 = a.latitude * .pi / 180
        let lat2 = b.latitude * .pi / 180
        let dLon = (b.longitude - a.longitude) * .pi / 180
        let y = sin(dLon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon)
        return (atan2(y, x) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360)
    }

    private static func distanceSquared(
        _ a: CLLocationCoordinate2D,
        _ b: CLLocationCoordinate2D
    ) -> Double {
        let dLat = a.latitude - b.latitude
        let dLon = a.longitude - b.longitude
        return dLat * dLat + dLon * dLon
    }
}
