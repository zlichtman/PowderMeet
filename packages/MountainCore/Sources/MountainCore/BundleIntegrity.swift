import Foundation

public enum BundleIntegrityError: Error, Equatable, Sendable {
    case blankResortID
    case unknownTimeZone(String)
    case invalidBoundingBox
    case emptyNodes
    case emptyEdges
    case blankNodeID
    case duplicateNodeID(NodeID)
    case invalidNodeCoordinate(NodeID)
    case invalidNodeElevation(NodeID)
    case blankEdgeID
    case duplicateEdgeID(EdgeID)
    case missingEndpoint(edge: EdgeID, node: NodeID)
    case invalidGeometryCount(edge: EdgeID, count: Int)
    case invalidGeometryCoordinate(edge: EdgeID, index: Int)
    case geometryEndpointMismatch(edge: EdgeID, endpoint: String)
    case invalidAttribute(edge: EdgeID, field: String)
    case missingGroup(edge: EdgeID)
    case duplicateGroupID(GroupID)
    case groupMembershipMismatch(group: GroupID, edge: EdgeID)
    case duplicateRendezvousID(RendezvousID)
    case invalidRendezvous(RendezvousID, field: String)
    /// A live bundle whose status aliases name too few of its lift groups.
    case liveStatusCoverage(mapped: Int, lifts: Int)
    case invalidIntegrityMetric(String)
}

/// What a bundle contained when it passed validation.
public struct BundleIntegrityReport: Hashable, Sendable {
    public var nodeCount: Int
    public var edgeCount: Int
    public var groupCount: Int
    public var rendezvousCount: Int
    public var metrics: BundleDocument.IntegrityMetrics
}

/// The fail-closed trust boundary for a decoded bundle. Decoding proves only that
/// the JSON has the right shape; this proves the graph is referentially sound and
/// physically usable (`specs/02-DOMAIN.md` section 2).
public enum BundleIntegrity {
    static let maximumEndpointSeparationM = 1.0
    static let maximumLengthDeviation = 0.05
    /// The share of lift groups a live bundle's status aliases must name; the
    /// status worker's own rule (`MIN_LIFT_COVERAGE` in `status.ts`).
    public static let minimumLiveAliasCoverage = 0.8

    @discardableResult
    public static func validate(_ bundle: ResortBundle) throws -> BundleIntegrityReport {
        guard !bundle.resortID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw BundleIntegrityError.blankResortID
        }
        guard bundle.timeZone != nil else {
            throw BundleIntegrityError.unknownTimeZone(bundle.timezone)
        }
        let box = bundle.bbox
        guard Coordinate(lon: box.minLon, lat: box.minLat).isValid,
              Coordinate(lon: box.maxLon, lat: box.maxLat).isValid,
              box.minLon <= box.maxLon, box.minLat <= box.maxLat, box.contains(bundle.center) else {
            throw BundleIntegrityError.invalidBoundingBox
        }

        let graph = bundle.graph
        guard !graph.nodes.isEmpty else { throw BundleIntegrityError.emptyNodes }
        guard !graph.edges.isEmpty else { throw BundleIntegrityError.emptyEdges }
        if let duplicate = graph.duplicateNodeIDs.first {
            throw BundleIntegrityError.duplicateNodeID(duplicate)
        }

