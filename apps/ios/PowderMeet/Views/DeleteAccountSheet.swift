import SwiftUI

/// Settings → Account → Delete account: what is deleted, typed DELETE to
/// confirm, then the red action. Glass bubbles in the floating panel.
struct DeleteAccountSheet: View {
    @Environment(AppModel.self) private var model

    @State private var typed = ""

    init() {}

    private var canDelete: Bool {
        typed.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() == "DELETE"
    }

    var body: some View {
        Group {
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.largeTitle)
                    .foregroundStyle(HUDTheme.accentRed)
                    .accessibilityHidden(true)
                Text("Your account, profile, friends and history are deleted for good.")
                    .textRole(.bodyEmph)
                    .foregroundStyle(HUDTheme.primaryText)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity)
            .glassCard()

            GlassSection("Type DELETE") {
                TextField("", text: $typed,
                          prompt: Text("DELETE").foregroundStyle(HUDTheme.secondaryText))
                    .textRole(.metric)
                    .foregroundStyle(HUDTheme.primaryText)
                    .multilineTextAlignment(.center)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .padding(.horizontal, 12)
                    .frame(height: 44)
                    .glassField()
                    .padding(GlassLayout.cardPadding)
            }

            // The intent reports nothing back: success signs out (which
            // removes this page) and a failure posts a toast, so it closes now.
            PrimaryButton(title: "Delete forever", isEnabled: canDelete, tint: HUDTheme.accentRed) {
                model.deleteAccount()
                model.leavePanelPage(.deleteAccount)
            }
        }
        .pageScroll(spacing: GlassLayout.gap)
    }
}
