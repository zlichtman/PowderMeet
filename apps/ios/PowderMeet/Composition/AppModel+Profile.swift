import AppCore
import Foundation
import MapScene
import MapboxAdapter
import MeetSolver
import MountainCore
import Observation
import PMLogging
import PowderMeetAPI

extension AppModel {
    // MARK: Profile intents

    /// Saves the onboarding answers. Speeds start from the preset for the ability;
    /// imported runs replace them later. A refusal lands in
    /// `account.onboardingFailure`; a name refusal sends onboarding back to the
    /// name step.
    func finishOnboarding(displayName: String, ability: Ability, gear: GearDraft) {
        saveOnboarding(gear.applied(to: Self.calibration(
            ability, ProfilePatch().displayName(DisplayName.normalize(displayName))
        )))
    }

    /// The name step's Continue: the chosen name is saved before the steps
    /// after it, so a friend request sent from the contacts step goes out
    /// under that name and never the account's placeholder. Onboarding still
    /// ends only with the last step's save; `onSaved` moves on to the next step.
    func saveOnboardingName(_ displayName: String, onSaved: @escaping @MainActor () -> Void) {
        saveOnboarding(ProfilePatch().displayName(DisplayName.normalize(displayName)), onSaved: onSaved)
    }

    private func saveOnboarding(_ patch: ProfilePatch, onSaved: @escaping @MainActor () -> Void = {}) {
        guard !account.isFinishingOnboarding else { return }
        account.isFinishingOnboarding = true
        account.onboardingFailure = nil
        run("onboarding") { [weak self, session] in
            do {
                try await session.completeOnboarding(patch)
                self?.refreshOnboardingProfile()
                onSaved()
            } catch {
                let error = PowderMeetError(error)
                self?.account.onboardingFailure = error
                if case .profile(.nameTaken) = error { self?.account.nameCheck = .taken }
                if case .profile(.nameNotAllowed) = error { self?.account.nameCheck = .notAllowed }
            }
            self?.account.isFinishingOnboarding = false
        }
    }

    func renameProfile(_ displayName: String) {
        session.send(.profileEdited(ProfilePatch().displayName(DisplayName.normalize(displayName))))
    }

    /// A new ability brings its preset speeds, moved by the runs on file. It
    /// sets pace only: the hardest-run limit stays what the skier chose.
    func changeAbility(to ability: Ability) {
        guard profile != nil else { return }
        session.send(.profileEdited(
            Self.calibration(ability, ProfilePatch())
                .baselineSpeeds(PaceCalibration.baselineSpeeds(
                    ability: ability, evidence: activity.history.evidence
                ))
        ))
    }

    /// Equipment, body and limits from Profile → GEAR.
    func saveGear(_ gear: GearDraft) {
        session.send(.profileEdited(gear.applied(to: ProfilePatch())))
    }

    private static func calibration(_ ability: Ability, _ patch: ProfilePatch) -> ProfilePatch {
        let preset = SkierProfile.preset(ability, userID: UUID())
        var speeds: [String: Double] = [:]
        for (difficulty, speed) in preset.baselineSpeedMS { speeds[difficulty.rawValue] = speed }
        // No hardest-run limit here: onboarding sends the one on the gear step.
        return patch
            .ability(ability.rawValue)
            .baselineSpeeds(speeds)
    }
}
