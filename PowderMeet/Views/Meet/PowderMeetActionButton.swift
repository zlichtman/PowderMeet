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
    let isNavigable: Bool
    /// Pre-release only: the result is a strict solve on a preview map and
    /// may be sent as a clearly labeled test meetup (`PreviewMeetupPolicy`).
    var isTestSendable: Bool = false
    let hasSelection: Bool
    let isSolving: Bool
    let requestSent: Bool
    let action: () -> Void

    private var canSend: Bool { isNavigable || isTestSendable }

    private var isArmed: Bool {
        hasFriend && hasResult && canSend && hasSelection && !isSolving && !requestSent
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
        } else if !canSend {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 14, weight: .bold))
            label("PREVIEW ONLY — NO SAFE LIVE ROUTE", size: 11)
        } else if !hasSelection {
            Image(systemName: "hand.tap.fill")
                .font(.system(size: 14, weight: .bold))
            label("SELECT A MEETING POINT", size: 12)
        } else if !isNavigable {
            Image(systemName: "testtube.2")
                .font(.system(size: 14, weight: .bold))
            label("SEND TEST MEETUP · PREVIEW MAP", size: 11)
        } else {
            Image(systemName: "bolt.fill")
                .font(.system(size: 14, weight: .bold))
            Text("POWDERMEET")
                .hudType(.metric)
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
        if hasResult && !isNavigable { return HUDTheme.accentAmber }
        if isArmed || (hasFriend && hasResult && hasSelection) { return .white }
        return HUDTheme.secondaryText.opacity(0.5)
    }

    // A sendable test meetup keeps the amber "not live" palette, with a
    // stronger fill so it still reads as an armed button.
    private var background: Color {
        if requestSent { return HUDTheme.accentGreen.opacity(0.12) }
        if isArmed && !isNavigable { return HUDTheme.accentAmber.opacity(0.22) }
        if hasResult && !isNavigable { return HUDTheme.accentAmber.opacity(0.10) }
        if hasFriend && hasResult && isNavigable && hasSelection { return HUDTheme.accent }
        return HUDTheme.cardBackground
    }

    private var border: Color {
        if requestSent { return HUDTheme.accentGreen.opacity(0.4) }
        if isArmed && !isNavigable { return HUDTheme.accentAmber }
        if hasResult && !isNavigable { return HUDTheme.accentAmber.opacity(0.45) }
        if hasFriend && hasResult && isNavigable && hasSelection { return HUDTheme.accent }
        return HUDTheme.cardBorder
    }
}
