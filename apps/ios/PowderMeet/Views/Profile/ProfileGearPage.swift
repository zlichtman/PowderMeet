import MeetSolver
import MountainCore
import PowderMeetAPI
import SwiftUI

/// Gear: the skis drawn large (the button to the ski picker)
/// with one line under them, then one glass group per section (Skis, How you
/// ski, Body, Pace), rows split by hairlines, labels and values only. Edits
/// save themselves a moment after the last change, so holding a stepper is one
/// save, not forty.
struct ProfileGearPage: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let profile = model.profile {
            GearForm(profile: profile)
        } else {
            ProgressView()
                .frame(maxWidth: .infinity, minHeight: 120)
                .glassCard()
        }
    }
}

private struct GearForm: View {
    @Environment(AppModel.self) private var model

    let profile: Profile
    @State private var draft: GearDraft
    /// The last draft handed to the session, so a server echo of an older save
    /// does not undo newer taps.
    @State private var sent: GearDraft
    /// Shown at once; the session saves it with the pace that goes with it.
    @State private var ability: String

    init(profile: Profile) {
        self.profile = profile
        let stored = GearDraft(profile)
        _draft = State(initialValue: stored)
        _sent = State(initialValue: stored)
        _ability = State(initialValue: profile.ability)
    }

    var body: some View {
        Group {
            skis
            howYouSki
            bodySection
            pace
        }
        .pageScroll()
        .task(id: draft) {
            guard draft != sent else { return }
            do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
            save()
        }
        .onChange(of: profile) { _, updated in
            // Nothing unsaved: follow the server.
            if draft == sent {
                draft = GearDraft(updated)
                sent = draft
            }
            ability = updated.ability
        }
        .onDisappear(perform: save)
    }

    private func save() {
        guard draft != sent else { return }
        sent = draft
        model.saveGear(draft)
    }

    // MARK: Skis

    private var skisLine: String { draft.label ?? "Not set yet" }