        for id in graph.nodes.keys.sorted() {
            guard let node = graph.nodes[id] else { continue }
            guard !id.rawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw BundleIntegrityError.blankNodeID
            }
            guard node.coordinate.isValid, box.contains(node.coordinate) else {
                throw BundleIntegrityError.invalidNodeCoordinate(id)
            }
            guard node.eleM.isFinite else { throw BundleIntegrityError.invalidNodeElevation(id) }
        }

        var edgeIDs = Set<EdgeID>()
        var incidentNodes = Set<NodeID>()
        for edge in graph.edges {
            guard !edge.id.rawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !edge.id.isReverse else { throw BundleIntegrityError.blankEdgeID }
            guard edgeIDs.insert(edge.id).inserted else {
                throw BundleIntegrityError.duplicateEdgeID(edge.id)
            }
            guard let from = graph.nodes[edge.from] else {
                throw BundleIntegrityError.missingEndpoint(edge: edge.id, node: edge.from)
            }
            guard let to = graph.nodes[edge.to] else {
                throw BundleIntegrityError.missingEndpoint(edge: edge.id, node: edge.to)
            }
            incidentNodes.insert(edge.from)
            incidentNodes.insert(edge.to)
            try validateGeometry(edge, from: from, to: to, box: box)
            try validateAttributes(edge)
            if edge.kind != .connection {
                guard let groupID = edge.group, bundle.group(groupID) != nil else {
                    throw BundleIntegrityError.missingGroup(edge: edge.id)
                }
            }
        }

        var groupIDs = Set<GroupID>()
        for group in bundle.groups {
            guard groupIDs.insert(group.id).inserted else {
                throw BundleIntegrityError.duplicateGroupID(group.id)
            }
            for edgeID in group.edgeIDs {
                guard let edge = graph.edge(edgeID), !edgeID.isReverse, edge.group == group.id else {
                    throw BundleIntegrityError.groupMembershipMismatch(group: group.id, edge: edgeID)
                }
            }
        }

        var rendezvousIDs = Set<RendezvousID>()
        for point in bundle.rendezvous {
            guard rendezvousIDs.insert(point.id).inserted else {
                throw BundleIntegrityError.duplicateRendezvousID(point.id)
            }
            guard !point.id.rawValue.isEmpty else {
                throw BundleIntegrityError.invalidRendezvous(point.id, field: "id")
            }
            // A stopping point no edge touches can never be routed to.
            guard graph.nodes[point.nodeID] != nil, incidentNodes.contains(point.nodeID) else {
                throw BundleIntegrityError.invalidRendezvous(point.id, field: "node_id")
            }
            guard point.confidence.isFinite, (0...1).contains(point.confidence) else {
                throw BundleIntegrityError.invalidRendezvous(point.id, field: "confidence")
            }
            guard point.quality.isFinite, (0...1).contains(point.quality) else {
                throw BundleIntegrityError.invalidRendezvous(point.id, field: "quality")
            }
        }

        if bundle.statusMode == .live {
            // The status worker writes a row only when its feed maps at least
            // this share of lift groups; the lifts it cannot name run on their
            // hours (`specs/05-PIPELINE.md` section 2).
            let aliased = Set(bundle.statusAliases.values.flatMap(\.values))
            let lifts = bundle.groups.filter { $0.kind == .lift }
            let mapped = lifts.count { aliased.contains($0.id) }
            guard !lifts.isEmpty,
                  Double(mapped) >= Self.minimumLiveAliasCoverage * Double(lifts.count) else {
                throw BundleIntegrityError.liveStatusCoverage(mapped: mapped, lifts: lifts.count)
            }
        }

        let metrics = bundle.integrity
        for (name, value) in [
            ("lift_tops_reaching_base", metrics.liftTopsReachingBase),
            ("rendezvous_reachable_from_all_lift_tops", metrics.rendezvousReachableFromAllLiftTops),
            ("orphan_edge_share", metrics.orphanEdgeShare),
            ("unnamed_run_share", metrics.unnamedRunShare),
        ] {
            guard value.isFinite, (0...1).contains(value) else {
                throw BundleIntegrityError.invalidIntegrityMetric(name)
            }
        }

        return BundleIntegrityReport(
            nodeCount: graph.nodes.count, edgeCount: graph.edges.count,
            groupCount: bundle.groups.count, rendezvousCount: bundle.rendezvous.count,
            metrics: metrics
        )
    }

    private static func validateGeometry(
        _ edge: Edge, from: Node, to: Node, box: BoundingBox
    ) throws {
        guard edge.geometry.count >= 2 else {
            throw BundleIntegrityError.invalidGeometryCount(
                edge: edge.id, count: edge.geometry.count
            )
        }
        for (index, point) in edge.geometry.enumerated() {
            guard point.coordinate.isValid, point.eleM.isFinite, box.contains(point.coordinate) else {
                throw BundleIntegrityError.invalidGeometryCoordinate(edge: edge.id, index: index)
            }
        }
        guard let first = edge.geometry.first,
              Geo.haversineM(first.coordinate, from.coordinate) <= maximumEndpointSeparationM else {
            throw BundleIntegrityError.geometryEndpointMismatch(edge: edge.id, endpoint: "from")
        }
        guard let last = edge.geometry.last,
              Geo.haversineM(last.coordinate, to.coordinate) <= maximumEndpointSeparationM else {
            throw BundleIntegrityError.geometryEndpointMismatch(edge: edge.id, endpoint: "to")
        }
        guard edge.lengthM.isFinite, edge.lengthM > 0 else {
            throw BundleIntegrityError.invalidAttribute(edge: edge.id, field: "length_m")
        }
        // The stored length may be the map length or the slope length; either is
        // an honest measure of the same geometry.
        let flat = Geo.lengthM(edge.coordinates)
        let slope = Geo.slopeLengthM(edge.geometry)
        func close(_ reference: Double) -> Bool {
            abs(edge.lengthM - reference) <= maximumLengthDeviation * max(reference, 1)
        }
        guard close(flat) || close(slope) else {
            throw BundleIntegrityError.invalidAttribute(edge: edge.id, field: "length_m")
        }
    }

    private static func validateAttributes(_ edge: Edge) throws {
        func invalid(_ field: String) -> BundleIntegrityError {
            .invalidAttribute(edge: edge.id, field: field)
        }
        guard edge.verticalM.isFinite else { throw invalid("vertical_m") }
        if edge.kind == .run, edge.verticalM > 0 { throw invalid("vertical_m") }
        if let grade = edge.gradeMaxDeg, !(grade.isFinite && (0...90).contains(grade)) {
            throw invalid("grade_max_deg")
        }
        if let aspect = edge.aspectDeg, !(aspect.isFinite && (0...360).contains(aspect)) {
            throw invalid("aspect_deg")
        }
        if edge.kind == .run, !edge.oneWay { throw invalid("one_way") }

        guard let lift = edge.lift else {
            if edge.kind == .lift { throw invalid("lift") }
            return
        }
        guard edge.kind == .lift else { throw invalid("lift") }
        guard lift.rideS.isFinite, lift.rideS > 0 else { throw invalid("lift.ride_s") }
        if let capacity = lift.capacityPPH, capacity <= 0 { throw invalid("lift.capacity_pph") }
        // `both` if and only if the lift is bidirectional.
        guard (lift.queueEntry == .both) == !edge.oneWay else { throw invalid("lift.queue_entry") }
        for hours in lift.operatingHours {
            guard !hours.days.isEmpty, hours.days.allSatisfy({ (1...7).contains($0) }),
                  hours.openMinute < hours.closeMinute else {
                throw invalid("lift.operating_hours")
            }
        }
    }
}
