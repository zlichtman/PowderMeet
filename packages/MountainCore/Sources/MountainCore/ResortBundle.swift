import Foundation

public enum StatusMode: String, Codable, Sendable, Hashable {
    case live
    case scheduledOnly = "scheduled_only"
}

/// The bundle JSON document, `schema_version` 1 (`specs/02-DOMAIN.md` section 2).
public struct BundleDocument: Sendable, Codable {
    public struct Source: Hashable, Sendable, Codable {
        public var extractID: String
        public var osmExtractAt: Date
        public var openskimapAt: Date?
        public var official: [String]
        public var manifestVersion: Int

        public init(
            extractID: String, osmExtractAt: Date, openskimapAt: Date? = nil,
            official: [String] = [], manifestVersion: Int
        ) {
            self.extractID = extractID
            self.osmExtractAt = osmExtractAt
            self.openskimapAt = openskimapAt
            self.official = official
            self.manifestVersion = manifestVersion
        }

        private enum CodingKeys: String, CodingKey {
            case official
            case extractID = "extract_id"
            case osmExtractAt = "osm_extract_at"
            case openskimapAt = "openskimap_at"
            case manifestVersion = "manifest_version"
        }
    }

    public struct IntegrityFlag: Hashable, Sendable, Codable {
        public var code: String
        public var edgeID: EdgeID?
        public var lon: Double?
        public var lat: Double?
        public var note: String?

        private enum CodingKeys: String, CodingKey {
            case code, lon, lat, note
            case edgeID = "edge_id"
        }
    }

    /// The pipeline's own measurements. The client checks they are present; the
    /// pipeline checks them against the publication thresholds.
    public struct IntegrityMetrics: Hashable, Sendable, Codable {
        public var liftTopsReachingBase: Double
        public var rendezvousReachableFromAllLiftTops: Double
        public var orphanEdgeShare: Double
        public var unnamedRunShare: Double
        public var flags: [IntegrityFlag]

        public init(
            liftTopsReachingBase: Double = 1, rendezvousReachableFromAllLiftTops: Double = 1,
            orphanEdgeShare: Double = 0, unnamedRunShare: Double = 0, flags: [IntegrityFlag] = []
        ) {
            self.liftTopsReachingBase = liftTopsReachingBase
            self.rendezvousReachableFromAllLiftTops = rendezvousReachableFromAllLiftTops
            self.orphanEdgeShare = orphanEdgeShare
            self.unnamedRunShare = unnamedRunShare
            self.flags = flags
        }

        private enum CodingKeys: String, CodingKey {
            case flags
            case liftTopsReachingBase = "lift_tops_reaching_base"
            case rendezvousReachableFromAllLiftTops = "rendezvous_reachable_from_all_lift_tops"
            case orphanEdgeShare = "orphan_edge_share"
            case unnamedRunShare = "unnamed_run_share"
        }
    }

    public var schemaVersion: Int
    public var resortID: String
    public var name: String
    /// IANA time zone; all mountain-local time uses this (invariant I-06).
    public var timezone: String
    public var bbox: BoundingBox
    public var center: Coordinate
    public var statusMode: StatusMode
    /// provider → provider's name → group.
    public var statusAliases: [String: [String: GroupID]]
    public var source: Source
    public var builtAt: Date
    public var pipelineVersion: String
    public var nodes: [Node]
    public var edges: [Edge]
    public var groups: [Group]
    public var rendezvous: [Rendezvous]
    public var integrity: IntegrityMetrics

    public init(
        schemaVersion: Int = 1, resortID: String, name: String, timezone: String,
        bbox: BoundingBox, center: Coordinate, statusMode: StatusMode = .scheduledOnly,
        statusAliases: [String: [String: GroupID]] = [:], source: Source, builtAt: Date,
        pipelineVersion: String = "1.0.0", nodes: [Node], edges: [Edge], groups: [Group],
        rendezvous: [Rendezvous], integrity: IntegrityMetrics = IntegrityMetrics()
    ) {
        self.schemaVersion = schemaVersion
        self.resortID = resortID
        self.name = name
        self.timezone = timezone
        self.bbox = bbox
        self.center = center
        self.statusMode = statusMode
        self.statusAliases = statusAliases
        self.source = source
        self.builtAt = builtAt
        self.pipelineVersion = pipelineVersion
        self.nodes = nodes
        self.edges = edges
        self.groups = groups
        self.rendezvous = rendezvous
        self.integrity = integrity
    }

