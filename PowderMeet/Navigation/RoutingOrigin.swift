//
//  RoutingOrigin.swift
//  PowderMeet
//
//  A GPS-aware start for directed routing. Interior origins retain the
//  current edge in the path but charge only its unskiied remainder.
//

import Foundation

nonisolated struct RoutingOrigin: Hashable, Sendable {
    let startNodeID: String
    let approachEdgeID: String?
    let approachTargetNodeID: String?
    private let remainingPermille: Int
    private let positionUncertaintyMetersRounded: Int

    var positionUncertaintyMeters: Double {
        Double(positionUncertaintyMetersRounded)
    }

    var remainingFraction: Double {
        Double(remainingPermille) / 1_000
    }

    /// Progress already made along the directed approach edge. A node origin
    /// has no partially traversed edge, so its initial progress is zero.
    var fractionAlongApproachEdge: Double {
        approachEdgeID == nil ? 0 : 1 - remainingFraction
    }

    /// Seeds active-route tracking only when the solved path retained this
    /// exact directed approach edge as its first canonical edge.
    func initialFraction(forFirstEdgeID edgeID: String?) -> Double {
        guard let approachEdgeID, approachEdgeID == edgeID else { return 0 }
        return fractionAlongApproachEdge
    }

    var cacheFingerprint: String {
        guard let approachEdgeID, let approachTargetNodeID else {
            return "node:\(startNodeID):u\(positionUncertaintyMetersRounded)"
        }
        return "edge:\(approachEdgeID):\(startNodeID)>\(approachTargetNodeID):r\(remainingPermille):u\(positionUncertaintyMetersRounded)"
    }

    static func node(
        _ nodeID: String,
        positionUncertaintyMeters: Double = 0
    ) -> RoutingOrigin {
        RoutingOrigin(
            startNodeID: nodeID,
            approachEdgeID: nil,
            approachTargetNodeID: nil,
            remainingPermille: 0,
            positionUncertaintyMetersRounded: quantizedUncertainty(
                positionUncertaintyMeters
            )
        )
    }

    static func interior(
        edge: GraphEdge,
        fractionAlongEdge: Double,
        positionUncertaintyMeters: Double = 0
    ) -> RoutingOrigin {
        let along = max(0, min(1, fractionAlongEdge))
        let remaining = Int(((1 - along) * 1_000).rounded())
        return RoutingOrigin(
            startNodeID: edge.sourceID,
            approachEdgeID: edge.id,
            approachTargetNodeID: edge.targetID,
            remainingPermille: max(1, min(1_000, remaining)),
            positionUncertaintyMetersRounded: quantizedUncertainty(
                positionUncertaintyMeters
            )
        )
    }

    private static func quantizedUncertainty(_ meters: Double) -> Int {
        guard meters.isFinite else { return 0 }
        return max(0, min(150, Int(meters.rounded())))
    }
}
