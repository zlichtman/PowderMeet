//
//  StoredRouteValidator.swift
//  PowderMeet
//
//  Pure, all-or-nothing validation for meet-request routes. Stored edge IDs
//  cross a device/network boundary, so activation must never reconstruct a
//  partial path or infer missing topology.
//

import Foundation

nonisolated enum StoredRouteValidationFailure: Error, Equatable, Sendable {
    case missingTarget(String)
    case missingPath
    case emptyPathDoesNotReachTarget(expectedStartID: String?, targetID: String)
    case missingEdge(String)
    case closedEdge(String)
    case missingEndpoint(edgeID: String, nodeID: String)
    case wrongStart(expected: String, actual: String)
    case discontinuity(previousEdgeID: String, nextEdgeID: String, expectedSource: String, actualSource: String)
    case wrongTarget(expected: String, actual: String)
}

/// Validates a stored route against the exact graph/status currently loaded.
/// Success returns edges in the same order as `edgeIDs`; one bad ID rejects
/// the entire route. An empty route is valid only when the stamped start is
/// already the target.
nonisolated enum StoredRouteValidator {
    static func validate(
        edgeIDs: [String]?,
        in graph: MountainGraph,
        expectedStartID: String?,
        targetID: String
    ) -> Result<[GraphEdge], StoredRouteValidationFailure> {
        guard graph.nodes[targetID] != nil else {
            return .failure(.missingTarget(targetID))
        }
        guard let edgeIDs else {
            return .failure(.missingPath)
        }
        guard !edgeIDs.isEmpty else {
            if expectedStartID == targetID {
                return .success([])
            }
            return .failure(
                .emptyPathDoesNotReachTarget(
                    expectedStartID: expectedStartID,
                    targetID: targetID
                )
            )
        }

        var resolved: [GraphEdge] = []
        resolved.reserveCapacity(edgeIDs.count)

        for edgeID in edgeIDs {
            guard let edge = graph.edge(byID: edgeID) else {
                return .failure(.missingEdge(edgeID))
            }
            guard edge.attributes.isOpen else {
                return .failure(.closedEdge(edgeID))
            }
            guard graph.nodes[edge.sourceID] != nil else {
                return .failure(.missingEndpoint(edgeID: edgeID, nodeID: edge.sourceID))
            }
            guard graph.nodes[edge.targetID] != nil else {
                return .failure(.missingEndpoint(edgeID: edgeID, nodeID: edge.targetID))
            }
            resolved.append(edge)
        }

        if let expectedStartID, let first = resolved.first,
           first.sourceID != expectedStartID {
            return .failure(.wrongStart(expected: expectedStartID, actual: first.sourceID))
        }

        for index in 1..<resolved.count {
            let previous = resolved[index - 1]
            let next = resolved[index]
            guard previous.targetID == next.sourceID else {
                return .failure(
                    .discontinuity(
                        previousEdgeID: previous.id,
                        nextEdgeID: next.id,
                        expectedSource: previous.targetID,
                        actualSource: next.sourceID
                    )
                )
            }
        }

        if let finalTarget = resolved.last?.targetID, finalTarget != targetID {
            return .failure(.wrongTarget(expected: targetID, actual: finalTarget))
        }

        return .success(resolved)
    }
}

/// Derives the only start-node stamp that can truthfully describe a stored
/// directed path. GPS may move or snap differently between solve and send;
/// stamping a fresh nearest node would make an otherwise exact path fail its
/// cross-device integrity check.
nonisolated enum StoredRouteStamp {
    static func startNodeID(for path: [GraphEdge], targetID: String) -> String {
        path.first?.sourceID ?? targetID
    }
}
