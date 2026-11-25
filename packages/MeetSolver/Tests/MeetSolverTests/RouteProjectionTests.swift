import Foundation
import MountainCore
import Testing
@testable import MeetSolver

// The ghost's position along a solved route: it starts where the skier is
// (part-way along the first edge), moves with the solver's leg times, maps
// back to the same route time, and waits at the rendezvous once arrived.
@Test func aRouteProjectsWhereTheSkierWillBe() throws {
    var m = Mountain()
    let top = m.node("top", lon: -106, lat: 40.000, ele: 2_400)
    let mid = m.node("mid", lon: -106, lat: 40.004, ele: 2_200)
    let base = m.node("base", .liftBottom, lon: -106, lat: 40.008, ele: 2_000)
    m.run("upper", top, mid, length: 500)
    m.run("lower", mid, base, length: 500)
    m.meet(base)
    let bundle = m.bundle()
    let who = skier(at: .onEdge("upper", fraction: 0.5))
    let route = try MeetSolver.route(for: who, to: "base", in: input(bundle, who, who)).get()
    let projection = try #require(RouteProjection(route: route, graph: bundle.graph))

    let start = projection.position(atRouteTime: 0)
    #expect(start.legIndex == 0 && abs(start.fractionAlongLeg - 0.5) < 1e-9)
    #expect(abs(start.coordinate.lat - 40.002) < 1e-6, "the ghost starts where the skier is")
    #expect(projection.routeTime(legIndex: 0, fraction: 0.5) == 0)

    let first = route.legs[0]
    let halfway = projection.position(atRouteTime: (first.enterS + first.exitS) / 2)
    #expect(abs(halfway.fractionAlongLeg - 0.75) < 1e-9, "half the first leg's time covers half of what is left of it")

    let second = route.legs[1]
    let t = second.enterS + (second.exitS - second.enterS) * 0.3
    let onLower = projection.position(atRouteTime: t)
    #expect(onLower.legIndex == 1)
    #expect(abs(projection.routeTime(legIndex: onLower.legIndex, fraction: onLower.fractionAlongLeg) - t) < 1e-6)

    let end = projection.position(atRouteTime: projection.durationS + 600)
    #expect(end.arrived && end.coordinate == base.coordinate)
}
