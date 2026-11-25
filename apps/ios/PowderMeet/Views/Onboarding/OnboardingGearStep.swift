import MeetSolver
import MountainCore
import SwiftUI

/// Second step: what you ride and where you will not go. Everything here can
/// be left as it is and changed later in Profile → GEAR.
struct OnboardingGearStep: View {
    @Binding var skillLevel: String
    @Binding var draft: GearDraft

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 14) {
                Spacer().frame(height: 12)

                Text("Your gear and limits")
                    .textRole(.title)
                    .foregroundColor(HUDTheme.primaryText)

                VStack(alignment: .leading, spacing: 8) {
                    Text("Skill level")
                        .textRole(.caption)
                        .foregroundColor(HUDTheme.secondaryText)
                    SkillLevelPicker(selection: skillLevel, onSelect: { skillLevel = $0 })
                }
                .padding(.horizontal, 20)

                GearAndLimitsEditor(draft: $draft)
                    .padding(.horizontal, 20)

                Spacer(minLength: 8)
            }
        }
    }
}
