//
//  PrimaryButton.swift
//  PowderMeet
//
//  One source of truth for the full-width accent CTA that was
//  copy-pasted (with divergent corner radius 8/10/12, font 12/13,
//  padding) across SignInForm, SignUpForm, AuthView, PasswordReset,
//  NewPasswordSheet, OnboardingView, PowderMeetActionButton.
//
//  Standard: cornerRadius 10 (continuous), vertical padding 14,
//  full-width, `.hudType(.bodyEmph)` label (theme-aware face) with
//  CTA tracking, `spinnerForm` loading tint, disabled = 0.4 opacity.
//  `tint:` lets a caller (PowderMeetActionButton's 5-state logic)
//  drive the fill without re-implementing the chrome.
//

import SwiftUI

struct PrimaryButton: View {
    enum Kind {
        case filled   // accent fill, white label — primary CTA
        case quiet    // card fill, accent label — secondary action
    }

    let title: String
    var kind: Kind = .filled
    var isLoading: Bool = false
    var isEnabled: Bool = true
    /// Fill (filled) or label+border (quiet) color. Defaults to the
    /// theme accent; PowderMeetActionButton injects its state color.
    var tint: Color = HUDTheme.accent
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if isLoading {
                    ProgressView()
                        .tint(kind == .filled ? HUDTheme.spinnerForm : tint)
                        .scaleEffect(0.6)
                        .accessibilityHidden(true)
                }
                Text(title)
                    .hudType(.bodyEmph)
                    .tracking(1.6)
                    .foregroundColor(kind == .filled ? .white : tint)
                    .multilineTextAlignment(.center)
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, minHeight: 48)
            // Decorative shapes must not determine layout: a flexible
            // ZStack background consumed all available form height, while
            // large wrapped labels had no padding inside its painted edge.
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(fill))
            .overlay {
                if kind == .quiet {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(tint.opacity(0.45), lineWidth: 1)
                }
            }
            // The painted shape and the semantic hit target are the same
            // full-width surface. A label-only hit region made large CTAs
            // respond only when the glyphs themselves were tapped.
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .frame(maxWidth: .infinity)
        .buttonStyle(.plain)
        .disabled(!isEnabled || isLoading)
        .opacity(isEnabled ? 1.0 : 0.62)
        .accessibilityLabel(title)
        .accessibilityValue(isLoading ? "In progress" : "")
    }

    private var fill: Color {
        switch kind {
        case .filled: return tint
        case .quiet:  return HUDTheme.cardBackground
        }
    }
}
