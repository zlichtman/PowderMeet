//
//  HUDDoneButton.swift
//  PowderMeet
//
//  Top-right "DONE" button used by every non-destructive sheet
//  (ResortPicker, PasswordReset, FriendSearch, …). One source of
//  truth for the styling — same font weight, padding, background,
//  corner radius across the app, and one place to retune later.
//

import SwiftUI

/// Standard top-right DONE button for sheet headers. Reads the
/// dismiss action from the environment, so callers don't pass an
/// explicit closure — drop it into a sheet's header `HStack` next
/// to a `Spacer` and you're done.
///
/// For destructive flows (account deletion, etc.) use a footer
/// CANCEL button pattern instead — the dismiss verb itself
/// signals intent on those screens.
struct HUDDoneButton: View {
    @Environment(\.dismiss) private var dismiss

    var label: String = "DONE"

    var body: some View {
        Button { dismiss() } label: {
            Text(label)
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundColor(HUDTheme.accent)
                .tracking(1.5)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(HUDTheme.cardBackground)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(HUDTheme.cardBorder, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }
}
