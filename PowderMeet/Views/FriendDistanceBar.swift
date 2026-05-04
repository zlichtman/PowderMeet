//
//  FriendDistanceBar.swift
//  PowderMeet
//
//  Horizontal strip above the timeline listing friends currently on
//  the same resort, sorted closest → farthest. Each chip shows
//  display name + straight-line distance. No bearing arrow — the
//  map already shows the dots; this bar just summarizes "who's
//  near, who's far" so the user can scan it without panning.
//
//  Replaces the floating per-friend off-screen chips that pointed
//  toward off-frame friends; that pattern competed with the route
//  overlay and didn't aggregate the picture across friends. The
//  bar fits cleanly above the timeline / weather scrubber.
//

import SwiftUI

struct FriendDistanceBar: View {
    let items: [Item]

    struct Item: Identifiable, Equatable {
        let id: UUID
        let name: String
        let distanceMeters: Double
    }

    var body: some View {
        // Render nothing when nobody's nearby — the timeline below
        // gets its full height back. Empty bar hairline would be
        // visual noise.
        if items.isEmpty {
            EmptyView()
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(items) { item in
                        chip(for: item)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            }
            .background(HUDTheme.headerBackground)
            .overlay(
                Rectangle()
                    .fill(HUDTheme.cardBorder.opacity(0.5))
                    .frame(height: 0.5),
                alignment: .top
            )
        }
    }

    private func chip(for item: Item) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(HUDTheme.routeSkierB)
                .frame(width: 6, height: 6)

            Text(item.name.uppercased())
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundColor(HUDTheme.primaryText)
                .tracking(0.6)
                .lineLimit(1)

            Text(formatDistance(item.distanceMeters))
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundColor(HUDTheme.secondaryText)
                .tracking(0.4)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(HUDTheme.cardBackground.opacity(0.85))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(HUDTheme.cardBorder.opacity(0.4), lineWidth: 0.5)
        )
    }

    /// Distance formatting: meters under 1km, one-decimal km up to
    /// 10km, integer km above. Matches the casual "how far is X" feel.
    private func formatDistance(_ meters: Double) -> String {
        if meters < 1000 {
            return "\(Int(meters.rounded())) M"
        }
        let km = meters / 1000
        if km < 10 {
            return String(format: "%.1f KM", km)
        }
        return "\(Int(km.rounded())) KM"
    }
}
