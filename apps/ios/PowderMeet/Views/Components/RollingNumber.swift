// A stat's value that rolls up from zero on first appearance: one `Text`
// with `.contentTransition(.numericText())`, so the stat box's
// `lineLimit(1)` and `minimumScaleFactor` still scale it as a unit. The
// value ("12.4 mph", "1,240 ft", "—") is the final state; the starting state
// is the same string with every digit zeroed, so units and separators stay
// put. No digits shows the text as it is; Reduce Motion shows the final value
// at once. It rolls once; coming back to the view does not roll it again.

import SwiftUI

struct RollingNumber: View {
    let text: String
    var color: Color = HUDTheme.primaryText

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown: String = ""
    @State private var didRoll = false

    /// True when there's something to animate (at least one digit).
    private var hasDigits: Bool { text.contains(where: \.isNumber) }

    /// `text` with every digit replaced by "0" — the roll's start
    /// frame. Units, ".", "," and "—" are preserved.
    private var zeroed: String {
        String(text.map { $0.isNumber ? "0" : $0 })
    }

    var body: some View {
        Text(shown.isEmpty ? text : shown)
            .textRole(.metric)
            .foregroundColor(color)
            .contentTransition(.numericText())
            .onAppear {
                guard !didRoll else { return }
                didRoll = true
                guard hasDigits, !reduceMotion else {
                    shown = text
                    return
                }
                shown = zeroed
                // Brief beat so the zeroed frame is seen, then roll.
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(50))
                    withAnimation(.spring(response: 0.85, dampingFraction: 0.78)) {
                        shown = text
                    }
                }
            }
            .onChange(of: text) { _, newValue in
                guard didRoll else { return }
                withAnimation(reduceMotion ? nil : .spring(response: 0.6, dampingFraction: 0.85)) {
                    shown = newValue
                }
            }
    }
}
