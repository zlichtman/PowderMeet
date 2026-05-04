//
//  PowderMeetActionButton.swift
//  PowderMeet
//
//  Pinned-bottom action button for the Meet tab. Cycles label /
//  styling through the user's progress: "SELECT A FRIEND" → "TAP
//  FRIEND TO SOLVE" → "SELECT A MEETING POINT" → "POWDERMEET" →
//  "REQUEST SENT". Disabled in every non-armed state. Extracted from
//  `MeetView` so the cycling label/style logic doesn't bloat the
//  parent's body type-checker budget.
//

import SwiftUI

struct PowderMeetActionButton: View {
    let hasFriend: Bool
    let hasResult: Bool
    let hasSelection: Bool
    let isSolving: Bool
    let requestSent: Bool
    let action: () -> Void

    private var isArmed: Bool {
        hasFriend && hasResult && hasSelection && !isSolving && !requestSent
    }

    var body: some View {
        Button {
            guard isArmed else { return }
            action()
        } label: {
            HStack(spacing: 10) {
                content
            }
            .foregroundColor(foreground)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(background)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(border, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .disabled(!isArmed)
    }

    @ViewBuilder
    private var content: some View {
        if isSolving {
            ProgressView()
                .tint(HUDTheme.spinnerForm)
                .scaleEffect(0.7)
            label("FINDING ROUTES...", size: 12)
        } else if requestSent {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 14, weight: .bold))
            label("REQUEST SENT", size: 12)
        } else if !hasFriend {
            Image(systemName: "person.fill.questionmark")
                .font(.system(size: 14, weight: .bold))
            label("SELECT A FRIEND", size: 12)
        } else if !hasResult {
            Image(systemName: "point.topleft.down.to.point.bottomright.curvepath")
                .font(.system(size: 14, weight: .bold))
            label("TAP FRIEND TO SOLVE", size: 12)
        } else if !hasSelection {
            Image(systemName: "hand.tap.fill")
                .font(.system(size: 14, weight: .bold))
            label("SELECT A MEETING POINT", size: 12)
        } else {
            Image(systemName: "bolt.fill")
                .font(.system(size: 14, weight: .bold))
            Text("POWDERMEET")
                .font(.system(size: 14, weight: .black, design: .monospaced))
                .tracking(2)
            Image(systemName: "bolt.fill")
                .font(.system(size: 14, weight: .bold))
        }
    }

    private func label(_ text: String, size: CGFloat) -> some View {
        Text(text)
            .font(.system(size: size, weight: .bold, design: .monospaced))
            .tracking(1.5)
    }

    private var foreground: Color {
        if requestSent { return HUDTheme.accentGreen }
        if isSolving { return HUDTheme.secondaryText }
        if isArmed || (hasFriend && hasResult && hasSelection) { return .white }
        return HUDTheme.secondaryText.opacity(0.5)
    }

    private var background: Color {
        if requestSent { return HUDTheme.accentGreen.opacity(0.12) }
        if hasFriend && hasResult && hasSelection { return HUDTheme.accent }
        return HUDTheme.cardBackground
    }

    private var border: Color {
        if requestSent { return HUDTheme.accentGreen.opacity(0.4) }
        if hasFriend && hasResult && hasSelection { return HUDTheme.accent }
        return HUDTheme.cardBorder
    }
}