    private var skis: some View {
        VStack(alignment: .leading, spacing: GlassLayout.gap) {
            SectionHeader("Skis")
            // The skis are the button to the ski picker: their own glass,
            // answering a press, with the swap mark in its corner.
            Button {
                save()
                model.openFloating(.skiPicker)
            } label: {
                VStack(spacing: 10) {
                    VStack(spacing: 6) {
                        SkiBody(look: draft.look).skiGlow()
                        SkiBody(look: draft.look).skiGlow()
                    }
                    .frame(maxWidth: 300)
                    .frame(height: 64)
                    HStack(spacing: 8) {
                        Text(skisLine)
                            .textRole(.bodyEmph)
                            .foregroundStyle(HUDTheme.primaryText)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
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
                .frame(maxWidth: .infinity)
                .glassCardControl()
            }
            .buttonStyle(PressableStyle())
            .accessibilityLabel("Your skis: \(skisLine)")
            .accessibilityHint("Changes your skis")
            GlassSection { skiRows }
        }
    }

    @ViewBuilder
    private var skiRows: some View {
            if let discipline = draft.discipline {
                if draft.ski == nil {
                    pillsRow("Type") {
                        HUDChoicePills(
                            choices: EquipmentType.allCases.map {
                                HUDChoicePills<EquipmentType>.Choice(
                                    value: $0, label: $0 == .allMountain ? "All-mtn" : $0.label)
                            },
                            selection: draft.type
                        ) { draft.type = $0 }
                    }
                } else {
                    GlassRow(icon: nil, title: "Type") { GlassValue(text: draft.type.label) }
                }
                GlassDivider()
                HUDStepperRow(
                    label: "Length", boxed: false, value: draft.lengthCM.map { "\($0) cm" },
                    onStep: { step in
                        draft.lengthCM = GearDraft.stepped(
                            draft.lengthCM, by: step, from: draft.startingLengthCM, in: ProfileEquipment.lengthRangeCM)
                    },
                    onClear: { draft.lengthCM = nil }
                )
                if discipline == .ski {
                    GlassDivider()
                    if draft.ski == nil {
                        HUDStepperRow(
                            label: "Waist", boxed: false, value: draft.waistMM.map { "\($0) mm" },
                            onStep: { step in
                                draft.waistMM = GearDraft.stepped(draft.waistMM, by: step, from: 90, in: ProfileEquipment.waistRangeMM)
                            },
                            onClear: { draft.waistMM = nil }
                        )
                    } else {
                        GlassRow(icon: nil, title: "Waist") { GlassValue(text: draft.waistMM.map { "\($0) mm" } ?? "—") }
                    }
                }
            }
    }

    // MARK: How you ski

    private var howYouSki: some View {
        GlassSection("How you ski") {
            pillsRow("Level") {
                HUDChoicePills(
                    choices: SkillTier.allTiers.map {
                        HUDChoicePills<String>.Choice(value: $0.key, label: $0.label)
                    },
                    selection: SkillTier.tier(for: ability).key
                ) { key in
                    guard key != ability else { return }
                    ability = key
                    model.changeAbility(to: Ability(profileValue: key))
                }
            }
            GlassDivider()
            pillsRow("Hardest run") {
                DifficultyPills(selection: draft.maxDifficulty) { draft.maxDifficulty = $0 }
            }
            GlassDivider()
            HUDStepperRow(
                label: "Steepest", boxed: false, value: draft.maxPitchDeg.map { "\($0)°" },
                onStep: { step in
                    draft.maxPitchDeg = GearDraft.stepped(draft.maxPitchDeg, by: step, from: 25, in: Profile.maxPitchRangeDeg)
                },
                onClear: { draft.maxPitchDeg = nil }
            )
            GlassDivider()
            VStack(alignment: .leading, spacing: 8) {
                Text("Avoid")
                    .textRole(.body)
                    .foregroundStyle(HUDTheme.primaryText)
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible())], spacing: 6) {
                    ForEach(Avoidance.allCases, id: \.self) { choice in
                        HUDToggleChip(label: choice.label, detail: choice.detail, isOn: draft.avoid.contains(choice)) {
                            if draft.avoid.contains(choice) { draft.avoid.remove(choice) } else { draft.avoid.insert(choice) }
                        }
                    }
                }
            }
            .padding(GlassLayout.cardPadding)
        }
    }

    // MARK: Body

    private var bodySection: some View {
        GlassSection("Body") {
            HUDStepperRow(
                label: "Height", boxed: false, value: draft.heightCM.map(UnitFormatter.height),
                onStep: { step in
                    let next = draft.heightCM.map { UnitFormatter.steppedHeight($0, by: step) } ?? 170
                    draft.heightCM = min(max(next, Profile.heightRangeCM.lowerBound), Profile.heightRangeCM.upperBound)
                },
                onClear: { draft.heightCM = nil }
            )
            GlassDivider()
            HUDStepperRow(
                label: "Weight", boxed: false, value: draft.weightKG.map(UnitFormatter.weight),
                onStep: { step in
                    let next = draft.weightKG.map { UnitFormatter.steppedWeight($0, by: step) } ?? 70
                    draft.weightKG = min(max(next, Profile.weightRangeKG.lowerBound), Profile.weightRangeKG.upperBound)
                },
                onClear: { draft.weightKG = nil }
            )
        }
    }

    // MARK: Pace

    private var pace: some View {
        let runs = model.activity.history.calibrationRuns
        return GlassSection("Pace") {
            GlassRow(icon: nil, title: "Learned") {
                GlassValue(text: runs > 0 ? "\(runs) \(runs == 1 ? "run" : "runs")" : "Not yet")
            }
        }
    }

    /// A label over a row of pills, inside a section.
    private func pillsRow<Pills: View>(_ label: String, @ViewBuilder pills: () -> Pills) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label)
                .textRole(.body)
                .foregroundStyle(HUDTheme.primaryText)
            pills()
        }
        .padding(GlassLayout.cardPadding)
    }
}

/// A level's trail-map symbol in its colour: green circle, blue square,
/// black diamond, two black diamonds for double black.
struct TrailSymbol: View {
    let level: Difficulty

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<(level == .doubleBlack ? 2 : 1), id: \.self) { _ in
                Image(systemName: level.icon)
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(HUDTheme.color(for: level))
            }
        }
        .accessibilityHidden(true)
    }
}

/// The hardest run as the trail symbols in their colours: green circle, blue
/// square, black diamond, double black diamond.
struct DifficultyPills: View {
    let selection: Difficulty
    let onSelect: (Difficulty) -> Void

    var body: some View {
        HStack(spacing: 4) {
            ForEach(GearDraft.ladder, id: \.self) { level in
                let isSelected = level == selection
                Button { onSelect(level) } label: {
                    TrailSymbol(level: level)
                    .frame(maxWidth: .infinity, minHeight: GlassLayout.chipHeight)
                    .background(isSelected ? HUDTheme.accent.opacity(0.35) : Color.clear, in: Capsule())
                    .overlay { if isSelected { Capsule().strokeBorder(HUDTheme.accent, lineWidth: 2) } }
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(level.displayName)
                .accessibilityAddTraits(isSelected ? [.isSelected] : [])
            }
        }
        .padding(4)
        .hudCard(cornerRadius: GlassLayout.cardRadius)
    }
}
