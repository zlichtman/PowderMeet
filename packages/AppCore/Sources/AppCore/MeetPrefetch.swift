import Foundation
import MeetSolver
import MountainCore
import PowderMeetAPI

/// Meeting options solved ahead of a tap, so tapping a friend shows them at
/// once.
///
/// `ResortSession` keeps one of these and runs at most one prefetch job at a
/// time, for the friends whose fresh position is at the open resort. A job loads
/// the friend's routing profile and pace (again once the copy is older than
/// `MeetSession.partnerRefreshS`) and solves the pair off the actor; the answer is kept under a coarse key, so it is found again on
/// a tap while both people are still roughly where they were. The tap shows
/// those options at once and `MeetSession` solves again on the exact inputs,
/// replacing them a moment later.
///
/// Battery: nothing runs while a meet is under way, while the app is in the
/// background, in Low Power Mode or before the map is ready; a friend is solved
/// again only when someone has moved to another bucket or the solve hour
/// changes, at most `maxFriends` friends are kept, and the gap between two jobs
/// is at least `minimumGapS` and four times the last solve's duration, so
/// prefetching stays under a fifth of one core on a mountain where solves are
/// slow.
public struct MeetPrefetch: Sendable {
    /// About 450 m north–south and 300 m east–west at 50° N: positions that
    /// snap to the same part of the mountain share options.
    public static let bucketDegrees = 0.004
    public static let maxFriends = 6
    public static let minimumGapS = 5.0
    public static let retryAfterFailureS = 60.0
    /// A friend's fix older than this is not worth solving for.
    public static let freshPresenceS = 5.0 * 60

    /// Where a person is, coarsely.
    public struct Bucket: Hashable, Sendable {
        public var lat: Int
        public var lon: Int

        public init(_ coordinate: Coordinate) {
            lat = Int((coordinate.lat / MeetPrefetch.bucketDegrees).rounded(.down))
            lon = Int((coordinate.lon / MeetPrefetch.bucketDegrees).rounded(.down))
        }
    }

    /// Friend, both coarse positions, this phone's routing profile and the
    /// solve hour: what the options depend on that changes during a day.
    public struct Key: Hashable, Sendable {
        public var friend: UUID
        public var mine: Bucket
        public var theirs: Bucket
        public var profile: SkierProfile
        /// Whole hours since the reference date, of the solve clock.
        public var hour: Int

        public init(friend: UUID, mine: Coordinate, theirs: Coordinate, profile: SkierProfile, at: Date) {
            self.friend = friend
            self.mine = Bucket(mine)
            self.theirs = Bucket(theirs)
            self.profile = profile
            hour = Int((at.timeIntervalSinceReferenceDate / 3_600).rounded(.down))
        }
    }

    /// A friend's routing profile and learned pace, as `MeetSession` needs them.
    public struct Person: Sendable, Hashable {
        public var profile: SkierProfile
        public var pace: PaceModel?
        /// Their display name, for a failed meet that is about them.
        public var name: String?
        /// When this copy was read: a level or pace can change mid-session.
        public var readAt: Date

        public init(profile: SkierProfile, pace: PaceModel?, name: String? = nil, readAt: Date) {
            self.profile = profile
            self.pace = pace
            self.name = name
            self.readAt = readAt
        }
    }

    /// What a tap starts from: options when the key matched, otherwise only
    /// the people, which still saves the profile reads.
    public struct Seed: Sendable {
        public var options: MeetOptions?
        public var partner: Person?
        public var myPace: PaceModel?
    }

    /// Nil for a pair the solver had no answer for (someone off the graph), so
    /// it is not tried again until someone moves.
    private var answers: [Key: MeetOptions?] = [:]
    /// Keys in the order they were stored, oldest first.
    private var order: [Key] = []
    public private(set) var people: [UUID: Person] = [:]
    /// Nil until loaded; `.some(nil)` when this user has no learned pace.
    public private(set) var myPace: PaceModel??
    /// When the next job may start.
    public private(set) var notBefore: Date = .distantPast

    public init() {}

    public func options(for key: Key) -> MeetOptions? { answers[key] ?? nil }

    public func seed(for key: Key?, friend: UUID) -> Seed {
        Seed(options: key.flatMap { options(for: $0) }, partner: people[friend], myPace: myPace ?? nil)
    }

    /// The friend to solve next, nearest first among those with no answer for
    /// where everyone is now; nil when everything is answered.
    public func next(
        friends: [Presence], resortID: String, mine: Coordinate, profile: SkierProfile, at: Date, now: Date
    ) -> Key? {
        friends
            .filter { friend in
                friend.resortID == resortID && now.timeIntervalSince(friend.capturedAt) < Self.freshPresenceS
            }
            .map { friend in
                (friend, Geo.haversineM(mine, Coordinate(lon: friend.lon, lat: friend.lat)))
            }
            .sorted { ($0.1, $0.0.userID.uuidString) < ($1.1, $1.0.userID.uuidString) }
            .prefix(Self.maxFriends)
            .map { friend, _ in
                Key(friend: friend.userID, mine: mine, theirs: Coordinate(lon: friend.lon, lat: friend.lat),
                    profile: profile, at: at)
            }
            .first { answers.index(forKey: $0) == nil }
    }

    /// Keeps a solve's answer, nil when there was none. Each friend keeps only
    /// their newest key.
    public mutating func store(_ value: MeetOptions?, for key: Key, solvedInS: Double, now: Date) {
        if let stale = order.firstIndex(where: { $0.friend == key.friend }) {
            answers.removeValue(forKey: order.remove(at: stale))
        }
        answers[key] = .some(value)
        order.append(key)
        while order.count > Self.maxFriends {
            answers.removeValue(forKey: order.removeFirst())
        }
        notBefore = now.addingTimeInterval(max(Self.minimumGapS, 4 * solvedInS))
    }

    /// A job that could not read what it needed (offline, say): nobody is
    /// tried again for a minute.
    public mutating func failed(now: Date) {
        notBefore = now.addingTimeInterval(Self.retryAfterFailureS)
    }

    public mutating func remember(_ person: Person, for friend: UUID) { people[friend] = person }

    /// The friend's profile and pace while the copy is young enough to solve
    /// on; nil sends the job to read them again.
    public func freshPerson(_ friend: UUID, now: Date) -> Person? {
        guard let person = people[friend],
              now.timeIntervalSince(person.readAt) < MeetSession.partnerRefreshS else { return nil }
        return person
    }

    public mutating func rememberMyPace(_ pace: PaceModel?) { myPace = .some(pace) }

    /// Status or conditions changed: every stored answer may be out of date.
    public mutating func forgetOptions() {
        answers = [:]
        order = []
    }

    /// An unfriend or block: nothing about that person is kept.
    public mutating func forget(_ friend: UUID) {
        people[friend] = nil
        order.removeAll { key in
            guard key.friend == friend else { return false }
            answers.removeValue(forKey: key)
            return true
        }
    }

    /// Low Power Mode is on: no work that only saves a moment later.
    static var deviceSavingPower: Bool {
        #if os(iOS)
        ProcessInfo.processInfo.isLowPowerModeEnabled
        #else
        false
        #endif
    }
}
