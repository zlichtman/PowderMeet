//
//  SkillLevelPicker.swift
//  PowderMeet
//
//  Single condensed card for skill-tier selection. Displayed below the
//  activity-import row in both Onboarding and Profile because it's a
//  fallback for users who haven't imported real run data — four giant
//  cards for a backup default felt over-weight for what it represents.
//
//  UX shape: a row of four run-color chips (green / blue / black /
//  double black) plus the resolved tier label and one-line description.
//  Tap a chip to set "I'm comfortable up to and including this color".
//  Cells fill cumulatively (tap blue → green + blue lit). The
//  highest-lit color maps 1:1 onto the canonical four-tier ladder
//  beginner / intermediate / advanced / expert via `SkillTier.level`.
//

import SwiftUI

// MARK: - SkillTier

/// One of the four canonical skill tiers. The `key` matches the string
/// stored in `profiles.skill_level` (and `UserProfile.skillLevel`),
/// so callers can pass the raw string and we resolve to a tier here.
struct SkillTier: Hashable, Identifiable {
    let key: String
    let label: String
    let desc: String
    /// 1…4 — how many run-color cells light up. Beginner = 1 (greens
    /// only), Expert = 4 (everything including double blacks). Also
    /// used as the cumulative-fill index when rendering the chips.
    let level: Int

    var id: String { key }

    /// Single source of truth — both onboarding and profile read from here.
    /// Add or rename a tier in exactly one place; both surfaces follow.
    static let allTiers: [SkillTier] = [
        SkillTier(key: "beginner",     label: "BEGINNER",     desc: "STICKING TO GREENS, LEARNING THE BASICS",  level: 1),
        SkillTier(key: "intermediate", label: "INTERMEDIATE", desc: "COMFORTABLE ON BLUES, TRYING SOME BLACKS", level: 2),
        SkillTier(key: "advanced",     label: "ADVANCED",     desc: "CHARGING BLACKS, HITTING THE PARK",        level: 3),
        SkillTier(key: "expert",       label: "EXPERT",       desc: "DOUBLE BLACKS, BACKCOUNTRY, SEND IT",      level: 4),
    ]

    /// Default fallback when a stored skillLevel doesn't match any
    /// known tier. Intermediate is the safe middle so the solver
    /// behaves reasonably until the user re-picks.
    static let defaultTier: SkillTier = allTiers[1]

    /// Resolve a raw `skill_level` string back to a tier; falls back
    /// to `defaultTier` for unknown values (legacy rows, schema drift).
    static func tier(for key: String) -> SkillTier {
        allTiers.first(where: { $0.key == key }) ?? defaultTier
    }
}

// MARK: - SkillLevelPicker

/// Single horizontal card. Top row shows the resolved tier name on the
/// right; the four colored cells beneath toggle the level; description
/// rides at the bottom.
struct SkillLevelPicker: View {
    /// Current `skill_level` key (e.g. `"intermediate"`).
    let selection: String

    /// Fired when the user taps a tier cell. Caller persists.
    let onSelect: (String) -> Void

    private var currentTier: SkillTier { SkillTier.tier(for: selection) }

    var body: some View {
        // One short row: 4 abbreviated pills + the selected tier's
        // full label (color word + checkmark) inline. Compact enough
        // to match the original picker's height (~36pt) while
        // staying text-only per the user's "no color fills" rule.
        HStack(spacing: 4) {
            ForEach(SkillTier.allTiers) { tier in
                Button { onSelect(tier.key) } label: {
                    pill(for: tier, isSelected: tier.key == currentTier.key)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(tier.label) — \(Self.runLabels[tier.level - 1])")
                .accessibilityAddTraits(tier.key == currentTier.key ? [.isSelected] : [])
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 6)
        .background(HUDTheme.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(HUDTheme.cardBorder, lineWidth: 1)
        )
    }

    /// Three-letter color-word abbreviations, one per tier. Fixed-
    /// width labels so every pill renders the same size whether
    /// selected or not.
    private static let runLabels = ["GRN", "BLU", "BLK", "2BLK"]

    @ViewBuilder
    private func pill(for tier: SkillTier, isSelected: Bool) -> some View {
        let idx = tier.level - 1
        Text(Self.runLabels[idx])
            .font(.system(size: 10, weight: .bold, design: .monospaced))
            .foregroundColor(isSelected ? .white : HUDTheme.primaryText)
            .tracking(0.8)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isSelected ? HUDTheme.accent : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(isSelected ? Color.clear : HUDTheme.cardBorder, lineWidth: 0.5)
            )
            .contentShape(Rectangle())
    }
}
