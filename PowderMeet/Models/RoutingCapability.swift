//
//  RoutingCapability.swift
//  PowderMeet
//
//  Typed, user-explainable hard capability limits shared by route eligibility
//  and the solver's relaxed failure diagnostic.
//

import Foundation

nonisolated enum RunCapabilityBlocker: Hashable, Sendable {
    case markedDifficulty(RunDifficulty)
    case mogulsAvoided
    case ungroomedAvoided
    case gladesAvoided
    case gradientLimit(maxDegrees: Int)
    case gradientDataUnverified
    case invalidGradientLimit

    var userFacingLabel: String {
        switch self {
        case .markedDifficulty(.terrainPark):
            return "TERRAIN PARK"
        case .markedDifficulty(let difficulty):
            return "\(difficulty.displayName.uppercased()) TERRAIN"
        case .mogulsAvoided:
            return "MOGULS SET TO AVOID"
        case .ungroomedAvoided:
            return "UNGROOMED SET TO AVOID"
        case .gladesAvoided:
            return "GLADES SET TO AVOID"
        case .gradientLimit(let maxDegrees):
            return "PITCH ABOVE \(maxDegrees)° LIMIT"
        case .gradientDataUnverified:
            return "PITCH DATA UNVERIFIED"
        case .invalidGradientLimit:
            return "PITCH LIMIT NEEDS REVIEW"
        }
    }
}

nonisolated struct SkierCapabilityDiagnostic: Equatable, Sendable {
    let skierID: UUID?
    let skierName: String
    let blockers: [RunCapabilityBlocker]

    init(
        skierID: UUID? = nil,
        skierName: String,
        blockers: [RunCapabilityBlocker]
    ) {
        self.skierID = skierID
        self.skierName = skierName
        self.blockers = blockers
    }

    var userFacingSummary: String {
        let labels = blockers.map(\.userFacingLabel)
        return "\(skierName): \(labels.joined(separator: ", "))"
    }
}
