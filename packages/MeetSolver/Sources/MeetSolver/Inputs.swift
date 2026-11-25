import Foundation
import MountainCore

public enum Ability: String, Codable, Sendable, Hashable, CaseIterable {
    case beginner, intermediate, advanced, expert
}

public enum Discipline: String, Codable, Sendable, Hashable, CaseIterable {
    case ski
}

public enum EquipmentType: String, Codable, Sendable, Hashable, CaseIterable {
    case allMountain = "all_mountain"
    case carving, freeride, park
}

/// What the skier rides. Every field changes pace (`specs/06-SOLVER.md` section 2).
public struct Equipment: Hashable, Codable, Sendable {
    public var discipline: Discipline
    public var type: EquipmentType
    public var lengthCM: Int?
    /// Skis only.
    public var waistMM: Int?

    public init(
        discipline: Discipline, type: EquipmentType = .allMountain, lengthCM: Int? = nil,
        waistMM: Int? = nil
    ) {
        self.discipline = discipline
        self.type = type
        self.lengthCM = lengthCM
        self.waistMM = waistMM
    }
}

/// Terrain and lifts a skier is never routed onto.
public enum Avoidance: String, Codable, Sendable, Hashable, CaseIterable {
    case ungroomed, flats, park
    case surfaceLifts = "surface_lifts"
}

public struct SkierProfile: Hashable, Codable, Sendable {
    public var userID: UUID
    public var ability: Ability
    /// Hard gate: harder marked terrain is never routed.
    public var maxDifficulty: Difficulty
    /// Metres per second by difficulty. A missing entry means the skier has not
    /// said they ski that category, so it is never routed either.
    public var baselineSpeedMS: [Difficulty: Double]
    public var liftBoardingPenaltyS: Double
    public var prefersGroomed: Bool
    public var equipment: Equipment?
    /// Hard gates, like `maxDifficulty`.
    public var avoid: Set<Avoidance>
    /// Hard gate: a run with a steeper pitch is never routed. nil is no limit.
    public var maxPitchDeg: Double?
    /// Private to their owner, so nil for anyone but the device's own skier.
    public var heightCM: Int?
    public var weightKG: Int?

    public init(
        userID: UUID, ability: Ability, maxDifficulty: Difficulty,
        baselineSpeedMS: [Difficulty: Double], liftBoardingPenaltyS: Double = 0,
        prefersGroomed: Bool = false, equipment: Equipment? = nil,
        avoid: Set<Avoidance> = [], maxPitchDeg: Double? = nil, heightCM: Int? = nil,
        weightKG: Int? = nil
    ) {
        self.userID = userID
        self.ability = ability
        self.maxDifficulty = maxDifficulty
        self.baselineSpeedMS = baselineSpeedMS
        self.liftBoardingPenaltyS = liftBoardingPenaltyS
        self.prefersGroomed = prefersGroomed
        self.equipment = equipment
        self.avoid = avoid
        self.maxPitchDeg = maxPitchDeg
        self.heightCM = heightCM
        self.weightKG = weightKG
    }

    /// The onboarding presets.
    /// Ability sets pace only: every preset has a speed for every rating, so the
    /// hardest-run limit (`maxDifficulty`, here a default for a new account) is
    /// the only difficulty gate. Speeds above a preset's own limit are slow on
    /// purpose.
    public static func preset(_ ability: Ability, userID: UUID) -> SkierProfile {
        let speeds: [Difficulty: Double]
        let maxDifficulty: Difficulty
        switch ability {
        case .beginner:
            speeds = [.green: 4, .blue: 2, .black: 1.2, .doubleBlack: 0.8, .park: 1.5]
            maxDifficulty = .green
        case .intermediate:
            speeds = [.green: 7, .blue: 5, .black: 3, .doubleBlack: 2, .park: 4]
            maxDifficulty = .blue
        case .advanced:
            speeds = [.green: 10, .blue: 8, .black: 6, .doubleBlack: 4, .park: 6]
            maxDifficulty = .black
        case .expert:
            speeds = [.green: 12, .blue: 10, .black: 9, .doubleBlack: 7, .park: 8]
            maxDifficulty = .doubleBlack
        }
        return SkierProfile(
            userID: userID, ability: ability, maxDifficulty: maxDifficulty,
            baselineSpeedMS: speeds
        )
    }
}

/// Learned pace, produced only by the server (`specs/08-ACTIVITY.md`).
public struct PaceModel: Hashable, Codable, Sendable {
    public var ownerID: UUID
    public var computedAt: Date
    /// Multiplicative against the baseline speed, already shrunk.
    public var difficultyFactor: [Difficulty: Double]
    /// Multiplicative against the difficulty estimate, already shrunk.
    public var edgeFactor: [EdgeID: Double]
    /// Learned stop rate, used for elapsed (not moving) time.
    public var stopsPerKm: Double

