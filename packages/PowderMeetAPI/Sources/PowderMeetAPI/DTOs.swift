import Foundation
import MountainCore

// Rows and RPC results as the database returns them. Field names follow the
// columns in `backend/supabase/migrations/0002_tables.sql`.

// MARK: Auth

public struct AuthSession: Hashable, Sendable {
    public enum Provider: String, Hashable, Sendable {
        case apple, email
    }

    public var userID: UUID
    /// The address on the account. For Sign in with Apple it may be a private
    /// relay address, or missing.
    public var email: String?
    public var provider: Provider

    public init(userID: UUID, email: String? = nil, provider: Provider = .apple) {
        self.userID = userID
        self.email = email
        self.provider = provider
    }

    /// Apple's "Hide My Email" relay address.
    public var isPrivateRelayEmail: Bool {
        email?.lowercased().hasSuffix("@privaterelay.appleid.com") == true
    }
}

/// The result of an email sign-up.
public enum SignUpOutcome: Hashable, Sendable {
    /// The account exists; it can sign in once the address is confirmed.
    case confirmationSent
    /// Email confirmation is off on the server: signed in at once.
    case signedIn(AuthSession)
}

/// A confirmation or password reset link, after it signed the user in.
public struct AuthLink: Hashable, Sendable {
    /// Where the sign-up confirmation email returns to. It and
    /// `recoveryRedirect` must be on the project's redirect allow list.
    public static let confirmRedirect = URL(string: "powdermeet://auth-callback")!
    /// Where the password reset email returns to.
    public static let recoveryRedirect = URL(string: "powdermeet://auth-callback?type=recovery")!

    public var session: AuthSession
    /// True for a password reset link: the user must choose a new password.
    public var isPasswordRecovery: Bool

    public init(session: AuthSession, isPasswordRecovery: Bool) {
        self.session = session
        self.isPasswordRecovery = isPasswordRecovery
    }

    /// True for a URL the app should hand to `openAuthLink`.
    public static func isAuthCallback(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "powdermeet" && url.host?.lowercased() == "auth-callback"
    }

    /// True when the link came from a password reset email.
    public static func isRecovery(_ url: URL) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return false }
        let items = (components.queryItems ?? [])
            + (URLComponents(string: "x:?" + (components.fragment ?? ""))?.queryItems ?? [])
        return items.contains { $0.name == "type" && $0.value == "recovery" }
    }
}

public enum AuthEvent: Hashable, Sendable {
    /// The refresh token was rejected or the user was signed out elsewhere.
    case sessionExpired
}


// MARK: Resorts

/// A `published_resorts` or `resort_catalog` row. `bundleID` is null until the
/// pipeline publishes a bundle for the resort: such a resort is listed by the
/// picker but cannot be selected. `region`, `country` and `builtAt` come from the
/// catalog only.
public struct PublishedResort: Hashable, Sendable, Codable, Identifiable {
    public var id: String
    public var name: String
    public var timezone: String
    /// `[minLon, minLat, maxLon, maxLat]`.
    public var bbox: BoundingBox?
    /// `[lon, lat]`.
    public var center: Coordinate?
    /// `{zoom, bearing, pitch, center?}`; the map adapter owns its meaning.
    public var camera: JSONValue?
    public var passProducts: [String]
    public var statusProvider: String?
    public var statusMode: StatusMode
    public var reviewMinutes: Int?
    public var bundleID: BundleID?
    public var publishedAt: Date?
    /// State or province code in the USA and Canada, else the country code.
    public var region: String?
    public var country: String?
    /// When the pipeline built the active bundle.
    public var builtAt: Date?
    /// Other names the picker's search matches ("St. Anton" for Arlberg);
    /// empty for most resorts and before migration 0020.
    public var aliases: [String]

    /// A map is published, so the resort can be selected.
    public var hasMap: Bool { bundleID != nil }

    public init(
        id: String, name: String, timezone: String, bbox: BoundingBox? = nil,
        center: Coordinate? = nil, camera: JSONValue? = nil, passProducts: [String] = [],
        statusProvider: String? = nil, statusMode: StatusMode = .scheduledOnly,
        reviewMinutes: Int? = nil, bundleID: BundleID? = nil, publishedAt: Date? = nil,
        region: String? = nil, country: String? = nil, builtAt: Date? = nil,
        aliases: [String] = []
    ) {
        self.aliases = aliases
        self.region = region
        self.country = country
        self.builtAt = builtAt
        self.id = id
        self.name = name
        self.timezone = timezone
        self.bbox = bbox
        self.center = center
        self.camera = camera
        self.passProducts = passProducts
        self.statusProvider = statusProvider
        self.statusMode = statusMode
        self.reviewMinutes = reviewMinutes
        self.bundleID = bundleID
        self.publishedAt = publishedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, timezone, bbox, center, camera, region, country, aliases
        case builtAt = "built_at"
        case passProducts = "pass_products"
        case statusProvider = "status_provider"
        case statusMode = "status_mode"
        case reviewMinutes = "review_minutes"
        case bundleID = "bundle_id"
        case publishedAt = "published_at"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        timezone = try c.decode(String.self, forKey: .timezone)
        bbox = try c.decodeIfPresent(BoundingBox.self, forKey: .bbox)
        center = try c.decodeIfPresent(Coordinate.self, forKey: .center)
        camera = try c.decodeIfPresent(JSONValue.self, forKey: .camera)
        passProducts = try c.decodeIfPresent([String].self, forKey: .passProducts) ?? []
        statusProvider = try c.decodeIfPresent(String.self, forKey: .statusProvider)
        statusMode = try c.decodeIfPresent(StatusMode.self, forKey: .statusMode) ?? .scheduledOnly
        reviewMinutes = try c.decodeIfPresent(Int.self, forKey: .reviewMinutes)
        bundleID = try c.decodeIfPresent(BundleID.self, forKey: .bundleID)
        publishedAt = try c.decodeIfPresent(Date.self, forKey: .publishedAt)
        region = try c.decodeIfPresent(String.self, forKey: .region)
        country = try c.decodeIfPresent(String.self, forKey: .country)
        builtAt = try c.decodeIfPresent(Date.self, forKey: .builtAt)
        aliases = try c.decodeIfPresent([String].self, forKey: .aliases) ?? []
    }
}
