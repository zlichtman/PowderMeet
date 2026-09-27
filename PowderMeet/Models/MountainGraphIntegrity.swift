//
//  MountainGraphIntegrity.swift
//  PowderMeet
//
//  Fail-closed trust boundary for canonical graph blobs. Codable proves only
//  that JSON has the expected shape; this layer proves that the decoded graph
//  is the requested resort, is internally referentially sound, has physically
//  usable geometry/weights, and matches the builder's advertised fingerprint.
//

import Foundation
import CoreLocation

nonisolated enum MountainGraphIntegrityError: Error, Equatable, Sendable {
    case decodingFailed(String)
    case missingAdvertisedFingerprint
    case fingerprintMismatch(expected: String, actual: String)
    case resortMismatch(expected: String, actual: String)
    case emptyNodes
    case emptyEdges
    case blankNodeID(dictionaryKey: String)
    case nodeKeyMismatch(dictionaryKey: String, nodeID: String)
    case invalidNodeCoordinate(nodeID: String)
    case invalidNodeElevation(nodeID: String)
    case blankEdgeID(index: Int)
    case duplicateEdgeID(String)
    case blankEndpointID(edgeID: String, endpoint: String)
    case missingEndpoint(edgeID: String, nodeID: String, endpoint: String)
    case invalidGeometryCount(edgeID: String, count: Int)
    case invalidGeometryCoordinate(edgeID: String, index: Int)
    case geometryEndpointMismatch(edgeID: String, endpoint: String)
    case invalidAttribute(edgeID: String, field: String)
    case invalidRendezvousCatalog
}

extension MountainGraphIntegrityError: LocalizedError {
    nonisolated var errorDescription: String? {
        switch self {
        case .decodingFailed(let message):
            return "graph JSON could not be decoded: \(message)"
        case .missingAdvertisedFingerprint:
            return "graph blob is missing its advertised fingerprint"
        case .fingerprintMismatch(let expected, let actual):
            return "graph fingerprint mismatch (advertised \(expected), computed \(actual))"
        case .resortMismatch(let expected, let actual):
            return "graph resort mismatch (expected \(expected), got \(actual))"
        case .emptyNodes:
            return "canonical graph has no nodes"
        case .emptyEdges:
            return "canonical graph has no edges"
        case .blankNodeID(let dictionaryKey):
            return "graph node at key \(dictionaryKey) has a blank ID"
        case .nodeKeyMismatch(let dictionaryKey, let nodeID):
            return "graph node dictionary key \(dictionaryKey) does not match node ID \(nodeID)"
        case .invalidNodeCoordinate(let nodeID):
            return "graph node \(nodeID) has an invalid coordinate"
        case .invalidNodeElevation(let nodeID):
            return "graph node \(nodeID) has a non-finite elevation"
        case .blankEdgeID(let index):
            return "graph edge at index \(index) has a blank ID"
        case .duplicateEdgeID(let edgeID):
            return "graph contains duplicate edge ID \(edgeID)"
        case .blankEndpointID(let edgeID, let endpoint):
            return "graph edge \(edgeID) has a blank \(endpoint) ID"
        case .missingEndpoint(let edgeID, let nodeID, let endpoint):
            return "graph edge \(edgeID) references missing \(endpoint) node \(nodeID)"
        case .invalidGeometryCount(let edgeID, let count):
            return "graph edge \(edgeID) has \(count) geometry points; at least 2 are required"
        case .invalidGeometryCoordinate(let edgeID, let index):
            return "graph edge \(edgeID) has an invalid geometry coordinate at index \(index)"
        case .geometryEndpointMismatch(let edgeID, let endpoint):
            return "graph edge \(edgeID) geometry does not meet its \(endpoint) node"
        case .invalidAttribute(let edgeID, let field):
            return "graph edge \(edgeID) has an invalid \(field) attribute"
        case .invalidRendezvousCatalog:
            return "canonical rendezvous metadata is invalid for this graph"
        }
    }
}

