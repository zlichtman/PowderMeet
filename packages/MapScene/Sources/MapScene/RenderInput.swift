import Foundation
import MeetSolver
import MountainCore

/// Everything the map shows, as one value. `SceneBuilder.build` is a pure function
/// of it.
public struct RenderInput: Sendable {
    public var bundle: ResortBundle
    /// The same value the solver was given (invariant I-15).
    public var status: ResortStatus?
    /// At most one route per slot.
    public var routes: [SceneRoute]
    /// The agreed (or previewed) meeting point.
    public var meeting: RendezvousID?
    public var friends: [FriendMarker]
    /// This phone's own position.
    public var user: Coordinate?
    /// The trail or lift whose card is open.
    public var selection: GroupID?
    public var time: SceneTime
    public var theme: MapTheme
    /// The catalog's camera override for this resort (`resorts.camera`), if any.
    public var camera: ResortInfo.Camera?
    /// Scrubbing back: friends' paths up to the scrubbed instant.
    public var breadcrumbs: [BreadcrumbTrail]
    /// Scrubbing forward in a meet: each skier on their route.
    public var ghosts: [GhostMarker]
    /// How many times this skier has skied each run here, by
    /// `RunOverlay.skiedKey` of its name: the "Run Completion" colouring.
    public var skied: [String: Int]

    public init(
        bundle: ResortBundle, status: ResortStatus? = nil, routes: [SceneRoute] = [],
        meeting: RendezvousID? = nil, friends: [FriendMarker] = [], user: Coordinate? = nil,
        selection: GroupID? = nil, time: SceneTime, theme: MapTheme = .standard,
        camera: ResortInfo.Camera? = nil, breadcrumbs: [BreadcrumbTrail] = [], ghosts: [GhostMarker] = [],
        skied: [String: Int] = [:]
    ) {
        self.skied = skied
        self.breadcrumbs = breadcrumbs
        self.ghosts = ghosts
        self.bundle = bundle
        self.status = status
        self.routes = routes
        self.meeting = meeting
        self.friends = friends
        self.user = user
        self.selection = selection
        self.time = time
        self.theme = theme
        self.camera = camera
    }
}

/// One friend's path while the timeline is scrubbed back, oldest first.
public struct BreadcrumbTrail: Sendable, Hashable, Identifiable {
    public var id: UUID
    public var coordinates: [Coordinate]

    public init(id: UUID, coordinates: [Coordinate]) {
        self.id = id
        self.coordinates = coordinates
    }
}

/// One skier of an active meet at a future instant on their planned route.
public struct GhostMarker: Sendable, Hashable, Identifiable {
    public var id: UUID
    /// This phone's skier (route A's colour) or the partner (route B's).
    public var isSelf: Bool
    /// "YOU @ 3:15 PM".
    public var label: String
    public var coordinate: Coordinate
    /// Dots from where they are now to the ghost, the last one the ghost.
    public var trail: [Coordinate]

    public init(id: UUID, isSelf: Bool, label: String, coordinate: Coordinate, trail: [Coordinate]) {
        self.id = id
        self.isSelf = isSelf
        self.label = label
        self.coordinate = coordinate
        self.trail = trail
    }
}

/// When the timeline is off "Live": the map replays the past or shows the
/// meet ahead only beyond this much either side of now, the same span the
/// timeline still calls Live.
public enum TimelineMode: Sendable, Hashable {
    case live, past, future

    public static let liveToleranceS: TimeInterval = 15 * 60

    public init(display: Date, now: Date) {
        let offset = display.timeIntervalSince(now)
        self = offset > Self.liveToleranceS ? .future : offset < -Self.liveToleranceS ? .past : .live
    }
}


public struct SceneTime: Sendable, Hashable {
    /// The real instant: status freshness and friend ages.
    public var now: Date
    /// The timeline scrubber's instant: sun only, never status.
    public var display: Date

    public init(now: Date, display: Date? = nil) {
        self.now = now
        self.display = display ?? now
    }
}

