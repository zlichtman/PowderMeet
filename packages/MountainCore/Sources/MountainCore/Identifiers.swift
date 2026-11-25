import Foundation

/// A string identity from `specs/02-DOMAIN.md` section 1. Identities are compared
/// by string equality only; nothing derives one from a decoded model.
public protocol StringIdentifier: RawRepresentable, Hashable, Comparable, Codable, Sendable,
    CodingKeyRepresentable, ExpressibleByStringLiteral, CustomStringConvertible
where RawValue == String {
    init(rawValue: String)
}

extension StringIdentifier {
    public init(_ rawValue: String) { self.init(rawValue: rawValue) }
    public init(stringLiteral value: String) { self.init(rawValue: value) }
    public var description: String { rawValue }
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    public var codingKey: CodingKey { StringIdentifierKey(stringValue: rawValue) }
    public init?<T: CodingKey>(codingKey: T) { self.init(rawValue: codingKey.stringValue) }
}

struct StringIdentifierKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
}

/// `n<osm_node_id>` or `v<12 hex>`.
public struct NodeID: StringIdentifier {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
}

/// `w<osm_way_id>:<k>`. A two-way edge is also traversable against its stored
/// direction; the client names that traversal with `EdgeID.reverseSuffix`.
public struct EdgeID: StringIdentifier {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    /// Client-only marker for the to→from traversal of an edge whose `one_way` is
    /// false. It never appears in a bundle and is never sent to the server.
    public static let reverseSuffix = "~rev"

    public var isReverse: Bool { rawValue.hasSuffix(Self.reverseSuffix) }

    /// The identity stored in the bundle (the reverse marker removed).
    public var stored: EdgeID {
        isReverse ? EdgeID(rawValue: String(rawValue.dropLast(Self.reverseSuffix.count))) : self
    }

    var reversed: EdgeID { EdgeID(rawValue: stored.rawValue + Self.reverseSuffix) }

    /// Source way and split ordinal for `w<way>:<k>`; nil for any other shape.
    public var waySegment: (way: String, ordinal: Int)? {
        let raw = stored.rawValue
        guard raw.first == "w", let colon = raw.lastIndex(of: ":") else { return nil }
        let way = raw[raw.index(after: raw.startIndex)..<colon]
        let ordinalText = raw[raw.index(after: colon)...]
        guard !way.isEmpty, way.utf8.allSatisfy({ (48...57).contains($0) }),
              let ordinal = Int(ordinalText), ordinal >= 0, String(ordinal) == ordinalText
        else { return nil }
        return (String(way), ordinal)
    }
}

/// `trail:<slug>` or `lift:<slug>`.
public struct GroupID: StringIdentifier {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
}

/// Manifest-owned slug, e.g. `roundhouse-lodge`.
public struct RendezvousID: StringIdentifier {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
}

/// 64 lowercase hex characters: the SHA-256 of the stored (gzipped) bundle bytes.
public struct BundleID: RawRepresentable, Hashable, Codable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init?(rawValue: String) {
        guard rawValue.utf8.count == 64, rawValue.utf8.allSatisfy({
            (48...57).contains($0) || (97...102).contains($0)
        }) else { return nil }
        self.rawValue = rawValue
    }

    public init?(_ rawValue: String) { self.init(rawValue: rawValue) }

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        guard let id = BundleID(rawValue: raw) else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "bundle_id must be 64 lowercase hex characters"
            ))
        }
        self = id
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public var description: String { rawValue }
}
