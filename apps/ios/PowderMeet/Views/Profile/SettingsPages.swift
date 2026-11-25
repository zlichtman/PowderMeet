import AppCore
import MapboxAdapter
import PowderMeetAPI
import SwiftUI
import UIKit

/// Settings: separate glass tiles spinning out like the
/// profile panel's, each opening a page of its own: Account, Appearance,
/// Notifications, Permissions, Maps, About, and Dev in test builds.
struct SettingsRoot: View {
    @Environment(AppModel.self) private var model
    @Environment(DeveloperModel.self) private var developer: DeveloperModel?

    private var theme: ThemeManager { ThemeManager.shared }

    var body: some View {
        // Six tiles fill three even rows; Dev, in test builds, is the odd one
        // out and spans the whole last row rather than
        // sitting alone beside a gap.
        VStack(spacing: GlassLayout.gap) {
            PanelTileGrid {
                ForEach(Array(SettingsPage.allCases.enumerated()), id: \.element) { index, page in
                    PanelTile(icon: page.icon, title: page.title, value: value(page)) {
                        model.pushPanel(.settings(page))
                    }
                    .spinOut(index)
                }
            }
            if let developer, developer.isAvailable {
                PanelTile(icon: "hammer.fill", title: "Dev", value: "Testing") {
                    model.pushPanel(.developer)
                }
                .spinOut(SettingsPage.allCases.count)
            }
        }
        .pageScroll()
        .task {
            model.loadNotificationPrefs()
            model.refreshNotificationPermission()
            if model.catalog.resorts.isEmpty, !model.catalog.isLoading { model.loadCatalog() }
            model.refreshMaps()
        }
    }

    /// The value under each tile: where it stands now.
    private func value(_ page: SettingsPage) -> String {
        switch page {
        case .account: SettingsText.isEmailAccount(model) ? "Email" : "Apple ID"
        case .appearance: theme.displayName
        case .notifications: SettingsText.notificationsSummary(model)
        case .location: SettingsText.locationShort(model)
        case .maps: MapsText.tileValue(model)
        case .about: model.displayVersion
        }
    }

}

/// One Settings page, pushed from its row.
struct SettingsDetailPage: View {
    let page: SettingsPage

    var body: some View {
        // Maps is a long list with its own search bar at its foot.
        if page == .maps {
            MapsSettings()
        } else {
            detail
        }
    }

    private var detail: some View {
        Group {
            switch page {
            case .account: AccountSettings()
            case .appearance: AppearanceSettings()
            case .notifications: NotificationSettings()
            case .location: LocationSettings()
            case .maps: EmptyView()
            case .about: AboutSettings()
            }
        }
        .pageScroll()
    }
}

// MARK: Wording shared by the rows and the pages

@MainActor
private enum SettingsText {
    static func isEmailAccount(_ model: AppModel) -> Bool { model.account.identity?.provider == .email }

    /// The address on the account, or what Apple left out.
    static func accountEmail(_ model: AppModel) -> String? {
        guard let identity = model.account.identity, let email = identity.email, !email.isEmpty,
              !identity.isPrivateRelayEmail else { return nil }
        return email
    }

    static func accountSummary(_ model: AppModel) -> String {
        let kind = isEmailAccount(model) ? "Email" : "Apple ID"
        return "\(kind) · \(accountEmail(model) ?? "hidden email")"
    }

    static func notificationsSummary(_ model: AppModel) -> String {
        guard model.notificationPermission == .allowed else { return "Off" }
        let on = PushKind.allCases.count { model.notificationPrefs.isOn($0) }
        return "\(on) of \(PushKind.allCases.count)"
    }

    static func locationShort(_ model: AppModel) -> String {
        switch model.locationPermission {
        case .allowed: model.locationAlways ? "Always" : "While using the app"
        case .denied: "Off"
        case .notDetermined: "Not asked yet"
        }
    }
}

/// Opens this app's page in iOS Settings.
@MainActor
private func openSystemSettings(_ openURL: OpenURLAction) {
    if let settings = URL(string: UIApplication.openSettingsURLString) { openURL(settings) }
}

// MARK: Account

/// The skier's picture, name and the lettering of the name: the one place
/// they change (the profile only shows them).
private struct AccountProfileEditor: View {
    @Environment(AppModel.self) private var model
    @State private var manager = ThemeManager.shared
    @State private var name = ""
    @State private var nameError: String?

