import Foundation
import MountainCore

// MARK: People

/// `profiles.equipment`: what the skier rides, as routing uses it
/// (`specs/02-DOMAIN.md` section 5.1), plus how the skis are drawn.
public struct ProfileEquipment: Hashable, Sendable, Codable {
    /// What the client writes. The column's check constraint also accepts a legacy
    /// `snowboard`, which decoding reads as `ski`.
    public static let disciplines = ["ski"]
    public static let types = ["all_mountain", "carving", "freeride", "park"]
    public static let lengthRangeCM = 60...220
    public static let waistRangeMM = 55...140
    /// The drawn skins: the house ski, or a pattern in the viewer's theme colours.
    public static let skins = ["house", "solid", "stripes", "split", "bands", "fade", "tip", "tricolor"]

    public var discipline: String
    public var type: String
    public var lengthCM: Int?
    /// Skis only.
    public var waistMM: Int?
    /// Skis only: the key of a ski in the app's bundled catalog (`atomic-bent-110`).
    /// Display only; routing reads the fields above.
    public var ski: String?
    /// One of `skins`. Nil draws the catalog ski's topsheet, or the house ski.
    public var skin: String?

    public init(
        discipline: String, type: String = "all_mountain", lengthCM: Int? = nil, waistMM: Int? = nil,
        ski: String? = nil, skin: String? = nil
    ) {
        self.discipline = discipline
        self.type = type
        self.lengthCM = lengthCM
        self.waistMM = waistMM
        self.ski = ski
        self.skin = skin
    }

    private enum CodingKeys: String, CodingKey {
        case discipline, type, ski, skin
        case lengthCM = "length_cm"
        case waistMM = "waist_mm"
    }

    /// Gear an older build saved as a snowboard is read as skis, so the profile
    /// loads, routes as a skier and saves back a value the column accepts. A
    /// board's length says nothing about a ski's, so it is dropped; the column
    /// never let a board have a waist or a catalog ski.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let stored = try c.decode(String.self, forKey: .discipline)
        let legacyBoard = stored == "snowboard"
        discipline = legacyBoard ? "ski" : stored
        type = try c.decode(String.self, forKey: .type)
        lengthCM = legacyBoard ? nil : try c.decodeIfPresent(Int.self, forKey: .lengthCM)
        waistMM = try c.decodeIfPresent(Int.self, forKey: .waistMM)
        ski = try c.decodeIfPresent(String.self, forKey: .ski)
        skin = try c.decodeIfPresent(String.self, forKey: .skin)
    }

    /// Lowercase words joined by single hyphens, at most 64 characters.
    public static func isSkiKey(_ key: String) -> Bool {
        (1...64).contains(key.utf8.count)
            && key.split(separator: "-", omittingEmptySubsequences: false).allSatisfy { word in
                !word.isEmpty && word.utf8.allSatisfy { (48...57).contains($0) || (97...122).contains($0) }
            }
    }

    /// What the client may write: a subset of what the `equipment` check constraint accepts.
    public var isValid: Bool {
        Self.disciplines.contains(discipline) && Self.types.contains(type)
            && lengthCM.map(Self.lengthRangeCM.contains) != false
            && waistMM.map { discipline == "ski" && Self.waistRangeMM.contains($0) } != false
            && ski.map { discipline == "ski" && Self.isSkiKey($0) } != false
            && skin.map(Self.skins.contains) != false
    }

    var json: JSONValue {
        var object: [String: JSONValue] = ["discipline": .string(discipline), "type": .string(type)]
        if let lengthCM { object["length_cm"] = .number(Double(lengthCM)) }
        if let waistMM { object["waist_mm"] = .number(Double(waistMM)) }
        if let ski { object["ski"] = .string(ski) }
        if let skin { object["skin"] = .string(skin) }
        return .object(object)
    }
}

/// A `profiles` row, limited to the columns `authenticated` may select, plus the
/// owner's private height and weight when the row is the caller's own.
public struct Profile: Hashable, Sendable, Codable, Identifiable {
    public static let avoidChoices = ["ungroomed", "flats", "park", "surface_lifts"]
    public static let maxPitchRangeDeg = 10...45
    public static let heightRangeCM = 100...230
    public static let weightRangeKG = 25...200

