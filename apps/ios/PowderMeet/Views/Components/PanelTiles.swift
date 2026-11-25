import SwiftUI

/// One entry of a panel level: a separate glass tile with the
/// icon and title on one line and, where it carries one, a short value under
/// them. The profile panel's four sections, Settings' pages and Appearance's
/// four choices are all these tiles.
struct PanelTile: View {
    let icon: String
    let title: String
    var value: String?
    var titleTint: Color?
    /// Something waiting behind the tile (friend requests), counted at its corner.
    var badge = 0
    /// A narrow tile (three in a row) stacks the icon over the title.
    var compact = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Group {
                if compact {
                    VStack(spacing: 6) {
                        glyph
                        titleText
                        if let value { valueText(value) }
                    }
                    .frame(maxWidth: .infinity)
                } else {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            // Wide symbols (the Map tile's mountains) fit the
                            // same column as the narrow ones, so every title
                            // starts at one edge.
                            // A fixed height too, so a tall symbol (Activity's
                            // skier) does not push its title and value lower
                            // than the tile beside it.
                            glyph.frame(width: glyphWidth, height: glyphHeight)
                            titleText
                        }
                        if let value { valueText(value).padding(.leading, glyphWidth + 8) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(minHeight: compact ? 72 : 44)
            .glassCardControl(padding: 14)
            .overlay(alignment: .topTrailing) {
                CountBadge(count: badge).padding(10)
            }
        }
        .buttonStyle(PressableStyle())
        .accessibilityElement(children: .combine)
        // The badge is a glyph only; the count is said here.
        .accessibilityValue(badge > 0 ? "\(badge) waiting" : "")
        .accessibilityHint("Opens \(title)")
    }

    /// The icon column, as wide as the widest symbol a tile uses.
    @ScaledMetric(relativeTo: .body) private var glyphWidth: CGFloat = 30
    @ScaledMetric(relativeTo: .body) private var glyphHeight: CGFloat = 22

    private var glyph: some View {
        Image(systemName: icon)
            .font(.body.weight(.semibold))
            .foregroundStyle(titleTint ?? HUDTheme.accent)
    }

    private var titleText: some View {
        Text(title)
            .textRole(.bodyEmph)
            .foregroundStyle(titleTint ?? HUDTheme.primaryText)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
    }

    /// The whole value when it fits; otherwise its first part ("Atomic Bent
    /// 110" of "Atomic Bent 110 · 184 cm") rather than a word cut off.
    private func valueText(_ value: String) -> some View {
        let head = value.components(separatedBy: " · ").first ?? value
        return ViewThatFits(in: .horizontal) {
            valueLine(value)
            valueLine(head).minimumScaleFactor(0.8)
        }
        .accessibilityLabel(value)
    }

    private func valueLine(_ text: String) -> some View {
        Text(text)
            .textRole(.label)
            .foregroundStyle(HUDTheme.secondaryText)
            .lineLimit(1)
    }
}

/// A level's tiles in a grid, spinning out from the bottom one after another
/// when the level appears, as the profile panel's tiles do.
struct PanelTileGrid<Content: View>: View {
    var columns = 2
    @ViewBuilder var content: Content

    var body: some View {
        LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: GlassLayout.gap), count: columns),
            spacing: GlassLayout.gap
        ) {
            content
        }
    }
}

/// The spin-out of one tile: from small at its bottom edge, a little turned,
/// to its place, `index` steps after the first. Under Reduce Motion it only
/// fades in.
struct SpinOut: ViewModifier {
    let index: Int
    @State private var isOut = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .scaleEffect(isOut || reduceMotion ? 1 : 0.6, anchor: .bottom)
            .rotationEffect(.degrees(isOut || reduceMotion ? 0 : -6), anchor: .bottomTrailing)
            .opacity(isOut ? 1 : 0)
            .onAppear {
                guard !isOut else { return }
                withAnimation(reduceMotion ? MapChrome.reducedFade : MapChrome.panelSpring.delay(Double(index) * 0.03)) {
                    isOut = true
                }
            }
    }
}

extension View {
    /// Spins the tile out when its level appears (`SpinOut`).
    func spinOut(_ index: Int) -> some View {
        modifier(SpinOut(index: index))
    }
}

/// A small accent count at a control's corner; nothing at zero.
struct CountBadge: View {
    let count: Int

    var body: some View {
        if count > 0 {
            Text("\(count)")
                .font(.caption2.weight(.bold))
                .monospacedDigit()
                .foregroundStyle(HUDTheme.onAccent)
                .padding(.horizontal, 5)
                .frame(minWidth: 18, minHeight: 18)
                .background(HUDTheme.accent, in: Capsule())
                .accessibilityHidden(true)
                .transition(.scale.combined(with: .opacity))
        }
    }
}
