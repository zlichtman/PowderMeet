import Foundation
import MeetSolver
import MountainCore

/// "GO TO" a run or lift: a solo route from this phone's position. The solver
/// routes to rendezvous only (`MeetSolver.route(for:to:in:)`), so the route ends
/// at the catalog place on the run's or lift's entry, or, when there is none
/// there, the nearest one within `GoToPlanner.nearbyM`. The card says which.
public enum GoToPlanner {
    /// How far from the entry a stand-in rendezvous may be.
    public static let nearbyM = 300.0

    public struct Target: Sendable, Hashable {
        /// The run or lift asked for; nil when a place itself was asked for.
        public var group: GroupID?
        public var rendezvous: RendezvousID
        /// The rendezvous sits on the entry itself, not merely near it.
        public var isExact: Bool
        /// Straight-line distance from the entry to the rendezvous.
        public var offsetM: Double
    }

    public struct Plan: Sendable, Hashable {
        public var target: Target
        public var route: Route
        /// Vertical metres skied (descent) and ridden (ascent) along the route.
        public var descentM: Double
        public var ascentM: Double
    }

    public enum Failure: Error, Sendable, Hashable {
        /// Neither the entry nor anything near it is a place the solver can route to.
        case noTarget
        /// This phone's fix is not on or near the trail network.
        case notOnMap
        /// The route on screen crosses a lift or run that has since closed, and
        /// there is no usable fix to plan another from.
        case routeClosed
        case solver(SolveFailure)
    }

    /// Where a group is entered: a lift's bottom station, a run's highest start.
    public static func entryNode(of group: Group, in bundle: ResortBundle) -> Node? {
        let edges = group.edgeIDs.compactMap(bundle.graph.edge)
        let ends = Set(edges.map(\.to))
        let starts = edges.map(\.from).filter { !ends.contains($0) }
        let candidates = (starts.isEmpty ? edges.map(\.from) : starts).compactMap { bundle.graph.nodes[$0] }
        return candidates.max { a, b in
            a.eleM != b.eleM ? (group.kind == .lift ? a.eleM > b.eleM : a.eleM < b.eleM) : a.id > b.id
        }
    }

    public static func target(for groupID: GroupID, in bundle: ResortBundle) -> Target? {
        guard let group = bundle.group(groupID), let entry = entryNode(of: group, in: bundle) else {
            return nil
        }
        if let exact = bundle.rendezvous.first(where: { $0.nodeID == entry.id }) {
            return Target(group: groupID, rendezvous: exact.id, isExact: true, offsetM: 0)
        }
        let nearest = bundle.rendezvous.compactMap { point -> (Rendezvous, Double)? in
            bundle.graph.nodes[point.nodeID].map { (point, Geo.haversineM(entry.coordinate, $0.coordinate)) }
        }
        .min { ($0.1, $0.0.id) < ($1.1, $1.0.id) }
        guard let nearest, nearest.1 <= nearbyM else { return nil }
        return Target(group: groupID, rendezvous: nearest.0.id, isExact: false, offsetM: nearest.1)
    }

    /// One solve. Pure and synchronous: call it off the main actor.
    public static func plan(
        to groupID: GroupID, skier: SkierInput?, bundle: ResortBundle, status: ResortStatus?,
        conditions: Conditions?, at: Date
    ) -> Result<Plan, Failure> {
        guard let target = target(for: groupID, in: bundle) else { return .failure(.noTarget) }
        return plan(to: target, skier: skier, bundle: bundle, status: status, conditions: conditions, at: at)
    }

    /// A solo route to a place on the map (a lodge, a lift station): the
    /// place is a rendezvous, so the route ends on it exactly.
    public static func plan(
        toPlace place: RendezvousID, skier: SkierInput?, bundle: ResortBundle, status: ResortStatus?,
        conditions: Conditions?, at: Date
    ) -> Result<Plan, Failure> {
        guard bundle.rendezvous(place) != nil else { return .failure(.noTarget) }
        let target = Target(group: nil, rendezvous: place, isExact: true, offsetM: 0)
        return plan(to: target, skier: skier, bundle: bundle, status: status, conditions: conditions, at: at)
    }

    private static func plan(
        to target: Target, skier: SkierInput?, bundle: ResortBundle, status: ResortStatus?,
        conditions: Conditions?, at: Date
    ) -> Result<Plan, Failure> {
        guard let skier else { return .failure(.notOnMap) }
        let input = SolveInput(
            bundle: bundle, status: status, conditions: conditions, at: at, skiers: (skier, skier))
        switch MeetSolver.route(for: skier, to: target.rendezvous, in: input) {
        case .failure(let failure):
            return .failure(.solver(failure))
        case .success(let route):
            var descent = 0.0, ascent = 0.0
            for leg in route.legs {
                guard let edge = bundle.graph.edge(leg.edgeID) else { continue }
                let share = 1 - max(0, min(1, leg.startFraction))
                if edge.verticalM < 0 { descent -= edge.verticalM * share } else { ascent += edge.verticalM * share }
            }
            return .success(Plan(target: target, route: route, descentM: descent, ascentM: ascent))
        }
    }
}