    public var id: UUID
    public var displayName: String
    /// Object path in the `avatars` bucket (`<user id>/<file>`), not a URL.
    public var avatarURL: String?
    public var ability: String
    public var maxDifficulty: String
    /// Metres per second by difficulty. Empty until onboarding saves it.
    public var baselineSpeeds: [String: Double]
    public var equipment: ProfileEquipment?
    /// Terrain and lifts never routed onto; a subset of `avoidChoices`.
    public var avoid: [String]
    public var maxPitchDeg: Int?
    /// Private: nil on every row but the caller's own.
    public var heightCM: Int?
    public var weightKG: Int?
    public var currentResortID: String?
    public var createdAt: Date?
    public var updatedAt: Date?

    /// The column list a select must name: `select *` is denied by column grants.
    public static let columns =
        "id,display_name,avatar_url,ability,max_difficulty,baseline_speeds,equipment,avoid,"
        + "max_pitch_deg,current_resort_id,created_at,updated_at"

    public init(
        id: UUID, displayName: String, avatarURL: String? = nil, ability: String = "intermediate",
        maxDifficulty: String = "blue", baselineSpeeds: [String: Double] = [:],
        equipment: ProfileEquipment? = nil, avoid: [String] = [], maxPitchDeg: Int? = nil,
        heightCM: Int? = nil, weightKG: Int? = nil, currentResortID: String? = nil,
        createdAt: Date? = nil, updatedAt: Date? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.avatarURL = avatarURL
        self.ability = ability
        self.maxDifficulty = maxDifficulty
        self.baselineSpeeds = baselineSpeeds
        self.equipment = equipment
        self.avoid = avoid
        self.maxPitchDeg = maxPitchDeg
        self.heightCM = heightCM
        self.weightKG = weightKG
        self.currentResortID = currentResortID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, ability, equipment, avoid
        case displayName = "display_name"
        case avatarURL = "avatar_url"
        case maxDifficulty = "max_difficulty"
        case baselineSpeeds = "baseline_speeds"
        case maxPitchDeg = "max_pitch_deg"
        case heightCM = "height_cm"
        case weightKG = "weight_kg"
        case currentResortID = "current_resort_id"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        displayName = try c.decode(String.self, forKey: .displayName)
        avatarURL = try c.decodeIfPresent(String.self, forKey: .avatarURL)
        ability = try c.decodeIfPresent(String.self, forKey: .ability) ?? "intermediate"
        maxDifficulty = try c.decodeIfPresent(String.self, forKey: .maxDifficulty) ?? "blue"
        baselineSpeeds = try c.decodeIfPresent([String: Double].self, forKey: .baselineSpeeds) ?? [:]
        equipment = try c.decodeIfPresent(ProfileEquipment.self, forKey: .equipment)
        avoid = try c.decodeIfPresent([String].self, forKey: .avoid) ?? []
        maxPitchDeg = try c.decodeIfPresent(Int.self, forKey: .maxPitchDeg)
        heightCM = try c.decodeIfPresent(Int.self, forKey: .heightCM)
        weightKG = try c.decodeIfPresent(Int.self, forKey: .weightKG)
        currentResortID = try c.decodeIfPresent(String.self, forKey: .currentResortID)
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt)
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt)
    }
}

/// `profile_private()`: the caller's own height and weight.
public struct ProfilePrivate: Hashable, Sendable, Codable {
    public var heightCM: Int?
    public var weightKG: Int?

    public init(heightCM: Int? = nil, weightKG: Int? = nil) {
        self.heightCM = heightCM
        self.weightKG = weightKG
    }

    private enum CodingKeys: String, CodingKey {
        case heightCM = "height_cm"
        case weightKG = "weight_kg"
    }
}

/// The `p_patch` argument of `profile_update`: only the keys that are set are
/// sent, and a key set to nil is sent as JSON null (which clears the column).
public struct ProfilePatch: Hashable, Sendable, Codable {
    public private(set) var values: [String: JSONValue] = [:]

    public init() {}

    public var isEmpty: Bool { values.isEmpty }

