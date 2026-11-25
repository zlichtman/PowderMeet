import AppCore
import MeetSolver
import SwiftUI

/// One dev person (`specs/07-CLIENT.md` section 8): their level, a test
/// meet-up with them, and putting them on, moving them round or taking them
/// off the mountain.
struct DeveloperPersonPage: View {
    @Environment(DeveloperModel.self) private var developer
    let id: UUID

    private var name: String { DeveloperModel.name(of: id) }
    private var hasMountain: Bool { developer.app.resort?.ready != nil }
    private var isPlaced: Bool { developer.isPlaced(id) }

    var body: some View {
        Group {
            if let note = developer.note {
                ContextNote(icon: "info.circle.fill", text: note)
            }
            GlassSection("Level") {
                levelPicker.padding(GlassLayout.cardPadding)
            }
            if isPlaced {
                GlassSection("Meet-Up") {
                    GlassRow(icon: "figure.2", title: "Test Meet-Up", detail: developer.rehearsalLine(with: id)) {
                        PrimaryButton(
                            title: "Run", isLoading: developer.isRunningRehearsal && developer.rehearsalPartner == id,
                            isEnabled: hasMountain && !developer.isRunningRehearsal, fillsWidth: false
                        ) {
                            developer.runTestMeet(with: id)
                        }
                    }
                }
            }
            mapSection
        }
        .pageScroll()
    }

    private var mapSection: some View {
        GlassSection("Map") {
            if isPlaced {
                GlassNavRow(icon: "hand.tap.fill", title: "Move \(name)") { developer.beginPlacing(.dev(id)) }
                    .disabled(!hasMountain)
                GlassDivider(inset: 54)
                GlassNavRow(icon: "person.fill.xmark", title: "Remove \(name)", titleTint: HUDTheme.accentRed) {
                    developer.removeDevPerson(id)
                }
            } else {
                GlassNavRow(icon: "person.fill.badge.plus", title: "Put \(name) on the Mountain") {
                    developer.putBack(id)
                }
                .disabled(!hasMountain)
                GlassDivider(inset: 54)
                GlassNavRow(icon: "hand.tap.fill", title: "Place by Tapping the Map") {
                    developer.beginPlacing(.dev(id))
                }
                .disabled(!hasMountain)
            }
        }
    }

    /// The app's four levels. Segmented while it fits; a menu at the largest
    /// text sizes or on the narrowest phones.
    private var levelPicker: some View {
        let selection = Binding(
            get: { developer.level(of: id) },
            set: { developer.setLevel($0, for: id) }
        )
        let picker = { (label: String) in
            Picker(label, selection: selection) {
                ForEach(Ability.allCases, id: \.self) { level in
                    Text(level.label).tag(level)
                }
            }
        }
        return ViewThatFits(in: .horizontal) {
            picker("\(name)'s Level")
                .pickerStyle(.segmented)
            HStack {
                Text("Level").textRole(.body).foregroundStyle(HUDTheme.primaryText)
                Spacer(minLength: 8)
                picker("\(name)'s Level").pickerStyle(.menu)
            }
        }
    }
}
