import Foundation
import MeetSolver
import MountainCore
import PowderMeetAPI

extension SkierProfile {
    /// The routing profile for a `profiles` row. A row that predates onboarding
    /// routes on the preset for its ability. A rating the stored speeds leave out
    /// (rows saved while ability capped the hardest run) takes the preset's pace,
    /// so the hardest-run limit alone decides what may be skied.
    public init(_ profile: Profile) {
        let ability = Ability(rawValue: profile.ability) ?? .intermediate
        let preset = SkierProfile.preset(ability, userID: profile.id)
        var speeds = preset.baselineSpeedMS
        for (key, speed) in profile.baselineSpeeds where speed > 0 {
            if let difficulty = Difficulty(rawValue: key) { speeds[difficulty] = speed }
        }
        self.init(
            userID: profile.id, ability: ability,
            maxDifficulty: Difficulty(rawValue: profile.maxDifficulty) ?? preset.maxDifficulty,
            baselineSpeedMS: speeds,
            equipment: profile.equipment.flatMap(Equipment.init),
            avoid: Set(profile.avoid.compactMap(Avoidance.init(rawValue:))),
            maxPitchDeg: profile.maxPitchDeg.map(Double.init),
            // Present only on the device's own row (`04-SCHEMA.md` section 3).
            heightCM: profile.heightCM, weightKG: profile.weightKG
        )
    }
}

extension Equipment {
    /// Nil for a discipline this build does not know: the skier then routes
    /// without equipment rather than as the wrong one.
    public init?(_ row: ProfileEquipment) {
        guard let discipline = Discipline(rawValue: row.discipline) else { return nil }
        self.init(
            discipline: discipline, type: EquipmentType(rawValue: row.type) ?? .allMountain,
            lengthCM: row.lengthCM, waistMM: discipline == .ski ? row.waistMM : nil
        )
    }
}

extension PaceModel {
    /// Nil when the server has not learned a stop rate yet: the solver's defaults
    /// are better than a half-filled model.
    public init?(_ row: PaceModelRow) {
        guard let stopsPerKm = row.stopsPerKm else { return nil }
        var difficulty: [Difficulty: Double] = [:]
        for (key, factor) in row.difficultyFactor {
            if let level = Difficulty(rawValue: key) { difficulty[level] = factor }
        }
        var edges: [EdgeID: Double] = [:]
        for (key, factor) in row.edgeFactor { edges[EdgeID(key)] = factor }
        self.init(
            ownerID: row.ownerID, computedAt: row.computedAt, difficultyFactor: difficulty,
            edgeFactor: edges, stopsPerKm: stopsPerKm
        )
    }
}

/// Places a fix on the graph. A fix that is not near anything yields nil, and the
/// solver is never handed a guess (I-07). Public for the map's solo "GO TO" route.
public enum OriginResolver {
    static let nodeRadiusM = 35.0
    static let edgeCorridorM = 60.0
    /// Below this ground speed a fix is standing (the presence publisher's
    /// moving threshold); every lift moves faster than this.
    static let standingSpeedMS = ResortSession.movingSpeedMS

    /// The fastest a fix on this lift can move: its ride speed with the slack
    /// `PlaceLocator` allows for GPS speed noise, the same bound it uses to
    /// tell riding from skiing beside the line. A lift with no ride time is
    /// taken at a fast chair's 5 m/s.
    static func fastestRideMS(_ edge: Edge) -> Double {
        let nominal = edge.lift.flatMap { $0.rideS > 0 ? edge.lengthM / $0.rideS : nil } ?? 5
        return nominal * 1.5 + 1
    }

    public static func origin(for fix: Fix, in bundle: ResortBundle) -> RoutingOrigin? {
        let point = fix.coordinate
        let graph = bundle.graph
        let node = graph.nodes.values
            .map { (id: $0.id, distance: Geo.haversineM(point, $0.coordinate)) }
            .min { ($0.distance, $0.id) < ($1.distance, $1.id) }
        if let node, node.distance <= nodeRadiusM {
            return .node(node.id, fixAccuracyM: fix.accuracyM)
        }
        // A skier standing still beside a lift line, or skiing past it faster
        // than it runs, is not riding it: placed on the lift they would pay only
        // the rest of the ride, with no queue or boarding. A fix has no course,
        // so one moving at the lift's speed, or with no speed, may still be on it.
        let edge = graph.edges.compactMap { edge -> (id: EdgeID, fraction: Double, distance: Double)? in
            if edge.kind == .lift, let speed = fix.speedMS,
               speed < standingSpeedMS || speed > fastestRideMS(edge) { return nil }
            return Geo.project(point, onto: edge.coordinates).map { (edge.id, $0.fraction, $0.distanceM) }
        }.min { ($0.distance, $0.id) < ($1.distance, $1.id) }
        if let edge, edge.distance <= edgeCorridorM {
            return .onEdge(edge.id, fraction: edge.fraction, fixAccuracyM: fix.accuracyM)
        }
        return nil
    }
}

/// The solver calls a session makes, off the actor.
enum Solving {
    struct Inputs: Sendable {
        var bundle: ResortBundle
        var status: ResortStatus?
        var conditions: Conditions?
        var at: Date
    }

    static func input(_ inputs: Inputs, _ a: SkierInput, _ b: SkierInput) -> SolveInput {
        SolveInput(
            bundle: inputs.bundle, status: inputs.status, conditions: inputs.conditions,
            at: inputs.at, skiers: (a, b)
        )
    }

    /// One skier's route to the agreed rendezvous.
    static func route(
        _ skier: SkierInput, to rendezvous: RendezvousID, _ inputs: Inputs
    ) async -> Result<Route, SolveFailure> {
        MeetSolver.route(for: skier, to: rendezvous, in: input(inputs, skier, skier))
    }

    static func recost(
        _ route: Route, from progress: RouteProgressValue, skier: SkierInput, _ inputs: Inputs
    ) async -> ETA? {
        MeetSolver.recost(route, from: progress, at: inputs.at, in: input(inputs, skier, skier))
    }
}