    public func displayName(_ value: String) -> Self { setting("display_name", .string(value)) }
    public func avatarURL(_ value: String?) -> Self { setting("avatar_url", value.map(JSONValue.string) ?? .null) }
    public func ability(_ value: String) -> Self { setting("ability", .string(value)) }
    public func maxDifficulty(_ value: String) -> Self { setting("max_difficulty", .string(value)) }
    public func baselineSpeeds(_ value: [String: Double]) -> Self {
        setting("baseline_speeds", .object(value.mapValues(JSONValue.number)))
    }
    public func equipment(_ value: ProfileEquipment?) -> Self { setting("equipment", value?.json ?? .null) }
    public func avoid(_ value: [String]) -> Self { setting("avoid", .array(value.sorted().map(JSONValue.string))) }
    public func maxPitchDeg(_ value: Int?) -> Self { setting("max_pitch_deg", Self.number(value)) }
    public func heightCM(_ value: Int?) -> Self { setting("height_cm", Self.number(value)) }
    public func weightKG(_ value: Int?) -> Self { setting("weight_kg", Self.number(value)) }
    public func currentResortID(_ value: String?) -> Self {
        setting("current_resort_id", value.map(JSONValue.string) ?? .null)
    }

    private static func number(_ value: Int?) -> JSONValue { value.map { .number(Double($0)) } ?? .null }

    private func setting(_ key: String, _ value: JSONValue) -> Self {
        var copy = self
        copy.values[key] = value
        return copy
    }

    public init(from decoder: Decoder) throws {
        values = try decoder.singleValueContainer().decode([String: JSONValue].self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(values)
    }
}

/// `(id, display_name, avatar_url)`: a `find_users` match.
public struct UserMatch: Hashable, Sendable, Codable, Identifiable {
    public var id: UUID
    public var displayName: String
    public var avatarURL: String?

    public init(id: UUID, displayName: String, avatarURL: String? = nil) {
        self.id = id
        self.displayName = displayName
        self.avatarURL = avatarURL
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case displayName = "display_name"
        case avatarURL = "avatar_url"
    }
}

public enum FriendshipStatus: String, Codable, Sendable, Hashable {
    case pending, accepted
}

public struct Friendship: Hashable, Sendable, Codable, Identifiable {
    public var id: UUID
    public var requesterID: UUID
    public var addresseeID: UUID
    public var status: FriendshipStatus
    public var createdAt: Date
    public var respondedAt: Date?

    public init(
        id: UUID, requesterID: UUID, addresseeID: UUID, status: FriendshipStatus,
        createdAt: Date, respondedAt: Date? = nil
    ) {
        self.id = id
        self.requesterID = requesterID
        self.addresseeID = addresseeID
        self.status = status
        self.createdAt = createdAt
        self.respondedAt = respondedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, status
        case requesterID = "requester_id"
        case addresseeID = "addressee_id"
        case createdAt = "created_at"
        case respondedAt = "responded_at"
    }
}

/// The result of `social_snapshot()`.
public struct SocialSnapshot: Hashable, Sendable, Codable {
    /// One person in a snapshot list. `friendshipID` is nil for a block; `at` is
    /// `since` for a friend and `created_at` for a request or block. The card
    /// fields (`ability`, `equipment`, `stats`, `lastSeen`; migration 0016) are
    /// sent for accepted friends only and are nil on every other list.
    public struct Person: Hashable, Sendable, Codable, Identifiable {
        public var friendshipID: UUID?
        public var userID: UUID
        public var displayName: String
        /// Object path in the `avatars` bucket, not a URL.
        public var avatarURL: String?
        public var at: Date?
        public var ability: String?
        public var equipment: ProfileEquipment?
        public var stats: LifetimeStats?
        /// Where the friend's last position inside the presence TTL was.
        public var lastSeen: LastSeen?

        public var id: UUID { userID }

        public init(
            friendshipID: UUID? = nil, userID: UUID, displayName: String,
            avatarURL: String? = nil, at: Date? = nil, ability: String? = nil,
            equipment: ProfileEquipment? = nil, stats: LifetimeStats? = nil, lastSeen: LastSeen? = nil
        ) {
            self.friendshipID = friendshipID
            self.userID = userID
            self.displayName = displayName
            self.avatarURL = avatarURL
            self.at = at
            self.ability = ability
            self.equipment = equipment
            self.stats = stats
            self.lastSeen = lastSeen
        }

