//
//  UserProfile.swift
//  PowderMeet
//
//  Codable model mapping to the Supabase `profiles` table, plus profile
//  presets and derived ability values. Routing physics lives in the focused
//  `UserProfile+Traversal.swift` extension.
//

import Foundation

// `nonisolated` — `traverseTime(for:context:ignoreSkillGates:)` is the
// hot inner loop of Dijkstra and must run from the solver's detached
// task without an actor hop. Project default isolation is MainActor;
// opt out. Pure value type; all members are Sendable.
nonisolated struct UserProfile: Codable, Identifiable, Sendable, Equatable {
    let id: UUID
    var displayName: String
    var avatarUrl: String?
    var currentResortId: String?
    var skillLevel: String
    var speedGreen: Double?
    var speedBlue: Double?
    var speedBlack: Double?
    var speedDoubleBlack: Double?
    var speedTerrainPark: Double?
    var conditionMoguls: Double
    var conditionUngroomed: Double
    var conditionIcy: Double
    var conditionGladed: Double

    // MARK: - Continuous skill fields
    //
    // Finer-grained than the bucketed skill level / condition sliders.
    // The bucketed gradient cap (`maxGradientForLevel`) blocks routes, which
    // is too coarse — a strong intermediate can ski a 32° pitch if it's
    // groomed, but the current code blocks everything above the level's cap.
    // These fields let the solver ramp penalties instead of hard-blocking.
    //
    // Defaults mirror the bucketed behaviour; onboarding / calibration can
    // refine them. `Double?` so we can tell "user never set this" from "user
    // explicitly chose 0".
    var maxComfortableGradientDegrees: Double?   // hard block above this + ramp below
    var mogulTolerance: Double?                  // 0..1
    var narrowTrailTolerance: Double?            // 0..1
    var exposureTolerance: Double?               // 0..1 — fall-line exposure
    var crustConditionTolerance: Double?         // 0..1 — refrozen crust

    // MARK: - Live recording feature gate
    //
    // When true (default), `LiveRunRecorder` passively segments incoming
    // GPS fixes into runs while the app is open and persists each
    // completed run to `imported_runs` (source = "live"). Toggling this
    // off in the Profile › ACTIVITY tab stops the recorder immediately —
    // useful for users who want full control over what data lands in
    // the algorithm's per-edge skill memory.
    var liveRecordingEnabled: Bool

    // MARK: - Body metrics + ski choice
    //
    // Captured for the algorithm's future per-skier pacing model (heavier
    // skiers carve faster on groomers, ski waist width influences powder
    // tolerance, etc.). Persisted as nullables so a row that pre-dates
    // this column decodes cleanly. HealthKit-prefilled where available;
    // user-editable.
    var heightCm: Double?
    var weightKg: Double?
    var preferredSkiId: UUID?

    var onboardingCompleted: Bool
    let createdAt: Date?
    var updatedAt: Date?

    // MARK: - Memberwise Init

    init(
        id: UUID,
        displayName: String,
        avatarUrl: String? = nil,
        currentResortId: String? = nil,
        skillLevel: String,
        speedGreen: Double? = nil,
        speedBlue: Double? = nil,
        speedBlack: Double? = nil,
        speedDoubleBlack: Double? = nil,
        speedTerrainPark: Double? = nil,
        conditionMoguls: Double,
        conditionUngroomed: Double,
        conditionIcy: Double,
        conditionGladed: Double,
        maxComfortableGradientDegrees: Double? = nil,
        mogulTolerance: Double? = nil,
        narrowTrailTolerance: Double? = nil,
        exposureTolerance: Double? = nil,
        crustConditionTolerance: Double? = nil,
        liveRecordingEnabled: Bool = true,
        heightCm: Double? = nil,
        weightKg: Double? = nil,
        preferredSkiId: UUID? = nil,
        onboardingCompleted: Bool,
        createdAt: Date? = nil,
        updatedAt: Date? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.avatarUrl = avatarUrl
        self.currentResortId = currentResortId
        self.skillLevel = skillLevel
        self.speedGreen = speedGreen
        self.speedBlue = speedBlue
        self.speedBlack = speedBlack
        self.speedDoubleBlack = speedDoubleBlack
        self.speedTerrainPark = speedTerrainPark
        self.conditionMoguls = conditionMoguls
        self.conditionUngroomed = conditionUngroomed
        self.conditionIcy = conditionIcy
        self.conditionGladed = conditionGladed
        self.maxComfortableGradientDegrees = maxComfortableGradientDegrees
        self.mogulTolerance = mogulTolerance
        self.narrowTrailTolerance = narrowTrailTolerance
        self.exposureTolerance = exposureTolerance
        self.crustConditionTolerance = crustConditionTolerance
        self.liveRecordingEnabled = liveRecordingEnabled
        self.heightCm = heightCm
        self.weightKg = weightKg
        self.preferredSkiId = preferredSkiId
        self.onboardingCompleted = onboardingCompleted
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    // MARK: - Decoding (backward compat for new fields)

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        displayName = try c.decode(String.self, forKey: .displayName)
        avatarUrl = try c.decodeIfPresent(String.self, forKey: .avatarUrl)
        currentResortId = try c.decodeIfPresent(String.self, forKey: .currentResortId)
        skillLevel = try c.decode(String.self, forKey: .skillLevel)
        speedGreen = try c.decodeIfPresent(Double.self, forKey: .speedGreen)
        speedBlue = try c.decodeIfPresent(Double.self, forKey: .speedBlue)
        speedBlack = try c.decodeIfPresent(Double.self, forKey: .speedBlack)
        speedDoubleBlack = try c.decodeIfPresent(Double.self, forKey: .speedDoubleBlack)
        speedTerrainPark = try c.decodeIfPresent(Double.self, forKey: .speedTerrainPark)
        conditionMoguls = try c.decode(Double.self, forKey: .conditionMoguls)
        conditionUngroomed = try c.decode(Double.self, forKey: .conditionUngroomed)
        conditionIcy = try c.decode(Double.self, forKey: .conditionIcy)
        conditionGladed = try c.decode(Double.self, forKey: .conditionGladed)
        maxComfortableGradientDegrees = try c.decodeIfPresent(Double.self, forKey: .maxComfortableGradientDegrees)
        mogulTolerance = try c.decodeIfPresent(Double.self, forKey: .mogulTolerance)
        narrowTrailTolerance = try c.decodeIfPresent(Double.self, forKey: .narrowTrailTolerance)
        exposureTolerance = try c.decodeIfPresent(Double.self, forKey: .exposureTolerance)
        crustConditionTolerance = try c.decodeIfPresent(Double.self, forKey: .crustConditionTolerance)
        // Default to true so existing accounts (column missing on a stale
        // profile JSON, or older app build that wrote the row before this
        // column shipped) get live recording on by default. Toggling it
        // off is a deliberate user action; never silently disabled.
        liveRecordingEnabled = try c.decodeIfPresent(Bool.self, forKey: .liveRecordingEnabled) ?? true
        heightCm = try c.decodeIfPresent(Double.self, forKey: .heightCm)
        weightKg = try c.decodeIfPresent(Double.self, forKey: .weightKg)
        preferredSkiId = try c.decodeIfPresent(UUID.self, forKey: .preferredSkiId)
        onboardingCompleted = try c.decode(Bool.self, forKey: .onboardingCompleted)
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt)
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt)
    }

    // MARK: - Helpers

    /// Speed in m/s for a given difficulty, nil = can't/won't ski it.
    func speed(for difficulty: RunDifficulty) -> Double? {
        switch difficulty {
        case .green:       return speedGreen
        case .blue:        return speedBlue
        case .black:       return speedBlack
        case .doubleBlack: return speedDoubleBlack
        case .terrainPark: return speedTerrainPark
        }
    }

    /// Returns the preset name (`"beginner"` / `"intermediate"` /
    /// `"advanced"` / `"expert"`) whose speed + condition fields match
    /// this profile exactly, or nil if the profile has been calibrated
    /// (any field deviates from a preset). Used by the skill-level
    /// picker to decide whether changing `skill_level` should also
    /// roll the speed/condition fields to the new tier — yes if the
    /// user is on default values, no if they've calibrated via
    /// imports / manual edits (which would otherwise be silently
    /// overwritten).
    var matchingPreset: String? {
        var probe = self
        for level in ["beginner", "intermediate", "advanced", "expert"] {
            probe.applyPreset(level)
            if probe.speedGreen == self.speedGreen,
               probe.speedBlue == self.speedBlue,
               probe.speedBlack == self.speedBlack,
               probe.speedDoubleBlack == self.speedDoubleBlack,
               probe.speedTerrainPark == self.speedTerrainPark,
               probe.conditionMoguls == self.conditionMoguls,
               probe.conditionUngroomed == self.conditionUngroomed,
               probe.conditionIcy == self.conditionIcy,
               probe.conditionGladed == self.conditionGladed {
                return level
            }
        }
        return nil
    }

    // MARK: - Derived skill values

    /// Highest conventional piste grade for display and compatibility. Actual
    /// eligibility uses `canTraverseRun(_:)` because terrain park is a parallel
    /// category rather than a fifth ordered difficulty.
    var maxRunDifficulty: RunDifficulty {
        switch skillLevel {
        case "beginner":     return .green
        case "intermediate": return .blue
        case "advanced":     return .black
        case "expert":       return .doubleBlack
        default:             return .blue
        }
    }

    /// Explicit marked-terrain contract shared by the solver and profile copy.
    /// The stored speed is a second, independent opt-in: tier alone never
    /// fabricates permission for a category whose speed is nil.
    func canTraverseRun(_ difficulty: RunDifficulty) -> Bool {
        guard let declaredSpeed = speed(for: difficulty),
              declaredSpeed.isFinite, declaredSpeed > 0 else {
            return false
        }
        switch skillLevel {
        case "beginner":
            return difficulty == .green
        case "intermediate":
            return difficulty == .green || difficulty == .blue
        case "advanced":
            return difficulty == .green || difficulty == .blue
                || difficulty == .black || difficulty == .terrainPark
        case "expert":
            return true
        default:
            // Unknown/legacy tiers degrade to the safe intermediate contract.
            return difficulty == .green || difficulty == .blue
        }
    }

    var steepPenaltyForLevel: Double {
        switch skillLevel {
        case "beginner":     return TraversalConstants.Run.Gradient.beginnerPenaltyWeight
        case "intermediate": return TraversalConstants.Run.Gradient.intermediatePenaltyWeight
        case "advanced":     return TraversalConstants.Run.Gradient.advancedPenaltyWeight
        case "expert":       return TraversalConstants.Run.Gradient.expertPenaltyWeight
        default:             return TraversalConstants.Run.Gradient.intermediatePenaltyWeight
        }
    }

    var maxGradientForLevel: Double {
        switch skillLevel {
        case "beginner":     return TraversalConstants.Run.Gradient.beginnerMaxDegrees
        case "intermediate": return TraversalConstants.Run.Gradient.intermediateMaxDegrees
        case "advanced":     return TraversalConstants.Run.Gradient.advancedMaxDegrees
        case "expert":       return TraversalConstants.Run.Gradient.expertMaxDegrees
        default:             return TraversalConstants.Run.Gradient.intermediateMaxDegrees
        }
    }

    // MARK: - Presets (for onboarding defaults)

    static func defaultProfile(id: UUID) -> UserProfile {
        // Values mirror `applyPreset("intermediate")` and the DB column
        // defaults on `profiles` (speed_green=7.0, speed_blue=5.0,
        // etc.), so a Swift-side fallback profile and a freshly-
        // inserted row through `handle_new_user` agree. Earlier this
        // factory had `speedGreen: 5.0, speedBlue: 8.0` which inverted
        // the green-faster-than-blue invariant the rest of the app
        // assumes (steeper terrain → more turns / more caution).
        UserProfile(
            id: id,
            displayName: "",
            avatarUrl: nil,
            currentResortId: nil,
            skillLevel: "intermediate",
            speedGreen: 7.0,
            speedBlue: 5.0,
            speedBlack: 3.0,
            speedDoubleBlack: nil,
            speedTerrainPark: 4.0,
            conditionMoguls: 0.5,
            conditionUngroomed: 0.6,
            conditionIcy: 0.5,
            conditionGladed: 0.4,
            onboardingCompleted: false,
            createdAt: nil,
            updatedAt: nil
        )
    }

    mutating func applyPreset(_ level: String) {
        skillLevel = level
        switch level {
        case "beginner":
            speedGreen = 4.0; speedBlue = 2.0; speedBlack = nil; speedDoubleBlack = nil; speedTerrainPark = nil
            conditionMoguls = 0.2; conditionUngroomed = 0.3; conditionIcy = 0.3; conditionGladed = 0.0
        case "intermediate":
            // Ladder: greens are faster than blues across all tiers
            // (steeper terrain → more turns / more caution). The earlier
            // (5, 8) values inverted that on intermediate only and
            // disagreed with both the DB default and
            // `OnboardingView.presetSpeeds`. Aligned to (7, 5) to match.
            speedGreen = 7.0; speedBlue = 5.0; speedBlack = 3.0; speedDoubleBlack = nil; speedTerrainPark = 4.0
            conditionMoguls = 0.5; conditionUngroomed = 0.6; conditionIcy = 0.5; conditionGladed = 0.4
        case "advanced":
            speedGreen = 10.0; speedBlue = 8.0; speedBlack = 6.0; speedDoubleBlack = 4.0; speedTerrainPark = 6.0
            conditionMoguls = 0.8; conditionUngroomed = 0.8; conditionIcy = 0.7; conditionGladed = 0.7
        case "expert":
            speedGreen = 12.0; speedBlue = 10.0; speedBlack = 9.0; speedDoubleBlack = 7.0; speedTerrainPark = 8.0
            conditionMoguls = 1.0; conditionUngroomed = 1.0; conditionIcy = 0.85; conditionGladed = 0.9
        default: break
        }
    }

    // MARK: - CodingKeys (snake_case DB columns)

    enum CodingKeys: String, CodingKey {
        case id
        case displayName = "display_name"
        case avatarUrl = "avatar_url"
        case currentResortId = "current_resort_id"
        case skillLevel = "skill_level"
        case speedGreen = "speed_green"
        case speedBlue = "speed_blue"
        case speedBlack = "speed_black"
        case speedDoubleBlack = "speed_double_black"
        case speedTerrainPark = "speed_terrain_park"
        case conditionMoguls = "condition_moguls"
        case conditionUngroomed = "condition_ungroomed"
        case conditionIcy = "condition_icy"
        case conditionGladed = "condition_gladed"
        case maxComfortableGradientDegrees = "max_comfortable_gradient_degrees"
        case mogulTolerance = "mogul_tolerance"
        case narrowTrailTolerance = "narrow_trail_tolerance"
        case exposureTolerance = "exposure_tolerance"
        case crustConditionTolerance = "crust_condition_tolerance"
        case liveRecordingEnabled = "live_recording_enabled"
        case heightCm = "height_cm"
        case weightKg = "weight_kg"
        case preferredSkiId = "preferred_ski_id"
        case onboardingCompleted = "onboarding_completed"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    // MARK: - Update Payload (excludes server-managed columns)

    /// Encodable payload that omits `id`, `created_at`, and `updated_at`
    /// so we never send read-only fields to Supabase on UPDATE.
    var updatePayload: ProfileUpdatePayload {
        ProfileUpdatePayload(
            displayName: displayName,
            avatarUrl: avatarUrl,
            currentResortId: currentResortId,
            skillLevel: skillLevel,
            speedGreen: speedGreen,
            speedBlue: speedBlue,
            speedBlack: speedBlack,
            speedDoubleBlack: speedDoubleBlack,
            speedTerrainPark: speedTerrainPark,
            conditionMoguls: conditionMoguls,
            conditionUngroomed: conditionUngroomed,
            conditionIcy: conditionIcy,
            conditionGladed: conditionGladed,
            maxComfortableGradientDegrees: maxComfortableGradientDegrees,
            mogulTolerance: mogulTolerance,
            narrowTrailTolerance: narrowTrailTolerance,
            exposureTolerance: exposureTolerance,
            crustConditionTolerance: crustConditionTolerance,
            liveRecordingEnabled: liveRecordingEnabled,
            heightCm: heightCm,
            weightKg: weightKg,
            preferredSkiId: preferredSkiId,
            onboardingCompleted: onboardingCompleted
        )
    }
}

