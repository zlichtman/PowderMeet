import Foundation
import Testing
@testable import PowderMeetAPI

// The phone's copy of the server's display-name normalisation. These are the
// cases `backend/supabase/tests/database/080_display_names.test.sql` checks
// against `display_name_normalize`; a difference means the name field would
// accept a name the server then refuses, or the reverse.

@Test(arguments: [
    ("  Al  ", "Al"),
    ("Jo    Bloggs", "Jo Bloggs"),
    ("Jo\tBloggs", "Jo Bloggs"),
    ("Jo\u{00A0}Bloggs", "Jo Bloggs"),
    ("Ann\u{200B}e", "Anne"),
    ("Ma\u{202E}x", "Max"),
    ("Zo\u{00AD}e", "Zoe"),
    ("\u{FF3A}\u{FF41}\u{FF43}\u{FF48}", "Zach"),
    ("\u{3164}\u{3164}", ""),
    ("Jos\u{00E9}", "Jos\u{00E9}"),
    // Not in the pgTAP file: a decomposed accent composes, and an invisible
    // character between two spaces leaves one space.
    ("Jose\u{0301}", "Jos\u{00E9}"),
    ("A \u{200B} B", "A B"),
])
func normalizesAsTheServerDoes(raw: String, expected: String) {
    #expect(DisplayName.normalize(raw) == expected)
}

@Test func lengthIsTwoToTwentyFourCodePoints() {
    #expect(DisplayName.validate("A") == .failure(.init(problem: .tooShort)))
    #expect(DisplayName.validate("A\u{200B}") == .failure(.init(problem: .tooShort)))
    #expect(DisplayName.validate(String(repeating: "a", count: 25)) == .failure(.init(problem: .tooLong)))
    #expect(DisplayName.validate(String(repeating: "a", count: 24)) == .success(String(repeating: "a", count: 24)))
    #expect(DisplayName.validate(" Al ") == .success("Al"))
    // Postgres counts code points: a family emoji is five of them, not one.
    #expect(DisplayName.length("👨‍👩‍👧") == 5)
}

@Test func theFakeServerAppliesTheSameRules() async throws {
    let backend = FakeBackend()
    let alice = await backend.addUser(displayName: "Alice")
    let bob = await backend.addUser(displayName: "Bob")
    let asBob = backend.client(signedInAs: bob)
    await #expect(throws: BackendError.nameTaken) {
        _ = try await asBob.profileUpdate(ProfilePatch().displayName("ALICE"))
    }
    await #expect(throws: BackendError.invalid) {
        _ = try await asBob.profileUpdate(ProfilePatch().displayName("x"))
    }
    #expect(try await asBob.displayNameAvailable("alice") == .taken)
    #expect(try await asBob.displayNameAvailable("bob") == .available)
    let saved = try await backend.client(signedInAs: alice).profileUpdate(ProfilePatch().displayName("  alice  "))
    #expect(saved.displayName == "alice")
}
