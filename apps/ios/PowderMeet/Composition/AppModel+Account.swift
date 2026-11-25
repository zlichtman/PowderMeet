import AppCore
import Foundation
import PowderMeetAPI

/// What the display-name field says about the name typed so far.
nonisolated enum NameCheck: Sendable, Hashable {
    case empty, tooShort, tooLong, checking, available, taken, notAllowed
    /// The server could not be asked (offline, say). Saving still checks.
    case unknown

    /// True when the name may be sent: the server has the last word on save.
    var canContinue: Bool {
        switch self {
        case .available, .unknown: true
        case .empty, .tooShort, .tooLong, .checking, .taken, .notAllowed: false
        }
    }

    var message: String? {
        switch self {
        case .empty, .checking, .available, .unknown: nil
        case .tooShort, .tooLong: "Names are \(DisplayName.minLength) to \(DisplayName.maxLength) characters"
        case .taken: "That name is taken"
        case .notAllowed: "That name isn't allowed"
        }
    }
}

/// Email accounts, password reset and the display-name check, as the auth,
/// onboarding and account screens show them.
nonisolated struct AccountState: Sendable, Hashable {
    /// The signed-in account: its email and how it signs in.
    var identity: AuthSession?
    /// An email sign-up waiting for its confirmation link.
    var awaitingConfirmation: String?
    /// A sign-in refused because this address is not confirmed yet.
    var unconfirmedEmail: String?
    var isResending = false
    var resentTo: String?
    var isSendingReset = false
    var resetSentTo: String?
    var resetFailure: PowderMeetError?
    /// A reset link signed the user in; a new password is owed.
    var needsNewPassword = false
    /// The reset sheet is on screen. A cover cannot present over it, so a
    /// reset link first closes it and the cover follows (`resetSheetClosed`).
    var isResetSheetOpen = false
    var closeResetSheet = false
    var isSavingPassword = false
    var passwordFailure: PowderMeetError?
    /// The name Apple gave at first sign-in, offered in onboarding.
    var suggestedName: String?
    var nameCheck = NameCheck.empty
    var isFinishingOnboarding = false
    var onboardingFailure: PowderMeetError?
    /// The profile as saved so far while onboarding runs (its name, once the
    /// name step is saved, and its photo): `AppModel.profile` is nil until
    /// onboarding is done.
    var onboardingProfile: Profile?
}

extension AppModel {
    /// Shortest password the app accepts. The project's own setting
    /// (Authentication → Sign In / Providers → Email) should match it.
    static let minimumPasswordLength = 8

    // MARK: Email sign-in and sign-up

    func signIn(email: String, password: String) {
        guard !auth.isSigningIn else { return }
        auth = AuthProgress(isSigningIn: true)
        account.unconfirmedEmail = nil
        run("sign-in") { [weak self, session] in
            do {
                try await session.signIn(email: email, password: password)
            } catch {
                let error = PowderMeetError(error)
                if error == .auth(.emailNotConfirmed) {
                    self?.account.unconfirmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
                }
                self?.auth = AuthProgress(failure: error)
            }
        }
    }

    func signUp(email: String, password: String) {
        guard !auth.isSigningIn else { return }
        auth = AuthProgress(isSigningIn: true)
        run("sign-in") { [weak self, session] in
            do {
                let outcome = try await session.signUp(email: email, password: password)
                if case .confirmationSent = outcome {
                    self?.auth = AuthProgress()
                    self?.account.awaitingConfirmation = email.trimmingCharacters(in: .whitespacesAndNewlines)
                    self?.account.resentTo = nil
                }
            } catch {
                let error = PowderMeetError(error)
                self?.auth = AuthProgress(failure: error)
            }
        }
    }

    /// Back from "check your email" to the empty form.
    func leaveConfirmation() {
        account.awaitingConfirmation = nil
        account.resentTo = nil
        auth = AuthProgress()
    }

