import Foundation
import MountainCore
import Testing
@testable import MeetSolver

/// Two ways down to one lift: a shorter north-facing run in the shade and a
/// longer one facing the midday sun. At −5 °C the shaded snow is hard, so the
/// sunny run is quicker though the shaded one is shorter.
private func sunAndShade() -> (ResortBundle, SkierInput) {
    var mountain = Mountain()
    let top = mountain.node("top", lon: -105.0)
    let base = mountain.node("base", lon: -105.01)
    mountain.run("shaded", top, base, length: 2_000, aspect: 0)
    mountain.run("sunny", top, base, length: 2_200, aspect: 180)
    mountain.lift("chair", base, top, ride: 300)
    mountain.meet(base)
    return (mountain.bundle(), skier(at: top))
}

@Test func aRouteTheSunFavouredSaysSo() throws {
    let (bundle, who) = sunAndShade()
    let noon = Clock.denver(12)
    let cold = input(bundle, who, who, at: noon, conditions: weather(at: noon, tempC: -5))
    let option = try #require(try MeetSolver.solve(cold).get().options.first)
    #expect(option.routes.0.legs.map(\.edgeID) == ["sunny"])
    #expect(option.routes.0.weatherFavours == [.sunnySide])
    #expect(try MeetSolver.route(for: who, to: "base", in: cold).get().weatherFavours == [.sunnySide])

    // No weather, no weather words: the shorter run is simply the way.
    let plain = try #require(try MeetSolver.solve(input(bundle, who, who, at: noon)).get().options.first)
    #expect(plain.routes.0.legs.map(\.edgeID) == ["shaded"])
    #expect(plain.routes.0.weatherFavours.isEmpty)
}
