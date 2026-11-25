import Foundation
import PMLogging
import PowderMeetAPI

/// What a returning user needs to reach the map before the network answers: their
/// own profile, with `currentResortID` holding the resort that was on screen.
/// Nothing about anyone else is stored (`specs/07-CLIENT.md` section 4).
public struct LaunchSnapshot: Sendable, Hashable, Codable {
    public var profile: Profile
    public var savedAt: Date

    public init(profile: Profile, savedAt: Date) {
        self.profile = profile
        self.savedAt = savedAt
    }

    private enum CodingKeys: String, CodingKey {
        case profile
        case savedAt = "saved_at"
    }
}

/// One file on disk holding the last `LaunchSnapshot`. The session writes it
/// whenever the profile or the selected resort changes and removes it at sign-out.
/// The server stays the authority: a launch from this cache is replaced by the
/// loaded profile, and ends in sign-in if the server no longer knows the user.
public struct LaunchCache: Sendable {
    public let directory: URL
    private let log: PMLog

    public init(directory: URL, log: PMLog = PMLog()) {
        self.directory = directory
        self.log = log
    }

    private var url: URL { directory.appendingPathComponent("launch.json") }

    /// The snapshot for `user`, or nil when there is none, it belongs to someone
    /// else or it cannot be read. A file that fails either check is removed.
    public func snapshot(for user: UUID) -> LaunchSnapshot? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            let snapshot = try WireCoding.decoder().decode(
                LaunchSnapshot.self, from: try Data(contentsOf: url))
            guard snapshot.profile.id == user else {
                clear()
                return nil
            }
            return snapshot
        } catch {
            log.error(.session, "launch cache is unreadable: \(error)")
            clear()
            return nil
        }
    }

    public func save(_ snapshot: LaunchSnapshot) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try WireCoding.encoder().encode(snapshot).write(to: url, options: .atomic)
        } catch {
            log.error(.session, "launch cache not written: \(error)")
        }
    }

    public func clear() {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            log.error(.session, "launch cache not removed: \(error)")
        }
    }
}
