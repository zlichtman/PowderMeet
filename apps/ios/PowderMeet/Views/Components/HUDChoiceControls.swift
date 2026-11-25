import SwiftUI

/// A row of equal capsules, one selected in the accent: units, the backend
/// switch, skis or board, a ski's type, the hardest run.
struct HUDChoicePills<Value: Hashable>: View {
    struct Choice: Identifiable {
        let value: Value
        let label: String
        var isEnabled = true
        var id: Value { value }
    }

    let choices: [Choice]
    let selection: Value?
    let onSelect: (Value) -> Void

    var body: some View {
        HStack(spacing: 4) {
            ForEach(choices) { choice in
                let isSelected = choice.value == selection
                Button { onSelect(choice.value) } label: {
                    Text(choice.label)
                        .textRole(.label)
                        .fontWeight(isSelected ? .semibold : .regular)
                        .foregroundStyle(isSelected ? HUDTheme.onAccent : HUDTheme.primaryText)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .padding(.horizontal, 4)
                        .frame(maxWidth: .infinity, minHeight: GlassLayout.chipHeight)
                        .background(isSelected ? HUDTheme.accent : Color.clear, in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(!choice.isEnabled)
                .opacity(choice.isEnabled ? 1 : 0.35)
                .accessibilityLabel(choice.label)
                .accessibilityAddTraits(isSelected ? [.isSelected] : [])
            }
        }
        .padding(4)
        .hudCard(cornerRadius: GlassLayout.cardRadius)
    }
}

/// A labelled value with minus and plus, and a clear button once it is set.
/// Holding a button repeats.
struct HUDStepperRow: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let label: String
    var caption: String?
    /// In its own well (onboarding), or a plain row of a section's card.
    var boxed = true
    /// nil shows "Not set".
    let value: String?
    let onStep: (Int) -> Void
    let onClear: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // At accessibility sizes the controls take a line under the label,
            // so neither has to shrink.
            if dynamicTypeSize.isAccessibilitySize {
                Text(label)
                    .textRole(.body)
                    .foregroundStyle(HUDTheme.primaryText)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Spacer(minLength: 0)
                    controls
                }
            } else {
                HStack(spacing: 8) {
                    Text(label)
                        .textRole(.body)
                        .foregroundStyle(HUDTheme.primaryText)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Spacer(minLength: 4)
                    controls
                }
            }
            if let caption {
                Text(caption)
                    .textRole(.caption)
                    .foregroundStyle(HUDTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.trailing, 8)
                    .padding(.bottom, 4)
            }
        }
        .padding(.leading, boxed ? 14 : GlassLayout.cardPadding)
        .padding(.trailing, boxed ? 6 : 10)
        .padding(.vertical, 6)
        .frame(minHeight: boxed ? nil : GlassLayout.rowHeight)
        .modifier(StepperBox(boxed: boxed))
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var controls: some View {
            if value != nil {
                Button(action: onClear) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(HUDTheme.secondaryText)
                        .frame(width: GlassLayout.iconButton, height: GlassLayout.iconButton)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear \(label.lowercased())")
            }
            stepButton("minus", step: -1)
            Text(value ?? "Not set")
                .textRole(value == nil ? .label : .metric)
                .foregroundStyle(value == nil ? HUDTheme.secondaryText : HUDTheme.primaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(minWidth: 76)
            stepButton("plus", step: 1)
    }

    private func stepButton(_ symbol: String, step: Int) -> some View {
        Button { onStep(step) } label: {
            Image(systemName: symbol)
                .font(.body.weight(.semibold))
                .foregroundStyle(HUDTheme.accent)
                .frame(width: GlassLayout.iconButton, height: GlassLayout.iconButton)
                .background(HUDTheme.accent.opacity(0.14), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .buttonRepeatBehavior(.enabled)
        .accessibilityLabel(step < 0 ? "Decrease \(label.lowercased())" : "Increase \(label.lowercased())")
    }
}

/// A two-line choice that is on or off: the "never route me on" choices.
struct HUDToggleChip: View {
    let label: String
    let detail: String
    let isOn: Bool
    let onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 8) {
                Image(systemName: isOn ? "nosign" : "circle")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(isOn ? HUDTheme.accentRed : HUDTheme.secondaryText)
                VStack(alignment: .leading, spacing: 1) {
                    Text(label)
                        .textRole(.label).fontWeight(.semibold)
                        .foregroundStyle(HUDTheme.primaryText)
                    Text(detail)
                        .textRole(.caption)
                        .foregroundStyle(HUDTheme.secondaryText)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: 48)
            .hudCard()
            .overlay {
                if isOn {
                    RoundedRectangle(cornerRadius: GlassLayout.innerRadius, style: .continuous)
                        .strokeBorder(HUDTheme.accentRed.opacity(0.7), lineWidth: 1.5)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Avoid \(label.lowercased())")
        .accessibilityValue(isOn ? "On" : "Off")
    }
}

extension View {
    /// The box a control or a value sits in: a well inside a glass card
    /// (`isOnGlass`), the theme's glass on its own, so the same control reads
    /// right in onboarding and on a page.
    func hudCard(cornerRadius: CGFloat = GlassLayout.innerRadius) -> some View {
        modifier(HUDBoxModifier(cornerRadius: cornerRadius))
    }
}

private struct HUDBoxModifier: ViewModifier {
    @Environment(\.isOnGlass) private var isOnGlass
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if isOnGlass {
            content.background(HUDGlass.well, in: shape)
        } else {
            content.glassEffect(HUDGlass.surface, in: shape)
        }
    }
}

private struct StepperBox: ViewModifier {
    let boxed: Bool

    func body(content: Content) -> some View {
        if boxed { content.hudCard() } else { content }
    }
}
