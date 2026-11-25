// The skill level as four run-colour choices (green, blue, black, double
// black): "comfortable up to and including this colour", mapped one to one
// onto the four tiers beginner, intermediate, advanced and expert. Onboarding
// and Profile use it.

import SwiftUI

// MARK: - SkillTier

/// One of the four canonical skill tiers. The `key` matches the string
/// stored in `profiles.skill_level` (and `UserProfile.skillLevel`),
/// so callers can pass the raw string and we resolve to a tier here.
struct SkillTier: Hashable, Identifiable {
    let key: String
    let label: String
    /// 1…4 — how many run-color cells light up. Beginner = 1 (greens
    /// only), Expert = 4 (everything including double blacks). Also
    /// used as the cumulative-fill index when rendering the chips.
    let level: Int

    var id: String { key }

    /// Single source of truth — both onboarding and profile read from here.
    /// Add or rename a tier in exactly one place; both surfaces follow.
    static let allTiers: [SkillTier] = [
        SkillTier(key: "beginner", label: "Beginner", level: 1),
        SkillTier(key: "intermediate", label: "Intermediate", level: 2),
        SkillTier(key: "advanced", label: "Advanced", level: 3),
        SkillTier(key: "expert", label: "Expert", level: 4),
    ]

    /// Default fallback when a stored skillLevel doesn't match any
    /// known tier. Intermediate is the safe middle so the solver
    /// behaves reasonably until the user re-picks.
    static let defaultTier: SkillTier = allTiers[1]

    /// Resolve a raw `skill_level` string back to a tier; falls back
    /// to `defaultTier` for unknown values (older rows, schema drift).
    static func tier(for key: String) -> SkillTier {
        allTiers.first(where: { $0.key == key }) ?? defaultTier
    }
}

// MARK: - SkillLevelPicker

/// The four run colours as one row of choices.
struct SkillLevelPicker: View {
    /// Current `skill_level` key (e.g. `"intermediate"`).
    let selection: String

    /// Fired when the user taps a tier. Caller persists.
    let onSelect: (String) -> Void

    /// The run colour each tier is comfortable up to.
    private static let runLabels = ["Green", "Blue", "Black", "Double black"]

    var body: some View {
        HUDChoicePills(
            choices: SkillTier.allTiers.map {
                HUDChoicePills<String>.Choice(value: $0.key, label: Self.runLabels[$0.level - 1])
            },
            selection: SkillTier.tier(for: selection).key,
            onSelect: onSelect
        )
        .accessibilityLabel("Skill level, \(SkillTier.tier(for: selection).label)")
    }
}
