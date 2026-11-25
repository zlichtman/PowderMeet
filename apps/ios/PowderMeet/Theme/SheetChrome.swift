import SwiftUI

// One presentation rule: everything opened from the profile
// panel continues in the same floating space above the bottom row, as theme
// glass bubbles straight over the dimmed map, with no sheet and no backing.
// A page has a glass title bubble with a back control, then its groups
// scrolling inside the room between the message row and the bottom row, and a
// search bar at its foot where it searches. Only the system's own sheets
// (share, Files, photos, Apple sign-in) and the sign-in screen's reset sheet
// are sheets.

/// Full-screen states that are not over the map (splash, sign-in,
/// onboarding): the theme's background with the faint mountain lines.
struct PageBackground: View {
    var body: some View {
        ZStack {
            HUDTheme.mapBackground
            MountainLinesTexture(placement: .panel)
        }
        .ignoresSafeArea()
    }
}

/// A sheet's backdrop (sign-in's reset sheet, onboarding's ski list): the
/// mountain seen through the theme's glass.
struct SheetBackdrop: View {
    var body: some View {
        Rectangle()
            .fill(.clear)
            .glassEffect(HUDGlass.backdrop, in: Rectangle())
            .ignoresSafeArea()
    }
}

extension View {
    /// A page pushed inside a sheet's navigation (sign-in and onboarding
    /// only): the title, the system back button.
    func pushedPage(_ title: String) -> some View {
        self
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .scrollContentBackground(.hidden)
    }

    /// The body of a panel page: its groups `spacing` apart (24 pt between
    /// sections), hugging their height above the bottom row and scrolling
    /// once they reach the message row.
    func pageScroll(spacing: CGFloat = GlassLayout.sectionGap) -> some View {
        PanelScroll(spacing: spacing, content: self) { EmptyView() }
    }

    /// The same, with a bar at its foot under the groups (the search bar).
    func pageScroll<Foot: View>(spacing: CGFloat = GlassLayout.sectionGap, @ViewBuilder foot: () -> Foot) -> some View {
        PanelScroll(spacing: spacing, content: self, foot: foot)
    }
}

/// The scrolling area of a panel page. It is as tall as its content up to the
/// room it is given, fades its rows at the edges instead of cutting them, and
/// a pull down past the top folds the whole panel.
struct PanelScroll<Content: View, Foot: View>: View {
    @Environment(AppModel.self) private var model
    @Environment(\.panelScrollRoom) private var room
    let spacing: CGFloat
    let content: Content
    let foot: Foot

    @State private var contentHeight: CGFloat = 0
    @State private var footHeight: CGFloat = 0

    /// The scrolling area's height: its content's, up to the room left over.
    private var height: CGFloat? {
        let ceiling = room.map { max(80, $0 - (footHeight > 0 ? footHeight + GlassLayout.gap : 0)) }
        guard contentHeight > 0 else { return ceiling }
        return min(contentHeight, ceiling ?? .infinity)
    }

    init(spacing: CGFloat, content: Content, @ViewBuilder foot: () -> Foot) {
        self.spacing = spacing
        self.content = content
        self.foot = foot()
    }

    private static var fade: CGFloat { 12 }

    var body: some View {
        VStack(spacing: GlassLayout.gap) {
            ScrollView {
                VStack(alignment: .leading, spacing: spacing) { content }
                    .padding(.vertical, Self.fade)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
            }
            .frame(height: height)
            .scrollIndicators(.hidden)
            .scrollDismissesKeyboard(.interactively)
            .onScrollGeometryChange(for: CGFloat.self) { geometry in
                geometry.contentOffset.y + geometry.contentInsets.top
            } action: { _, offset in
                if offset < -80 { model.closePanel() }
            }
            .mask {
                VStack(spacing: 0) {
                    LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom).frame(height: Self.fade)
                    Rectangle()
                    LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom).frame(height: Self.fade)
                }
            }
            foot
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { footHeight = $0 }
        }
    }
}

/// Written out rather than with `@Entry`: the target's default main-actor
/// isolation would otherwise isolate the key's `defaultValue`.
private nonisolated struct PanelScrollRoomKey: EnvironmentKey {
    static let defaultValue: CGFloat? = nil
}

extension EnvironmentValues {
    /// The most a panel page's scrolling area may take (`PanelPage`).
    nonisolated var panelScrollRoom: CGFloat? {
        get { self[PanelScrollRoomKey.self] }
        set { self[PanelScrollRoomKey.self] = newValue }
    }
}

/// The title bubble on top of a panel page: the back control to the level
/// above, the page's one-word title and, on a page that has one, its "…"
/// menu at the trailing end. A swipe down on it folds the panel.
struct PanelHeader: View {
    @Environment(AppModel.self) private var model
    let title: String
    var trailing: AnyView?

    var body: some View {
        HStack(spacing: 4) {
            Button { model.panelBack() } label: {
                Image(systemName: "chevron.left")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(HUDTheme.primaryText)
                    .frame(width: GlassLayout.iconButton, height: GlassLayout.iconButton)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Back")
            Text(title)
                .textRole(.bodyEmph)
                .foregroundStyle(HUDTheme.primaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 8)
            if let trailing { trailing }
        }
        .padding(4)
        .frame(maxWidth: .infinity)
        .glassEffect(HUDGlass.surface, in: Capsule())
        .environment(\.isOnGlass, true)
        .contentShape(Capsule())
        .gesture(
            DragGesture(minimumDistance: 20).onEnded { value in
                if value.translation.height > 50, abs(value.translation.width) < value.translation.height {
                    model.closePanel()
                }
            }
        )
    }
}

/// The presentation the few remaining sheets share (onboarding's ski list):
/// full height, the theme's glass behind.
struct MapSheetPresentation: ViewModifier {
    func body(content: Content) -> some View {
        content
            .environment(\.isOnGlass, false)
            .tint(HUDTheme.accent)
            .preferredColorScheme(.dark)
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
            .presentationBackground { SheetBackdrop() }
    }
}

/// "Alex wants to meet": a meet request that arrived while a panel page was
/// up. Tapping it folds the panel; the request is in the context sheet.
struct IncomingMeetBanner: View {
    let name: String
    let onShow: () -> Void

    var body: some View {
        Button(action: onShow) {
            HStack(spacing: 10) {
                Image(systemName: "person.2.wave.2.fill")
                    .foregroundStyle(HUDTheme.accent)
                    .accessibilityHidden(true)
                Text("\(name) wants to meet")
                    .textRole(.bodyEmph)
                    .foregroundStyle(HUDTheme.primaryText)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text("Show")
                    .textRole(.bodyEmph)
                    .foregroundStyle(HUDTheme.accent)
            }
            .frame(maxWidth: .infinity)
            .glassChip(interactive: true)
        }
        .buttonStyle(.plain)
        .accessibilityHint("Closes this and shows the request on the map")
    }
}
