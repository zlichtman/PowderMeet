import AppCore
import MapboxAdapter
import MeetSolver
import MountainCore
import PowderMeetAPI
import SwiftUI

/// The map screen's fixed measures.
enum MapChrome {
    /// The row kept free under whatever covers the top (the status bar, the
    /// meet's pinned instruction, the developer banner) for the app's one
    /// message: the panel, the context sheet and the floating lists stop under
    /// it, so a toast never covers them or the instruction.
    static let messageRow = GlassLayout.chipHeight
    /// Where that message sits, `covered` points below the top of the safe area.
    static func messagesTop(covered: CGFloat) -> CGFloat { covered + GlassLayout.gap }

    /// The one motion of the floating panel: it opens, folds and turns its
    /// pages on this spring.
    static let panelSpring = Animation.spring(response: 0.32, dampingFraction: 0.88)

    /// The same spring, a beat later: the pieces of one arrival in order
    /// (a resort opening: the friends row, then the timeline).
    static func arrival(_ step: Int) -> Animation { panelSpring.delay(0.12 + 0.1 * Double(step)) }

    /// Under Reduce Motion the chrome fades for 0.2 s instead: no spring,
    /// nothing slides or scales (`12-DESIGN-BRIEF.md`).
    static let reducedFade = Animation.easeInOut(duration: 0.2)

    /// The panel spring, or the fade under Reduce Motion.
    static func motion(reduce: Bool) -> Animation { reduce ? reducedFade : panelSpring }

    /// A transition that moves or scales, or a plain fade under Reduce Motion.
    static func transition(_ moving: AnyTransition, reduce: Bool) -> AnyTransition { reduce ? .opacity : moving }

    /// While a meet is under way, or a card with a route on it is open
    /// (meeting options, an invitation, a sent request, Go to), the weather
    /// card folds to the hour and the scrubber and the friends row steps
    /// aside, so the route has the map and its card has the height; a run's
    /// card then carries the weather line the big card would repeat.
    @MainActor static func isWeatherCollapsed(_ resort: ResortModel) -> Bool {
        if resort.isMeetActive { return true }
        switch resort.contextCard {
        case .options, .incoming, .sent, .goTo: return true
        case .meet, .group, .place, nil: return false
        }
    }

    /// The Mapbox logo and ⓘ's lower edge, from the screen's bottom: clear
    /// of the home indicator where there is one.
    static func badgeBottom(safeBottom: CGFloat) -> CGFloat { safeBottom > 0 ? 16 : 8 }

    /// Room under the bottom row, inside the safe area, for the Mapbox logo
    /// and ⓘ (under the resort bar, so they never sit over a
    /// route or a card): their row and a small gap above it.
    static func bottomRoom(safeBottom: CGFloat) -> CGFloat {
        max(GlassLayout.gap, badgeBottom(safeBottom: safeBottom) + CGFloat(MapObscuredArea.badgeHeight) + 6 - safeBottom)
    }
}

/// How tall the map's top chrome is (the meet's pinned instruction, the
/// developer banner), from the top of the safe area: the messages sit under it.
struct MapTopCoverKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// The one screen of the app (`specs/13-APP-MAP.md`): the map, with the
/// floating panel and the floating lists over it. System sheets (share, Files,
/// photos) are presented by the pages that need them.
struct MainScaffold: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        MapScreen()
            // "Pick one from a list" floats over the map and over the panel.
            .overlay {
                if let picker = model.floatingPicker {
                    FloatingPickerHost(picker: picker)
                }
            }
            .animation(.easeInOut(duration: 0.2), value: model.floatingPicker)
            .preferredColorScheme(.dark)
    }
}

