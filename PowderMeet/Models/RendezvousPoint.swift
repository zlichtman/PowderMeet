//
//  RendezvousPoint.swift
//  PowderMeet
//
//  Dataset-bound, explicitly eligible stopping points for a PowderMeet.
//  Routing may pass through any safe graph node, but it may only terminate at
//  one of these validated points.
//

import Foundation

nonisolated struct RendezvousPoint: Codable, Equatable, Hashable, Sendable, Identifiable {
    enum Kind: String, Codable, Sendable {
        case liftBase
        case midStation
        case signedMeetingArea
        case lodge
        case patrol

        var userFacingLabel: String {
            switch self {
            case .liftBase: return "LIFT BASE"
            case .midStation: return "MID-STATION"
            case .signedMeetingArea: return "SIGNED MEETING AREA"
            case .lodge: return "LODGE"
            case .patrol: return "SKI PATROL"
            }
        }

        var systemImageName: String {
            switch self {
            case .liftBase: return "figure.skiing.downhill"
            case .midStation: return "arrow.up.and.down.circle.fill"
            case .signedMeetingArea: return "mappin.and.ellipse"
            case .lodge: return "house.fill"
            case .patrol: return "cross.case.fill"
            }
        }
    }

    /// Stable ID sent in the existing `meeting_node_id` field. It deliberately
    /// equals the stable graph node ID so legacy receivers still resolve it.
    let id: String
    let nodeID: String
    let kind: Kind
    let displayName: String?
    /// 0...1 confidence that source metadata identifies a real stopping area.
    let confidence: Double
    /// 0...1 operator quality score (space, visibility, recognisability).
    let quality: Double

    init(
        id: String,
        nodeID: String,
        kind: Kind,
        displayName: String? = nil,
        confidence: Double,
        quality: Double
    ) {
        self.id = id
        self.nodeID = nodeID
        self.kind = kind
        self.displayName = displayName
        self.confidence = confidence
        self.quality = quality
    }
}

nonisolated struct RendezvousCatalog: Codable, Equatable, Sendable {
    let points: [RendezvousPoint]

    var nodeIDs: Set<String> { Set(points.map(\.nodeID)) }

    /// Stable cache/determinism signature. Catalog order never affects it.
    var fingerprint: String {
        points.sorted(by: { $0.id < $1.id }).map {
            let confidence = Int(($0.confidence * 10_000).rounded())
            let quality = Int(($0.quality * 10_000).rounded())
            return "\($0.id):\($0.nodeID):\($0.kind.rawValue):\($0.displayName ?? "-"):\(confidence):\(quality)"
        }.joined(separator: "|")
    }

    init(points: [RendezvousPoint], graph: MountainGraph) {
        var seenIDs: Set<String> = []
        var seenNodes: Set<String> = []
        let ordered = points.sorted { lhs, rhs in
            if lhs.id != rhs.id { return lhs.id < rhs.id }
            if lhs.nodeID != rhs.nodeID { return lhs.nodeID < rhs.nodeID }
            if lhs.confidence != rhs.confidence { return lhs.confidence > rhs.confidence }
            if lhs.quality != rhs.quality { return lhs.quality > rhs.quality }
            return lhs.kind.rawValue < rhs.kind.rawValue
        }
        self.points = ordered.filter { point in
            guard point.id == point.nodeID,
                  !point.id.isEmpty,
                  point.confidence.isFinite,
                  point.quality.isFinite,
                  (0...1).contains(point.confidence),
                  (0...1).contains(point.quality),
                  let node = graph.nodes[point.nodeID],
                  Self.kind(point.kind, isCompatibleWith: node.kind),
                  graph.edges.contains(where: {
                      $0.sourceID == point.nodeID || $0.targetID == point.nodeID
                  }),
                  seenIDs.insert(point.id).inserted,
                  seenNodes.insert(point.nodeID).inserted else {
                return false
            }
            return true
        }
    }

    /// Compatibility catalog for graph blobs produced before explicit
    /// rendezvous metadata existed. This is deterministic and deliberately
    /// conservative: only lift bases and mid-stations become stopping points.
    /// Lift tops, trail junctions, heads and ends remain route-through nodes.
    static func derived(from graph: MountainGraph) -> RendezvousCatalog {
        let naming = MountainNaming(graph)
        let points = graph.nodes.values.compactMap { node -> RendezvousPoint? in
            let kind: RendezvousPoint.Kind
            let baseQuality: Double
            switch node.kind {
            case .liftBase:
                kind = .liftBase
                baseQuality = 0.85
            case .midStation:
                kind = .midStation
                baseQuality = 0.75
            default:
                return nil
            }

            let incident = graph.edges.filter {
                $0.sourceID == node.id || $0.targetID == node.id
            }
            guard !incident.isEmpty else { return nil }
            let officialCount = incident.filter(\.attributes.isOfficiallyValidated).count
            let officialRatio = Double(officialCount) / Double(incident.count)
            let confidence = 0.80 + min(0.15, officialRatio * 0.15)
            let exitBonus = min(0.10, Double(incident.count) * 0.015)

            return RendezvousPoint(
                id: node.id,
                nodeID: node.id,
                kind: kind,
                displayName: naming.meetingNodeLabel(node.id),
                confidence: confidence,
                quality: min(1, baseQuality + exitBonus)
            )
        }
        return RendezvousCatalog(points: points, graph: graph)
    }

    private static func kind(
        _ kind: RendezvousPoint.Kind,
        isCompatibleWith nodeKind: GraphNode.NodeKind
    ) -> Bool {
        switch kind {
        case .liftBase:
            return nodeKind == .liftBase
        case .midStation:
            return nodeKind == .midStation
        case .signedMeetingArea, .lodge, .patrol:
            // These require curated server metadata, but may be anchored to a
            // lift base or mid-station. Never anchor them to an arbitrary run.
            return nodeKind == .liftBase || nodeKind == .midStation
        }
    }
}

