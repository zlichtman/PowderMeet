import AppCore
import PowderMeetAPI
import SwiftUI

/// The floating panel (`specs/13-APP-MAP.md` section 3): the profile panel,
/// and every page opened from it, in the one space above the bottom row. A
/// page gives way to the next where it stood: deeper slides in from the
/// trailing edge while the page under it slides off to the leading edge and
/// fades; back, the page on top fades and the one under it slides back. The
/// pages under the top one stay alive (hidden), so a search or an open day is
/// where it was on the way back.
struct PanelHost: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let path = model.panelPath
        // The room between the message row and the bottom row, handed to each
        // level as its ceiling so a long page scrolls inside it.
        GeometryReader { proxy in
        ZStack(alignment: .bottom) {
            GlassEffectContainer(spacing: 0) {
                ProfilePanel(onClose: model.closePanel)
            }
            .frame(maxHeight: proxy.size.height, alignment: .bottom)
            .modifier(PanelLayer(isTop: path.isEmpty))

            ForEach(Array(path.enumerated()), id: \.offset) { index, route in
                PanelPage(route: route, room: proxy.size.height)
                    .id(route)
                    .modifier(PanelLayer(isTop: index == path.count - 1))
                    .transition(MapChrome.transition(
                        .asymmetric(insertion: .opacity.combined(with: .offset(x: 40)), removal: .opacity),
                        reduce: reduceMotion))
            }
        }
        .frame(width: proxy.size.width, height: proxy.size.height, alignment: .bottom)
        }
        .tint(HUDTheme.accent)
    }
}

/// A level of the panel: shown on top, or waiting under the page above it.
private struct PanelLayer: ViewModifier {
    let isTop: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .opacity(isTop ? 1 : 0)
            .offset(x: isTop || reduceMotion ? 0 : -40)
            .allowsHitTesting(isTop)
            .accessibilityHidden(!isTop)
    }
}

/// One page of the panel: a meet request waiting, the title bubble with its
/// back control, then the page's own groups.
private struct PanelPage: View {
    @Environment(AppModel.self) private var model
    let route: PanelRoute
    /// The height this page may take at most.
    let room: CGFloat

    private var incomingName: String? {
        guard let meet = model.resort?.meet, case .incoming(let incoming) = meet.state else { return nil }
        return model.name(of: incoming.meet.proposerID)
    }

    var body: some View {
        let banner = incomingName
        // What the page's scrolling area may take: the room less the title
        // bubble (and the banner), each with its gap. Handed down explicitly,
        // since the glass container lays its content out at ideal size.
        let chrome = (GlassLayout.iconButton + 8 + GlassLayout.gap)
            + (banner == nil ? 0 : GlassLayout.chipHeight + GlassLayout.gap)
        // No glass container around the page: a container draws its glass in
        // one layer above the scroll view's clip, so cards would show past the
        // scrolling area's edges.
        VStack(spacing: GlassLayout.gap) {
            if let banner {
                IncomingMeetBanner(name: banner) { model.showMap() }
                    .transition(.opacity)
            }
            PanelHeader(title: title, trailing: headerMenu)
            page
                .environment(\.panelScrollRoom, max(120, room - chrome))
        }
        .accessibilityAction(.escape) { model.panelBack() }
    }

    @ViewBuilder
    private var page: some View {
        switch route {
        case .section(.friends): FriendsPage()
        case .section(.activity): ProfileActivityPage()
        case .section(.gear): ProfileGearPage()
        case .section(.settings): SettingsRoot()
        case .friendCard(let id): FriendCardSheet(friendID: id)
        case .blocked: BlockedUsersSheet()
        case .report(let target): ReportUserSheet(target: target)
        case .logs: ActivityLogsView()
        case .runDetail(let run): ActivityRunDetailSheet(run: run)
        case .importReport: ActivityImportSheet()
        case .settings(let page): SettingsDetailPage(page: page)
        case .units: UnitsPage()
        case .acknowledgements: AcknowledgementsPage()
        case .deleteAccount: DeleteAccountSheet()
        case .resetPassword:
            PasswordResetView(initialEmail: model.account.identity?.email ?? "") {
                model.leavePanelPage(.resetPassword)
            }
            .pageScroll()
        case .developer: DeveloperScreen()
        case .developerPage(let page): DeveloperSubpage(page: page)
        }
    }

    /// A friend's card keeps Remove, Block and Report in the title bubble's
    /// "…", away from its Meet up (design brief §1).
    private var headerMenu: AnyView? {
        guard case .friendCard(let id) = route else { return nil }
        return AnyView(FriendCardMenu(friendID: id))
    }

    private var title: String {
        switch route {
        case .section(let page): page.title
        case .friendCard(let id): model.name(of: id)
        case .blocked: "Blocked"
        case .report: "Report"
        case .logs: "Logs"
        case .runDetail(let run): run.title
        case .importReport: "Import"
        case .settings(let page): page.title
        case .units: "Units"
        case .acknowledgements: "Acknowledgements"
        case .deleteAccount: "Delete"
        case .resetPassword: "Password"
        case .developer: "Dev"
        case .developerPage(let page): page.title
        }
    }
}