    private enum CodingKeys: String, CodingKey {
        case name, timezone, bbox, center, source, nodes, edges, groups, rendezvous, integrity
        case schemaVersion = "schema_version"
        case resortID = "resort_id"
        case statusMode = "status_mode"
        case statusAliases = "status_aliases"
        case builtAt = "built_at"
        case pipelineVersion = "pipeline_version"
    }
}

/// A decoded, verified, immutable resort. Identity is the SHA-256 of the stored
/// bytes (`id`), so equality and hashing use `id` alone (invariant I-17).
public struct ResortBundle: Sendable, Hashable, Identifiable {
    public static let supportedBundleSchemas: Set<Int> = [1]

    public let id: BundleID
    public let schemaVersion: Int
    public let resortID: String
    public let name: String
    public let timezone: String
    public let bbox: BoundingBox
    public let center: Coordinate
    public let statusMode: StatusMode
    public let statusAliases: [String: [String: GroupID]]
    public let source: BundleDocument.Source
    public let builtAt: Date
    public let pipelineVersion: String
    public let graph: Graph
    /// Sorted by id.
    public let groups: [Group]
    /// Sorted by id.
    public let rendezvous: [Rendezvous]
    public let integrity: BundleDocument.IntegrityMetrics
    private let groupIndex: [GroupID: Group]
    private let rendezvousIndex: [RendezvousID: Rendezvous]

    /// Wraps a document under an identity the caller vouches for. `BundleLoader`
    /// is the only production caller; fixtures and pipeline tooling may use it
    /// directly, and it performs no validation.
    public init(id: BundleID, document: BundleDocument) {
        self.id = id
        schemaVersion = document.schemaVersion
        resortID = document.resortID
        name = document.name
        timezone = document.timezone
        bbox = document.bbox
        center = document.center
        statusMode = document.statusMode
        statusAliases = document.statusAliases
        source = document.source
        builtAt = document.builtAt
        pipelineVersion = document.pipelineVersion
        graph = Graph(nodes: document.nodes, edges: document.edges)
        groups = document.groups.sorted { $0.id < $1.id }
        rendezvous = document.rendezvous.sorted { $0.id < $1.id }
        integrity = document.integrity
        var groupIndex: [GroupID: Group] = [:]
        for group in groups { groupIndex[group.id] = group }
        self.groupIndex = groupIndex
        var rendezvousIndex: [RendezvousID: Rendezvous] = [:]
        for point in rendezvous { rendezvousIndex[point.id] = point }
        self.rendezvousIndex = rendezvousIndex
    }

    public func group(_ id: GroupID) -> Group? { groupIndex[id] }

    public func rendezvous(_ id: RendezvousID) -> Rendezvous? { rendezvousIndex[id] }

    /// The resort's zone, or nil when the identifier is not a known IANA zone.
    public var timeZone: TimeZone? { TimeZone(identifier: timezone) }

    public static func == (lhs: ResortBundle, rhs: ResortBundle) -> Bool { lhs.id == rhs.id }

    public func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

enum BundleCoding {
    /// ISO 8601 with or without fractional seconds, always with a zone.
    static func date(from text: String) -> Date? {
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        if let date = plain.date(from: text) { return date }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text)
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            guard let date = date(from: text) else {
                throw DecodingError.dataCorrupted(.init(
                    codingPath: decoder.codingPath,
                    debugDescription: "expected an ISO 8601 timestamp, got \(text)"
                ))
            }
            return date
        }
        return decoder
    }

    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}

extension BundleDocument {
    /// Decodes bundle JSON with the pack's timestamp format.
    public static func decode(_ json: Data) throws -> BundleDocument {
        try BundleCoding.decoder().decode(BundleDocument.self, from: json)
    }

    /// Encodes to JSON the loader accepts. Used by fixtures and tooling.
    public func encoded() throws -> Data { try BundleCoding.encoder().encode(self) }
}
