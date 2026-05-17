//
//  RollingNumber.swift
//  PowderMeet
//
//  The casino "spin-down" effect for stat numerals. On first
//  appearance the digits roll up from zero to the real value.
//
//  Implemented with SwiftUI's `.contentTransition(.numericText())`
//  driving a single `Text` (not hand-built digit drums): the digits
//  visibly roll, but it stays a `Text`, so the stat tile's existing
//  `lineLimit(1)` + `minimumScaleFactor(0.5)` still scale it as a
//  unit (a custom HStack of drums would NOT scale — that was the
//  flagged risk). Lower risk, same UX.
//
//  The value string ("12.4 MPH", "1,240 FT", "—") is shown verbatim
//  as the final state; the rolled-FROM state is the same string with
//  every digit zeroed ("00.0 MPH"), so units/separators stay put and
//  only the numerals spin. No digits (or "—") → plain static Text.
//  Reduce Motion → render the final value immediately, no roll.
//  One-shot: tab away/back never re-spins.
//

import SwiftUI

struct RollingNumber: View {
    let text: String
    var color: Color = HUDTheme.textPrimary

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
            .hudType(.metric)
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
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    withAnimation(.spring(response: 0.85, dampingFraction: 0.78)) {
                        shown = text
                    }
                }
            }
            // If the underlying stat changes after first roll (live
            // recompute), reflect it with the same rolling transition.
            .onChange(of: text) { _, newValue in
                guard didRoll else { return }
                withAnimation(.spring(response: 0.6, dampingFraction: 0.85)) {
                    shown = newValue
                }
            }
    }
}
