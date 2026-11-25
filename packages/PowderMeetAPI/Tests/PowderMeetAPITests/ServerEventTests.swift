import Foundation
import MountainCore
import Testing
@testable import PowderMeetAPI

// Payloads as `public.emit` builds them: `to_jsonb(row)` for meets and status,
// `jsonb_build_object` for the rest. Postgres prints timestamps with microseconds
// and a numeric offset, and uuids in lower case.

private func decode(_ json: String) throws -> ServerEventEnvelope {
    try ServerEventEnvelope.decode(Data(json.utf8))
}

private let meetID = UUID(uuidString: "7b1c2f0e-58a3-4a61-9d55-0f3a5a0c1d11")!
private let alice = UUID(uuidString: "0a6f4f0c-3d4b-4c58-8a4b-2f1f0b9f7a01")!
private let bob = UUID(uuidString: "5e0b8c1d-9f3e-4b7a-a1c2-6d7e8f9a0b02")!

@Test func timestampsParseInEveryPostgresShape() throws {
    let expected = Date(timeIntervalSince1970: 1_795_150_496)
    #expect(WireCoding.date(from: "2026-11-20T04:54:56Z") == expected)
    #expect(WireCoding.date(from: "2026-11-20T04:54:56+00:00") == expected)
    #expect(WireCoding.date(from: "2026-11-19 21:54:56-07") == expected)
    let micro = try #require(WireCoding.date(from: "2026-11-20T04:54:56.123456+00:00"))
    #expect(abs(micro.timeIntervalSince(expected) - 0.123456) < 1e-6)
    #expect(WireCoding.date(from: "2026-11-20") == nil)
    #expect(WireCoding.date(from: WireCoding.string(from: expected)) == expected)
}

@Test func meetProposedDecodesTheFullRow() throws {
    let envelope = try decode("""
    {"v": 1, "type": "meet.proposed", "at": "2026-11-20T04:54:56.482913+00:00", "data": {
      "meet_id": "7b1c2f0e-58a3-4a61-9d55-0f3a5a0c1d11", "resort_id": "whistler-blackcomb",
      "bundle_id": "9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08",
      "rendezvous_id": "roundhouse-lodge",
      "proposer_id": "0a6f4f0c-3d4b-4c58-8a4b-2f1f0b9f7a01",
      "invitee_id": "5e0b8c1d-9f3e-4b7a-a1c2-6d7e8f9a0b02",
      "status": "proposed", "end_reason": null,
      "proposer_eta_s": 540, "proposer_eta_sd_s": 75, "invitee_eta_s": null, "invitee_eta_sd_s": null,
      "created_at": "2026-11-20T04:54:56.482913+00:00", "responded_at": null, "ended_at": null,
      "expires_at": "2026-11-20T05:24:56.482913+00:00", "superseded_by": null}}
    """)
    guard case .meetProposed(let meet) = envelope.event else {
        Issue.record("expected meet.proposed, got \(envelope.event)")
        return
    }
    #expect(envelope.v == 1)
    #expect(meet.meetID == meetID)
    #expect(meet.rendezvousID == "roundhouse-lodge")
    #expect(meet.proposerID == alice && meet.inviteeID == bob)
    #expect(meet.status == .proposed && meet.endReason == nil)
    #expect(meet.proposerEtaS == 540 && meet.inviteeEtaS == nil)
    #expect(meet.expiresAt.timeIntervalSince(meet.createdAt) == 30 * 60)
}

