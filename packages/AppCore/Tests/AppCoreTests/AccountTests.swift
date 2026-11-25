import Foundation
import PowderMeetAPI
import Testing
@testable import AppCore

// Email accounts end to end against the fake server: confirmation required,
// a refused name sends onboarding back, and a reset link lands signed in with
// the new-password step owed.

private func link(_ code: String?, recovery: Bool = false) throws -> URL {
    let code = try #require(code)
    let base = recovery ? AuthLink.recoveryRedirect : AuthLink.confirmRedirect
    return try #require(URL(string: base.absoluteString + (recovery ? "&" : "?") + "code=\(code)"))
}

@Test func signUpWaitsForTheEmailLinkThenOnboardsWithAFreeName() async throws {
    let world = try await World()
    await world.backend.addUser(displayName: "Alice")
    let phone = Phone("new", user: UUID(), world: world, signedIn: false)
    try #require(await eventually { await phone.app.state == .signedOut(.noSession) })

    #expect(try await phone.app.signUp(email: " New@Example.com ", password: "powder123") == .confirmationSent)
    await #expect(throws: PowderMeetError.auth(.emailNotConfirmed)) {
        try await phone.app.signIn(email: "new@example.com", password: "powder123")
    }
    await #expect(throws: PowderMeetError.auth(.emailInUse)) {
        _ = try await phone.app.signUp(email: "new@example.com", password: "powder123")
    }

    let code = await world.backend.lastEmailedCode["new@example.com"]
    #expect(try await phone.app.openAuthLink(try link(code)) == false)
    try #require(await eventually { await phone.app.state == .needsOnboarding })
    #expect(await phone.app.account?.email == "new@example.com")
    #expect(await phone.app.account?.provider == .email)

    // The placeholder is never kept: onboarding must save a real name.
    #expect(try await phone.app.displayNameAvailable("alice") == .taken)
    await #expect(throws: PowderMeetError.profile(.nameTaken)) {
        try await phone.app.completeOnboarding(
            ProfilePatch().displayName("ALICE").baselineSpeeds(["blue": 5])
        )
    }
    #expect(await phone.app.state == .needsOnboarding)
    try await phone.app.completeOnboarding(ProfilePatch().displayName("  New  Skier ").baselineSpeeds(["blue": 5]))
    try #require(await eventually {
        if case .ready(let profile) = await phone.app.state { return profile.displayName == "New Skier" }
        return false
    })

    // A used link does not work twice.
    await #expect(throws: PowderMeetError.auth(.linkExpired)) {
        _ = try await phone.app.openAuthLink(try link(code))
    }
    await phone.kill()
    world.cleanUp()
}

@Test func aResetLinkSignsInAndAsksForANewPassword() async throws {
    let world = try await World()
    let first = Phone("first", user: UUID(), world: world, signedIn: false)
    _ = try await first.app.signUp(email: "pat@example.com", password: "powder123")
    _ = try await first.app.openAuthLink(try link(await world.backend.lastEmailedCode["pat@example.com"]))
    try #require(await eventually { await first.app.state == .needsOnboarding })
    await first.kill()

    let phone = Phone("pat", user: UUID(), world: world, signedIn: false)
    await #expect(throws: PowderMeetError.auth(.wrongPassword)) {
        try await phone.app.signIn(email: "pat@example.com", password: "forgotten")
    }
    try await phone.app.sendPasswordReset(email: "pat@example.com")
    try await phone.app.sendPasswordReset(email: "nobody@example.com") // no error: the server does not say
    let code = await world.backend.lastEmailedCode["pat@example.com"]
    #expect(try await phone.app.openAuthLink(try link(code, recovery: true)) == true)
    try #require(await eventually { await phone.app.state == .needsOnboarding })

    await #expect(throws: PowderMeetError.auth(.weakPassword)) {
        try await phone.app.updatePassword("short")
    }
    try await phone.app.updatePassword("new-powder-1")
    phone.app.send(.signOutRequested)
    try #require(await eventually { await phone.app.state == .signedOut(.userRequested) })
    try await phone.app.signIn(email: "pat@example.com", password: "new-powder-1")
    try #require(await eventually { await phone.app.state == .needsOnboarding })

    await phone.kill()
    world.cleanUp()
}
