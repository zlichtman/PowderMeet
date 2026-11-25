import Foundation
import MountainCore
import PowderMeetAPI

/// What the location source should be doing, decided from what wants fixes
/// (`specs/07-CLIENT.md` section 4). The app's CoreLocation driver applies the
/// answer; nothing else sets accuracy or background updates.
///
/// | Mode | When | Accuracy | Filter | Background |
/// |---|---|---|---|---|
/// | `navigation` | a meet is active, app on screen | best | 5 m | yes |
/// | `navigationBackground` | a meet is active, app in the background, not recording | 10 m | 10 m | yes; never pauses |
/// | `recording` | recording is on and the phone is at a resort | best | 5 m | yes |
/// | `presence` | a resort is open, at a resort, nothing above | 10 m | 30 m | yes |
/// | `browsing` | a resort is open on screen far from any resort | 100 m | 100 m | no |
/// | `watching` | recording is on, not at a resort | 1 km | 500 m | no; significant changes only |
/// | `locating` | nothing above; the app wants to know which resort it is at (launch, foreground) | 100 m | 100 m | no |
/// | `off` | nothing wants fixes | — | — | — |
///
/// `navigationBackground` keeps the partner's view of "still on the way" fresh
/// with the phone in a pocket: fixes every 10 m of movement (a skier at 10 m/s
/// gives one a second, a chairlift one every few seconds; presence goes out at
/// most every 10 s moving and 30 s still, progress every 10 s), at ten-metre
/// accuracy rather than best. It never lets iOS pause updates: a skier
/// waiting at the meeting point must keep reporting that they are there, or
/// the friend's arrival cannot complete the meet (an arrival older than
/// `MeetSession.arrivalFreshS` no longer counts, so that one left behind by
/// a skier who lost service and moved on does not). A meet is short, so the
/// battery this costs is small.
///
/// `presence` keeps going with the phone locked so friends still see you on
/// the mountain (presence is published at most every 30 s still, 5 s moving),
/// but loosely: a 30 m filter, and only routing-grade accuracy (I-14). It works
/// with "While Using" (iOS shows the blue indicator); "Always" is asked only
/// for meets and recording. `watching` is what lets recording start by itself
/// on arrival without a live process at home all week: coarse fixes while the
/// app is open, and with the phone locked only the significant-change service
/// (with "Always"), which wakes or relaunches the app on arrival.
public enum LocationMode: String, Sendable, Hashable {
    case off, locating, watching, browsing, presence, recording, navigationBackground, navigation

    public struct Settings: Sendable, Hashable {
        /// Desired horizontal accuracy in metres; 0 is "best".
        public var accuracyM: Double
        public var distanceFilterM: Double
        /// Updates continue with the phone locked (the blue indicator shows).
        public var background: Bool
        /// Also keep the significant-change service running, so iOS relaunches
        /// the app after it was terminated.
        public var significantChanges: Bool
        /// Let iOS pause updates while the phone is still. In the background
        /// a pause only ends by the driver's wake-up region, so a mode that
        /// keeps running in the background pauses only with "Always".
        public var pausesWhenStill: Bool

        public init(
            accuracyM: Double, distanceFilterM: Double, background: Bool, significantChanges: Bool,
            pausesWhenStill: Bool? = nil
        ) {
            self.accuracyM = accuracyM
            self.distanceFilterM = distanceFilterM
            self.background = background
            self.significantChanges = significantChanges
            self.pausesWhenStill = pausesWhenStill ?? !background
        }
    }

    public var settings: Settings? {
        switch self {
        case .off: nil
        case .locating: Settings(accuracyM: 100, distanceFilterM: 100, background: false, significantChanges: false)
        case .watching: Settings(accuracyM: 1_000, distanceFilterM: 500, background: false, significantChanges: true)
        case .browsing: Settings(accuracyM: 100, distanceFilterM: 100, background: false, significantChanges: false)
        case .presence: Settings(accuracyM: 10, distanceFilterM: 30, background: true, significantChanges: false)
        case .recording: Settings(accuracyM: 0, distanceFilterM: 5, background: true, significantChanges: true)
        case .navigation: Settings(accuracyM: 0, distanceFilterM: 5, background: true, significantChanges: false)
        case .navigationBackground:
            Settings(accuracyM: 10, distanceFilterM: 10, background: true, significantChanges: false, pausesWhenStill: false)
        }
    }

    /// Whether this mode is a reason to ask for "Always".
    public var wantsAlways: Bool {
        self == .navigation || self == .navigationBackground || self == .recording || self == .watching
    }
}

/// The inputs to the mode, as the app knows them.
public struct LocationDemand: Sendable, Hashable {
    /// A resort session is running and wants fixes for presence and the map.
    public var resortOpen: Bool
    /// The user turned live recording on.
    public var recordingOn: Bool
    /// A meet is active: navigation needs tight fixes.
    public var meetActive: Bool
    /// The last fix is at a published resort (`ResortVicinity`); nil when no
    /// fix is known yet.
    public var atResort: Bool?
    /// The app is not on screen.
    public var inBackground: Bool
    /// The app wants one fix to open the resort it is at (`ResortArrival`).
    public var locating: Bool

