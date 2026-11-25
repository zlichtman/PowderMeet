import AppCore
import Foundation
import PowderMeetAPI

/// Where a Debug build opens, from launch arguments, so any screen or state
/// can be reached for a screenshot without driving the UI. Release builds
/// ignore them.
///
/// - `-openSheet resorts | themes | icons | looks | skis | badges` (a floating list) or
///   `friends | activity | gear | settings` (a section in the floating panel)
/// - `-openRoute logs | import | blocked | developer | developer.dev1 (to 3) |
///   developer.time | developer.weather | developer.diagnostics | units |
///   deleteAccount | resetPassword | settings.account | settings.appearance |
///   settings.notifications | settings.location | settings.maps |
///   settings.about` (pushed on the section; opens its section if none is set)
/// - `-profilePanel YES`: the profile panel open over the map
/// - `-previewData YES`: signed out, the map screen with a made-up profile
///   (`-previewCrop YES` adds the photo crop screen)
/// - `-previewData YES -previewResort <id>` (`PreviewStage`): signed in as the
///   made-up profile on a private fake server on this phone, with that one
///   mountain copied from the live catalog, so `-meetState` and `-mapCard`
///   work without an account; `-previewSnow YES` makes the forecast snow
/// - `-openResort <id>`, `-mapCard run | lift | place | goto`, `-meetState
///   options | sent | active | ended`: a context-sheet state on the live
///   backend through developer testing (`DebugScript`); `-cardExpanded YES`
///   opens it swiped up
/// - `-debugTheme "Tokyo Night"`, `-debugMapLook satellite` (`ThemeManager`)
/// - `-debugOnboardingStep 1`, `-debugImport "/a.gpx|/b.slopes"` (with
///   `-debugImportDelay 8` to show the empty Activity first)
/// - `-demoCameraBearing 150`: frame captured routes facing the skiable fronts.
/// - The demo (`docs/DEMO-STORYBOARD.md`): `-previewWeather script` and the
///   `-demo…` arguments of `DemoCast`; `-placeMe`, `-placeFriend` and
///   `-stage blue` in `DebugScript`
nonisolated enum DebugLaunch {
    private static func string(_ key: String) -> String? {
        #if DEBUG
        UserDefaults.standard.string(forKey: key)
        #else
        nil
        #endif
    }

    private static func flag(_ key: String) -> Bool {
        #if DEBUG
        UserDefaults.standard.bool(forKey: key)
        #else
        false
        #endif
    }

    /// The floating list open on launch.
    static var picker: MapSheet? {
        switch string("openSheet")?.lowercased() {
        case "resorts", "resortpicker": .resortPicker
        case "themes": .themePicker
        case "icons": .iconPicker
        case "looks": .mapLookPicker
        case "skis": .skiPicker
        case "badges": .badgePicker
        default: nil
        }
    }

    /// The floating panel's pages open on launch: `-openSheet` names the
    /// section, `-openRoute` the page pushed on it (its section is implied).
    static var panelPath: [PanelRoute]? {
        let name = string("openSheet")?.lowercased()
        let section = name.flatMap(ProfilePage.init(rawValue:))
        guard let route else {
            return section.map { [.section($0)] }
        }
        let implied: ProfilePage = switch route {
        case .logs, .importReport: .activity
        case .blocked, .report: .friends
        default: .settings
        }
        var path: [PanelRoute] = [.section(section ?? implied)]
        // The page in between, where there is one.
        switch route {
        case .units: path.append(.settings(.appearance))
        case .deleteAccount, .resetPassword: path.append(.settings(.account))
        case .developerPage: path.append(.developer)
        default: break
        }
        return path + [route]
    }

    /// The page pushed on the section.
    private static var route: PanelRoute? {
        guard let name = string("openRoute") else { return nil }
        if name.lowercased().hasPrefix("developer.") {
            return developerPage(String(name.dropFirst("developer.".count)).lowercased()).map(PanelRoute.developerPage)
        }
        if name.hasPrefix("settings.") {
            return SettingsPage(rawValue: String(name.dropFirst("settings.".count))).map(PanelRoute.settings)
        }
        switch name.lowercased() {
        case "logs": return .logs
        case "import": return .importReport
        case "blocked": return .blocked
        case "developer": return .developer
        case "deleteaccount": return .deleteAccount
        case "resetpassword": return .resetPassword
        case "units": return .units
        default: return nil
        }
    }

    private static func developerPage(_ name: String) -> DeveloperPage? {
        switch name {
        case "time": return .time
        case "weather": return .weather
        case "diagnostics": return .diagnostics
        default:
            guard name.hasPrefix("dev"), let number = Int(name.dropFirst(3)),
                  let person = DeveloperSandbox.devPeople.first(where: { $0.number == number }) else { return nil }
            return .person(person.id)
        }
    }

    static var profilePanel: Bool { flag("profilePanel") }

    /// `-demoCapture YES`: the website's stills, without the Mapbox logo and
    /// ⓘ (the site carries the credit as text beside the image, as Mapbox
    /// allows for static images).
    static var demoCapture: Bool { flag("demoCapture") }

    /// `-demoMotion YES`: let the rehearsal skiers travel at real time during a capture.
    static var demoMotion: Bool { flag("demoMotion") }

    /// `-lockMeetCamera YES`: compare option routes from the same capture angle.
    static var lockMeetCamera: Bool { flag("lockMeetCamera") }

    /// `-previewData YES`: signed out, the map screen shows over the sign-in
    /// backdrop with a made-up profile, so the panel and its pages can be
    /// screenshot without an account. Nothing it shows is saved anywhere.
    static var previewData: Bool { flag("previewData") }

    /// `-previewCrop YES` with `-previewData`: the photo crop screen over a
    /// drawn picture.
    static var previewCrop: Bool { flag("previewCrop") }

    #if DEBUG
    static let previewProfile = Profile(
        id: UUID(uuidString: "00000000-0000-4000-8000-000000000001") ?? UUID(), displayName: "Alex Rivera",
        ability: "advanced", maxDifficulty: "black",
        equipment: ProfileEquipment(discipline: "ski", type: "all_mountain", lengthCM: 184, waistMM: 100),
        heightCM: 180, weightKG: 78)
    #endif

    static var cardExpanded: Bool { flag("cardExpanded") }

    /// `-debugImport "/path/a.gpx|/path/b.slopes"`: files to import once signed
    /// in, so the import flow can be walked in the simulator without Files.
    /// Split on `|` because export names carry commas ("January 14, 2026 - …").
    static var importPaths: [String] {
        (string("debugImport") ?? "").split(separator: "|").map(String.init)
    }

    /// `-debugImportDelay 8`: seconds after sign-in before `-debugImport` runs.
    static var importDelay: Double {
        #if DEBUG
        UserDefaults.standard.double(forKey: "debugImportDelay")
        #else
        0
        #endif
    }

    static var onboardingStep: Int {
        #if DEBUG
        UserDefaults.standard.integer(forKey: "debugOnboardingStep")
        #else
        0
        #endif
    }
}
