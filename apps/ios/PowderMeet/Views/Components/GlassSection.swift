import SwiftUI

/// The one section header: a short label above a card. Over the map it is a
/// small glass bubble of its own, so it reads on any terrain; inside a card,
/// plain text in the secondary tier. `accent` tints it where the header
/// carries meaning (requests waiting).
struct SectionHeader: View {
    @Environment(\.isOnGlass) private var isOnGlass
    let label: String
    var accent: Color?

    init(_ label: String, accent: Color? = nil) {
        self.label = label
        self.accent = accent
    }

    var body: some View {
        Group {
            if isOnGlass {
                text.foregroundStyle(accent ?? HUDTheme.secondaryText)
            } else {
                text
                    .foregroundStyle(accent ?? HUDTheme.primaryText)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .glassEffect(HUDGlass.surface, in: Capsule())
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityAddTraits(.isHeader)
    }

    private var text: some View {
        Text(label)
            .textRole(.label)
            .fontWeight(.semibold)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
    }
}

/// One section of a page: the header over one glass card holding the
/// section's rows, split by hairlines (`GlassDivider`), and an optional line
/// of small print under it.
struct GlassSection<Content: View>: View {
    let title: String?
    var footnote: String?
    var accent: Color?
    let content: Content

    init(
        _ title: String? = nil, footnote: String? = nil, accent: Color? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.footnote = footnote
        self.accent = accent
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: GlassLayout.gap) {
            if let title { SectionHeader(title, accent: accent) }
            VStack(alignment: .leading, spacing: 0) { content }
                .frame(maxWidth: .infinity, alignment: .leading)
                .glassCard(padding: 0)
            if let footnote {
                // Over the map, small print has its own glass to read on.
                GlassFootnote(text: footnote)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .glassEffect(HUDGlass.surface, in: RoundedRectangle(cornerRadius: GlassLayout.innerRadius, style: .continuous))
            }
        }
    }
}

/// One row: an accent glyph, the title, an optional one-line detail in the
/// secondary tier, then whatever sits at the trailing edge (a chevron, a
/// switch, a value). 56 pt at least, 16 pt from the card's edges.
struct GlassRow<Trailing: View>: View {
    let icon: String?
    let title: String
    var detail: String?
    /// A destructive row's title and glyph.
    var titleTint: Color?
    var iconTint: Color?
    let trailing: Trailing

    init(
        icon: String?, title: String, detail: String? = nil, titleTint: Color? = nil,
        iconTint: Color? = nil, @ViewBuilder trailing: () -> Trailing
    ) {
        self.icon = icon
        self.title = title
        self.detail = detail
        self.titleTint = titleTint
        self.iconTint = iconTint
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: 12) {
            if let icon {
                Image(systemName: icon)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(iconTint ?? titleTint ?? HUDTheme.accent)
                    .frame(width: 26)
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .textRole(.body)
                    .foregroundStyle(titleTint ?? HUDTheme.primaryText)
                    .lineLimit(2)
                if let detail, !detail.isEmpty {
                    Text(detail)
                        .textRole(.label)
                        .foregroundStyle(HUDTheme.secondaryText)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            trailing
        }
        .padding(.horizontal, GlassLayout.cardPadding)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, minHeight: GlassLayout.rowHeight, alignment: .leading)
        .contentShape(Rectangle())
    }
}

extension GlassRow where Trailing == EmptyView {
    init(icon: String?, title: String, detail: String? = nil, titleTint: Color? = nil, iconTint: Color? = nil) {
        self.init(icon: icon, title: title, detail: detail, titleTint: titleTint, iconTint: iconTint) {
            EmptyView()
        }
    }
}

/// A row's trailing value in the secondary tier.
struct GlassValue: View {
    let text: String