/// The whole app (`specs/13-APP-MAP.md` section 1): the map edge to edge, and
/// everything else floating on it as theme glass. From the bottom up: the
/// bottom row (resort bar and profile button), which never moves; over
/// it either the map's own stack (the timeline, the friends row and the
/// context sheet) or the floating panel (the profile panel and the section
/// pages). At the top only the status bar's fade and, in developer testing,
/// its banner.
struct MapScreen: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var topHeight: CGFloat = 0
    /// The map's own stack with the context sheet short, for the camera.
    @State private var stackHeight: CGFloat = 0
    /// The friends row and the timeline, so the sheet knows its room.
    @State private var restHeight: CGFloat = 0
    @State private var isCardExpanded = DebugLaunch.cardExpanded

    /// The map is under nothing but its own chrome.
    private var isMapInView: Bool { !model.isProfilePanelOpen && model.floatingPicker == nil }

    /// A light map look under the status bar: its glyphs go dark.
    private var isLightMap: Bool { model.resort != nil && ThemeManager.shared.mapLook == .whiteout }

    var body: some View {
        ZStack {
            // The map keeps its frame when the keyboard rises over the panel.
            GeometryReader { proxy in
                mapLayers(safeArea: proxy.safeAreaInsets)
            }
            .ignoresSafeArea(.keyboard)

            statusBarFade
                .background(StatusBarDarkener(isDark: isLightMap))

            if model.isProfilePanelOpen, model.floatingPicker == nil {
                // The map behind the panel, dimmed: a tap on it folds the panel.
                Color.black.opacity(0.35)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture { model.closePanel() }
                    .transition(.opacity)
                    .accessibilityHidden(true)
            }

            GeometryReader { proxy in
                chrome(available: proxy.size.height, safeBottom: proxy.safeAreaInsets.bottom)
            }
        }
        .animation(MapChrome.motion(reduce: reduceMotion), value: model.isProfilePanelOpen)
        .animation(MapChrome.motion(reduce: reduceMotion), value: model.panelPath)
        .animation(MapChrome.motion(reduce: reduceMotion), value: model.resort?.contextCard)
        .onChange(of: isMapInView, initial: true) { _, visible in
            model.resort?.mapVisibilityChanged(visible)
        }
        // The app's one message (`MessagesOverlay`) sits under the top
        // chrome, so it moves down with the pinned instruction. A floating
        // picker hides that chrome, so nothing is covered then.
        .preference(key: MapTopCoverKey.self, value: model.floatingPicker == nil ? topHeight : 0)
        // "Run Completion" follows the skier's days: a run recorded or imported
        // recolours the map.
        .onChange(of: model.activity.history.totals.runs) { _, _ in
            if ThemeManager.shared.runOverlay == .skied { model.syncSkiedRuns() }
        }
        .onChange(of: model.resort?.contextCard) { old, new in
            // A new subject starts short.
            if old != new, !DebugLaunch.cardExpanded { isCardExpanded = false }
        }
    }

    // MARK: Layers

    @ViewBuilder
    private func mapLayers(safeArea: EdgeInsets) -> some View {
        ZStack {
            if !DebugLaunch.previewData || model.resort != nil {
                HUDTheme.mapBackground.ignoresSafeArea()
            }
            if let resort = model.resort {
                MapSurface(
                    resort: resort, resortName: model.selectedResort?.name ?? resort.bundle?.name,
                    obscured: obscured(safeArea),
                    flyIn: model.mapFlyIn,
                    weather: resort.weatherAtDisplayTime, weatherMoves: isMapInView
                )
                .ignoresSafeArea()
            } else if !DebugLaunch.previewData {
                ChooseMountainView()
            }
        }
    }

    /// The one drawn overlay: the status bar's glyphs have no glass of their
    /// own. White glyphs over a dark fade; on Whiteout dark glyphs
    /// (`StatusBarDarkener`) over a light one, so bright runs never sit
    /// under them.
    private var statusBarFade: some View {
        let shade: Color = isLightMap ? .white : .black
        return VStack(spacing: 0) {
            LinearGradient(colors: [shade.opacity(isLightMap ? 0.6 : 0.45), shade.opacity(0)],
                           startPoint: .top, endPoint: .bottom)
                .frame(height: 110)
            Spacer(minLength: 0)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    private func chrome(available: CGFloat, safeBottom: CGFloat) -> some View {
        VStack(spacing: 0) {
            VStack(spacing: GlassLayout.gap) {
                DeveloperMapBanner()
                // The colouring's legend, while nothing else has the top: not
                // under the profile panel, a meet's directions or open options.
                if !model.isProfilePanelOpen, model.resort?.isMeetActive != true, !areOptionsOpen,
                   model.resort?.bundle != nil {
                    RunOverlayMapLegend()
                }
                // During a meet: the one instruction pinned at the top.
                if !model.isProfilePanelOpen, let resort = model.resort, let bundle = resort.bundle,
                   resort.isMeetActive {
                    // Never more than the room the cards below leave, so its open
                    // step list cannot push the bottom row off the screen.
                    MeetNavigationBanner(
                        resort: resort, bundle: bundle,
                        maxHeight: min(
                            available * 0.55,
                            available - stackHeight - GlassLayout.barHeight - MapChrome.messageRow
                                - MapChrome.bottomRoom(safeBottom: safeBottom) - 4 * GlassLayout.gap))
                        .transition(MapChrome.transition(.move(edge: .top).combined(with: .opacity), reduce: reduceMotion))
                }
            }
            // Everything here counts as covered: the camera aims below it and
            // the message row sits under it, so a toast never covers the
            // instruction or its open step list.
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { topHeight = $0 }
            // Keeps the panel and the sheet clear of the message row. Open
            // meeting options take that row too, to a small gap under the
            // status bar: a message shows over their top for its few seconds.
            Spacer(minLength: areOptionsOpen ? GlassLayout.gap : MapChrome.messageRow + GlassLayout.gap)

            // The floating space above the bottom row: the map's stack, or the
            // panel. Each is its own glass container, so nothing melts into a
            // neighbour while it moves.
            ZStack(alignment: .bottom) {
                if model.isProfilePanelOpen {
                    PanelHost()
                        // Grows out of the profile button's corner.
                        .transition(MapChrome.transition(
                            .scale(scale: 0.6, anchor: .bottomTrailing).combined(with: .opacity), reduce: reduceMotion))
                } else {
                    mapStack(available: available, bottomRoom: MapChrome.bottomRoom(safeBottom: safeBottom))
                        // Sinks behind the bottom row as it fades.
                        .transition(MapChrome.transition(.offset(y: 48).combined(with: .opacity), reduce: reduceMotion))
                }
            }
            .frame(maxHeight: .infinity, alignment: .bottom)
            .padding(.bottom, GlassLayout.gap)

            // Never part of the swap: the row stays put while the rest moves.
            GlassEffectContainer(spacing: GlassLayout.gap / 2) {
                // With meeting options swiped up the bar is the send button:
                // the resort picker has nothing to do while a route is chosen.
                if areOptionsOpen, let resort = model.resort {
                    MeetSendButton(resort: resort)
                } else {
                    MapBottomRow()
                }
            }
        }
        .padding(.horizontal, GlassLayout.inset)
        .padding(.bottom, MapChrome.bottomRoom(safeBottom: safeBottom))
        // A picker floating over the map takes the chrome's place.
        .opacity(model.floatingPicker == nil ? 1 : 0)
        .allowsHitTesting(model.floatingPicker == nil)
    }

    /// The context sheet over the friends row and the timeline.
    /// Meeting options, swiped up.
    private var areOptionsOpen: Bool { isCardExpanded && model.resort?.contextCard == .options }

    private func mapStack(available: CGFloat, bottomRoom: CGFloat) -> some View {
        GlassEffectContainer(spacing: GlassLayout.gap / 2) {
            VStack(spacing: GlassLayout.gap) {
                if let resort = model.resort, let card = resort.contextCard {
                    ContextSheet(
                        resort: resort, card: card, isExpanded: $isCardExpanded,
                        // Open meeting options get every point there is: the
                        // screen less what sits above and below them, exactly.
                        maxHeight: areOptionsOpen
                            ? max(160, available - topHeight - restHeight - GlassLayout.barHeight
                                - bottomRoom - 4 * GlassLayout.gap)
                            : max(160, available - topHeight - restHeight - GlassLayout.barHeight
                                - MapChrome.messageRow - 4 * GlassLayout.gap)
                    )
                    // One card through a meet's life (options, sent,
                    // incoming, under way): its glass morphs from one state
                    // to the next instead of swapping. Anything else rises.
                    .id(card.family)
                    .transition(MapChrome.transition(.move(edge: .bottom).combined(with: .opacity), reduce: reduceMotion))
                }
                if let resort = model.resort {
                    // A resort opening: once its map has drawn, the friends row
                    // and then the timeline fade in where they sit, in order;
                    // nothing slides, so the gap to the resort bar is there from
                    // the first frame.
                    VStack(spacing: GlassLayout.gap) {
                        // With meeting options open the row stays: the lit chip
                        // says who the options are for, and another friend is one
                        // tap away.
                        if !MapChrome.isWeatherCollapsed(resort) || resort.selectedGroupID != nil
                            || resort.contextCard == .options {
                            MapFriendsRow(resort: resort, isVisible: isMapInView)
                                .opacity(resort.hasSettledFirstView ? 1 : 0)
                                .animation(MapChrome.arrival(0), value: resort.hasSettledFirstView)
                                .transition(.opacity)
                        }
                        // No forecast scrubber over open meeting options: the
                        // height goes to the routes.
                        if resort.bundle != nil, !areOptionsOpen {
                            ResortTimelineView(
                                resort: resort, arrival: resort.meetArrival,
                                isCollapsed: MapChrome.isWeatherCollapsed(resort))
                                .opacity(resort.hasSettledFirstView ? 1 : 0)
                                .animation(MapChrome.arrival(1), value: resort.hasSettledFirstView)
                        }
                    }
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { restHeight = $0 }
                }
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
            // The camera keeps aiming at the map above the short sheet; a
            // sheet swiped up is a passing state.
            // Open meeting options count: their routes are framed above them.
            if !isCardExpanded || areOptionsOpen { stackHeight = height }
        }
    }

    /// What the floating layers cover, in the map's points: the map ignores
    /// the safe area, so its edges are the screen's.
    private func obscured(_ safeArea: EdgeInsets) -> MapObscuredArea {
        let stack = stackHeight > 0 ? stackHeight + GlassLayout.gap : 0
        return MapObscuredArea(
            top: safeArea.top + (topHeight > 0 ? topHeight + GlassLayout.gap : 0),
            bottom: safeArea.bottom + MapChrome.bottomRoom(safeBottom: safeArea.bottom) + GlassLayout.barHeight + stack,
            badgeBottom: MapChrome.badgeBottom(safeBottom: safeArea.bottom)
        )
    }
}

/// Before any mountain is picked: the sign-in backdrop and the name, nothing
/// to read or press. The resort list opens over it and the bottom row's
/// resort button reopens it, so a second prompt here would only repeat them.
private struct ChooseMountainView: View {
    var body: some View {
        ZStack {
            PreMapBackdrop()
            VStack(spacing: 18) {
                Image(systemName: "mountain.2.fill")
                    .font(.system(size: 64, weight: .semibold))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, HUDTheme.accent)
                    .accessibilityHidden(true)
                Image("PowderMeetWordmark")
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 240)
                    .foregroundStyle(HUDTheme.primaryText)
                    .accessibilityLabel("PowderMeet")
            }
            .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
