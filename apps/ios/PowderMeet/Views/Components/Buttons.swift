import SwiftUI

// The app's buttons, and the only ones (`specs/13-APP-MAP.md` section 4):
// primary (accent fill), secondary (glass, or a well on a card), destructive
// (the secondary with red text) and a 44 pt round icon button. Sheets have no
// Done (`13-APP-MAP.md` section 5).

/// The screen's one main action: an accent capsule with a white label, 52 pt.
struct PrimaryButton: View {
    let title: String
    var systemImage: String?
    /// The same symbol again after the title, for the one button that wears
    /// it on both sides (the send button's bolts).
    var mirrorsImage = false
    /// An asset drawn in place of the title's letters (the send button's
    /// wordmark). The title is still the button's spoken name.
    var titleImage: String?
    var isLoading = false
    var isEnabled = true
    /// The fill. The accent, or a status colour for a confirming action.
    var tint: Color = HUDTheme.accent
    /// The label on the fill: white on the accent, the background on a status colour.
    var onTint: Color = HUDTheme.onAccent
    /// Full width (a screen's action) or hugging its label (Go to on a card).
    var fillsWidth = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if isLoading {
                    ProgressView()
                        .tint(onTint)
                        .controlSize(.small)
                        .accessibilityHidden(true)
                } else if let systemImage {
                    Image(systemName: systemImage)
                        .font(.body.weight(.semibold))
                }
                if let titleImage, !isLoading {
                    Image(titleImage)
                        .resizable()
                        .scaledToFit()
                        .frame(height: 20)
                        .accessibilityHidden(true)
                } else {
                    Text(title)
                        .textRole(.bodyEmph)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                if mirrorsImage, !isLoading, let systemImage {
                    Image(systemName: systemImage)
                        .font(.body.weight(.semibold))
                        .accessibilityHidden(true)
                }
            }
            .fixedSize(horizontal: !fillsWidth, vertical: false)
            .foregroundStyle(onTint)
            .padding(.horizontal, fillsWidth ? 20 : 16)
            .frame(
                maxWidth: fillsWidth ? .infinity : nil,
                minHeight: fillsWidth ? GlassLayout.barHeight : GlassLayout.chipHeight)
            .background(tint, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled || isLoading)
        .opacity(isEnabled ? 1 : 0.5)
        .accessibilityLabel(title)
        .accessibilityValue(isLoading ? "In progress" : "")
    }
}

/// Every other action: a glass capsule 44 pt tall. On a glass card it draws as
/// a well instead, since glass does not sit on glass. `destructive` turns the
/// label red.
struct SecondaryButton: View {
    @Environment(\.isOnGlass) private var isOnGlass

    let title: String
    var systemImage: String?
    var destructive = false
    var isLoading = false
    var isEnabled = true
    /// Stretch to the row's width (paired buttons), or hug the label.
    var fillsWidth = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if isLoading {
                    ProgressView().controlSize(.small).accessibilityHidden(true)
                } else if let systemImage {
                    Image(systemName: systemImage)
                        .font(.subheadline.weight(.semibold))
                }
                Text(title)
                    .textRole(.bodyEmph)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .foregroundStyle(destructive ? HUDTheme.accentRed : HUDTheme.primaryText)
            .padding(.horizontal, 16)
            .frame(maxWidth: fillsWidth ? .infinity : nil, minHeight: GlassLayout.chipHeight)
            .modifier(SecondarySurface(isOnGlass: isOnGlass))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled || isLoading)
        .opacity(isEnabled ? 1 : 0.5)
    }
}

private struct SecondarySurface: ViewModifier {
    let isOnGlass: Bool

    func body(content: Content) -> some View {
        if isOnGlass {
            content.background(HUDGlass.well, in: Capsule())
        } else {
            content.glassEffect(HUDGlass.control, in: Capsule())
        }
    }
}

/// A round 44 pt control holding one symbol: close, show on map, a camera
/// action. Glass over the map, a well on a card.
struct IconButton: View {
    @Environment(\.isOnGlass) private var isOnGlass

    let systemImage: String
    let label: String
    var tint: Color = HUDTheme.primaryText
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.body.weight(.semibold))
                .foregroundStyle(tint)
                .frame(width: GlassLayout.iconButton, height: GlassLayout.iconButton)
                .modifier(IconSurface(isOnGlass: isOnGlass))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

private struct IconSurface: ViewModifier {
    let isOnGlass: Bool

    func body(content: Content) -> some View {
        if isOnGlass {
            content.background(HUDGlass.well, in: Circle())
        } else {
            content.glassEffect(HUDGlass.control, in: Circle())
        }
    }
}

/// The close control of a card on the map: the icon button with ×.
struct CloseButton: View {
    var label = "Close"
    let action: () -> Void

    var body: some View {
        IconButton(systemImage: "xmark", label: label, tint: HUDTheme.secondaryText, action: action)
    }
}


/// A large glass control that answers a press by settling a little (the Gear
/// skis): the glass's own response, plus a scale the eye can follow.
struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