    var body: some View {
        Text(text)
            .textRole(.body)
            .foregroundStyle(HUDTheme.secondaryText)
            .monospacedDigit()
            .lineLimit(1)
    }
}

/// The trailing chevron of a row that opens something.
struct GlassChevron: View {
    var body: some View {
        Image(systemName: "chevron.right")
            .font(.footnote.weight(.semibold))
            .foregroundStyle(HUDTheme.secondaryText)
            .accessibilityHidden(true)
    }
}

/// A row that opens something: the row with a chevron, as one button.
struct GlassNavRow: View {
    let icon: String
    let title: String
    var detail: String?
    var titleTint: Color?
    var value: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            GlassRow(icon: icon, title: title, detail: detail, titleTint: titleTint) {
                HStack(spacing: 8) {
                    if let value { GlassValue(text: value) }
                    GlassChevron()
                }
            }
        }
        .buttonStyle(.plain)
    }
}

/// A row that pushes a page of the floating panel: the row with a chevron.
struct GlassLinkRow: View {
    @Environment(AppModel.self) private var model
    let icon: String
    let title: String
    var detail: String?
    var value: String?
    var titleTint: Color?
    let route: PanelRoute

    var body: some View {
        Button { model.pushPanel(route) } label: {
            GlassRow(icon: icon, title: title, detail: detail, titleTint: titleTint) {
                HStack(spacing: 8) {
                    if let value { GlassValue(text: value) }
                    GlassChevron()
                }
            }
        }
        .buttonStyle(.plain)
    }
}

/// A row with a switch, in the accent.
struct GlassToggleRow: View {
    let icon: String?
    let title: String
    var detail: String?
    @Binding var isOn: Bool
    var isEnabled = true

    var body: some View {
        GlassRow(icon: icon, title: title, detail: detail) {
            Toggle(title, isOn: $isOn)
                .labelsHidden()
                .tint(HUDTheme.accent)
                .disabled(!isEnabled)
        }
        .opacity(isEnabled ? 1 : 0.5)
    }
}

/// The rule between two rows of a card, inset to the text.
struct GlassDivider: View {
    var inset: CGFloat = GlassLayout.cardPadding

    var body: some View {
        Rectangle()
            .fill(HUDGlass.hairline)
            .frame(height: 0.5)
            .padding(.leading, inset)
    }
}

/// A line of small print under a section or a control: what a setting does.
struct GlassFootnote: View {
    var icon: String?
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if let icon {
                Image(systemName: icon)
                    .font(.caption.weight(.semibold))
                    .accessibilityHidden(true)
            }
            Text(text)
                .textRole(.label)
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(HUDTheme.secondaryText)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A short status in a capsule: Open, Live, a pass. Text in the status
/// colour on a faint wash of it.
struct StatusChip: View {
    let text: String
    var tint: Color = HUDTheme.secondaryText
    /// A glyph before the words; with empty words the chip is the glyph alone.
    var systemImage: String?

    var body: some View {
        HStack(spacing: 3) {
            if let systemImage {
                Image(systemName: systemImage)
                    .imageScale(.small)
                    .accessibilityHidden(true)
            }
            if !text.isEmpty { Text(text) }
        }
            .textRole(.caption)
            .fontWeight(.semibold)
            .foregroundStyle(tint)
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(tint.opacity(0.16), in: Capsule())
    }
}

/// Nothing to show yet: a glyph, a line and, maybe, an action.
struct EmptyStateView: View {
    let icon: String
    let title: String
    var detail: String?
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.largeTitle)
                .foregroundStyle(HUDTheme.secondaryText)
                .accessibilityHidden(true)
            Text(title)
                .textRole(.bodyEmph)
                .foregroundStyle(HUDTheme.primaryText)
                .multilineTextAlignment(.center)
            if let detail {
                Text(detail)
                    .textRole(.label)
                    .foregroundStyle(HUDTheme.secondaryText)
                    .multilineTextAlignment(.center)
            }
            if let actionTitle, let action {
                SecondaryButton(title: actionTitle, fillsWidth: false, action: action)
                    .padding(.top, 4)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity)
    }
}