    public init(
        ownerID: UUID, computedAt: Date, difficultyFactor: [Difficulty: Double] = [:],
        edgeFactor: [EdgeID: Double] = [:], stopsPerKm: Double
    ) {
        self.ownerID = ownerID
        self.computedAt = computedAt
        self.difficultyFactor = difficultyFactor
        self.edgeFactor = edgeFactor
        self.stopsPerKm = stopsPerKm
    }
}

public struct RoutingOrigin: Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        case node(NodeID)
        /// Part-way along a directed edge: only the remainder is charged and drawn
        /// (invariant I-12).
        case onEdge(EdgeID, fraction: Double)
    }

    public var kind: Kind
    /// Feeds the route's initial variance.
    public var fixAccuracyM: Double

    public init(kind: Kind, fixAccuracyM: Double = 0) {
        self.kind = kind
        self.fixAccuracyM = fixAccuracyM
    }

    public static func node(_ id: NodeID, fixAccuracyM: Double = 0) -> RoutingOrigin {
        RoutingOrigin(kind: .node(id), fixAccuracyM: fixAccuracyM)
    }

    public static func onEdge(
        _ id: EdgeID, fraction: Double, fixAccuracyM: Double = 0
    ) -> RoutingOrigin {
        RoutingOrigin(kind: .onEdge(id, fraction: fraction), fixAccuracyM: fixAccuracyM)
    }
}

public struct SkierInput: Hashable, Sendable {
    public var id: UUID
    public var profile: SkierProfile
    public var pace: PaceModel?
    public var origin: RoutingOrigin

    public init(id: UUID, profile: SkierProfile, pace: PaceModel? = nil, origin: RoutingOrigin) {
        self.id = id
        self.profile = profile
        self.pace = pace
        self.origin = origin
    }
}

public enum StatusPolicy: Hashable, Sendable {
    /// Refuse to solve without fresh status.
    case strict
    /// Solve on operating hours and label the result.
    case degraded
}

public struct SolveOptions: Hashable, Sendable {
    public var maxOptions = 5
    public var maxLabelsPerNode = 8
    /// nil → from the conditions and rendezvous-kind table.
    public var fairnessAlpha: Double? = nil
    public var statusPolicy: StatusPolicy = .degraded
    /// A meeting place the skier asked for by name. When both can reach it and
    /// the solver's own list leaves it out, it is added as the last option
    /// (`Tradeoff.yourPick`), whatever its rank.
    public var requested: RendezvousID? = nil

    public init(
        maxOptions: Int = 5, maxLabelsPerNode: Int = 8, fairnessAlpha: Double? = nil,
        statusPolicy: StatusPolicy = .degraded, requested: RendezvousID? = nil
    ) {
        self.requested = requested
        self.maxOptions = maxOptions
        self.maxLabelsPerNode = maxLabelsPerNode
        self.fairnessAlpha = fairnessAlpha
        self.statusPolicy = statusPolicy
    }
}

/// Everything a solve depends on. Its `Hashable` conformance is the cache key;
/// nothing else is.
public struct SolveInput: Hashable, Sendable {
    /// Hashable by `bundle_id`.
    public var bundle: ResortBundle
    public var status: ResortStatus?
    public var conditions: Conditions?
    /// Quantized to 60 s inside the solver.
    public var at: Date
    public var skiers: (SkierInput, SkierInput)
    public var options: SolveOptions

    public init(
        bundle: ResortBundle, status: ResortStatus? = nil, conditions: Conditions? = nil,
        at: Date, skiers: (SkierInput, SkierInput), options: SolveOptions = SolveOptions()
    ) {
        self.bundle = bundle
        self.status = status
        self.conditions = conditions
        self.at = at
        self.skiers = skiers
        self.options = options
    }

    public static func == (lhs: SolveInput, rhs: SolveInput) -> Bool {
        lhs.bundle == rhs.bundle && lhs.status == rhs.status
            && lhs.conditions == rhs.conditions && lhs.at == rhs.at
            && lhs.skiers.0 == rhs.skiers.0 && lhs.skiers.1 == rhs.skiers.1
            && lhs.options == rhs.options
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(bundle)
        hasher.combine(status)
        hasher.combine(conditions)
        hasher.combine(at)
        hasher.combine(skiers.0)
        hasher.combine(skiers.1)
        hasher.combine(options)
    }
}
