import SwiftUI

/// Second step, after the name is saved: a profile photo, the same choose,
/// crop and upload as Account's. Optional: Continue goes on with or without
/// one, and never waits for an upload. A failed upload says why in the app's
/// message row and leaves the initials, so the skier can try again or go on.
struct OnboardingPhotoStep: View {
    @Environment(AppModel.self) private var model

    private var hasPhoto: Bool { model.photoOwner?.avatarURL != nil }

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Text("Your photo")
                .textRole(.title)
                .foregroundColor(HUDTheme.primaryText)

            ProfilePhotoButton(size: 120)

            Text(hasPhoto
                 ? "Friends see it on the map and when you meet up. Tap it to change it."
                 : "Friends see it on the map and when you meet up. It's optional: you can add one later in Account.")
                .textRole(.body)
                .foregroundStyle(HUDTheme.secondaryText)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 28)

            Spacer()
            Spacer()
        }
        .onboardingStepScroll()
    }
}