    var body: some View {
        if let profile = model.profile {
            GlassSection("Profile") {
                HStack(spacing: 14) {
                    ProfilePhotoButton(size: 64)
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            TextField("", text: $name, prompt: Text("Your name").foregroundStyle(HUDTheme.secondaryText))
                                .font(manager.nameFont.font)
                                .foregroundStyle(HUDTheme.primaryText)
                                .textInputAutocapitalization(.words)
                                .submitLabel(.done)
                                .onSubmit { commit(profile) }
                                .padding(.horizontal, 12)
                                .frame(minHeight: 44)
                                .glassField()
                                .accessibilityLabel("Display name")
                            if isChanged(profile) {
                                IconButton(systemImage: "checkmark", label: "Save display name", tint: HUDTheme.accent) {
                                    commit(profile)
                                }
                            }
                        }
                        if let nameError {
                            Text(nameError)
                                .textRole(.label)
                                .foregroundStyle(HUDTheme.accentRed)
                        }
                    }
                }
                .padding(GlassLayout.cardPadding)
                GlassDivider()
                VStack(alignment: .leading, spacing: 8) {
                    Text("Font")
                        .textRole(.body)
                        .foregroundStyle(HUDTheme.primaryText)
                    HUDChoicePills(
                        choices: NameFont.allCases.map { .init(value: $0, label: $0.title) },
                        selection: manager.nameFont
                    ) { manager.selectNameFont($0) }
                }
                .padding(GlassLayout.cardPadding)
            }
            .onAppear { name = profile.displayName }
            .onChange(of: name) { _, _ in nameError = nil }
        }
    }

    private func isChanged(_ profile: Profile) -> Bool {
        name.trimmingCharacters(in: .whitespacesAndNewlines) != profile.displayName
    }

    /// The save is the session's; a failure arrives as a toast.
    private func commit(_ profile: Profile) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            nameError = "Name can't be empty"
            return
        }
        if trimmed != profile.displayName { model.renameProfile(trimmed) }
    }
}

private struct AccountSettings: View {
    @Environment(AppModel.self) private var model
    @State private var confirmsSignOut = false

    var body: some View {
        let isEmail = SettingsText.isEmailAccount(model)
        AccountProfileEditor()
        GlassSection {
            GlassRow(
                icon: isEmail ? "envelope.fill" : "apple.logo",
                title: SettingsText.accountEmail(model) ?? "Apple ID, Hidden Email",
                detail: isEmail ? "Signed in with email" : "Signed in with Apple"
            )
            .accessibilityElement(children: .combine)
        }
        GlassSection {
            // A reset link goes to the account's address rather than changing
            // the password here, so an unlocked phone is not enough to change it.
            if isEmail {
                GlassLinkRow(icon: "key.fill", title: "Reset Password", route: PanelRoute.resetPassword)
                GlassDivider(inset: 54)
            }
            GlassNavRow(icon: "rectangle.portrait.and.arrow.right", title: "Sign Out") {
                confirmsSignOut = true
            }
        }
        GlassSection {
            GlassLinkRow(
                icon: "trash.fill", title: "Delete Account", titleTint: HUDTheme.accentRed, route: .deleteAccount)
        }
        .alert("Sign out?", isPresented: $confirmsSignOut) {
            Button("Cancel", role: .cancel) {}
            Button("Sign Out", role: .destructive) { model.signOut() }
        } message: {
            Text("You'll need to sign in again to use PowderMeet.")
        }
    }
}

// MARK: Appearance

private struct AppearanceSettings: View {
    @Environment(AppModel.self) private var model
    private var theme: ThemeManager { ThemeManager.shared }

    var body: some View {
        // The four choices as tiles, two by two: Theme beside the map look it
        // colours (Holographic takes the accent), then the icon and units.
        // The skis' glow lives in the ski picker.
        PanelTileGrid(columns: 2) {
            PanelTile(icon: "paintpalette.fill", title: "Theme", value: theme.displayName) {
                model.openFloating(.themePicker)
            }
            .spinOut(1)
            PanelTile(icon: "mountain.2.fill", title: "Map", value: theme.mapLook.title) {
                model.openFloating(.mapLookPicker)
            }
            .spinOut(2)
            PanelTile(icon: "app.badge.fill", title: "Icon", value: theme.selectedIcon.title) {
                model.openFloating(.iconPicker)
            }
            .spinOut(3)
            PanelTile(icon: "ruler.fill", title: "Units", value: theme.units.label) {
                model.pushPanel(.units)
            }
            .spinOut(4)
        }
    }
}

