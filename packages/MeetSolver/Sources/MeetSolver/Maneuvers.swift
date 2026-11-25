import Foundation
import MountainCore

/// One instruction a skier follows: a whole trail, lift or connector, however
/// many edges it is stored as.
public struct Maneuver: Hashable, Sendable {
    public enum Action: Hashable, Sendable { case ski, ride, connect }
    public enum Turn: Hashable, Sendable { case left, straight, right }

    public var action: Action
    /// nil when the trail, lift or connector has no name (an empty name is none).
    public var name: String?
    public var group: GroupID?
    /// The run's marked rating; nil for lifts, connectors and unrated runs.
    public var difficulty: Difficulty?
    public var edgeIDs: [EdgeID]
    /// Direction onto this maneuver from the one before, from geometry.
    public var turn: Turn
    public var lengthM: Double
    /// Seconds from the route's start.
    public var enterS: Double
    public var exitS: Double
}

public enum Maneuvers {
    static let turnThresholdDeg = 25.0

    public static func build(for route: Route, in bundle: ResortBundle) -> [Maneuver] {
        var maneuvers: [Maneuver] = []
        var previous: Edge?
        var previousIdentity: String?
        for leg in route.legs {
            guard let edge = bundle.graph.edge(leg.edgeID) else { continue }
            let identity = RouteSimplicity.actionIdentity(for: edge)
            let lengthM = edge.lengthM * (1 - leg.startFraction)
            if identity == previousIdentity, previous?.to == edge.from, !maneuvers.isEmpty {
                // Fragments of one trail or lift continue straight on.
                maneuvers[maneuvers.count - 1].edgeIDs.append(edge.id)
                maneuvers[maneuvers.count - 1].lengthM += lengthM
                maneuvers[maneuvers.count - 1].exitS = leg.exitS
            } else {
                let action: Maneuver.Action = switch edge.kind {
                case .run: .ski
                case .lift: .ride
                case .connection: .connect
                }
                let named = [edge.name, edge.group.flatMap { bundle.group($0)?.name }]
                    .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .first { !$0.isEmpty }
                maneuvers.append(Maneuver(
                    action: action,
                    name: named,
                    group: edge.group,
                    difficulty: edge.kind == .run ? edge.difficulty.flatMap { $0 == .unknown ? nil : $0 } : nil,
                    edgeIDs: [edge.id], turn: turn(from: previous, to: edge), lengthM: lengthM,
                    enterS: leg.enterS, exitS: leg.exitS
                ))
            }
            previous = edge
            previousIdentity = identity
        }
        return foldingShortLinks(maneuvers)
    }

    /// An unnamed link shorter than this is not worth an instruction of its own.
    static let shortLinkM = 100.0
    /// ...or quicker than this to cover, whatever its length.
    static let shortLinkS = 20.0

    /// Folds short unnamed runs and connectors (mostly the few metres between a
    /// lift station and the first named trail, or what is left of the edge a
    /// route starts part-way along) into the instruction they lead to, or into
    /// the one before when nothing follows. Lifts are never folded.
    static func foldingShortLinks(_ maneuvers: [Maneuver]) -> [Maneuver] {
        func isShortLink(_ m: Maneuver) -> Bool {
            m.action != .ride && m.name == nil
                && (m.lengthM < shortLinkM || m.exitS - m.enterS < shortLinkS)
        }
        var folded: [Maneuver] = []
        var carried: Maneuver?
        for var maneuver in maneuvers {
            if let link = carried {
                maneuver.edgeIDs = link.edgeIDs + maneuver.edgeIDs
                maneuver.lengthM += link.lengthM
                maneuver.enterS = link.enterS
                maneuver.turn = link.turn
                carried = nil
            }
            if isShortLink(maneuver) { carried = maneuver } else { folded.append(maneuver) }
        }
        if let link = carried {
            if folded.isEmpty {
                folded.append(link)
            } else {
                folded[folded.count - 1].edgeIDs += link.edgeIDs
                folded[folded.count - 1].lengthM += link.lengthM
                folded[folded.count - 1].exitS = link.exitS
            }
        }
        return folded
    }

    /// Bearings increase clockwise, so a positive change is a right turn. Small
    /// changes stay straight so noisy vertices do not invent turns.
    static func turn(from current: Edge?, to next: Edge) -> Maneuver.Turn {
        guard let current, let incoming = terminalBearing(current.coordinates),
              let outgoing = initialBearing(next.coordinates) else { return .straight }
        var delta = outgoing - incoming
        while delta > 180 { delta -= 360 }
        while delta < -180 { delta += 360 }
        if delta < -turnThresholdDeg { return .left }
        if delta > turnThresholdDeg { return .right }
        return .straight
    }

    private static func distinct(_ a: Coordinate, _ b: Coordinate) -> Bool {
        let dLat = a.lat - b.lat, dLon = a.lon - b.lon
        return dLat * dLat + dLon * dLon > 1e-16
    }

    private static func initialBearing(_ line: [Coordinate]) -> Double? {
        guard let first = line.first else { return nil }
        return line.dropFirst().first { distinct(first, $0) }
            .map { Geo.bearingDeg(from: first, to: $0) }
    }

    private static func terminalBearing(_ line: [Coordinate]) -> Double? {
        guard let last = line.last else { return nil }
        return line.dropLast().last { distinct($0, last) }
            .map { Geo.bearingDeg(from: $0, to: last) }
    }
}
