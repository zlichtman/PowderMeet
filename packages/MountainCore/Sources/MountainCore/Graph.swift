import Foundation

public enum Difficulty: String, Codable, Sendable, Hashable, CaseIterable, CodingKeyRepresentable {
    case green, blue, black
    case doubleBlack = "double_black"
    case park, unknown

    /// Position on the marked-piste ladder. `park` is a parallel category and
    /// `unknown` has no rank of its own, so both return nil.
    public var ladderRank: Int? {
        switch self {
        case .green: 0
        case .blue: 1
        case .black: 2
        case .doubleBlack: 3
        case .park, .unknown: nil
        }
    }

    public var codingKey: CodingKey { StringIdentifierKey(stringValue: rawValue) }
    public init?<T: CodingKey>(codingKey: T) { self.init(rawValue: codingKey.stringValue) }
}

public enum EdgeKind: String, Codable, Sendable, Hashable { case run, lift, connection }

public enum NodeKind: String, Codable, Sendable, Hashable {
    case junction
    case liftBottom = "lift_bottom"
    case liftTop = "lift_top"
    case base, landmark
}

public enum LiftType: String, Codable, Sendable, Hashable {
    case chair, gondola, tbar
    case magicCarpet = "magic_carpet"
    case ropeTow = "rope_tow"
    case cableCar = "cable_car"
}

public enum QueueEntry: String, Codable, Sendable, Hashable { case bottom, both }

/// One operating window. `days` are ISO weekdays in the resort's time zone
/// (1 = Monday … 7 = Sunday); `open` and `close` are local `HH:mm`.
public struct OperatingHours: Hashable, Sendable, Codable {
    public var days: [Int]
    public var openMinute: Int
    public var closeMinute: Int

    public init(days: [Int], openMinute: Int, closeMinute: Int) {
        self.days = days
        self.openMinute = openMinute
        self.closeMinute = closeMinute
    }

    private enum CodingKeys: String, CodingKey { case days, open, close }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        days = try c.decode([Int].self, forKey: .days)
        func minute(_ key: CodingKeys) throws -> Int {
            let text = try c.decode(String.self, forKey: key)
            let parts = text.split(separator: ":", omittingEmptySubsequences: false)
            guard parts.count == 2, let h = Int(parts[0]), let m = Int(parts[1]),
                  (0...24).contains(h), (0...59).contains(m), h * 60 + m <= 24 * 60 else {
                throw DecodingError.dataCorruptedError(
                    forKey: key, in: c, debugDescription: "expected HH:mm, got \(text)"
                )
            }
            return h * 60 + m
        }
        openMinute = try minute(.open)
        closeMinute = try minute(.close)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(days, forKey: .days)
        func text(_ minute: Int) -> String {
            let h = minute / 60, m = minute % 60
            return (h < 10 ? "0" : "") + String(h) + ":" + (m < 10 ? "0" : "") + String(m)
        }
        try c.encode(text(openMinute), forKey: .open)
        try c.encode(text(closeMinute), forKey: .close)
    }
}

public struct LiftInfo: Hashable, Sendable, Codable {
    public var type: LiftType
    public var rideS: Double
    public var capacityPPH: Int?
    public var operatingHours: [OperatingHours]
    public var queueEntry: QueueEntry

    public init(
        type: LiftType, rideS: Double, capacityPPH: Int? = nil,
        operatingHours: [OperatingHours] = [], queueEntry: QueueEntry = .bottom
    ) {
        self.type = type
        self.rideS = rideS
        self.capacityPPH = capacityPPH
        self.operatingHours = operatingHours
        self.queueEntry = queueEntry
    }

    private enum CodingKeys: String, CodingKey {
        case type
        case rideS = "ride_s"
        case capacityPPH = "capacity_pph"
        case operatingHours = "operating_hours"
        case queueEntry = "queue_entry"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type = try c.decode(LiftType.self, forKey: .type)
        rideS = try c.decode(Double.self, forKey: .rideS)
        capacityPPH = try c.decodeIfPresent(Int.self, forKey: .capacityPPH)
        operatingHours = try c.decodeIfPresent([OperatingHours].self, forKey: .operatingHours) ?? []
        queueEntry = try c.decodeIfPresent(QueueEntry.self, forKey: .queueEntry) ?? .bottom
    }
}

public struct Node: Hashable, Sendable, Codable, Identifiable {
    public var id: NodeID
    public var lon: Double
    public var lat: Double
    public var eleM: Double
    public var kind: NodeKind

