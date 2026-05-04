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
            if current.attributes.trailName != next?.attributes.trailName {
                return "arrow.turn.down.right"
            }
            return "arrow.down.right"
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
