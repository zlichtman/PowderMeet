//
//  HUDSectionHeader.swift
//  PowderMeet
//
//  Single source of truth for the "label + horizontal rule" section
//  divider used across the app. Every screen that groups content into
//  sections (Profile tabs, ResortPickerSheet, FriendsSheet, MeetView,
//  SkiPickerSheet, …) was inlining its own version with subtly
//  different fonts, opacities, and spacings. They\'re unified here so
//  there\'s one design to retune later — and so the next "this divider
//  looks different" regression is impossible by construction.
//

import SwiftUI

/// Standard section divider: monospaced label on the left, thin
/// horizontal rule filling the remaining width on the right.
///
/// Pass an `accent` to tint the label (used for sectioning where the
/// header carries semantic weight — "WANTS TO CONNECT" in friends,
/// region headers in the resort picker, etc.). Default is the
/// secondaryText muted look.
///
/// Set `accentDot: true` to prefix the label with a 4pt filled circle
/// in the accent color — used by the friends list to read at a glance
/// (amber dot for pending, accent dot for accepted friends).
struct HUDSectionHeader: View {
    let label: String
    var accent: Color? = nil
    var accentDot: Bool = false

    var body: some View {
        HStack(spacing: 6) {
            if accentDot, let accent {
                Circle()
                    .fill(accent)
                    .frame(width: 4, height: 4)
            }
            Text(label)
                .hudType(.label)
                .foregroundColor(
                    accentDot
                        ? HUDTheme.secondaryText.opacity(0.5)
                        : (accent?.opacity(0.6) ?? HUDTheme.secondaryText.opacity(0.5))
                )
                .tracking(accentDot ? 1.5 : 2)
            Rectangle()
                .fill(HUDTheme.cardBorder)
                .frame(height: 0.5)
        }
    }
}

#if DEBUG
#Preview {
    VStack(spacing: 18) {
        HUDSectionHeader(label: "CALIBRATION")
        HUDSectionHeader(label: "WANTS TO CONNECT", accent: HUDTheme.accentAmber)
        HUDSectionHeader(label: "YOUR FRIENDS · 12", accent: HUDTheme.accent)
        HUDSectionHeader(label: "DATA")
    }
    .padding()
    .background(HUDTheme.mapBackground)
}
#endif
