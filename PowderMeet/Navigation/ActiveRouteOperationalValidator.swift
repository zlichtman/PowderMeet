//
//  ActiveRouteOperationalValidator.swift
//  PowderMeet
//
//  Pure safety gate for routes that remain active across a canonical
//  operational-status refresh.
//


import Foundation

nonisolated enum ActiveRouteOperationalDecision: Equatable, Sendable {
    case valid
    case datasetDrift
    case statusUnavailable
    case mountainOffSeason
    case routeRequiresReroute
}

nonisolated enum ActiveRouteOperationalValidator {
    /// Exact unfinished edge identity for status validation and route-switch
    /// comparison. A 100%-completed current edge belongs to history even if
    /// the node-arrival state machine has not advanced its index yet.
    static func remainingEdgeIDs(
        path: [GraphEdge],
        currentEdgeIndex: Int,
        currentEdgeFraction: Double
    ) -> [String] {
        remainingRoute(path: path, currentEdgeIndex: currentEdgeIndex,
                       currentEdgeFraction: currentEdgeFraction).edgeIDs
    }

    /// Preserve observed progress without projecting movement through a
    /// signal gap. The fraction belongs only to the unfinished first edge;
    /// completing that edge must not transfer its fraction to the next one.
    static func remainingRoute(
        path: [GraphEdge],
        currentEdgeIndex: Int,
        currentEdgeFraction: Double
    ) -> (edgeIDs: [String], initialEdgeFraction: Double) {
        let index = min(max(0, currentEdgeIndex), path.count)
        let fraction = currentEdgeFraction.isFinite
            ? max(0, min(1, currentEdgeFraction)) : 0
        let startsAfterCurrent = index < path.count
            && fraction >= 0.999
        let start = min(path.count, index + (startsAfterCurrent ? 1 : 0))
        return (path.dropFirst(start).map(\.id),
                start < path.count && !startsAfterCurrent ? fraction : 0)
    }

    static func evaluate(
        identity: ActiveMeetDatasetIdentity,
        dataset: MountainDataset?,
        status: MountainStatus?,
        localRemainingEdgeIDs: [String],
        friendEdgeIDs: [String],
        meetingNodeID: String,
        now: Date = .now
    ) -> ActiveRouteOperationalDecision {
        guard let dataset,
              dataset.source == .canonicalServer,
              identity.resortID == dataset.resortID,
              identity.datasetVersion == dataset.version.identifier else {
            return .datasetDrift
        }

        guard let status,
              status.resortID == dataset.resortID,
              status.datasetVersion == dataset.version,
              status.isUsable(at: now) else {
            return .statusUnavailable
        }
        guard status.operatingMode == .active else {
            return .mountainOffSeason
        }

        let graph = dataset.routingGraph(applying: status, at: now)
        guard identity.matches(dataset: dataset, graph: graph) else {
            return .datasetDrift
        }

        guard routeIsValid(
            edgeIDs: localRemainingEdgeIDs,
            meetingNodeID: meetingNodeID,
            graph: graph
        ), routeIsValid(
            edgeIDs: friendEdgeIDs,
            meetingNodeID: meetingNodeID,
            graph: graph
        ) else {
            return .routeRequiresReroute
        }

        return .valid
    }

    private static func routeIsValid(
        edgeIDs: [String],
        meetingNodeID: String,
        graph: MountainGraph
    ) -> Bool {
        let expectedStartID = edgeIDs.first
            .flatMap { graph.edge(byID: $0)?.sourceID }
            ?? meetingNodeID
        if case .success = StoredRouteValidator.validate(
            edgeIDs: edgeIDs,
            in: graph,
            expectedStartID: expectedStartID,
            targetID: meetingNodeID
        ) {
            return true
        }
        return false
    }
}
