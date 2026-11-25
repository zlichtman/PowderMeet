import Foundation
import MeetSolver
import MountainCore

/// What the phone should signal as an active meet moves on: a new instruction,
/// a new route, leaving the route, arriving (once a meet: on this skier's arrival, or on the
/// meet completing if that is seen first). Pure: the app turns cues into haptics, a spoken
/// prompt and the arrival bell (`specs/07-CLIENT.md` section 6).
public enum NavigationCue: Hashable, Sendable {
    /// The maneuver the skier is now on, after a step, a new route or a reroute.
    case instruction(Maneuver)
    /// The route was replaced mid-meet (a closure, leaving it). Carries the
    /// hardest run above the skier's level when the new route is the easiest
    /// way down (06-SOLVER section 1), which must be said, not only shown.
    case rerouted(easiestWayDown: Difficulty?)
    case offRoute
    case arrived
}

/// Turns successive meet states into cues, each said once.
public struct NavigationCues: Sendable {
    private var meetID: UUID?
    private var routeLegs: [EdgeID]?
    private var maneuverIndex: Int?
    private var wasOffRoute = false
    private var hasArrived = false

    public init() {}

    public mutating func next(_ state: MeetSession.State) -> [NavigationCue] {
        if case .ended(let ended) = state, ended.reason == .arrived,
           let id = ended.meet?.meetID, id == meetID {
            // They met up. The state is kept, so the ended card repeating
            // itself says nothing more.
            guard !hasArrived else { return [] }
            hasArrived = true
            return [.arrived]
        }
        guard case .active(let active) = state else {
            self = NavigationCues()
            return []
        }
        if meetID != active.meet.meetID {
            self = NavigationCues()
            meetID = active.meet.meetID
        }
        if hasArrived { return [] }
        if active.arrived {
            hasArrived = true
            return [.arrived]
        }
        guard let navigation = active.navigation else { return [] }
        var cues: [NavigationCue] = []
        let offRoute = navigation.progress.state == .offRoute
        if offRoute, !wasOffRoute { cues.append(.offRoute) }
        wasOffRoute = offRoute

        let legs = navigation.route.legs.map(\.edgeID)
        let index = navigation.maneuverIndex
        let changed = legs != routeLegs || index != maneuverIndex
        if let known = routeLegs, known != legs {
            cues.append(.rerouted(easiestWayDown: navigation.route.easiestWayDown?.hardest))
        }
        routeLegs = legs
        maneuverIndex = index
        if changed, !offRoute, navigation.maneuvers.indices.contains(index) {
            cues.append(.instruction(navigation.maneuvers[index]))
        }
        return cues
    }
}
