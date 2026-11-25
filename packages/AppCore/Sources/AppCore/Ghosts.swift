import Foundation
import MeetSolver
import MountainCore

/// Where each skier of an active meet will be when the timeline is scrubbed
/// forward: a "ghost" along their planned route, labelled by the app
/// ("YOU @ 3:15 PM"). `MeetSession` builds the plan; it is a value, so the
/// timeline holds the latest copy and asks it on every frame without a hop
/// to the session.
///
/// Each track is a route and an anchor: the instant at which the skier was
/// `anchorRouteTimeS` into it. The user's own track is the route being
/// navigated, anchored at the last fix's progress along it. The partner's
/// route is not on this phone (only their ETA is), so it is solved here, the
/// way the meet options solve both routes: from their last presence fix, on
/// their profile and learned pace, to the agreed rendezvous, anchored at
/// that fix's capture time.
public struct GhostPlan: Sendable, Hashable {
    public struct Track: Sendable, Hashable {
        public var userID: UUID
        public var isSelf: Bool
        public var projection: RouteProjection
        public var anchor: Date
        public var anchorRouteTimeS: Double

        public init(userID: UUID, isSelf: Bool, projection: RouteProjection, anchor: Date, anchorRouteTimeS: Double) {
            self.userID = userID
            self.isSelf = isSelf
            self.projection = projection
            self.anchor = anchor
            self.anchorRouteTimeS = anchorRouteTimeS
        }

        /// When this skier reaches the rendezvous on the plan.
        public var arrivesAt: Date {
            anchor.addingTimeInterval(max(0, projection.durationS - anchorRouteTimeS))
        }
    }

    public struct Ghost: Sendable, Hashable {
        public var userID: UUID
        public var isSelf: Bool
        /// The scrubbed instant, for the label.
        public var at: Date
        public var coordinate: Coordinate
        /// At the rendezvous by then.
        public var arrived: Bool
        /// Dots along the way from the anchor to the ghost, about one a minute
        /// of plan time and at most `maximumTrailDots`, the last one the ghost.
        public var trail: [Coordinate]
    }

    public static let trailStepS = 60.0
    public static let maximumTrailDots = 20

    public var tracks: [Track]

    public init(tracks: [Track]) {
        self.tracks = tracks
    }

    /// Each skier's ghost at `instant`. A skier whose anchor is after it has
    /// none: the past is the breadcrumbs' to show.
    public func ghosts(at instant: Date) -> [Ghost] {
        tracks.compactMap { track in
            let ahead = instant.timeIntervalSince(track.anchor)
            guard ahead >= 0 else { return nil }
            let head = track.projection.position(atRouteTime: track.anchorRouteTimeS + ahead)
            // Dots stop at the rendezvous: plan time past arrival adds none.
            let travelled = min(ahead, max(0, track.projection.durationS - track.anchorRouteTimeS))
            let count = min(Self.maximumTrailDots, max(1, Int((travelled / Self.trailStepS).rounded(.up))))
            let step = travelled / Double(count)
            var trail = (1..<count).map {
                track.projection.position(atRouteTime: track.anchorRouteTimeS + step * Double($0)).coordinate
            }
            trail.append(head.coordinate)
            return Ghost(
                userID: track.userID, isSelf: track.isSelf, at: instant, coordinate: head.coordinate,
                arrived: head.arrived, trail: trail
            )
        }
    }
}
