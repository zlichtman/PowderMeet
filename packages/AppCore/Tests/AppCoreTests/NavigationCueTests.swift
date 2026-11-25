import Foundation
@testable import MeetSolver
import MountainCore
import PowderMeetAPI
import Testing
@testable import AppCore

/// Each cue once: an instruction per new step or route, off-route on leaving
/// it, the arrival once, nothing outside an active meet.
@Test func navigationCuesFireOncePerChange() {
    func maneuver(_ name: String, _ action: Maneuver.Action) -> Maneuver {
        Maneuver(action: action, name: name, group: nil, difficulty: nil, edgeIDs: [EdgeID(name)],
                 turn: .straight, lengthM: 100, enterS: 0, exitS: 60)
    }
    let ride = maneuver("lift", .ride), ski = maneuver("run", .ski)
    let route = Route(skierID: UUID(), legs: [RouteLeg(edgeID: "lift", enterS: 0, exitS: 60),
                                              RouteLeg(edgeID: "run", enterS: 60, exitS: 120)],
                      eta: ETA(meanS: 120, sdS: 10), hardestDifficulty: .blue, liftCount: 1, lengthM: 200)
    let meet = Meet(meetID: UUID(), resortID: "r", rendezvousID: "m", proposerID: UUID(), inviteeID: UUID(),
                    status: .active, createdAt: Date(), expiresAt: Date())
    func state(index: Int, offRoute: Bool = false, arrived: Bool = false, legs: Route? = nil) -> MeetSession.State {
        var progress = RouteProgressValue(fractionAlongLeg: 0)
        progress.state = offRoute ? .offRoute : .onRoute
        var active = MeetSession.Active(meet: meet)
        active.navigation = MeetSession.Navigation(
            route: legs ?? route, progress: progress, eta: route.eta, maneuvers: [ride, ski], maneuverIndex: index
        )
        active.arrived = arrived
        return .active(active)
    }
    var cues = NavigationCues()
    #expect(cues.next(.proposed(meet)).isEmpty)
    #expect(cues.next(state(index: 0)) == [.instruction(ride)])
    #expect(cues.next(state(index: 0)).isEmpty, "a new fix on the same step says nothing")
    #expect(cues.next(state(index: 1)) == [.instruction(ski)])
    #expect(cues.next(state(index: 1, offRoute: true)) == [.offRoute])
    #expect(cues.next(state(index: 1, offRoute: true)).isEmpty)
    var rerouted = route
    rerouted.legs.removeFirst()
    #expect(cues.next(state(index: 0, legs: rerouted)) == [.rerouted(easiestWayDown: nil), .instruction(ride)],
            "a reroute is said, and starts over")
    var steeper = route
    steeper.easiestWayDown = EasiestWayDown(
        hardest: .black, runsAboveLevel: [.black: 1], metresAboveLevel: 300, edgeIDs: ["run"]
    )
    #expect(cues.next(state(index: 0, legs: steeper)) == [.rerouted(easiestWayDown: .black), .instruction(ride)],
            "a reroute above the skier's level says so")
    #expect(cues.next(state(index: 0, arrived: true)) == [.arrived])
    #expect(cues.next(state(index: 1)).isEmpty, "nothing after arrival")
    var completed = meet
    completed.status = .completed
    let metUp = MeetSession.State.ended(MeetSession.Ended(meet: completed, reason: .arrived))
    #expect(cues.next(metUp).isEmpty, "already rung on arriving")

    // The skier still on the way when the meet completes hears it then, once.
    var waiting = NavigationCues()
    _ = waiting.next(state(index: 1))
    #expect(waiting.next(metUp) == [.arrived])
    #expect(waiting.next(metUp).isEmpty)
}
