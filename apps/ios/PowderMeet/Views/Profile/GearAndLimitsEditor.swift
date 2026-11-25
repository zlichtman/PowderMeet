import MeetSolver
import MountainCore
import PowderMeetAPI
import SwiftUI

// What the skier rides, their build and their limits, in three pieces that
// onboarding (`GearAndLimitsEditor`, on the opaque tier) and the Profile → Gear
// page (`ProfileGearPage`, in glass sections) share. They only edit the draft;
// saving is the caller's.

/// Onboarding's editor: the three pieces under their headers.
struct GearAndLimitsEditor: View {
    @Binding var draft: GearDraft

    var body: some View {
        VStack(spacing: 8) {
            SectionHeader("What you ride")
            GearRideFields(draft: $draft)

            SectionHeader("You · Private")
                .padding(.top, 10)
            GearBodyFields(draft: $draft)

            SectionHeader("Limits")
                .padding(.top, 10)
            GearLimitFields(draft: $draft)
            GlassFootnote(
                icon: "exclamationmark.triangle",
                text: "Runs steeper than your pitch limit, and anything you avoid, are never on your route. Your hardest run gives way only when there is no other way down, and the route says so first."
            )
        }
    }
}

/// Onboarding's ride, one clean choice: the chosen skis
/// drawn on their own tile with their name, a tap opening the ski list; then
/// the length (with type and waist for gear not picked by name).
struct GearRideFields: View {
    @Binding var draft: GearDraft
    @State private var showSkiPicker = false

    private var name: String {
        return draft.ski?.displayName ?? "PowderMeet ski"
    }

    private var detail: String? {
        draft.lengthCM.map { "\($0) cm" }
    }

    var body: some View {
        VStack(spacing: 8) {
            Button {
                showSkiPicker = true
            } label: { tile }
                .buttonStyle(PressableStyle())
                .accessibilityLabel("Your gear: \(name)")
                .accessibilityHint("Opens the ski list")

            if let discipline = draft.discipline {
                if draft.ski == nil {
                    HUDChoicePills(
                        choices: EquipmentType.allCases.map {
                            HUDChoicePills<EquipmentType>.Choice(value: $0, label: $0.shortLabel)
                        },
                        selection: draft.type
                    ) { draft.type = $0 }
                }
                HUDStepperRow(
                    label: "Length",
                    caption: "Steadier long, quicker short",
                    value: draft.lengthCM.map { "\($0) cm" },
                    onStep: { step in
                        draft.lengthCM = GearDraft.stepped(
                            draft.lengthCM, by: step, from: draft.startingLengthCM,
                            in: ProfileEquipment.lengthRangeCM
                        )
                    },
                    onClear: { draft.lengthCM = nil }
                )
                if discipline == .ski, draft.ski == nil {
                    HUDStepperRow(
                        label: "Waist width",
                        caption: "Narrow for groomers, wide for powder",
                        value: draft.waistMM.map { "\($0) mm" },
                        onStep: { step in
                            draft.waistMM = GearDraft.stepped(
                                draft.waistMM, by: step, from: 90, in: ProfileEquipment.waistRangeMM
                            )
                        },
                        onClear: { draft.waistMM = nil }
                    )
                }
            }
        }
        .sheet(isPresented: $showSkiPicker) {
            NavigationStack {
                SkiPickerSheet(draft: $draft)
                    .pushedPage("Your skis")
            }
            .modifier(MapSheetPresentation())
        }
    }

    /// The skis large, the name on one line, the swap mark.
    private var tile: some View {
        VStack(spacing: 12) {
            VStack(spacing: 6) {
                SkiBody(look: draft.look)
                SkiBody(look: draft.look)
            }
            .frame(maxWidth: 280)
            .frame(height: 56)
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(name)
                        .textRole(.bodyEmph)
                        .foregroundStyle(HUDTheme.primaryText)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    if let detail {
                        Text(detail)
                            .textRole(.label)
                            .foregroundStyle(HUDTheme.secondaryText)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                Label("Change", systemImage: "arrow.left.arrow.right")
                    .textRole(.label)
                    .fontWeight(.semibold)
                    .foregroundStyle(HUDTheme.accent)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(HUDGlass.well, in: Capsule())
            }
        }
        .padding(GlassLayout.cardPadding)
        .frame(maxWidth: .infinity)
        .background(HUDGlass.well, in: RoundedRectangle(cornerRadius: GlassLayout.innerRadius, style: .continuous))
        .contentShape(Rectangle())
    }
}

struct GearBodyFields: View {
    @Binding var draft: GearDraft

    var body: some View {
        VStack(spacing: 8) {
            HUDStepperRow(
                label: "Height",
                caption: "Sizes your length",
                value: draft.heightCM.map(UnitFormatter.height),
                onStep: { step in
                    let next = draft.heightCM.map { UnitFormatter.steppedHeight($0, by: step) } ?? 170
                    draft.heightCM = clamp(next, Profile.heightRangeCM)
                },
                onClear: { draft.heightCM = nil }
            )
            HUDStepperRow(
                label: "Weight",
                caption: "Glide on the flats",
                value: draft.weightKG.map(UnitFormatter.weight),
                onStep: { step in
                    let next = draft.weightKG.map { UnitFormatter.steppedWeight($0, by: step) } ?? 70
                    draft.weightKG = clamp(next, Profile.weightRangeKG)
                },
                onClear: { draft.weightKG = nil }
            )
            GlassFootnote(icon: "lock.fill", text: "Only you see height and weight. Friends never do.")
        }
    }

    private func clamp(_ value: Int, _ range: ClosedRange<Int>) -> Int {
        min(max(value, range.lowerBound), range.upperBound)
    }
}

/// The skier's own limits: hardest run, steepest pitch, what to avoid.
struct GearLimitFields: View {
    @Binding var draft: GearDraft

    var body: some View {
        VStack(spacing: 8) {
            GearCaption(text: "Hardest run")
            HUDChoicePills(
                choices: zip(GearDraft.ladder, ["Green", "Blue", "Black", "Double black"]).map { level, label in
                    HUDChoicePills<Difficulty>.Choice(value: level, label: label)
                },
                selection: draft.maxDifficulty
            ) { draft.maxDifficulty = $0 }

            HUDStepperRow(
                label: "Steepest pitch",
                caption: "Nothing steeper, unless it is the only way down",
                value: draft.maxPitchDeg.map { "\($0)°" },
                onStep: { step in
                    draft.maxPitchDeg = GearDraft.stepped(
                        draft.maxPitchDeg, by: step, from: 25, in: Profile.maxPitchRangeDeg
                    )
                },
                onClear: { draft.maxPitchDeg = nil }
            )

            GearCaption(text: "Never route me on")
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible())], spacing: 6) {
                ForEach(Avoidance.allCases, id: \.self) { choice in
                    HUDToggleChip(
                        label: choice.label, detail: choice.detail, isOn: draft.avoid.contains(choice)
                    ) {
                        if draft.avoid.contains(choice) {
                            draft.avoid.remove(choice)
                        } else {
                            draft.avoid.insert(choice)
                        }
                    }
                }
            }
        }
    }
}

/// A field label above a control.
struct GearCaption: View {
    let text: String

    var body: some View {
        Text(text)
            .textRole(.label)
            .foregroundColor(HUDTheme.secondaryText)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 4)
    }
}

private nonisolated extension EquipmentType {
    var shortLabel: String { self == .allMountain ? "All-mountain" : label }
}
