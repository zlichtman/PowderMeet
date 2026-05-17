//
//  ManeuverIconResolver.swift
//  PowderMeet
//
//  Pure static lookup from the current edge (and optional next edge) to the
//  SF Symbol that represents the upcoming maneuver. No view dependencies so
//  unit tests don't need SwiftUI.
//

import Foundation

enum ManeuverIconResolver {
    static func symbolName(for current: GraphEdge, next: GraphEdge?) -> String {
        switch (current.kind, next?.kind) {
        case (.lift, _):                         return "arrow.up.right.circle.fill"
        case (.traverse, _):                     return "figure.walk"
        case (.run, .lift?):                     return "arrow.up.right.circle"
        case (.run, .traverse?):                 return "figure.walk"
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
            return sameTrail ? "arrow.down.right" : "arrow.turn.down.right"
        case (.run, nil):                        return "flag.checkered"
        }
    }

    static func verb(for current: GraphEdge) -> String {
        switch current.kind {
        case .run:      return "DOWN"
        case .lift:     return "RIDE"
        case .traverse: return "TRAVERSE"
        }
    }
}