extension UnitChoice {
    nonisolated var label: String {
        switch self {
        case .device: "Device"
        case .metric: "Metric"
        case .imperial: "Imperial"
        }
    }
}

// MARK: Notifications

private struct NotificationSettings: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    /// The same key `NavigationFeedback` reads (default on).
    @AppStorage(SoundsAndVoicePreference.key) private var soundsAndVoice = true

    private var permissionDetail: String {
        switch model.notificationPermission {
        case .allowed: "On for this phone"
        case .notDetermined: "Not turned on yet"
        case .denied: "Off in iOS Settings. Nothing below arrives until you allow it."
        }
    }

    var body: some View {
        // The switches below save either way; while iOS has notifications
        // off none of them arrives, so that is said first.
        if model.notificationPermission != .allowed {
            GlassSection {
                GlassRow(
                    icon: "bell.slash.fill", title: "Notifications Are Off", detail: permissionDetail,
                    titleTint: HUDTheme.accentAmber
                ) {
                    switch model.notificationPermission {
                    case .notDetermined:
                        SecondaryButton(title: "Turn on", fillsWidth: false) { model.requestNotificationPermission() }
                    case .allowed, .denied:
                        SecondaryButton(title: "Settings", fillsWidth: false) { openSystemSettings(openURL) }
                    }
                }
            }
        }
        kinds("Meets", [.meetProposed, .meetAccepted, .meetDeclined, .meetPartnerArrived, .meetEnded, .meetExpired],
              footnote: nil)
        kinds("Friends", [.friendRequested, .friendAccepted], footnote: nil)
        if let failure = model.notificationPrefs.failure {
            GlassSection {
                GlassRow(
                    icon: "exclamationmark.triangle.fill",
                    title: model.notificationPrefs.isLoaded ? "Not Saved" : "Couldn't Load Your Choices",
                    detail: failure.userMessage, titleTint: HUDTheme.accentAmber
                ) {
                    SecondaryButton(title: "Retry", fillsWidth: false) { model.loadNotificationPrefs() }
                }
            }
        }
        GlassSection("Sound") {
            GlassToggleRow(icon: "speaker.wave.2.fill", title: "Voice and Bell", isOn: $soundsAndVoice)
        }
    }

    private func kinds(_ title: String, _ kinds: [PushKind], footnote: String?) -> some View {
        GlassSection(title, footnote: footnote) {
            ForEach(Array(kinds.enumerated()), id: \.element) { index, kind in
                if index > 0 { GlassDivider(inset: 54) }
                GlassToggleRow(
                    icon: kind.icon, title: kind.title,
                    isOn: Binding(
                        get: { model.notificationPrefs.isOn(kind) },
                        set: { model.setNotification(kind, on: $0) }
                    ),
                    isEnabled: model.notificationPrefs.isLoaded
                )
            }
        }
    }
}

/// The eight notification kinds as Settings lists them.
private nonisolated extension PushKind {
    var title: String {
        switch self {
        case .meetProposed: "Meet Requests"
        case .meetAccepted: "Meet Accepted"
        case .meetDeclined: "Meet Declined"
        case .meetPartnerArrived: "Friend Arrived"
        case .meetEnded: "Meet Ended or Cancelled"
        case .meetExpired: "Meet Expired"
        case .friendRequested: "Friend Requests"
        case .friendAccepted: "Friend Added"
        }
    }

    var icon: String {
        switch self {
        case .meetProposed: "person.2.wave.2.fill"
        case .meetAccepted: "checkmark.circle.fill"
        case .meetDeclined: "xmark.circle.fill"
        case .meetPartnerArrived: "mappin.and.ellipse"
        case .meetEnded: "flag.checkered"
        case .meetExpired: "clock.badge.xmark"
        case .friendRequested: "person.crop.circle.badge.plus"
        case .friendAccepted: "person.crop.circle.badge.checkmark"
        }
    }
}

// MARK: Location and privacy