/// Decodes the complete server wire envelope, including the fingerprint that
/// MountainGraph.Codable intentionally omits from local cache serialization.
nonisolated enum CanonicalMountainGraphDecoder {
    struct Payload: Sendable {
        let graph: MountainGraph
        /// Nil identifies a pre-catalog blob and enables the conservative
        /// client compatibility derivation. A present catalog is canonical
        /// metadata and therefore validated all-or-nothing.
        let rendezvousPoints: [RendezvousPoint]?
    }

    private struct WireEnvelope: Decodable {
        let resortID: String
        let nodes: [String: GraphNode]
        let edges: [GraphEdge]
        let fingerprint: String?
        let rendezvousCatalog: RendezvousCatalog?
    }

    static func decode(_ data: Data, expectedResortID: String) throws -> MountainGraph {
        try decodePayload(data, expectedResortID: expectedResortID).graph
    }

    static func decodePayload(_ data: Data, expectedResortID: String) throws -> Payload {
        let wire: WireEnvelope
        do {
            wire = try JSONDecoder().decode(WireEnvelope.self, from: data)
        } catch {
            throw MountainGraphIntegrityError.decodingFailed(error.localizedDescription)
        }

        guard let advertised = wire.fingerprint,
              !advertised.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MountainGraphIntegrityError.missingAdvertisedFingerprint
        }

        let graph = MountainGraph(
            resortID: wire.resortID,
            nodes: wire.nodes,
            edges: wire.edges
        )
        try MountainGraphIntegrity.validateCanonical(
            graph,
            expectedResortID: expectedResortID
        )
        guard advertised == graph.fingerprint else {
            throw MountainGraphIntegrityError.fingerprintMismatch(
                expected: advertised,
                actual: graph.fingerprint
            )
        }
        let points: [RendezvousPoint]?
        if let advertisedCatalog = wire.rendezvousCatalog {
            let validated = RendezvousCatalog(
                points: advertisedCatalog.points,
                graph: graph
            )
            guard !advertisedCatalog.points.isEmpty,
                  validated.points.count == advertisedCatalog.points.count,
                  Set(validated.points.map(\.id)).count == advertisedCatalog.points.count else {
                throw MountainGraphIntegrityError.invalidRendezvousCatalog
            }
            points = validated.points
        } else {
            points = nil
        }
        return Payload(graph: graph, rendezvousPoints: points)
    }
}

