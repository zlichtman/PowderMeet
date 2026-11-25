import Foundation
import MountainCore
import PowderMeetAPI
import Testing
@testable import AppCore

/// A metric row converts the imperial step honestly: 9,999 ft toward
/// 10,000 ft must not read as 3,048 m of 3,048 m, which looks reached.
@Test func aMetricBadgeRowNeverLooksReachedBeforeItIs() throws {
    let vertical = try #require(Badges.all.first { $0.id == "vertical" })
    let standing = Badges.Earned(badge: vertical, isEarned: false, tier: nil, value: 9_999)
    let metric = Badge.Units(metricLengths: true, metricSpeed: false)

    let progress = try #require(standing.progress(in: metric))
    #expect(progress.value < progress.next)
    #expect(progress.next == 3_048)
    #expect(vertical.rule(in: metric) == "Vertical metres skied in all.")
    // A UK phone: metres, but miles an hour.
    let speed = try #require(Badges.all.first { $0.id == "need-for-speed" })
    #expect(speed.rule(in: metric) == speed.rule)
}

/// The first launch after updating remembers what is already earned and says
/// nothing; after that only a badge or tier not seen before is announced, and
/// one earned again after its log was deleted is not.
@Test func aBadgeIsAnnouncedOnceWhenItIsFirstEarned() throws {
    func earned(_ id: String, _ tier: Badge.Tier? = nil) throws -> Badges.Earned {
        Badges.Earned(badge: try #require(Badges.all.first { $0.id == id }), isEarned: true, tier: tier, value: nil)
    }
    let before = [try earned("first-tracks"), try earned("explorer", .bronze)]
    let installed = BadgeMoments.check(before, seen: nil)
    #expect(installed.newlyEarned.isEmpty)

    let after = [try earned("first-tracks"), try earned("explorer", .silver), try earned("logbook")]
    let moment = BadgeMoments.check(after, seen: installed.seen)
    #expect(moment.newlyEarned.map(\.id) == ["explorer", "logbook"])
    #expect(moment.newlyEarned.first?.tier == .silver)

    let deleted = BadgeMoments.check([try earned("first-tracks")], seen: moment.seen)
    #expect(deleted.newlyEarned.isEmpty)
    #expect(BadgeMoments.check(after, seen: deleted.seen).newlyEarned.isEmpty)
}

/// Only a meet the server completed because both skiers arrived counts; an
/// end by hand, a decline or an expiry does not. Crew counts friends, not
/// meets, and First Chair Crew reads the resort's clock, not the phone's.
@Test func meetBadgesCountOnlyMeetUpsReached() throws {
    let me = UUID(), anna = UUID(), ben = UUID()
    let zone = "America/Vancouver"
    func meet(_ partner: UUID, _ status: MeetStatus, _ reason: MeetEndReason?, endedAt: String) throws -> Meet {
        Meet(
            meetID: UUID(), resortID: "whistler", rendezvousID: RendezvousID(rawValue: "roundhouse-lodge"),
            proposerID: me, inviteeID: partner, status: status, endReason: reason, createdAt: .distantPast,
            endedAt: try #require(ISO8601DateFormatter().date(from: endedAt)), expiresAt: .distantFuture)
    }
    let meets = [
        // 9:15 in Whistler, 17:15 UTC.
        try meet(anna, .completed, .arrived, endedAt: "2026-01-10T17:15:00Z"),
        try meet(anna, .completed, .arrived, endedAt: "2026-01-11T20:00:00Z"),
        try meet(ben, .cancelled, .userCancelled, endedAt: "2026-01-12T17:00:00Z"),
        try meet(ben, .expired, .timeout, endedAt: "2026-01-13T17:00:00Z"),
    ]
    let reached = Badges.reached(meets, me: me, zones: ["whistler": zone])
    #expect(reached.count == 2)

    func standing(_ id: String, _ meets: [Badges.ReachedMeet]?) -> Badges.Earned? {
        Badges.standings(ActivityHistory(), meets: meets, facts: [:], levelIsBacked: false, isBeta: false)
            .first { $0.id == id }
    }
    #expect(standing("first-meet", reached)?.isEarned == true)
    #expect(standing("crew", reached)?.value == 1)
    #expect(standing("regulars", reached)?.value == 2)
    #expect(standing("first-chair-crew", reached)?.isEarned == true)
    #expect(standing("first-chair-crew", Badges.reached(meets, me: me, zones: [:]))?.isEarned == false)
    // Not read yet: nothing counted, rather than none reached.
    #expect(standing("regulars", nil)?.value == nil)
    #expect(standing("first-meet", nil)?.isEarned == false)
}
