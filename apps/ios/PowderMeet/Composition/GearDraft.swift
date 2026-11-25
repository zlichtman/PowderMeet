import Foundation
import MeetSolver
import MountainCore
import PowderMeetAPI

/// The equipment, body and limits answers as the screens edit them, and the
/// `profile_update` patch they become. Every field here is one the solver reads
/// (`specs/02-DOMAIN.md` section 5.1).
nonisolated struct GearDraft: Hashable, Sendable {
    /// Skis, or nil before any gear is chosen. Gear an older build saved as a
    /// snowboard arrives as skis (`ProfileEquipment` decoding).
    var discipline: Discipline? = .ski
    var type: EquipmentType = .allMountain
    var lengthCM: Int?
    var waistMM: Int?
    /// The catalog ski picked by name, if any. Display only: type, length and
    /// waist above are what routing reads. A catalog ski is drawn with its own
    /// topsheet; custom gear (nil) with the PowderMeet ski.
    var skiKey: String?
    var heightCM: Int?
    var weightKG: Int?
    var maxDifficulty: Difficulty
    var avoid: Set<Avoidance> = []
    var maxPitchDeg: Int?

    /// The hardest-run limit a new account starts at. Ability sets pace only;
    /// the limit is the skier's own and can be anything on the ladder.
    static func defaultHardestRun(for ability: Ability) -> Difficulty {
        SkierProfile.preset(ability, userID: UUID()).maxDifficulty
    }

    static let ladder: [Difficulty] = [.green, .blue, .black, .doubleBlack]

    /// A new account: nothing chosen, the limit at the ability's default.
    init(ability: Ability) {
        maxDifficulty = Self.defaultHardestRun(for: ability)
    }

    init(_ profile: Profile) {
        let ability = Ability(rawValue: profile.ability) ?? .intermediate
        maxDifficulty = Difficulty(rawValue: profile.maxDifficulty) ?? Self.defaultHardestRun(for: ability)
        if let row = profile.equipment, let gear = Equipment(row) {
            type = gear.type
            lengthCM = gear.lengthCM
            waistMM = gear.waistMM
            skiKey = row.ski
        }
        heightCM = profile.heightCM
        weightKG = profile.weightKG
        avoid = Set(profile.avoid.compactMap(Avoidance.init(rawValue:)))
        maxPitchDeg = profile.maxPitchDeg
    }

    /// During onboarding the limit follows the ability's default until the
    /// skier picks one themselves; a limit they chose is kept whatever the
    /// ability. It is never capped by ability.
    func hardestRun(movingFrom old: Ability, to new: Ability) -> Difficulty {
        maxDifficulty == Self.defaultHardestRun(for: old) ? Self.defaultHardestRun(for: new) : maxDifficulty
    }

    /// Switching what is ridden drops the measurements of the other.
    mutating func select(_ choice: Discipline?) {
        guard choice != discipline else { return }
        discipline = choice
        lengthCM = nil
        waistMM = nil
        skiKey = nil
    }

    /// The catalog ski, when one is picked and this build knows it.
    var ski: SkiModel? { skiKey.flatMap(SkiCatalog.model(key:)) }

    var look: SkiLook { SkiLook(skiKey: discipline == nil ? nil : skiKey) }

    /// Picking a ski by name fills in what routing reads from it; the length
    /// stays the skier's, and every field can still be edited after.
    mutating func choose(_ ski: SkiModel) {
        if discipline != .ski { select(.ski) }
        skiKey = ski.key
        type = ski.category.equipmentType
        waistMM = ski.waistMM
    }

    private var equipment: ProfileEquipment? {
        guard let discipline else { return nil }
        return ProfileEquipment(
            discipline: discipline.rawValue, type: type.rawValue, lengthCM: lengthCM, waistMM: waistMM,
            // The skin is not a choice, so it is never written.
            ski: skiKey, skin: nil
        )
    }

    func applied(to patch: ProfilePatch) -> ProfilePatch {
        patch
            .equipment(equipment)
            .maxDifficulty(maxDifficulty.rawValue)
            .avoid(avoid.map(\.rawValue))
            .maxPitchDeg(maxPitchDeg)
            .heightCM(heightCM)
            .weightKG(weightKG)
    }

    // MARK: Steps

    /// A sensible first value when a stepper is tapped from "not set".
    var startingLengthCM: Int {
        heightCM.map { $0 - 8 } ?? 170
    }

    static func stepped(_ value: Int?, by delta: Int, from start: Int, in range: ClosedRange<Int>) -> Int {
        guard let value else { return min(max(start, range.lowerBound), range.upperBound) }
        return min(max(value + delta, range.lowerBound), range.upperBound)
    }

    /// What is ridden, in one rule everywhere it is named (the Gear ski button,
    /// the Gear tile, the ski strip on a profile card): the catalog ski by
    /// name, otherwise "Skis"; then the length.
    /// "Atomic Bent 110 · 184 cm", "Skis · 184 cm".
    var label: String? {
        guard discipline != nil else { return nil }
        let name = ski?.displayName ?? "Skis"
        return [name, lengthCM.map { "\($0) cm" }].compactMap { $0 }.joined(separator: " · ")
    }
}

nonisolated extension EquipmentType {
    var label: String {
        switch self {
        case .allMountain: "All-mountain"
        case .carving: "Carving"
        case .freeride: "Freeride"
        case .park: "Park"
        }
    }
}

nonisolated extension Avoidance {
    var label: String {
        switch self {
        case .ungroomed: "Ungroomed"
        case .flats: "Flats"
        case .park: "Terrain park"
        case .surfaceLifts: "Surface lifts"
        }
    }

    var detail: String {
        switch self {
        case .ungroomed: "Moguls, glades, powder"
        case .flats: "Cat tracks and traverses"
        case .park: "Jumps and rails"
        case .surfaceLifts: "T-bars, rope tows, carpets"
        }
    }
}