/// Encodable struct with only the mutable profile columns.
struct ProfileUpdatePayload: Encodable {
    var displayName: String
    var avatarUrl: String?
    var currentResortId: String?
    var skillLevel: String
    var speedGreen: Double?
    var speedBlue: Double?
    var speedBlack: Double?
    var speedDoubleBlack: Double?
    var speedTerrainPark: Double?
    var conditionMoguls: Double
    var conditionUngroomed: Double
    var conditionIcy: Double
    var conditionGladed: Double
    var maxComfortableGradientDegrees: Double?
    var mogulTolerance: Double?
    var narrowTrailTolerance: Double?
    var exposureTolerance: Double?
    var crustConditionTolerance: Double?
    var liveRecordingEnabled: Bool
    var heightCm: Double?
    var weightKg: Double?
    var preferredSkiId: UUID?
    var onboardingCompleted: Bool

    enum CodingKeys: String, CodingKey {
        case displayName = "display_name"
        case avatarUrl = "avatar_url"
        case currentResortId = "current_resort_id"
        case skillLevel = "skill_level"
        case speedGreen = "speed_green"
        case speedBlue = "speed_blue"
        case speedBlack = "speed_black"
        case speedDoubleBlack = "speed_double_black"
        case speedTerrainPark = "speed_terrain_park"
        case conditionMoguls = "condition_moguls"
        case conditionUngroomed = "condition_ungroomed"
        case conditionIcy = "condition_icy"
        case conditionGladed = "condition_gladed"
        case maxComfortableGradientDegrees = "max_comfortable_gradient_degrees"
        case mogulTolerance = "mogul_tolerance"
        case narrowTrailTolerance = "narrow_trail_tolerance"
        case exposureTolerance = "exposure_tolerance"
        case crustConditionTolerance = "crust_condition_tolerance"
        case liveRecordingEnabled = "live_recording_enabled"
        case heightCm = "height_cm"
        case weightKg = "weight_kg"
        case preferredSkiId = "preferred_ski_id"
        case onboardingCompleted = "onboarding_completed"
    }
}