nonisolated enum MountainGraphIntegrity {
    /// Source and target geometry are produced from the same source vertices.
    /// A small physical tolerance permits harmless serialization/coordinate
    /// precision differences while still rejecting detached route segments.
    private static let maximumEndpointSeparationMeters = 3.0

    static func validateCanonical(
        _ graph: MountainGraph,
        expectedResortID: String
    ) throws {
        guard graph.resortID == expectedResortID else {
            throw MountainGraphIntegrityError.resortMismatch(
                expected: expectedResortID,
                actual: graph.resortID
            )
        }
        guard !graph.nodes.isEmpty else {
            throw MountainGraphIntegrityError.emptyNodes
        }
        guard !graph.edges.isEmpty else {
            throw MountainGraphIntegrityError.emptyEdges
        }

        for key in graph.nodes.keys.sorted() {
            guard let node = graph.nodes[key] else { continue }
            guard !node.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw MountainGraphIntegrityError.blankNodeID(dictionaryKey: key)
            }
            guard key == node.id else {
                throw MountainGraphIntegrityError.nodeKeyMismatch(
                    dictionaryKey: key,
                    nodeID: node.id
                )
            }
            guard isValidCoordinate(node.coordinate) else {
                throw MountainGraphIntegrityError.invalidNodeCoordinate(nodeID: node.id)
            }
            guard node.elevation.isFinite else {
                throw MountainGraphIntegrityError.invalidNodeElevation(nodeID: node.id)
            }
        }

        var edgeIDs = Set<String>()
        for (index, edge) in graph.edges.enumerated() {
            guard !edge.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw MountainGraphIntegrityError.blankEdgeID(index: index)
            }
            guard edgeIDs.insert(edge.id).inserted else {
                throw MountainGraphIntegrityError.duplicateEdgeID(edge.id)
            }
            guard !edge.sourceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw MountainGraphIntegrityError.blankEndpointID(
                    edgeID: edge.id,
                    endpoint: "source"
                )
            }
            guard !edge.targetID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw MountainGraphIntegrityError.blankEndpointID(
                    edgeID: edge.id,
                    endpoint: "target"
                )
            }
            guard let source = graph.nodes[edge.sourceID] else {
                throw MountainGraphIntegrityError.missingEndpoint(
                    edgeID: edge.id,
                    nodeID: edge.sourceID,
                    endpoint: "source"
                )
            }
            guard let target = graph.nodes[edge.targetID] else {
                throw MountainGraphIntegrityError.missingEndpoint(
                    edgeID: edge.id,
                    nodeID: edge.targetID,
                    endpoint: "target"
                )
            }
            guard edge.geometry.count >= 2 else {
                throw MountainGraphIntegrityError.invalidGeometryCount(
                    edgeID: edge.id,
                    count: edge.geometry.count
                )
            }
            for (coordinateIndex, coordinate) in edge.geometry.enumerated() {
                guard isValidCoordinate(coordinate) else {
                    throw MountainGraphIntegrityError.invalidGeometryCoordinate(
                        edgeID: edge.id,
                        index: coordinateIndex
                    )
                }
            }
            guard let first = edge.geometry.first,
                  coordinateDistanceMeters(first, source.coordinate)
                    <= maximumEndpointSeparationMeters else {
                throw MountainGraphIntegrityError.geometryEndpointMismatch(
                    edgeID: edge.id,
                    endpoint: "source"
                )
            }
            guard let last = edge.geometry.last,
                  coordinateDistanceMeters(last, target.coordinate)
                    <= maximumEndpointSeparationMeters else {
                throw MountainGraphIntegrityError.geometryEndpointMismatch(
                    edgeID: edge.id,
                    endpoint: "target"
                )
            }
            try validateAttributes(edge)
        }
    }

    private static func validateAttributes(_ edge: GraphEdge) throws {
        let attributes = edge.attributes
        try requirePositive(attributes.lengthMeters, field: "lengthMeters", edgeID: edge.id)
        try requireNonnegative(attributes.verticalDrop, field: "verticalDrop", edgeID: edge.id)
        try requireNonnegative(attributes.averageGradient, field: "averageGradient", edgeID: edge.id)
        try requireNonnegative(attributes.maxGradient, field: "maxGradient", edgeID: edge.id)
        try requireOptionalRange(attributes.aspect, 0...360, field: "aspect", edgeID: edge.id)
        try requireRange(attributes.aspectVariance, 0...1, field: "aspectVariance", edgeID: edge.id)
        try requireOptionalPositive(
            attributes.estimatedTrailWidthMeters,
            field: "estimatedTrailWidthMeters",
            edgeID: edge.id
        )
        try requireOptionalRange(
            attributes.obstacleDensity,
            0...1,
            field: "obstacleDensity",
            edgeID: edge.id
        )
        try requireOptionalRange(
            attributes.fallLineExposure,
            0...1,
            field: "fallLineExposure",
            edgeID: edge.id
        )
        try requireOptionalFinite(
            attributes.midpointElevation,
            field: "midpointElevation",
            edgeID: edge.id
        )
        if let hours = attributes.lastGroomedHoursAgo, hours < 0 {
            throw MountainGraphIntegrityError.invalidAttribute(
                edgeID: edge.id,
                field: "lastGroomedHoursAgo"
            )
        }

        if edge.kind == .lift {
            guard attributes.chargesLiftWait != nil else {
                throw MountainGraphIntegrityError.invalidAttribute(
                    edgeID: edge.id,
                    field: "chargesLiftWait"
                )
            }
            try requireOptionalPositive(
                attributes.rideTimeSeconds,
                field: "rideTimeSeconds",
                edgeID: edge.id
            )
            try requireOptionalPositiveInt(
                attributes.liftCapacity,
                field: "liftCapacity",
                edgeID: edge.id
            )
            try requireOptionalNonnegative(
                attributes.waitTimeMinutes,
                field: "waitTimeMinutes",
                edgeID: edge.id
            )
            try requireOptionalNonnegative(
                attributes.weekdayWaitMinutes,
                field: "weekdayWaitMinutes",
                edgeID: edge.id
            )
            try requireOptionalNonnegative(
                attributes.weekendWaitMinutes,
                field: "weekendWaitMinutes",
                edgeID: edge.id
            )
            if attributes.chargesLiftWait == false
                && (
                    attributes.waitTimeMinutes != nil
                        || attributes.weekdayWaitMinutes != nil
                        || attributes.weekendWaitMinutes != nil
                ) {
                throw MountainGraphIntegrityError.invalidAttribute(
                    edgeID: edge.id,
                    field: "continuationLiftWait"
                )
            }
        } else if attributes.liftType != nil
            || attributes.liftCapacity != nil
            || attributes.rideTimeSeconds != nil
            || attributes.waitTimeMinutes != nil
            || attributes.weekdayWaitMinutes != nil
            || attributes.weekendWaitMinutes != nil
            || attributes.chargesLiftWait != nil {
            throw MountainGraphIntegrityError.invalidAttribute(
                edgeID: edge.id,
                field: "nonLiftLiftMetadata"
            )
        }
    }

    private static func isValidCoordinate(_ coordinate: CLLocationCoordinate2D) -> Bool {
        coordinate.latitude.isFinite
            && coordinate.longitude.isFinite
            && (-90...90).contains(coordinate.latitude)
            && (-180...180).contains(coordinate.longitude)
    }

    private static func coordinateDistanceMeters(
        _ lhs: CLLocationCoordinate2D,
        _ rhs: CLLocationCoordinate2D
    ) -> Double {
        let radians = Double.pi / 180
        let latitudeDelta = (rhs.latitude - lhs.latitude) * radians
        let longitudeDelta = (rhs.longitude - lhs.longitude) * radians
        let lhsLatitude = lhs.latitude * radians
        let rhsLatitude = rhs.latitude * radians
        let haversine = sin(latitudeDelta / 2) * sin(latitudeDelta / 2)
            + cos(lhsLatitude) * cos(rhsLatitude)
                * sin(longitudeDelta / 2) * sin(longitudeDelta / 2)
        return 2 * 6_371_000 * asin(sqrt(min(1, max(0, haversine))))
    }

    private static func requirePositive(
        _ value: Double,
        field: String,
        edgeID: String
    ) throws {
        guard value.isFinite, value > 0 else {
            throw MountainGraphIntegrityError.invalidAttribute(edgeID: edgeID, field: field)
        }
    }

    private static func requireNonnegative(
        _ value: Double,
        field: String,
        edgeID: String
    ) throws {
        guard value.isFinite, value >= 0 else {
            throw MountainGraphIntegrityError.invalidAttribute(edgeID: edgeID, field: field)
        }
    }

    private static func requireRange(
        _ value: Double,
        _ range: ClosedRange<Double>,
        field: String,
        edgeID: String
    ) throws {
        guard value.isFinite, range.contains(value) else {
            throw MountainGraphIntegrityError.invalidAttribute(edgeID: edgeID, field: field)
        }
    }

    private static func requireOptionalFinite(
        _ value: Double?,
        field: String,
        edgeID: String
    ) throws {
        guard let value else { return }
        guard value.isFinite else {
            throw MountainGraphIntegrityError.invalidAttribute(edgeID: edgeID, field: field)
        }
    }

    private static func requireOptionalPositive(
        _ value: Double?,
        field: String,
        edgeID: String
    ) throws {
        guard let value else { return }
        try requirePositive(value, field: field, edgeID: edgeID)
    }

    private static func requireOptionalNonnegative(
        _ value: Double?,
        field: String,
        edgeID: String
    ) throws {
        guard let value else { return }
        try requireNonnegative(value, field: field, edgeID: edgeID)
    }

    private static func requireOptionalRange(
        _ value: Double?,
        _ range: ClosedRange<Double>,
        field: String,
        edgeID: String
    ) throws {
        guard let value else { return }
        try requireRange(value, range, field: field, edgeID: edgeID)
    }

    private static func requireOptionalPositiveInt(
        _ value: Int?,
        field: String,
        edgeID: String
    ) throws {
        guard let value else { return }
        guard value > 0 else {
            throw MountainGraphIntegrityError.invalidAttribute(edgeID: edgeID, field: field)
        }
    }
}