private struct LocationSettings: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL

    private var notificationValue: String {
        switch model.notificationPermission {
        case .allowed: "On"
        case .notDetermined: "Not asked"
        case .denied: "Off"
        }
    }

    var body: some View {
        GlassSection {
            GlassRow(icon: "location.fill", title: "Location", detail: SettingsText.locationShort(model)) {
                SecondaryButton(title: "Settings", fillsWidth: false) { openSystemSettings(openURL) }
            }
            GlassDivider(inset: 54)
            GlassRow(icon: "bell.badge.fill", title: "Notifications", detail: notificationValue) {
                switch model.notificationPermission {
                case .notDetermined:
                    SecondaryButton(title: "Turn on", fillsWidth: false) { model.requestNotificationPermission() }
                case .allowed, .denied:
                    SecondaryButton(title: "Settings", fillsWidth: false) { openSystemSettings(openURL) }
                }
            }
        }
    }
}

// MARK: About and support

/// The app's safety line, the same notice as the README's and LICENSE's. It
/// lives in About only: not in onboarding, where it would scare people off.
enum SafetyNotice {
    /// One short line each, read as a list.
    static let lines = [
        "Run ratings and lift status can be wrong.",
        "Always follow resort signs and patrol.",
        "You use PowderMeet at your own risk.",
    ]
    static let text = lines.map { "• \($0)" }.joined(separator: "\n")
}

/// Where support and the privacy notice live: the project's public pages.
/// About links to both; the resort picker's request row to support.
enum SupportLinks {
    static let privacy = URL(string: "https://github.com/zlichtman/PowderMeet/blob/main/docs/PRIVACY.md")
    static let support = URL(string: "https://github.com/zlichtman/PowderMeet/issues")
}

private struct AboutSettings: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    @State private var shareItem: ShareItem?

    var body: some View {
        GlassSection {
            GlassRow(icon: "info.circle.fill", title: "Version") {
                GlassValue(text: model.displayVersion)
            }
            .accessibilityElement(children: .combine)
        }
        GlassSection("Safety", footnote: SafetyNotice.text) {
            GlassRow(icon: "exclamationmark.triangle.fill", title: "Not a Safety Tool")
        }
        GlassSection("Support") {
            GlassNavRow(icon: "ladybug.fill", title: "Bug Report") {
                if let url = model.exportBugReport() { shareItem = ShareItem(url: url) }
            }
            GlassDivider(inset: 54)
            GlassNavRow(icon: "questionmark.circle.fill", title: "Support") {
                if let url = SupportLinks.support { openURL(url) }
            }
            GlassDivider(inset: 54)
            GlassNavRow(icon: "hand.raised.fill", title: "Privacy") {
                if let url = SupportLinks.privacy { openURL(url) }
            }
        }
        GlassSection {
            GlassLinkRow(icon: "doc.text.fill", title: "Acknowledgements", route: PanelRoute.acknowledgements)
            GlassDivider(inset: 54)
            GlassRow(icon: "map", title: "Map Data", detail: "© Mapbox © OpenStreetMap")
                .accessibilityElement(children: .combine)
            GlassDivider(inset: 54)
            GlassRow(icon: "cloud.sun", title: "Weather Data", detail: "Open-Meteo.com, CC BY 4.0")
                .accessibilityElement(children: .combine)
        }
        .sheet(item: $shareItem) { item in
            ShareSheet(fileURL: item.url)
                .ignoresSafeArea()
        }
    }
}

/// The licences of the bundled theme palettes, as shipped.
struct AcknowledgementsPage: View {
    /// Read once when the page opens, not from disk on every redraw.
    @State private var text: String = {
        guard let url = Bundle.main.url(forResource: "ACKNOWLEDGEMENTS", withExtension: "txt") else { return "" }
        do {
            // The licences are hard-wrapped at 80 columns; rejoin each paragraph so
            // it flows to the screen's width instead of breaking mid-sentence.
            let raw = try String(contentsOf: url, encoding: .utf8)
            return raw.components(separatedBy: "\n\n")
                .map { $0.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " ") }
                .joined(separator: "\n\n")
        } catch { return "" }
    }()

    var body: some View {
        Group {
            Text(text)
                .textRole(.caption)
                .foregroundStyle(HUDTheme.secondaryText)
                .frame(maxWidth: .infinity, alignment: .leading)
                .glassCard()
        }
        .pageScroll()
    }
}
