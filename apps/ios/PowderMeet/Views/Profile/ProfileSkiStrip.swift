import AppCore
import MapScene
import MeetSolver
import PowderMeetAPI
import SwiftUI

/// The ski pair across the Profile card: the skier's own skis, large, with
/// nothing written on them (the levels sit beside the name,
/// `ProfileLevels`). With a resort selected the pair glows green while this
/// phone's fix is live and red without one. The pair is the button to the ski
/// picker, as on Gear.
struct ProfileSkiStrip: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let gear = model.profile.map { GearDraft($0) }
        let highlight: SkiPairView.Highlight = {
            guard model.selectedResort != nil else { return .none }
            // A fix from an hour ago is not "on the mountain now".
            guard let fix = model.lastFix,
                  FriendSignal.classify(lastSeen: fix.capturedAt, now: Date()) == .live else { return .offMountain }
            return .onMountain
        }()
        return Button {
            model.openFloating(.skiPicker)
        } label: {
            SkiPairView(topLabel: "", bottomLabel: "", highlight: highlight, look: gear?.look ?? .house)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Your skis, \(gear?.label ?? "PowderMeet")")
        .accessibilityHint("Changes your skis")
    }
}

/// Two levels beside the name, one word each: on top the level picked in
/// Gear (what routing uses); under it, marked as coming from the stats, the
/// level the imported runs back (`ActivityHistory.backedAbility`), a dash
/// until a rated run is in the log.
struct ProfileLevels: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let picked = Ability(profileValue: model.profile?.ability ?? "intermediate")
        let backed = model.activity.history.backedAbility
        // Each level with the mark of where it comes from, the marks in one
        // column: the Gear sliders for the one picked, a chart for the one
        // the runs show. With no rated run there is no second line at all.
        Grid(alignment: .leading, horizontalSpacing: 6, verticalSpacing: 4) {
            GridRow {
                Image(systemName: "slider.horizontal.3")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(HUDTheme.secondaryText)
                Text(picked.label)
                    .textRole(.bodyEmph)
                    .foregroundStyle(HUDTheme.primaryText)
            }
            if let backed {
                GridRow {
                    Image(systemName: "chart.line.uptrend.xyaxis")
                        .font(.caption.weight(.semibold))
                    Text(backed.label)
                        .textRole(.bodyEmph)
                }
                .foregroundStyle(HUDTheme.secondaryText)
            }
        }
        .lineLimit(1)
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Level you picked: \(picked.label). "
            + (backed.map { "Level your runs show: \($0.label)." } ?? "No rated runs yet."))
    }
}