@Test func meetUpdatedCarriesTheEndReason() throws {
    let envelope = try decode("""
    {"v": 1, "type": "meet.updated", "at": "2026-11-20T05:01:00+00:00", "data": {
      "meet_id": "7b1c2f0e-58a3-4a61-9d55-0f3a5a0c1d11", "resort_id": "whistler-blackcomb",
      "bundle_id": null, "rendezvous_id": "roundhouse-lodge",
      "proposer_id": "0a6f4f0c-3d4b-4c58-8a4b-2f1f0b9f7a01",
      "invitee_id": "5e0b8c1d-9f3e-4b7a-a1c2-6d7e8f9a0b02",
      "status": "invalidated", "end_reason": "status_blocks_route",
      "proposer_eta_s": 540, "proposer_eta_sd_s": 75, "invitee_eta_s": 610, "invitee_eta_sd_s": 90,
      "created_at": "2026-11-20T04:54:56+00:00", "responded_at": "2026-11-20T04:56:00+00:00",
      "ended_at": "2026-11-20T05:01:00+00:00", "expires_at": "2026-11-20T05:24:56+00:00",
      "superseded_by": null}}
    """)
    guard case .meetUpdated(let meet) = envelope.event else {
        Issue.record("expected meet.updated, got \(envelope.event)")
        return
    }
    #expect(meet.status == .invalidated && meet.status.isTerminal)
    #expect(meet.endReason == .statusBlocksRoute)
    #expect(meet.bundleID == nil && meet.inviteeEtaSdS == 90)
}

@Test func meetProgressDecodes() throws {
    let envelope = try decode("""
    {"v": 1, "type": "meet.progress", "at": "2026-11-20T04:58:10.5+00:00", "data": {
      "meet_id": "7b1c2f0e-58a3-4a61-9d55-0f3a5a0c1d11",
      "user_id": "5e0b8c1d-9f3e-4b7a-a1c2-6d7e8f9a0b02", "eta_s": 420, "eta_sd_s": 60,
      "remaining_m": 1830, "state": "rerouting", "fix_at": "2026-11-20T04:58:09+00:00"}}
    """)
    #expect(envelope.event == .meetProgress(MeetProgress(
        meetID: meetID, userID: bob, etaS: 420, etaSdS: 60, remainingM: 1_830, state: .rerouting,
        fixAt: Date(timeIntervalSince1970: 1_795_150_689)
    )))
}

@Test func presenceDecodesWithNullsAndNoServerFields() throws {
    let envelope = try decode("""
    {"v": 1, "type": "presence", "at": "2026-11-20T04:58:10+00:00", "data": {
      "user_id": "5e0b8c1d-9f3e-4b7a-a1c2-6d7e8f9a0b02", "resort_id": "whistler-blackcomb",
      "lon": -122.9486, "lat": 50.0683, "accuracy_m": 8.5, "speed_ms": null,
      "heading_deg": null, "captured_at": "2026-11-20T04:58:09+00:00"}}
    """)
    guard case .presence(let presence) = envelope.event else {
        Issue.record("expected presence, got \(envelope.event)")
        return
    }
    #expect(presence.userID == bob && presence.resortID == "whistler-blackcomb")
    #expect(presence.lon == -122.9486 && presence.accuracyM == 8.5)
    #expect(presence.speedMS == nil && presence.receivedAt == nil)
}

@Test func friendEventsDecode() throws {
    for (type, make) in [
        ("friend.requested", ServerEvent.friendRequested),
        ("friend.accepted", ServerEvent.friendAccepted),
        ("friend.removed", ServerEvent.friendRemoved),
    ] as [(String, (FriendEvent) -> ServerEvent)] {
        let envelope = try decode("""
        {"v": 1, "type": "\(type)", "at": "2026-11-20T04:58:10+00:00", "data": {
          "user_id": "0a6f4f0c-3d4b-4c58-8a4b-2f1f0b9f7a01", "display_name": "Alice",
          "avatar_url": null, "friendship_id": "7b1c2f0e-58a3-4a61-9d55-0f3a5a0c1d11"}}
        """)
        #expect(envelope.event == make(FriendEvent(
            friendshipID: meetID, userID: alice, displayName: "Alice"
        )))
    }
}

