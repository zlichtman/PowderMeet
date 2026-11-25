import Foundation
import MountainCore
import Testing
@testable import MeetSolver

// A listed step never reads "UNNAMED RUN ?": a short or quick unnamed leg folds
// into the named step it leads to, an empty name is no name, and an unrated run
// has no difficulty rather than "unknown".

@Test func shortOrQuickUnnamedLegsFoldIntoTheNamedStep() {
    var m = Mountain()
    let start = m.node("start", lon: 0), mid = m.node("mid", lon: 0.002), end = m.node("end", lon: 0.02)
    // 180 m but only 5 s: longer than the length rule, quicker than the time rule.
    let lead = m.run("lead", start, mid, length: 180, difficulty: .unknown, drop: 30, name: "")
    let named = m.run("named", mid, end, length: 1_200, difficulty: .blue, drop: 200, name: "Franz's")
    let bundle = m.bundle()
    let route = Route(
        skierID: UUID(),
        legs: [RouteLeg(edgeID: lead.id, enterS: 0, exitS: 5), RouteLeg(edgeID: named.id, enterS: 5, exitS: 200)],
        eta: ETA(meanS: 200, sdS: 20), hardestDifficulty: .blue, liftCount: 0, lengthM: 1_380
    )
    let steps = Maneuvers.build(for: route, in: bundle)
    #expect(steps.count == 1)
    #expect(steps.first?.name == "Franz's")
    #expect(steps.first?.edgeIDs == [lead.id, named.id])
    #expect(steps.first?.enterS == 0)
}

@Test func anUnnamedStepThatStaysHasNoInventedDifficulty() {
    var m = Mountain()
    let start = m.node("start", lon: 0), end = m.node("end", lon: 0.02)
    let only = m.run("only", start, end, length: 900, difficulty: .unknown, drop: 150, name: "  ")
    let route = Route(
        skierID: UUID(), legs: [RouteLeg(edgeID: only.id, enterS: 0, exitS: 150)],
        eta: ETA(meanS: 150, sdS: 15), hardestDifficulty: .unknown, liftCount: 0, lengthM: 900
    )
    let steps = Maneuvers.build(for: route, in: m.bundle())
    #expect(steps.count == 1)
    #expect(steps.first?.name == nil)
    #expect(steps.first?.difficulty == nil)
}