    public init(
        resortOpen: Bool = false, recordingOn: Bool = false, meetActive: Bool = false, atResort: Bool? = nil,
        inBackground: Bool = false, locating: Bool = false
    ) {
        self.resortOpen = resortOpen
        self.recordingOn = recordingOn
        self.meetActive = meetActive
        self.atResort = atResort
        self.inBackground = inBackground
        self.locating = locating
    }

    public var mode: LocationMode {
        if meetActive {
            // Recording's best-accuracy track wins over the looser meet mode.
            guard inBackground, !(recordingOn && atResort == true) else {
                return inBackground ? .recording : .navigation
            }
            return .navigationBackground
        }
        if recordingOn, atResort == true { return .recording }
        if resortOpen { return atResort == false ? .browsing : .presence }
        // Not known yet counts as away: a coarse fix answers it quickly.
        if recordingOn { return .watching }
        if locating, !inBackground { return .locating }
        return .off
    }
}

/// Whether a position is at a ski area, with hysteresis so a run along the
/// edge of a resort's box is not cut in two: enter within 1 km of a published
/// resort's bounding box, leave beyond 2 km of all of them.
public enum ResortVicinity {
    public static let enterM = 1_000.0
    public static let leaveM = 2_000.0

    /// The resort the position is at, or nil. `current` is the resort the
    /// phone was at before this fix.
    public static func resort(
        at coordinate: Coordinate, in resorts: [PublishedResort], current: String?
    ) -> PublishedResort? {
        if let current, let resort = resorts.first(where: { $0.id == current }),
           let box = resort.bbox, distanceM(coordinate, to: box) <= leaveM {
            return resort
        }
        return resorts
            .compactMap { resort in resort.bbox.map { (resort, distanceM(coordinate, to: $0)) } }
            .filter { $0.1 <= enterM }
            .min { ($0.1, $0.0.id) < ($1.1, $1.0.id) }?.0
    }

    /// Metres from the coordinate to the nearest point of the box; 0 inside.
    static func distanceM(_ coordinate: Coordinate, to box: BoundingBox) -> Double {
        let nearest = Coordinate(
            lon: min(max(coordinate.lon, box.minLon), box.maxLon),
            lat: min(max(coordinate.lat, box.minLat), box.maxLat)
        )
        return Geo.haversineM(coordinate, nearest)
    }
}

/// Opening the resort the phone is standing in, staying out of the way of
/// staged and developer testing.
///
/// Asked once per launch and once per return to the foreground, with the first
/// usable fix captured after it. Inside exactly one mapped resort's box, that
/// resort opens; inside several (boxes overlap: Alta and Snowbird, Brighton
/// and Solitude), the picker opens on just those. Never while the user picked a
/// resort themselves this session, while a meet is under way (opening another
/// resort would end it), or while developer testing moves the phone.
public enum ResortArrival {
    public enum Decision: Sendable, Hashable {
        case open(String)
        /// The ids, by name, to offer in the picker.
        case ask([String])
        case stay
    }

    public static let maximumAccuracyM = 200.0
    public static let maximumAgeS = 120.0

    /// Whether a fix may decide: recent, plausible and good to a couple of
    /// hundred metres (boxes are kilometres across).
    public static func isUsable(_ fix: Fix, now: Date) -> Bool {
        let age = now.timeIntervalSince(fix.capturedAt)
        return fix.coordinate.isValid && fix.accuracyM >= 0 && fix.accuracyM <= maximumAccuracyM
            && age < maximumAgeS && age >= -FixQuality.maximumFutureSkewS
    }

    /// - Parameters:
    ///   - current: the resort on screen, if any.
    ///   - userPicked: the user chose a resort (or closed one) this session.
    ///   - meetUnderWay: a meet is being planned, proposed, answered or skied.
    ///   - suppressed: the Debug preview stage, or developer testing has
    ///     teleported the phone or placed a dev person.
    public static func decide(
        fix: Fix, resorts: [PublishedResort], current: String?, userPicked: Bool, meetUnderWay: Bool,
        suppressed: Bool
    ) -> Decision {
        guard !userPicked, !meetUnderWay, !suppressed else { return .stay }
        let inside = resorts
            .filter { resort in resort.hasMap && resort.bbox.map { contains($0, fix.coordinate) } == true }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            .map(\.id)
        if inside.isEmpty { return .stay }
        if let current, inside.contains(current) { return .stay }
        return inside.count == 1 ? .open(inside[0]) : .ask(inside)
    }

    static func contains(_ box: BoundingBox, _ point: Coordinate) -> Bool {
        (box.minLon...box.maxLon).contains(point.lon) && (box.minLat...box.maxLat).contains(point.lat)
    }
}