    func resendConfirmation(to email: String) {
        guard !account.isResending else { return }
        account.isResending = true
        run("resend") { [weak self, session] in
            do {
                try await session.resendConfirmation(email: email)
                self?.account.resentTo = email
                self?.auth = AuthProgress()
            } catch {
                let error = PowderMeetError(error)
                self?.auth = AuthProgress(failure: error)
            }
            self?.account.isResending = false
        }
    }

    // MARK: Password reset

    func sendPasswordReset(to email: String) {
        guard !account.isSendingReset else { return }
        account.isSendingReset = true
        account.resetFailure = nil
        run("reset") { [weak self, session] in
            do {
                try await session.sendPasswordReset(email: email)
                self?.account.resetSentTo = email.trimmingCharacters(in: .whitespacesAndNewlines)
            } catch {
                let error = PowderMeetError(error)
                self?.account.resetFailure = error
            }
            self?.account.isSendingReset = false
        }
    }

    func clearPasswordReset() {
        account.resetSentTo = nil
        account.resetFailure = nil
    }

    /// The app was opened with `powdermeet://auth-callback…`: a sign-up
    /// confirmation or a password reset link.
    func openAuthLink(_ url: URL) {
        run("auth-link") { [weak self, session] in
            do {
                let recovery = try await session.openAuthLink(url)
                self?.account.awaitingConfirmation = nil
                self?.account.unconfirmedEmail = nil
                if recovery { self?.owePasswordAfterResetSheet() }
            } catch {
                let error = PowderMeetError(error)
                guard let self else { return }
                if case .signedOut = self.state {
                    self.auth = AuthProgress(failure: error)
                } else {
                    await self.deps.toasts.post(error)
                }
            }
        }
    }

    private func owePasswordAfterResetSheet() {
        if account.isResetSheetOpen {
            account.closeResetSheet = true
        } else {
            account.needsNewPassword = true
        }
    }

    func resetSheetOpened() {
        account.isResetSheetOpen = true
    }

    /// The reset sheet has gone; if a reset link closed it, ask for the password now.
    func resetSheetClosed() {
        account.isResetSheetOpen = false
        if account.closeResetSheet {
            account.closeResetSheet = false
            account.needsNewPassword = true
        }
    }

    func saveNewPassword(_ password: String) {
        guard !account.isSavingPassword else { return }
        account.isSavingPassword = true
        account.passwordFailure = nil
        run("new-password") { [weak self, session] in
            do {
                try await session.updatePassword(password)
                self?.account.needsNewPassword = false
            } catch {
                let error = PowderMeetError(error)
                self?.account.passwordFailure = error
            }
            self?.account.isSavingPassword = false
        }
    }

    // MARK: Display name

    /// Checks the name as it is typed: the length rule at once, the server
    /// (taken, not allowed) after a short pause.
    func checkDisplayName(_ raw: String) {
        work["name-check"]?.cancel()
        switch DisplayName.validate(raw) {
        case .failure(let error):
            account.nameCheck = DisplayName.normalize(raw).isEmpty
                ? .empty : (error.problem == .tooShort ? .tooShort : .tooLong)
        case .success(let name):
            account.nameCheck = .checking
            run("name-check") { [weak self, session] in
                do {
                    try await Task.sleep(for: .milliseconds(350))
                } catch {
                    return
                }
                let answer: NameCheck
                do {
                    let availability = try await session.displayNameAvailable(name)
                    answer = switch availability {
                    case .available: .available
                    case .taken: .taken
                    case .notAllowed: .notAllowed
                    case .invalid: .tooShort
                    }
                } catch {
                    answer = .unknown
                }
                if !Task.isCancelled { self?.account.nameCheck = answer }
            }
        }
    }

    // MARK: Account

    /// Follows the signed-in account for the ACCOUNT rows.
    func refreshAccountIdentity() {
        run("account") { [weak self, session] in
            self?.account.identity = await session.account
        }
    }

    /// Reads the profile saved so far while onboarding runs; nothing once it is done.
    func refreshOnboardingProfile() {
        guard state == .needsOnboarding else { return }
        run("onboarding-profile") { [weak self, session] in
            self?.account.onboardingProfile = await session.profileOnFile
        }
    }
}
