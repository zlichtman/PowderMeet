import Foundation

/// Which resort maps this phone keeps for use with no signal (Settings → Maps,
/// `specs/13-APP-MAP.md` section 3): the ones the user downloaded, kept until
/// they remove them, and the last few resorts opened, kept as recent and
/// cleared once they fall off the end. Everything else on disk is a cache the
/// phone clears.
public struct MapShelf: Codable, Sendable, Hashable {
    /// How many of the last opened resorts are kept as recent.
    public static let recentCount = 3

    public enum Place: Sendable, Hashable {
        case downloaded, recent
    }

    /// Kept for good.
    public var downloaded: Set<String> = []
    /// Recent resorts the user removed; opening one again brings it back.
    public var removedRecent: Set<String> = []
    /// "Update downloaded maps automatically", on unless turned off.
    public var updatesAutomatically = true
    /// The map look each resort's imagery was downloaded for: a new look
    /// needs other tiles (Satellite's photo, or none of it).
    public var imageryLooks: [String: String] = [:]

    public init() {}

    /// The recent ones, most recently opened first, from the resorts this
    /// phone opened, newest first.
    public func recent(_ opened: [String]) -> [String] {
        opened.prefix(Self.recentCount).filter { !downloaded.contains($0) && !removedRecent.contains($0) }
    }

    public func place(of resortID: String, opened: [String]) -> Place? {
        if downloaded.contains(resortID) { return .downloaded }
        return recent(opened).contains(resortID) ? .recent : nil
    }

    /// Every resort whose map stays on the phone.
    public func held(opened: [String]) -> Set<String> {
        downloaded.union(recent(opened))
    }

    /// Download, or Keep on a recent one.
    public mutating func keep(_ resortID: String) {
        downloaded.insert(resortID)
        removedRecent.remove(resortID)
    }

    public mutating func remove(_ resortID: String) {
        downloaded.remove(resortID)
        removedRecent.insert(resortID)
    }

    /// The resort was opened: a recent one the user removed comes back.
    public mutating func opened(_ resortID: String) {
        removedRecent.remove(resortID)
    }
}