        private enum CodingKeys: String, CodingKey {
            case since, ability, equipment, stats
            case friendshipID = "friendship_id"
            case userID = "user_id"
            case displayName = "display_name"
            case avatarURL = "avatar_url"
            case createdAt = "created_at"
            case lastSeen = "last_seen"
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            friendshipID = try c.decodeIfPresent(UUID.self, forKey: .friendshipID)
            userID = try c.decode(UUID.self, forKey: .userID)
            displayName = try c.decode(String.self, forKey: .displayName)
            avatarURL = try c.decodeIfPresent(String.self, forKey: .avatarURL)
            at = try c.decodeIfPresent(Date.self, forKey: .since)
                ?? c.decodeIfPresent(Date.self, forKey: .createdAt)
            ability = try c.decodeIfPresent(String.self, forKey: .ability)
            // Gear another build wrote in a shape this one cannot read is shown
            // as none rather than failing the whole snapshot.
            do {
                equipment = try c.decodeIfPresent(ProfileEquipment.self, forKey: .equipment)
            } catch {
                equipment = nil
            }
            stats = try c.decodeIfPresent(LifetimeStats.self, forKey: .stats)
            lastSeen = try c.decodeIfPresent(LastSeen.self, forKey: .lastSeen)
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encodeIfPresent(friendshipID, forKey: .friendshipID)
            try c.encode(userID, forKey: .userID)
            try c.encode(displayName, forKey: .displayName)
            try c.encodeIfPresent(avatarURL, forKey: .avatarURL)
            try c.encodeIfPresent(at, forKey: .createdAt)
            try c.encodeIfPresent(ability, forKey: .ability)
            try c.encodeIfPresent(equipment, forKey: .equipment)
            try c.encodeIfPresent(stats, forKey: .stats)
            try c.encodeIfPresent(lastSeen, forKey: .lastSeen)
        }
    }

    public var friends: [Person]
    public var pendingIn: [Person]
    public var pendingOut: [Person]
    public var blocks: [Person]

    public init(
        friends: [Person] = [], pendingIn: [Person] = [], pendingOut: [Person] = [],
        blocks: [Person] = []
    ) {
        self.friends = friends
        self.pendingIn = pendingIn
        self.pendingOut = pendingOut
        self.blocks = blocks
    }

    public func isFriend(_ user: UUID) -> Bool { friends.contains { $0.userID == user } }

    private enum CodingKeys: String, CodingKey {
        case friends, blocks
        case pendingIn = "pending_in"
        case pendingOut = "pending_out"
    }
}

/// The data of `friend.requested`, `friend.accepted` and `friend.removed`: the
/// counterpart's brief plus the friendship.
public struct FriendEvent: Hashable, Sendable, Codable {
    public var friendshipID: UUID
    public var userID: UUID
    /// Null when the counterpart's profile is already gone (account deletion).
    public var displayName: String?
    public var avatarURL: String?

    public init(friendshipID: UUID, userID: UUID, displayName: String?, avatarURL: String? = nil) {
        self.friendshipID = friendshipID
        self.userID = userID
        self.displayName = displayName
        self.avatarURL = avatarURL
    }

    private enum CodingKeys: String, CodingKey {
        case friendshipID = "friendship_id"
        case userID = "user_id"
        case displayName = "display_name"
        case avatarURL = "avatar_url"
    }
}

/// A `pace_models_friend_read` row: the owner's or an accepted friend's.
public struct PaceModelRow: Hashable, Sendable, Codable {
    public var ownerID: UUID
    public var computedAt: Date
    public var difficultyFactor: [String: Double]
    public var edgeFactor: [String: Double]
    public var stopsPerKm: Double?
    public var nDescents: Int

    public init(
        ownerID: UUID, computedAt: Date, difficultyFactor: [String: Double] = [:],
        edgeFactor: [String: Double] = [:], stopsPerKm: Double? = nil, nDescents: Int = 0
    ) {
        self.ownerID = ownerID
        self.computedAt = computedAt
        self.difficultyFactor = difficultyFactor
        self.edgeFactor = edgeFactor
        self.stopsPerKm = stopsPerKm
        self.nDescents = nDescents
    }

    private enum CodingKeys: String, CodingKey {
        case ownerID = "owner_id"
        case computedAt = "computed_at"
        case difficultyFactor = "difficulty_factor"
        case edgeFactor = "edge_factor"
        case stopsPerKm = "stops_per_km"
        case nDescents = "n_descents"
    }
}
