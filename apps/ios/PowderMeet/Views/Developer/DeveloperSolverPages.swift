import AppCore
import SwiftUI

/// The solver's time of day at the mountain (`specs/07-CLIENT.md` section 8):
/// half-hour steps, presets on the lift day, and whether lifts load then.
struct DeveloperTimePage: View {
    @Environment(DeveloperModel.self) private var developer

    var body: some View {
        Group {
            GlassSection("Clock") {
                HUDStepperRow(
                    label: "At the Mountain", caption: caption, boxed: false, value: developer.solveTimeText,
                    onStep: { developer.stepPretendTime($0) }, onClear: { developer.resetPretendTime() })
                GlassDivider()
                GlassRow(icon: "cablecar.fill", title: "Lifts", detail: developer.liftLine)
                    .accessibilityElement(children: .combine)
            }
            GlassSection("Presets") {
                ForEach(SolverTimePreset.allCases, id: \.self) { preset in
                    DeveloperChoiceRow(
                        title: preset.label, value: DeveloperModel.clockText(preset.minuteOfDay(on: developer.liftDay)),
                        isSelected: developer.currentPreset == preset
                    ) { developer.jump(to: preset) }
                    GlassDivider()
                }
                DeveloperChoiceRow(title: "Real Time", isSelected: developer.pretendTime == .real) {
                    developer.resetPretendTime()
                }
            }
        }
        .pageScroll()
    }

    private var caption: String {
        guard developer.pretendTime != .real else { return "Real time" }
        return developer.pretendTimeIsAhead
            ? "Pretend, later than now: lift status and weather may read as old"
            : "Pretend"
    }
}

/// The weather this phone's solver and weather card read in place of the
/// forecast (`specs/07-CLIENT.md` section 8).
struct DeveloperWeatherPage: View {
    @Environment(DeveloperModel.self) private var developer

    var body: some View {
        GlassSection("Conditions") {
            ForEach(Array(PretendWeather.allCases.enumerated()), id: \.element) { index, weather in
                if index > 0 { GlassDivider() }
                DeveloperChoiceRow(
                    title: weather.label, detail: weather.detail, isSelected: developer.pretendWeather == weather
                ) { developer.setPretendWeather(weather) }
            }
        }
        .pageScroll()
    }
}

/// One choice of a list: the row, a trailing value, a check on the one in use
/// (as Units does).
private struct DeveloperChoiceRow: View {
    let title: String
    var detail: String?
    var value: String?
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            GlassRow(icon: nil, title: title, detail: detail) {
                HStack(spacing: 8) {
                    if let value { GlassValue(text: value) }
                    if isSelected {
                        Image(systemName: "checkmark")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(HUDTheme.accent)
                    }
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
