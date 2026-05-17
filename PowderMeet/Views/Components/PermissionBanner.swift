//
//  PermissionBanner.swift
//  PowderMeet
//
//  Shown when the user granted only WhenInUse — without Always, iOS
//  suspends our background location updates the moment the screen
//  locks (phone in pocket on the chairlift). Without this surface
//  the user sees friends "go offline" with no explanation. Tap
//  deep-links to iOS Settings rather than re-prompting in-app —
//  iOS only shows the system Always prompt once, after that the
//  user has to flip it manually in Settings anyway.
//

import SwiftUI
import UIKit

struct PermissionBanner: View {
    var body: some View {
        Button {
            if let url = URL(string: UIApplication.openSettingsURLString) {
                UIApplication.shared.open(url)
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "location.slash.fill")
                    .font(.system(size: 11))
                Text("BACKGROUND LOCATION OFF — TAP TO FIX")
                    .hudType(.label)
                    .tracking(0.8)
            }
            .foregroundColor(HUDTheme.accentAmber)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .background(HUDTheme.accentAmber.opacity(0.10))
            .overlay(
                Rectangle()
                    .frame(height: 0.5)
                    .foregroundColor(HUDTheme.accentAmber.opacity(0.35)),
                alignment: .bottom
            )
        }
        .buttonStyle(.plain)
    }
}
