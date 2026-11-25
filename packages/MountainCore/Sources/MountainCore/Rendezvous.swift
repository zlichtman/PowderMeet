import Foundation

public enum RendezvousKind: String, Codable, Sendable, Hashable {
    case lodge
    case liftBase = "lift_base"
    case liftTop = "lift_top"
    case junction, landmark
}

/// A catalog entry a meet may end at (invariant I-01).
public struct Rendezvous: Hashable, Sendable, Codable, Identifiable {
    public var id: RendezvousID
    public var nodeID: NodeID
    public var kind: RendezvousKind
    public var name: String
    /// 0...1 confidence that the source metadata identifies a real stopping area.
    public var confidence: Double
    /// 0...1 stop quality: space, sightline, recognisability.
    public var quality: Double
    public var amenities: [String]

    public init(
        id: RendezvousID, nodeID: NodeID, kind: RendezvousKind, name: String,
        confidence: Double, quality: Double, amenities: [String] = []
    ) {
        self.id = id
        self.nodeID = nodeID
        self.kind = kind
        self.name = name
        self.confidence = confidence
        self.quality = quality
        self.amenities = amenities
    }

    public var isIndoor: Bool { amenities.contains("indoor") }

    private enum CodingKeys: String, CodingKey {
        case id, kind, name, confidence, quality, amenities
        case nodeID = "node_id"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(RendezvousID.self, forKey: .id)
        nodeID = try c.decode(NodeID.self, forKey: .nodeID)
        kind = try c.decode(RendezvousKind.self, forKey: .kind)
        name = try c.decode(String.self, forKey: .name)
        confidence = try c.decode(Double.self, forKey: .confidence)
        quality = try c.decode(Double.self, forKey: .quality)
        amenities = try c.decodeIfPresent([String].self, forKey: .amenities) ?? []
    }
}