    public init(id: NodeID, lon: Double, lat: Double, eleM: Double, kind: NodeKind) {
        self.id = id
        self.lon = lon
        self.lat = lat
        self.eleM = eleM
        self.kind = kind
    }

    public var coordinate: Coordinate { Coordinate(lon: lon, lat: lat) }

    private enum CodingKeys: String, CodingKey {
        case id, lon, lat, kind
        case eleM = "ele_m"
    }
}

public struct Edge: Hashable, Sendable, Codable, Identifiable {
    public var id: EdgeID
    public var from: NodeID
    public var to: NodeID
    public var kind: EdgeKind
    /// Every run and lift edge belongs to a group; a connection may not.
    public var group: GroupID?
    public var name: String?
    public var difficulty: Difficulty?
    /// Source geometry in from→to order.
    public var geometry: [GeoPoint]
    public var lengthM: Double
    /// Signed elevation change from→to; negative is downhill.
    public var verticalM: Double
    public var gradeMaxDeg: Double?
    public var groomedDefault: Bool?
    /// The map says the run is left to bump up (`piste:grooming=mogul`). It
    /// still reads as not groomed; only the run card's Moguls meter uses it.
    public var moguls: Bool
    public var aspectDeg: Double?
    public var oneWay: Bool
    public var lift: LiftInfo?

    public init(
        id: EdgeID, from: NodeID, to: NodeID, kind: EdgeKind, group: GroupID? = nil,
        name: String? = nil, difficulty: Difficulty? = nil, geometry: [GeoPoint],
        lengthM: Double, verticalM: Double, gradeMaxDeg: Double? = nil,
        groomedDefault: Bool? = nil, moguls: Bool = false, aspectDeg: Double? = nil,
        oneWay: Bool = true, lift: LiftInfo? = nil
    ) {
        self.id = id
        self.from = from
        self.to = to
        self.kind = kind
        self.group = group
        self.name = name
        self.difficulty = difficulty
        self.geometry = geometry
        self.lengthM = lengthM
        self.verticalM = verticalM
        self.gradeMaxDeg = gradeMaxDeg
        self.groomedDefault = groomedDefault
        self.moguls = moguls
        self.aspectDeg = aspectDeg
        self.oneWay = oneWay
        self.lift = lift
    }

    private enum CodingKeys: String, CodingKey {
        case id, from, to, kind, group, name, difficulty, geometry, lift, moguls
        case lengthM = "length_m"
        case verticalM = "vertical_m"
        case gradeMaxDeg = "grade_max_deg"
        case groomedDefault = "groomed_default"
        case aspectDeg = "aspect_deg"
        case oneWay = "one_way"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(EdgeID.self, forKey: .id)
        from = try c.decode(NodeID.self, forKey: .from)
        to = try c.decode(NodeID.self, forKey: .to)
        kind = try c.decode(EdgeKind.self, forKey: .kind)
        group = try c.decodeIfPresent(GroupID.self, forKey: .group)
        name = try c.decodeIfPresent(String.self, forKey: .name)
        difficulty = try c.decodeIfPresent(Difficulty.self, forKey: .difficulty)
        geometry = try c.decode([GeoPoint].self, forKey: .geometry)
        lengthM = try c.decode(Double.self, forKey: .lengthM)
        verticalM = try c.decode(Double.self, forKey: .verticalM)
        gradeMaxDeg = try c.decodeIfPresent(Double.self, forKey: .gradeMaxDeg)
        groomedDefault = try c.decodeIfPresent(Bool.self, forKey: .groomedDefault)
        // Optional in the bundle: written only on a flagged run, absent before pipeline 1.5.0.
        moguls = try c.decodeIfPresent(Bool.self, forKey: .moguls) ?? false
        aspectDeg = try c.decodeIfPresent(Double.self, forKey: .aspectDeg)
        oneWay = try c.decodeIfPresent(Bool.self, forKey: .oneWay) ?? true
        lift = try c.decodeIfPresent(LiftInfo.self, forKey: .lift)
    }

    public var coordinates: [Coordinate] { geometry.map(\.coordinate) }

    /// Mean of the end elevations, for lapse-rate temperature.
    public var midpointElevationM: Double? {
        guard let first = geometry.first, let last = geometry.last else { return nil }
        return (first.eleM + last.eleM) / 2
    }

    /// The to→from traversal of a two-way edge, named with `EdgeID.reverseSuffix`.
    var reverseTraversal: Edge {
        var edge = self
        edge.id = id.reversed
        edge.from = to
        edge.to = from
        edge.geometry = geometry.reversed()
        edge.verticalM = -verticalM
        edge.aspectDeg = aspectDeg.map { ($0 + 180).truncatingRemainder(dividingBy: 360) }
        return edge
    }
}

