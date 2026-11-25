import AppCore
import Foundation

// Where the user is in the one-screen app (`specs/13-APP-MAP.md`): the map is
// always underneath; the floating panel opens over its bottom (the profile
// panel, then the section pages pushed on it, `AppModel.panelPath`); at most
// one pick-one list floats over everything (`AppModel.floatingPicker`).
// Notifications and launch arguments set these values, so every screen can be
// reached without tapping.

/// The four sections of the profile panel. Each continues in the same
/// floating space, as glass bubbles over the map.
nonisolated enum ProfilePage: String, Sendable, Hashable, CaseIterable {
    case friends, activity, gear, settings

    var title: String { rawValue.capitalized }

    var icon: String {
        switch self {
        case .friends: "person.2.fill"
        case .activity: "figure.skiing.downhill"
        case .gear: "slider.horizontal.3"
        case .settings: "gearshape.fill"
        }
    }
}

/// A pick-one list floating over the map (`FloatingPicker`).
nonisolated enum MapSheet: Sendable, Hashable, Identifiable {
    case resortPicker, themePicker, iconPicker, skiPicker, mapLookPicker, meetPlacePicker, goToPicker, badgePicker

    var id: Self { self }
}

/// A page of the floating panel, pushed over the profile panel, with a back
/// control to the level above.
nonisolated enum PanelRoute: Sendable, Hashable {
    case section(ProfilePage)
    case friendCard(UUID)
    case blocked
    case report(ReportTarget)
    case logs
    case runDetail(ActivityHistory.Run)
    case importReport
    case settings(SettingsPage)
    case units
    case acknowledgements
    case deleteAccount
    case resetPassword
    case developer
    case developerPage(DeveloperPage)
}

/// The Dev page's own pages (`specs/13-APP-MAP.md` section 3).
nonisolated enum DeveloperPage: Sendable, Hashable {
    case person(UUID)
    case time, weather, diagnostics
}

/// Settings' rows, each a page of its own.
nonisolated enum SettingsPage: String, Sendable, Hashable, CaseIterable {
    case account, appearance, notifications, location, maps, about

    var title: String {
        switch self {
        case .account: "Account"
        case .appearance: "Appearance"
        case .notifications: "Notifications"
        case .location: "Permissions"
        case .maps: "Maps"
        case .about: "About"
        }
    }

    var icon: String {
        switch self {
        case .account: "person.crop.circle.fill"
        case .appearance: "paintpalette.fill"
        case .notifications: "bell.badge.fill"
        case .location: "hand.raised.fill"
        case .maps: "map.fill"
        case .about: "info.circle.fill"
        }
    }
}
