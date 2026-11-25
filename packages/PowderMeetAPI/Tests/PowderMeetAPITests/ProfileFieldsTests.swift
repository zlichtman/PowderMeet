import Foundation
import MountainCore
import Testing
@testable import PowderMeetAPI

// The fake follows `profile_update` and the profiles column grants: a friend's
// phone gets what it needs to route the skier, never their height or weight.

@Test func heightAndWeightNeverLeaveTheirOwner() async throws {
    let backend = FakeBackend()
    let alice = await backend.addUser(displayName: "Alice")
    let bob = await backend.addUser(displayName: "Bob")
    await backend.makeFriends(alice, bob)

    let saved = try await backend.client(signedInAs: alice).profileUpdate(
        ProfilePatch()
            .equipment(ProfileEquipment(discipline: "ski", type: "freeride", lengthCM: 184, waistMM: 108))
            .avoid(["surface_lifts", "park", "park"])
            .maxPitchDeg(32)
            .heightCM(178)
            .weightKG(74)
    )
    #expect(saved.heightCM == 178 && saved.weightKG == 74)
    #expect(saved.avoid == ["park", "surface_lifts"])

    let own = try #require(try await backend.client(signedInAs: alice).profile(id: alice))
    #expect(own.heightCM == 178 && own.weightKG == 74)

    let seenByFriend = try #require(try await backend.client(signedInAs: bob).profile(id: alice))
    #expect(seenByFriend.equipment?.waistMM == 108)
    #expect(seenByFriend.avoid == ["park", "surface_lifts"] && seenByFriend.maxPitchDeg == 32)
    #expect(seenByFriend.heightCM == nil && seenByFriend.weightKG == nil)
}

@Test func profileUpdateRefusesWhatTheColumnsRefuse() async throws {
    let backend = FakeBackend()
    let client = backend.client(signedInAs: await backend.addUser())
    let refused: [ProfilePatch] = [
        ProfilePatch().equipment(ProfileEquipment(discipline: "sled")),
        ProfilePatch().equipment(ProfileEquipment(discipline: "snowboard")),
        ProfilePatch().equipment(ProfileEquipment(discipline: "ski", lengthCM: 400)),
        ProfilePatch().equipment(ProfileEquipment(discipline: "ski", ski: "Atomic Bent 110")),
        ProfilePatch().equipment(ProfileEquipment(discipline: "ski", skin: "plaid")),
        ProfilePatch().avoid(["cliffs"]),
        ProfilePatch().maxPitchDeg(60),
        ProfilePatch().heightCM(20),
        ProfilePatch().weightKG(500),
    ]
    for patch in refused {
        await #expect(throws: BackendError.invalid) { _ = try await client.profileUpdate(patch) }
    }
    let cleared = try await client.profileUpdate(ProfilePatch().equipment(nil).maxPitchDeg(nil))
    #expect(cleared.equipment == nil && cleared.maxPitchDeg == nil)
}

@Test func equipmentUsesTheColumnsKeys() throws {
    let patch = ProfilePatch().equipment(ProfileEquipment(discipline: "ski", lengthCM: 177))
    let json = String(decoding: try JSONEncoder().encode(patch), as: UTF8.self)
    #expect(json.contains("\"length_cm\":177") && !json.contains("waist_mm"))
    let row = try JSONDecoder().decode(Profile.self, from: Data("""
    {"id": "0a6f4f0c-3d4b-4c58-8a4b-2f1f0b9f7a01", "display_name": "A",
     "equipment": {"discipline": "ski", "type": "park", "length_cm": 172},
     "avoid": ["flats"], "max_pitch_deg": 28, "height_cm": 170, "weight_kg": null}
    """.utf8))
    #expect(row.equipment == ProfileEquipment(discipline: "ski", type: "park", lengthCM: 172))
    #expect(row.avoid == ["flats"] && row.maxPitchDeg == 28 && row.heightCM == 170 && row.weightKG == nil)
}

@Test func gearAnOlderBuildSavedAsASnowboardLoadsAsSkisAndSavesBack() async throws {
    let row = try JSONDecoder().decode(Profile.self, from: Data("""
    {"id": "0a6f4f0c-3d4b-4c58-8a4b-2f1f0b9f7a01", "display_name": "A",
     "equipment": {"discipline": "snowboard", "type": "freeride", "length_cm": 156}}
    """.utf8))
    #expect(row.equipment == ProfileEquipment(discipline: "ski", type: "freeride"))
    #expect(row.equipment?.isValid == true)
    let backend = FakeBackend()
    let client = backend.client(signedInAs: await backend.addUser())
    let saved = try await client.profileUpdate(ProfilePatch().equipment(row.equipment))
    #expect(saved.equipment == ProfileEquipment(discipline: "ski", type: "freeride"))
}

@Test func theChosenSkiAndSkinAreSavedAndAFriendSeesThem() async throws {
    let backend = FakeBackend()
    let alice = await backend.addUser(displayName: "Alice")
    let bob = await backend.addUser(displayName: "Bob")
    await backend.makeFriends(alice, bob)
    let gear = ProfileEquipment(
        discipline: "ski", type: "freeride", lengthCM: 180, waistMM: 110, ski: "atomic-bent-110", skin: "stripes"
    )
    _ = try await backend.client(signedInAs: alice).profileUpdate(ProfilePatch().equipment(gear))
    let seenByFriend = try #require(try await backend.client(signedInAs: bob).profile(id: alice))
    #expect(seenByFriend.equipment == gear)
}

/// The email hash is the server's, from the confirmed auth email (0022): a
/// contact match comes from signing up, never from a hash the client sends.
@Test func aContactMatchesByItsConfirmedEmail() async throws {
    let backend = FakeBackend()
    await backend.setEmailConfirmationRequired(false)
    _ = try await backend.client().signUp(email: " Alice@Example.com ", password: "correct horse")
    let bob = await backend.addUser(displayName: "Bob")
    let hash = SHA256.hex(Data("alice@example.com".utf8))
    let matches = try await backend.client(signedInAs: bob).findUsers(emailHashes: [hash], phoneHashes: [])
    #expect(matches.count == 1)
}