@Test func resortStatusDecodesTheInsertedRow() throws {
    let envelope = try decode("""
    {"v": 1, "type": "resort.status", "at": "2026-11-20T05:00:00+00:00", "data": {
      "id": 4417, "resort_id": "whistler-blackcomb", "observed_at": "2026-11-20T05:00:00+00:00",
      "expires_at": "2026-11-20T05:20:00+00:00", "source": "epic",
      "groups": {"lift:peak-express": "closed", "lift:emerald-6-express": "open",
                 "lift:harmony-6-express": "hold"},
      "groomed": ["trail:ego-bowl"], "created_at": "2026-11-20T05:00:01.2+00:00"}}
    """)
    guard case .resortStatus(let status) = envelope.event else {
        Issue.record("expected resort.status, got \(envelope.event)")
        return
    }
    #expect(status.resortID == "whistler-blackcomb" && status.source == .epic)
    #expect(status.groups["lift:peak-express"] == .closed)
    #expect(status.groups["lift:harmony-6-express"] == .hold)
    #expect(status.groomed == ["trail:ego-bowl"])
    #expect(status.expiresAt.timeIntervalSince(status.observedAt) == 20 * 60)
}

@Test func unknownTypesAndVersionsAreNotMisread() throws {
    let unknown = try decode("""
    {"v": 1, "type": "meet.reaction", "at": "2026-11-20T05:00:00+00:00", "data": {"emoji": "x"}}
    """)
    #expect(unknown.event == .unknown(type: "meet.reaction"))
    #expect(throws: ServerEventEnvelope.DecodeError.unsupportedVersion(2)) {
        try decode("""
        {"v": 2, "type": "presence", "at": "2026-11-20T05:00:00+00:00", "data": {}}
        """)
    }
    #expect(throws: DecodingError.self) {
        try decode("""
        {"v": 1, "type": "meet.progress", "at": "2026-11-20T05:00:00+00:00", "data": {"meet_id": 4}}
        """)
    }
}

@Test func socialSnapshotDecodesTheRPCShape() throws {
    let snapshot = try WireCoding.decoder().decode(SocialSnapshot.self, from: Data("""
    {"friends": [{"friendship_id": "7b1c2f0e-58a3-4a61-9d55-0f3a5a0c1d11",
                  "user_id": "5e0b8c1d-9f3e-4b7a-a1c2-6d7e8f9a0b02", "display_name": "Bob",
                  "avatar_url": "5e0b8c1d-9f3e-4b7a-a1c2-6d7e8f9a0b02/a.jpg",
                  "since": "2026-11-01T10:00:00+00:00"}],
     "pending_in": [], "pending_out": [],
     "blocks": [{"user_id": "0a6f4f0c-3d4b-4c58-8a4b-2f1f0b9f7a01", "display_name": "Alice",
                 "avatar_url": null, "created_at": "2026-11-02T10:00:00+00:00"}]}
    """.utf8))
    #expect(snapshot.isFriend(bob))
    #expect(snapshot.friends[0].at != nil && snapshot.blocks[0].friendshipID == nil)
}

@Test func meetRowDecodesEndedByWhenPresentAndWhenAbsent() throws {
    func row(_ extra: String) -> String {
        """
        {"v": 1, "type": "meet.updated", "at": "2026-11-20T05:00:00+00:00", "data": {
          "meet_id": "7b1c2f0e-58a3-4a61-9d55-0f3a5a0c1d11", "resort_id": "whistler-blackcomb",
          "rendezvous_id": "roundhouse-lodge",
          "proposer_id": "0a6f4f0c-3d4b-4c58-8a4b-2f1f0b9f7a01",
          "invitee_id": "5e0b8c1d-9f3e-4b7a-a1c2-6d7e8f9a0b02",
          "status": "cancelled", "end_reason": "user_cancelled",
          "created_at": "2026-11-20T04:54:56+00:00", "ended_at": "2026-11-20T05:00:00+00:00",
          "expires_at": "2026-11-20T05:24:56+00:00"\(extra)}}
        """
    }
    for (extra, expected) in [
        ("", UUID?.none),
        (#", "ended_by": null"#, UUID?.none),
        (#", "ended_by": "0a6f4f0c-3d4b-4c58-8a4b-2f1f0b9f7a01""#, UUID(uuidString: "0a6f4f0c-3d4b-4c58-8a4b-2f1f0b9f7a01")),
    ] {
        guard case .meetUpdated(let meet) = try decode(row(extra)).event else {
            Issue.record("expected meet.updated")
            return
        }
        #expect(meet.endedBy == expected)
    }
}
