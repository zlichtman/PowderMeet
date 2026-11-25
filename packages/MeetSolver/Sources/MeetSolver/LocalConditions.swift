import Foundation
import MountainCore

/// The weather on one run or lift at one instant, as routing reads it: the
/// resort's forecast moved to the run's own height and slope (06-SOLVER
/// section 2).
public struct LocalConditions: Hashable, Sendable {
    public var tempC: Double
    /// Mean wind with a share of the gusts, for the run's height and the way it faces.
    public var windKmh: Double
    public var visibilityKm: Double
    /// 0 full shade, 1 full sun.
    public var sunExposure: Double
    /// The run is inside low cloud though the resort reading is clearer.
    public var inCloud: Bool
    /// The snow thawed in the last day and has refrozen.
    public var refrozen: Bool
}

extension MeetSolver {
    /// The weather on `edges` (the edges of one run or lift) at `date`, or nil
    /// with no conditions or no length to weigh by.
    public static func localConditions(
        on edges: [Edge], in bundle: ResortBundle, conditions: Conditions?, at date: Date
    ) -> LocalConditions? {
        // The reading depends on no skier; the model only needs one to exist.
        let nobody = SkierProfile(
            userID: UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)), ability: .intermediate,
            maxDifficulty: .blue, baselineSpeedMS: [:]
        )
        return CostModel(
            bundle: bundle, status: nil, conditions: conditions, profile: nobody, pace: nil, at: date
        ).localConditions(edges)
    }
}