public enum GroupKind: String, Codable, Sendable, Hashable { case trail, lift }

public struct Group: Hashable, Sendable, Codable, Identifiable {
    public var id: GroupID
    public var kind: GroupKind
    public var name: String
    public var difficulty: Difficulty?
    public var edgeIDs: [EdgeID]
    public var official: Bool

    public init(
        id: GroupID, kind: GroupKind, name: String, difficulty: Difficulty? = nil,
        edgeIDs: [EdgeID], official: Bool = true
    ) {
        self.id = id
        self.kind = kind
        self.name = name
        self.difficulty = difficulty
        self.edgeIDs = edgeIDs
        self.official = official
    }

    private enum CodingKeys: String, CodingKey {
        case id, kind, name, difficulty, official
        case edgeIDs = "edge_ids"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(GroupID.self, forKey: .id)
        kind = try c.decode(GroupKind.self, forKey: .kind)
        name = try c.decode(String.self, forKey: .name)
        difficulty = try c.decodeIfPresent(Difficulty.self, forKey: .difficulty)
        edgeIDs = try c.decode([EdgeID].self, forKey: .edgeIDs)
        official = try c.decodeIfPresent(Bool.self, forKey: .official) ?? false
    }
}

/// The immutable lift-and-trail graph. Adjacency is built once here and never
/// changes with status: a closure is a cost, not a missing edge (invariant I-18).
public struct Graph: Sendable {
    public let nodes: [NodeID: Node]
    /// The bundle's edges, sorted by id.
    public let edges: [Edge]
    /// Every directed traversal (stored edges plus the reverse of each two-way
    /// lift or connection), keyed by traversal id.
    private let traversals: [EdgeID: Edge]
    private let outgoingByNode: [NodeID: [Edge]]
    private let incomingByNode: [NodeID: [Edge]]
    /// Mean node elevation: the height weather readings are taken to describe.
    public let referenceElevationM: Double
    /// Hardest marked difficulty present, which `unknown` runs are gated as.
    public let hardestMarkedDifficulty: Difficulty
    /// Node ids that appeared more than once in the source list (an integrity failure).
    let duplicateNodeIDs: [NodeID]

    public init(nodes: [Node], edges: [Edge]) {
        var nodeIndex: [NodeID: Node] = [:]
        var duplicates = Set<NodeID>()
        for node in nodes where nodeIndex.updateValue(node, forKey: node.id) != nil {
            duplicates.insert(node.id)
        }
        duplicateNodeIDs = duplicates.sorted()
        self.nodes = nodeIndex
        let sorted = edges.sorted { $0.id < $1.id }
        self.edges = sorted

        var traversals: [EdgeID: Edge] = [:]
        var outgoing: [NodeID: [Edge]] = [:]
        var incoming: [NodeID: [Edge]] = [:]
        for edge in sorted {
            var directed = [edge]
            // A run is always one-way; only lifts and connections may be two-way.
            if !edge.oneWay, edge.kind != .run { directed.append(edge.reverseTraversal) }
            for traversal in directed {
                traversals[traversal.id] = traversal
                outgoing[traversal.from, default: []].append(traversal)
                incoming[traversal.to, default: []].append(traversal)
            }
        }
        self.traversals = traversals
        // Fixed iteration order (sorted edge id) is part of determinism (I-13).
        self.outgoingByNode = outgoing.mapValues { $0.sorted { $0.id < $1.id } }
        self.incomingByNode = incoming.mapValues { $0.sorted { $0.id < $1.id } }

        let elevations = nodeIndex.keys.sorted().compactMap { nodeIndex[$0]?.eleM }
        referenceElevationM = elevations.isEmpty
            ? 0 : elevations.reduce(0, +) / Double(elevations.count)
        hardestMarkedDifficulty = sorted
            .compactMap { $0.kind == .run ? $0.difficulty : nil }
            .filter { $0.ladderRank != nil }
            .max { ($0.ladderRank ?? 0) < ($1.ladderRank ?? 0) } ?? .doubleBlack
    }

    /// Looks up a stored edge or a reverse traversal by id.
    public func edge(_ id: EdgeID) -> Edge? { traversals[id] }

    public func outgoing(from node: NodeID) -> [Edge] { outgoingByNode[node] ?? [] }

    public func incoming(to node: NodeID) -> [Edge] { incomingByNode[node] ?? [] }
}
