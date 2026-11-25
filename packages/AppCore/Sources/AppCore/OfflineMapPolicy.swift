import Foundation

/// What kind of network the phone is on, as far as large downloads care.
public enum Connection: Sendable, Hashable {
    case offline
    /// Cellular, a personal hotspot or Low Data Mode: the user pays for bytes.
    case metered
    case unmetered
}

/// When a resort's map and imagery may be downloaded for use with no signal
/// (`specs/07-CLIENT.md` section 3). A download is up to hundreds of megabytes
/// of the same imagery and terrain the map on screen is asking for.
public enum OfflineMapPolicy {
    /// A download the user started from Settings → Maps: on any connection,
    /// cellular included, since they asked for it.
    public static func mayStart(connection: Connection) -> Bool {
        connection != .offline
    }

    /// The work nobody asked for: caching recent resorts and keeping the maps
    /// on the phone up to date. Only on Wi-Fi, never in Low Power Mode, and not
    /// while the open resort's map is still loading its first view, which
    /// would be fighting it for the same tiles.
    public static func mayRunUnattended(connection: Connection, lowPowerMode: Bool, mapLoading: Bool) -> Bool {
        connection == .unmetered && !lowPowerMode && !mapLoading
    }
}
