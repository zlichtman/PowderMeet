import Foundation
import Testing
@testable import PowderMeetAPI

// The friend card, add codes and reports (migrations 0016 and 0017): the wire
// shape `social_snapshot()` sends, the add link, and the fake keeping the card
// fields to friends as the SQL does (tests/database/100 and 110).

@Test func friendEntryDecodesTheCardFieldsAndOthersHaveNone() throws {
    let json = """
    {"friends": [{"friendship_id": "11111111-1111-4111-8111-111111111111",
                  "user_id": "22222222-2222-4222-8222-222222222222", "display_name": "Bob",
                  "avatar_url": "22222222-2222-4222-8222-222222222222/a.jpg", "since": "2026-01-10T18:00:00Z",
                  "ability": "expert",
                  "equipment": {"discipline": "ski", "type": "freeride", "length_cm": 184, "ski": "atomic-bent-110"},
                  "stats": {"runs": 3, "days": 2, "distance_m": 4500, "vertical_m": 900,
                            "top_speed_ms": 25, "avg_speed_ms": 7.5},
                  "last_seen": {"resort_id": "whistler-blackcomb", "at": "2026-01-10T17:58:00Z"}},
                 {"friendship_id": "33333333-3333-4333-8333-333333333333",
                  "user_id": "44444444-4444-4444-8444-444444444444", "display_name": "Ann",
                  "avatar_url": null, "since": null, "ability": "beginner",
                  "equipment": {"discipline": "sled"},
                  "stats": {"runs": 0, "days": 0, "distance_m": 0, "vertical_m": 0,
                            "top_speed_ms": null, "avg_speed_ms": null},
                  "last_seen": null}],
     "pending_in": [{"friendship_id": "55555555-5555-4555-8555-555555555555",
                     "user_id": "66666666-6666-4666-8666-666666666666", "display_name": "Carol",
                     "avatar_url": null, "created_at": "2026-01-10T17:00:00Z"}],
     "pending_out": [], "blocks": []}
    """
    let snapshot = try WireCoding.decoder().decode(SocialSnapshot.self, from: Data(json.utf8))

    let bob = try #require(snapshot.friends.first)
    #expect(bob.ability == "expert")
    #expect(bob.equipment?.ski == "atomic-bent-110")
    #expect(bob.stats == LifetimeStats(runs: 3, days: 2, distanceM: 4500, verticalM: 900, topSpeedMS: 25, avgSpeedMS: 7.5))
    #expect(bob.lastSeen?.resortID == "whistler-blackcomb")

    // Gear this build cannot read costs the gear, not the snapshot.
    let ann = snapshot.friends[1]
    #expect(ann.equipment == nil && ann.stats?.topSpeedMS == nil && ann.lastSeen == nil)

    let carol = try #require(snapshot.pendingIn.first)
    #expect(carol.ability == nil && carol.equipment == nil && carol.stats == nil && carol.lastSeen == nil)
}

@Test func authLinksAreRecognised() throws {
    #expect(AuthLink.isAuthCallback(try #require(URL(string: "powdermeet://auth-callback?code=x"))))
    #expect(!AuthLink.isAuthCallback(try #require(URL(string: "powdermeet://add/ABCDEFGH23"))))
}

@Test func theFakeKeepsCardFieldsToWhoMayHaveThem() async throws {
    let backend = FakeBackend()
    let alice = await backend.addUser(displayName: "Alice")
    let bob = await backend.addUser(displayName: "Bob")
    let carol = await backend.addUser(displayName: "Carol")
    let dave = await backend.addUser(displayName: "Dave")
    await backend.makeFriends(alice, bob)
    _ = try await backend.client(signedInAs: carol).friendRequest(user: alice)
    _ = try await backend.client(signedInAs: bob).profileUpdate(
        ProfilePatch().equipment(ProfileEquipment(discipline: "ski", type: "park")))

    let snapshot = try await backend.client(signedInAs: alice).socialSnapshot()
    #expect(snapshot.friends.map(\.displayName) == ["Bob"])
    #expect(snapshot.friends.first?.equipment?.type == "park")
    #expect(snapshot.friends.first?.stats == LifetimeStats())
    #expect(snapshot.pendingIn.first?.stats == nil && snapshot.pendingIn.first?.equipment == nil)

}

// Search by name (0019), the cases 130_search_users.test.sql checks: the wire
// row decodes, and the fake hides the caller, blocks either way and
// placeholder names, and puts prefix matches first.
@Test func searchByNameHidesSelfBlocksAndPlaceholders() async throws {
    let row = """
    [{"user_id": "22222222-2222-4222-8222-222222222222", "display_name": "Bob",
      "avatar_url": null, "relation": "request_received"}]
    """
    let decoded = try WireCoding.decoder().decode([UserSearchResult].self, from: Data(row.utf8))
    #expect(decoded.first?.relation == .requestReceived)

    let backend = FakeBackend()
    let alice = await backend.addUser(displayName: "Alice")
    let frank = await backend.addUser(displayName: "Frank")
    let gina = await backend.addUser(displayName: "Gina Frankel")
    let blocked = await backend.addUser(displayName: "Frankie Blocked")
    let blocker = await backend.addUser(displayName: "Frances Blocker")
    let skier = await backend.addUser(displayName: "Skier Frankfurt")
    _ = await backend.addUser(displayName: "Skier 123456")
    let me = backend.client(signedInAs: alice)
    try await me.blockUser(blocked)
    try await backend.client(signedInAs: blocker).blockUser(alice)
    _ = try await me.friendRequest(user: gina)

    let found = try await me.searchUsers(query: "  FRAN ")
    #expect(found.map(\.userID) == [frank, gina, skier], "prefix first, then contains, by name")
    #expect(found.map(\.relation) == [.none, .requestSent, .none])
    #expect(try await me.searchUsers(query: "skier 1").isEmpty, "placeholders are not listed")
    #expect(try await me.searchUsers(query: "alice").isEmpty, "nor is the caller")
    #expect(try await me.searchUsers(query: "f").isEmpty, "one character finds nobody")
    #expect(DisplayName.isPlaceholder("Skier 0123456789ab") && !DisplayName.isPlaceholder("Skier Sam"))
}

/// A block is never revealed: a request to someone who blocked you looks
/// unanswered, they see nothing, and a meet to them is just "not friends".
@Test func aBlockLooksLikeAnUnansweredRequest() async throws {
    let backend = FakeBackend()
    let alice = await backend.addUser(displayName: "Alice")
    let bob = await backend.addUser(displayName: "Bob")
    try await backend.client(signedInAs: bob).blockUser(alice)
    let me = backend.client(signedInAs: alice)

    let row = try await me.friendRequest(user: bob)
    #expect(row.status == .pending)
    #expect(try await me.socialSnapshot().pendingOut.map(\.userID) == [bob])
    #expect(try await backend.client(signedInAs: bob).socialSnapshot().pendingIn.isEmpty)
    await #expect(throws: BackendError.notFriends) {
        _ = try await me.meetPropose(
            meetID: UUID(), invitee: bob, resortID: "any", rendezvousID: "any", bundleID: nil,
            proposerEtaS: 60, proposerEtaSdS: 10, supersedes: nil
        )
    }
}
