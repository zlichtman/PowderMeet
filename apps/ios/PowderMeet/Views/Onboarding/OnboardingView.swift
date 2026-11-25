import AppCore
import MeetSolver
import SwiftUI

/// Six-step onboarding: name, photo, gear and limits, location, notifications,
/// contacts. The photo is optional; Location and Contacts offer "Not now";
/// nothing else is skipped.
struct OnboardingView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private enum Step: Int, CaseIterable {
        case name, photo, gear, location, notifications, contacts

        static let last = Step.contacts
    }

    @State private var step = Step(rawValue: DebugLaunch.onboardingStep) ?? .name
    @State private var displayName = ""
    @State private var skillLevel = SkillTier.defaultTier.key
    @State private var gear = GearDraft(ability: Ability(profileValue: SkillTier.defaultTier.key))

    private let totalSteps = Step.allCases.count

    init() {}

    var body: some View {
        ZStack {

            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    ForEach(0..<totalSteps, id: \.self) { i in
                        Capsule()
                            .fill(i <= step.rawValue ? HUDTheme.accent : HUDTheme.secondaryText.opacity(0.4))
                            .frame(width: i == step.rawValue ? 24 : 8, height: 4)
                            .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: step)
                    }
                }
                .accessibilityElement()
                .accessibilityLabel("Step \(step.rawValue + 1) of \(totalSteps)")
                // A line of its own under the safe area; the card starts under it.
                .frame(height: 44)

                ZStack {
                    switch step {
                    case .name:
                        OnboardingProfileStep(displayName: $displayName, check: model.account.nameCheck)
                            .transition(stepTransition)
                    case .photo:
                        OnboardingPhotoStep()
                            .transition(stepTransition)
                    case .gear:
                        OnboardingGearStep(skillLevel: $skillLevel, draft: $gear)
                            .transition(stepTransition)
                    case .location:
                        OnboardingLocationStep()
                            .transition(stepTransition)
                    case .notifications:
                        OnboardingNotificationsStep()
                            .transition(stepTransition)
                    case .contacts:
                        OnboardingContactsStep()
                            .transition(stepTransition)
                    }
                }
                // Every step fills the card, whatever its content's own width.
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                // Each step is one glass card over the backdrop.
                .glassCard(padding: 0)
                .clipShape(RoundedRectangle(cornerRadius: GlassLayout.cardRadius, style: .continuous))
                .padding(.horizontal, GlassLayout.pageInset)
                .padding(.bottom, 12)
                .animation(.easeInOut(duration: 0.25), value: step)
                // The limit starts at the ability's default and follows it until
                // the skier picks one themselves.
                .onChange(of: skillLevel) { old, new in
                    gear.maxDifficulty = gear.hardestRun(
                        movingFrom: Ability(profileValue: old), to: Ability(profileValue: new)
                    )
                }

                // On success the root swaps screens (the last step) or the
                // next step shows (the name step). A refused name goes back
                // to the name step; any other failure is said here, with the
                // button live again.
                if let failure = model.account.onboardingFailure, step == .name || step == .last {
                    AuthMessage(text: failure.userMessage)
                        .padding(.horizontal, 28)
                        .padding(.bottom, 10)
                }

                // One action per step. A permission step's button asks for
                // the permission (the system prompt comes from this tap, after
                // the card has said why); once iOS has an answer it moves on.
                PrimaryButton(
                    title: action.title,
                    systemImage: action.symbol,
                    isLoading: (step == .name || step == .last) && model.account.isFinishingOnboarding,
                    isEnabled: continueEnabled
                ) {
                    perform(action)
                }
                .padding(.horizontal, 28)
                .padding(.bottom, asksPermission ? 4 : 20)

                // On the last step, Not now finishes.
                if asksPermission {
                    Button("Not now") {
                        if let next = Step(rawValue: step.rawValue + 1) { step = next } else { perform(.finish) }
                    }
                        .textRole(.bodyEmph)
                        .foregroundStyle(HUDTheme.secondaryText)
                        .frame(minHeight: GlassLayout.chipHeight)
                        .padding(.bottom, 12)
                }
            }
        }
        // The name Apple gave at first sign-in, never the server's placeholder.
        .onAppear {
            // Skis, the PowderMeet ski, until they pick another.
            if gear.discipline == nil { gear.select(.ski) }
            if displayName.isEmpty, let suggested = model.account.suggestedName {
                displayName = suggested
            }
            model.checkDisplayName(displayName)
        }
        .onChange(of: displayName) { _, name in
            model.account.onboardingFailure = nil
            model.checkDisplayName(name)
        }
        .onChange(of: model.account.onboardingFailure) { _, failure in
            if case .profile = failure { step = .name }
        }
    }

    private var stepTransition: AnyTransition {
        reduceMotion ? .opacity : .asymmetric(insertion: .move(edge: .trailing), removal: .move(edge: .leading))
    }

    private enum Action {
        case saveName, next, finish, findFriends, allowLocation, allowNotifications

        var title: String {
            switch self {
            case .saveName, .next: "Continue"
            case .finish: "Get started"
            case .findFriends: "Find Friends in Contacts"
            case .allowLocation: "Allow location"
            case .allowNotifications: "Turn on notifications"
            }
        }

        var symbol: String? {
            switch self {
            case .saveName, .next, .finish: nil
            case .findFriends: "person.2.fill"
            case .allowLocation: "location.fill"
            case .allowNotifications: "bell.fill"
            }
        }
    }

    private var action: Action {
        switch step {
        case .name: .saveName
        case .location where model.locationPermission == .notDetermined: .allowLocation
        case .notifications where model.notificationPermission == .notDetermined: .allowNotifications
        case .contacts where !model.discovery.hasSearched && !model.discovery.isSearching
            && model.discovery.access != .denied: .findFriends
        case .last: .finish
        default: .next
        }
    }

    /// The step is still waiting for a permission the user may decline.
    private var asksPermission: Bool {
        action == .allowLocation || action == .findFriends
    }

    private func perform(_ action: Action) {
        switch action {
        case .saveName: model.saveOnboardingName(displayName) { step = .photo }
        case .next: if let next = Step(rawValue: step.rawValue + 1) { step = next }
        case .findFriends: model.findFriendsFromContacts()
        case .allowLocation: model.requestLocationPermission()
        case .allowNotifications: model.requestNotificationPermission()
        case .finish:
            model.finishOnboarding(
                displayName: displayName, ability: Ability(profileValue: skillLevel), gear: gear
            )
        }
    }

    private var continueEnabled: Bool {
        switch step {
        case .name:
            return model.account.nameCheck.canContinue && !model.account.isFinishingOnboarding
        case .last:
            // A lookup in progress keeps going after onboarding; one that is
            // waiting out the server's rate limit should not hold the user.
            return !model.account.isFinishingOnboarding
        default:
            return true
        }
    }
}

/// A step's content fills the card, so its spacers still place it, and
/// scrolls once it outgrows the card (large text, the smallest iPhone).
private struct OnboardingStepScroll: ViewModifier {
    func body(content: Content) -> some View {
        GeometryReader { proxy in
            ScrollView(showsIndicators: false) {
                content.frame(maxWidth: .infinity, minHeight: proxy.size.height)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
    }
}

extension View {
    func onboardingStepScroll() -> some View { modifier(OnboardingStepScroll()) }
}
