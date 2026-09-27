//
//  SharedLapUtility.swift
//  PowderMeet
//
//  Pure, bounded scoring for the skiing available after a rendezvous. Keeping
//  this separate from graph search makes the product weights directly testable
//  and prevents trail representation details from leaking into route policy.
//

import Foundation

nonisolated enum SharedLapUtility {
    static let strongFitThreshold: Double = 0.85

    static func isStrongFit(_ score: Double) -> Bool {
        score >= strongFitThreshold
    }

    /// Add a deliberately small reward for useful choice after the meetup.
    /// The first run is already represented by `baseScore`; the second and
    /// third distinct run identities split the available bonus. Further runs
    /// remain factual UI evidence but cannot increase rendezvous rank.
    static func scoreWithVariety(
        baseScore: Double,
        optionCount: Int
    ) -> Double {
        let boundedBase = min(1, max(0, baseScore))
        let additionalOptions = min(2, max(0, optionCount - 1))
        let bonus = Double(additionalOptions) / 2
            * SolverConstants.Scoring.sharedRunVarietyMaximumUtilityBonus
        return min(1, boundedBase + bonus)
    }

    /// Stable identity for the first run unlocked by a post-meet rollout.
    /// Canonical `trailGroupId` is authoritative. Older graphs conservatively
    /// collapse equal normalized names rather than claiming that stored edge
    /// segmentation represents extra skier choice.
    static func optionIdentity(for edge: GraphEdge) -> String {
        if let groupID = edge.attributes.trailGroupId,
           !groupID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "group:\(groupID)"
        }
        let normalizedName = (edge.attributes.trailName ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        return normalizedName.isEmpty ? "edge:\(edge.id)" : "name:\(normalizedName)"
    }

    static func score(
        runLengthMeters: Double,
        verticalDropMeters: Double,
        actionTransitionCount: Int,
        downhillAccessSeconds: Double,
        jointTerrainFit: Double
    ) -> Double {
        let length = min(1, max(0, runLengthMeters) / 1_200)
        let vertical = min(1, max(0, verticalDropMeters) / 400)
        let transitionCost = 0.08 * Double(max(0, actionTransitionCount))

        let delayedAccess = max(
            0,
            downhillAccessSeconds
                - SolverConstants.Scoring.sharedDownhillAccessGraceSeconds
        )
        let accessAlpha = min(
            1,
            delayedAccess
                / SolverConstants.Scoring.sharedDownhillAccessPenaltyWindowSeconds
        )
        let accessCost = accessAlpha
            * SolverConstants.Scoring.sharedDownhillAccessMaximumUtilityPenalty

        let fit = min(1, max(0, jointTerrainFit))
        let terrainFitCost = (1 - fit)
            * SolverConstants.Scoring.sharedTerrainFitMaximumUtilityPenalty

        return max(
            0,
            min(
                1,
                0.60 * length + 0.40 * vertical
                    - transitionCost - accessCost - terrainFitCost
            )
        )
    }

    /// Normalized least-comfortable-skier pace for one legal run edge. `1`
    /// means the current terrain/conditions/equipment model is at least as fast
    /// as that skier's neutral marked-difficulty pace; lower values capture
    /// modeled caution. This never decides eligibility—`traverseTime` has
    /// already applied closures and every capability gate before this runs.
    static func jointTerrainFit(
        profiles: [UserProfile],
        edge: GraphEdge,
        traversalSeconds: [Double]
    ) -> Double {
        guard edge.kind == .run,
              edge.attributes.lengthMeters > 0,
              profiles.count == traversalSeconds.count,
              !profiles.isEmpty else { return 1 }

        let difficulty = edge.attributes.difficulty ?? .blue
        return zip(profiles, traversalSeconds).map { profile, actualSeconds in
            guard actualSeconds > 0 else { return 1 }
            let neutralSpeed = max(
                TraversalConstants.Run.minViableSpeedMs,
                profile.speed(for: difficulty) ?? TraversalConstants.Run.fallbackSpeedMs
            )
            let neutralSeconds = edge.attributes.lengthMeters / neutralSpeed
            return min(1, max(0, neutralSeconds / actualSeconds))
        }.min() ?? 1
    }
}