public enum MapTheme: String, Sendable, Hashable {
    case standard, glare
}

public struct SceneRoute: Sendable, Hashable {
    public enum Slot: Sendable, Hashable {
        /// This phone's skier (cyan).
        case a
        /// The partner (orange).
        case b
    }

    public var slot: Slot
    public var route: Route
    /// `Progress.legIndex` and `Progress.fractionAlongLeg` for a route being skied;
    /// zero for a preview.
    public var legIndex: Int
    public var fractionAlongLeg: Double

    public init(slot: Slot, route: Route, legIndex: Int = 0, fractionAlongLeg: Double = 0) {
        self.slot = slot
        self.route = route
        self.legIndex = legIndex
        self.fractionAlongLeg = fractionAlongLeg
    }
}

public struct FriendMarker: Sendable, Hashable, Identifiable {
    public var id: UUID
    public var displayName: String
    public var coordinate: Coordinate
    public var accuracyM: Double?
    /// The sender's capture time, not when the row arrived.
    public var capturedAt: Date
    /// "On Pika's Traverse", "Riding Peak Express", drawn above the marker;
    /// nil where the map cannot tell.
    public var place: String?

    public init(
        id: UUID, displayName: String, coordinate: Coordinate, accuracyM: Double? = nil,
        capturedAt: Date, place: String? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.coordinate = coordinate
        self.accuracyM = accuracyM
        self.capturedAt = capturedAt
        self.place = place
    }
}

/// How current a friend's last fix is, and whether it is drawn at all.
public enum FriendSignal: Sendable, Hashable {
    case live
    case stale(minutesAgo: Int)
    case cold(minutesAgo: Int)

    public static let liveWindowS: TimeInterval = 75
    public static let maximumFutureSkewS: TimeInterval = 30
    /// A friend leaves the map once their last fix is this old: the server
    /// stops serving a position after the 15 minute presence TTL, and a friend
    /// who closed the resort, signed out or quit sends nothing more, so a
    /// marker past this would only show where they used to be. A phone still
    /// at the resort publishes within a minute even standing still (the
    /// location driver repeats a still fix), so a present friend never ages
    /// this far.
    public static let forgetAfterS: TimeInterval = 15 * 60

    public static func isVisibleOnMap(lastSeen: Date, now: Date) -> Bool {
        let age = now.timeIntervalSince(lastSeen)
        return age >= -maximumFutureSkewS && age <= forgetAfterS
    }

    public static func classify(lastSeen: Date, now: Date) -> FriendSignal {
        let elapsed = now.timeIntervalSince(lastSeen)
        guard elapsed.isFinite, elapsed >= -maximumFutureSkewS else { return .cold(minutesAgo: 0) }
        if elapsed < liveWindowS { return .live }
        let minutes = Int(exactly: (elapsed / 60).rounded(.down)) ?? Int.max
        return minutes <= 5 ? .stale(minutesAgo: minutes) : .cold(minutesAgo: minutes)
    }

    public var name: String {
        switch self {
        case .live: "live"
        case .stale: "stale"
        case .cold: "cold"
        }
    }

    /// Empty while live; "4M AGO" once stale; "LOST SIGNAL · 12M AGO" from ten minutes.
    public var label: String {
        func ago(_ total: Int) -> String {
            let m = max(0, total)
            if m < 1 { return "<1M AGO" }
            if m < 60 { return "\(m)M AGO" }
            return m % 60 == 0 ? "\(m / 60)H AGO" : "\(m / 60)H \(m % 60)M AGO"
        }
        switch self {
        case .live: return ""
        case .stale(let minutes): return ago(minutes)
        case .cold(let minutes): return minutes >= 10 ? "LOST SIGNAL · \(ago(minutes))" : ago(minutes)
        }
    }

    public var diskOpacity: Double {
        switch self {
        case .live: 1.0
        case .stale: 0.75
        case .cold: 0.45
        }
    }
}
