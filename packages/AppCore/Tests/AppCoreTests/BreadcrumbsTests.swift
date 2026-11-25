import Foundation
import MountainCore
import Testing
@testable import AppCore

// Scrubbing back: a throttled trail, the point between two crumbs, nothing
// for a position gone stale, and a removed person gone from every answer.
@Test func breadcrumbsReplayWhereEveryoneWas() {
    let t0 = Date(timeIntervalSince1970: 1_768_438_800)
    let bob = UUID(), carol = UUID()
    var crumbs = Breadcrumbs()
    let kept = [
        crumbs.record(bob, at: Coordinate(lon: 0, lat: 0), time: t0),
        crumbs.record(bob, at: Coordinate(lon: 9, lat: 9), time: t0.addingTimeInterval(4)),
        crumbs.record(bob, at: Coordinate(lon: 0.002, lat: 0.001), time: t0.addingTimeInterval(20)),
        crumbs.record(carol, at: Coordinate(lon: 1, lat: 1), time: t0),
    ]
    #expect(kept == [true, false, true, true], "the second crumb is inside the 10 s throttle")

    let middle = crumbs.positions(at: t0.addingTimeInterval(10))
    #expect(abs((middle[bob]?.lon ?? 0) - 0.001) < 1e-12 && abs((middle[bob]?.lat ?? 0) - 0.0005) < 1e-12)
    #expect(middle[carol] == Coordinate(lon: 1, lat: 1), "the last crumb before, when there is none after")
    #expect(crumbs.positions(at: t0.addingTimeInterval(-1)).isEmpty, "nobody before their first crumb")
    #expect(crumbs.positions(at: t0.addingTimeInterval(20 + Breadcrumbs.staleAfterS + 1)).isEmpty, "stale")

    #expect(crumbs.trail(for: bob, since: t0.addingTimeInterval(1)).map(\.at) == [t0.addingTimeInterval(20)])
    #expect(crumbs.timeRange == t0...t0.addingTimeInterval(20))
    crumbs.remove(bob)
    #expect(crumbs.positions(at: t0.addingTimeInterval(10)).keys.sorted { $0.uuidString < $1.uuidString } == [carol])
}
