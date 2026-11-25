import SwiftUI
import UIKit

// The labelled fields of the auth screens: a caption over a 44 pt input on the input background.

/// A caption over a plain text field.
struct AuthTextField: View {
    let label: String
    @Binding var text: String
    var placeholder: String
    var contentType: UITextContentType? = nil
    var keyboard: UIKeyboardType = .default
    var capitalization: TextInputAutocapitalization = .never

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .textRole(.caption)
                .foregroundColor(HUDTheme.secondaryText)

            TextField("", text: $text, prompt: Text(placeholder).foregroundColor(HUDTheme.secondaryText))
                .textRole(.bodyEmph)
                .foregroundColor(HUDTheme.primaryText)
                .textInputAutocapitalization(capitalization)
                .autocorrectionDisabled()
                .keyboardType(keyboard)
                .textContentType(contentType)
                // The caption above is its own element; the field carries the name too.
                .accessibilityLabel(label)
                .padding(.horizontal, 12)
                .frame(minHeight: 44)
                .authFieldBackground()
        }
    }
}

/// A caption (with an optional trailing control) over a secure field with a
/// show/hide eye.
struct AuthSecureField<Accessory: View>: View {
    let label: String
    @Binding var text: String
    var placeholder: String
    /// `.newPassword` on the first field of a new password only, so iOS
    /// offers to save one credential, not two.
    var contentType: UITextContentType?
    @ViewBuilder var accessory: () -> Accessory

    @State private var isVisible = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label)
                    .textRole(.caption)
                    .foregroundColor(HUDTheme.secondaryText)
                Spacer()
                accessory()
            }

            HStack(spacing: 0) {
                HUDSecureField(
                    text: $text,
                    placeholder: placeholder,
                    textColor: HUDTheme.primaryText,
                    placeholderColor: HUDTheme.secondaryText,
                    tintColor: HUDTheme.accent,
                    isSecure: !isVisible,
                    contentType: contentType
                )
                .accessibilityLabel(label)
                .padding(.leading, 12)
                .frame(maxWidth: .infinity)

                Button {
                    isVisible.toggle()
                } label: {
                    Image(systemName: isVisible ? "eye.slash.fill" : "eye.fill")
                        .font(.footnote.weight(.semibold))
                        .foregroundColor(HUDTheme.secondaryText.opacity(0.7))
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isVisible ? "Hide password" : "Show password")
            }
            .frame(minHeight: 44)
            .authFieldBackground()
        }
    }
}

extension AuthSecureField where Accessory == EmptyView {
    init(label: String, text: Binding<String>, placeholder: String, contentType: UITextContentType?) {
        self.init(label: label, text: text, placeholder: placeholder, contentType: contentType) { EmptyView() }
    }
}

/// A one-line message under a form: failures in the danger colour, notes in green.
struct AuthMessage: View {
    let text: String
    var isError = true

    var body: some View {
        Text(text)
            .textRole(.label)
            .foregroundColor(isError ? HUDTheme.accentRed : HUDTheme.accentGreen)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity)
    }
}

/// True for something shaped like an email address; the server decides.
nonisolated func looksLikeEmail(_ text: String) -> Bool {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let at = trimmed.firstIndex(of: "@") else { return false }
    return at != trimmed.startIndex && trimmed[at...].contains(".") && !trimmed.contains(" ")
}

private extension View {
    func authFieldBackground() -> some View {
        glassField()
    }
}

/// A sheet over sign-in: the app's one sheet chrome (grabber, small title,
/// the theme's glass), without the map-only messages of `MapSheetPresentation`.
struct AuthSheet: ViewModifier {
    func body(content: Content) -> some View {
        content
            .tint(HUDTheme.accent)
            .preferredColorScheme(.dark)
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
            .presentationBackground { SheetBackdrop() }
    }
}