/// Human-facing context for the weather-aware waiting term. The copy is
/// intentionally factual: it says which exposure was considered, not that a
/// single factor alone decided the recommendation.
nonisolated enum RendezvousWaitExplanation {
    static func copy(
        temperatureCelsius: Double,
        windSpeedKmh: Double,
        visibilityKm: Double,
        rendezvousKind: RendezvousPoint.Kind
    ) -> String? {
        var hazards: [String] = []
        if temperatureCelsius < -8 { hazards.append("COLD") }
        if windSpeedKmh > 20 { hazards.append("WIND") }
        if visibilityKm < 2 { hazards.append("LOW VISIBILITY") }
        guard !hazards.isEmpty else { return nil }
        let joined = hazards.joined(separator: " + ")
        switch rendezvousKind {
        case .lodge, .patrol:
            return "SHELTERED STOP REDUCES \(joined) WAIT EXPOSURE"
        case .liftBase, .midStation, .signedMeetingArea:
            return "\(joined) MAKES ARRIVAL SYNC MORE IMPORTANT"
        }
    }
}

/// Ski-specific rendezvous objective. Arrival, fairness, and uncertainty are
/// combined into one reliability score before the remaining deterministic
/// tie-breaks. This avoids a brittle failure mode where a point estimated one
/// second faster wins even if one skier waits minutes longer or the route has
/// a much wider ETA range.
nonisolated struct RendezvousRank: Comparable, Equatable, Sendable {
    let reliabilityScoreSeconds: Double
    let latestArrivalSeconds: Double
    let waitSpreadSeconds: Double
    let uncertaintySeconds: Double
    let approachSimplicityPenaltySeconds: Double
    let continuationPenalty: Double
    let confidencePenalty: Double
    let qualityPenalty: Double
    let stableID: String

    init(
        latestArrivalSeconds: Double,
        waitSpreadSeconds: Double,
        uncertaintySeconds: Double,
        waitPenaltyAlpha: Double = SolverConstants.Scoring.waitPenaltyAlpha,
        approachSimplicityPenaltySeconds: Double = 0,
        continuationPenalty: Double = 0,
        confidencePenalty: Double,
        qualityPenalty: Double,
        stableID: String
    ) {
        self.latestArrivalSeconds = latestArrivalSeconds
        self.waitSpreadSeconds = waitSpreadSeconds
        self.uncertaintySeconds = uncertaintySeconds
        self.approachSimplicityPenaltySeconds = approachSimplicityPenaltySeconds
        self.continuationPenalty = continuationPenalty
        self.confidencePenalty = confidencePenalty
        self.qualityPenalty = qualityPenalty
        self.stableID = stableID
        reliabilityScoreSeconds = latestArrivalSeconds
            + waitPenaltyAlpha * waitSpreadSeconds
            + SolverConstants.Scoring.cvarBeta * uncertaintySeconds
            + approachSimplicityPenaltySeconds
            + SolverConstants.Scoring.sharedContinuationPenaltySeconds * continuationPenalty
            + SolverConstants.Scoring.rendezvousConfidencePenaltySeconds * confidencePenalty
            + SolverConstants.Scoring.rendezvousQualityPenaltySeconds * qualityPenalty
    }

    static func < (lhs: RendezvousRank, rhs: RendezvousRank) -> Bool {
        if lhs.reliabilityScoreSeconds != rhs.reliabilityScoreSeconds {
            return lhs.reliabilityScoreSeconds < rhs.reliabilityScoreSeconds
        }
        if lhs.latestArrivalSeconds != rhs.latestArrivalSeconds {
            return lhs.latestArrivalSeconds < rhs.latestArrivalSeconds
        }
        if lhs.waitSpreadSeconds != rhs.waitSpreadSeconds {
            return lhs.waitSpreadSeconds < rhs.waitSpreadSeconds
        }
        if lhs.uncertaintySeconds != rhs.uncertaintySeconds {
            return lhs.uncertaintySeconds < rhs.uncertaintySeconds
        }
        if lhs.approachSimplicityPenaltySeconds != rhs.approachSimplicityPenaltySeconds {
            return lhs.approachSimplicityPenaltySeconds < rhs.approachSimplicityPenaltySeconds
        }
        if lhs.continuationPenalty != rhs.continuationPenalty {
            return lhs.continuationPenalty < rhs.continuationPenalty
        }
        if lhs.confidencePenalty != rhs.confidencePenalty {
            return lhs.confidencePenalty < rhs.confidencePenalty
        }
        if lhs.qualityPenalty != rhs.qualityPenalty {
            return lhs.qualityPenalty < rhs.qualityPenalty
        }
        return lhs.stableID < rhs.stableID
    }
}
