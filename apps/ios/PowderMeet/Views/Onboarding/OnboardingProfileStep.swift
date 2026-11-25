import PowderMeetAPI
import SwiftUI

/// First step: display name, asked here for every account rather than at
/// sign-up, pre-filled with the name Apple gave when there is one.
/// Names are unique ignoring case, 2 to 24 characters, and checked as typed.
struct OnboardingProfileStep: View {
    @Binding var displayName: String
    let check: NameCheck

    @FocusState private var nameFieldFocused: Bool

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 18) {
                Spacer().frame(height: 12)

                Text("Your profile")
                    .textRole(.title)
                    .foregroundColor(HUDTheme.primaryText)

                VStack(alignment: .leading, spacing: 6) {
                    Text("Display name")
                        .textRole(.caption)
                        .foregroundColor(HUDTheme.secondaryText)

                    TextField(
                        "",
                        text: $displayName,
                        prompt: Text("First Last")
                            .foregroundColor(HUDTheme.secondaryText)
                    )
                    .textRole(.metric)
                    .foregroundColor(HUDTheme.primaryText)
                    .textInputAutocapitalization(.words)
                    .autocorrectionDisabled()
                    .textContentType(.name)
                    .accessibilityLabel("Display name")
                    .focused($nameFieldFocused)
                    .submitLabel(.done)
                    .onSubmit { nameFieldFocused = false }
                    .padding(.horizontal, 12)
                    .frame(height: 44)
                    .glassField()

                    status
                        .frame(minHeight: 16, alignment: .leading)
                }
                .padding(.horizontal, 20)

                Spacer(minLength: 8)
            }
        }
        .scrollDismissesKeyboard(.interactively)
    }

    private var isRefused: Bool {
        check == .taken || check == .notAllowed
    }

    @ViewBuilder private var status: some View {
        switch check {
        case .checking:
            HStack(spacing: 6) {
                ProgressView().scaleEffect(0.5).frame(width: 12, height: 12)
                Text("Checking")
                    .textRole(.caption)
                    .foregroundColor(HUDTheme.secondaryText)
            }
        case .available:
            Label("Available", systemImage: "checkmark.circle.fill")
                .textRole(.caption)
                .foregroundColor(HUDTheme.accentGreen)
        case .unknown:
            Text("Couldn't check this name now. It's checked again when you finish.")
                .textRole(.caption)
                .foregroundColor(HUDTheme.secondaryText)
        case .empty:
            Text("\(DisplayName.minLength) to \(DisplayName.maxLength) characters, unique to you.")
                .textRole(.caption)
                .foregroundColor(HUDTheme.secondaryText)
        case .tooShort, .tooLong, .taken, .notAllowed:
            Text(check.message ?? "")
                .textRole(.caption)
                .foregroundColor(isRefused ? HUDTheme.accentRed : HUDTheme.accentAmber)
        }
    }
}
