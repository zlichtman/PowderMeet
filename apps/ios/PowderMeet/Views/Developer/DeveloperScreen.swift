import AppCore
import SwiftUI

/// Settings → Dev (`specs/07-CLIENT.md` section 8), on the live backend: one
/// short page of switches and rows, each dev person, the solver's time and
/// weather and the diagnostics on a page of their own. Debug and TestFlight
/// builds only. The buttons that need the map close the panel themselves
/// (`DeveloperModel`).
struct DeveloperScreen: View {
    @Environment(DeveloperModel.self) private var developer

    private var hasMountain: Bool { developer.app.resort?.ready != nil }

    var body: some View {
        Group {
            if let note = developer.note {
                ContextNote(icon: "info.circle.fill", text: note)
            }
            mountainSection
            peopleSection
            solverSection
            GlassSection {
                GlassLinkRow(
                    icon: "waveform.path.ecg", title: "Diagnostics", value: developer.diagnosticsSummary,
                    route: .developerPage(.diagnostics))
            }
        }
        .pageScroll()
        .task {
            developer.loadMountains()
            await developer.keepDiagnosticsFresh()
        }
    }

    // MARK: Mountain and me

    private var mountainSection: some View {
        GlassSection("Mountain") {
            // The resort picker, floating over the map, opens any published mountain.
            GlassNavRow(icon: "mountain.2.fill", title: developer.resortName ?? "No Mountain Open", value: "Change") {
                developer.app.openFloating(.resortPicker)
            }
            GlassDivider(inset: 54)
            GlassToggleRow(
                icon: "location.fill", title: "Teleport Me",
                isOn: Binding(get: { developer.isTeleported }, set: { developer.setTeleported($0) }),
                isEnabled: hasMountain || developer.isTeleported)
            if developer.isTeleported {
                GlassDivider(inset: 54)
                GlassNavRow(icon: "hand.tap.fill", title: "Move Me") { developer.beginPlacing(.me) }
                    .disabled(!hasMountain)
                GlassDivider(inset: 54)
                GlassToggleRow(
                    icon: "person.2.fill", title: "Friends See My Teleported Position",
                    detail: "For two test accounts meeting from home.",
                    isOn: Binding(get: { developer.sharesTeleport }, set: { developer.setSharesTeleport($0) }))
            }
        }
    }

    // MARK: Dev people

    private var peopleSection: some View {
        GlassSection("People") {
            GlassToggleRow(
                icon: "person.3.fill", title: "Show Dev People",
                isOn: Binding(get: { developer.showsDevPeople }, set: { developer.setShowsDevPeople($0) }),
                isEnabled: hasMountain || developer.showsDevPeople)
            if developer.showsDevPeople {
                ForEach(developer.devPeople) { person in
                    GlassDivider(inset: 54)
                    GlassLinkRow(
                        icon: "person.fill", title: DeveloperModel.name(of: person.id),
                        detail: developer.summary(of: person.id), route: .developerPage(.person(person.id)))
                }
                GlassDivider(inset: 54)
                GlassNavRow(icon: "shuffle", title: "Shuffle") {
                    developer.shuffleDevPeople()
                }
                .disabled(developer.placedPeople.isEmpty)
            }
        }
    }

    // MARK: Solver

    private var solverSection: some View {
        GlassSection("Solver") {
            GlassLinkRow(
                icon: "clock.fill", title: "Time", detail: hasMountain ? developer.liftLine : nil,
                value: developer.timeValue, route: .developerPage(.time))
            GlassDivider(inset: 54)
            GlassLinkRow(
                icon: "cloud.sun.fill", title: "Weather", value: developer.pretendWeather.label,
                route: .developerPage(.weather))
        }
    }
}

/// A page pushed from the Dev page.
struct DeveloperSubpage: View {
    let page: DeveloperPage

    var body: some View {
        switch page {
        case .person(let id): DeveloperPersonPage(id: id)
        case .time: DeveloperTimePage()
        case .weather: DeveloperWeatherPage()
        case .diagnostics: DeveloperDiagnosticsPage()
        }
    }
}

extension DeveloperPage {
    var title: String {
        switch self {
        case .person(let id): DeveloperModel.name(of: id)
        case .time: "Time"
        case .weather: "Weather"
        case .diagnostics: "Diagnostics"
        }
    }
}
