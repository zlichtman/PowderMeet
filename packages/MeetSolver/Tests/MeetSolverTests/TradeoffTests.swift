import Foundation
import MountainCore
import Testing
@testable import MeetSolver

// The tradeoff label reference cases, with the wait spread read as idle time
// (the wait left after any lap). There is no missing-uncertainty case: every
// ETA carries a finite sd.

private func m(
    _ rank: Int?, latest: Double, idle: Double, sd: Double, lifts: Int, connector: Double = 0
) -> Tradeoffs.Metrics {
    Tradeoffs.Metrics(
        terrainRank: rank, latestArrivalS: latest, idleS: idle, uncertaintyS: sd,
        liftBoardings: lifts, connectorM: connector
    )
}

@Test func alternateMeetingLabelsExplainMaterialTradeoff() {
    let pick = m(3, latest: 600, idle: 120, sd: 100, lifts: 3)
    func label(_ alternate: Tradeoffs.Metrics, against: Tradeoffs.Metrics = pick) -> Tradeoff {
        Tradeoffs.alternate(alternate, against: against)
    }
    #expect(label(m(2, latest: 700, idle: 120, sd: 100, lifts: 3)) == .easierTerrain)
    #expect(label(m(3, latest: 560, idle: 180, sd: 150, lifts: 4)) == .quickerArrival)
    #expect(label(m(2, latest: 650, idle: 120, sd: 100, lifts: 3, connector: 200),
                  against: m(2, latest: 600, idle: 120, sd: 100, lifts: 3, connector: 500)) == .lessSkating)
    #expect(label(m(3, latest: 650, idle: 50, sd: 100, lifts: 3)) == .lessWaiting)
    #expect(label(m(3, latest: 650, idle: 120, sd: 60, lifts: 3)) == .morePredictable)
    #expect(label(m(3, latest: 650, idle: 120, sd: 100, lifts: 2)) == .fewerLifts)
    #expect(label(m(3, latest: 650, idle: 120, sd: 100, lifts: 3)) == .alternative)
}

@Test func primaryMeetingLabelExplainsWhyTheRecommendationWon() {
    let pick = m(2, latest: 600, idle: 60, sd: 50, lifts: 2)
    func label(_ other: Tradeoffs.Metrics) -> Tradeoff { Tradeoffs.primary(pick, alternates: [other]) }
    #expect(Tradeoffs.primary(pick, alternates: []) == .onlyOption)
    #expect(label(m(1, latest: 640, idle: 20, sd: 20, lifts: 1)) == .fastestTogether)
    #expect(label(m(1, latest: 610, idle: 130, sd: 20, lifts: 1)) == .leastWaiting)
    #expect(label(m(1, latest: 610, idle: 70, sd: 100, lifts: 1)) == .mostPredictable)
    #expect(label(m(3, latest: 610, idle: 70, sd: 60, lifts: 1)) == .easiestTerrain)
    #expect(label(m(2, latest: 610, idle: 70, sd: 60, lifts: 3)) == .fewestLifts)
    #expect(label(m(1, latest: 610, idle: 70, sd: 60, lifts: 1)) == .bestBalance)
}

@Test func unknownDifficultyDoesNotBecomeEasierTerrain() {
    let black = m(2, latest: 100, idle: 0, sd: 14, lifts: 0)
    let unrated = m(nil, latest: 100, idle: 0, sd: 14, lifts: 0)
    #expect(Tradeoffs.alternate(unrated, against: black) != .easierTerrain)
    #expect(Tradeoffs.primary(unrated, alternates: [black]) != .easiestTerrain)
}

@Test func anUnevenPickNeverClaimsSpeedOrSync() {
    // The card already says the wait is unavoidable or no lift runs; it must not
    // also headline "fastest together" or "least waiting".
    var pick = m(1, latest: 600, idle: 900, sd: 50, lifts: 0)
    pick.flaggedUneven = true
    let other = m(1, latest: 700, idle: 1_200, sd: 50, lifts: 0)
    #expect(Tradeoffs.primary(pick, alternates: [other]) == .bestBalance)
}

@Test func aLapIsSkiingNotWaitingInTheLabels() throws {
    // Same arrivals; the pick's earlier skier laps for most of the gap.
    let ride = Route(skierID: UUID(), legs: [], eta: ETA(meanS: 600, sdS: 30), hardestDifficulty: .green,
                     liftCount: 0, lengthM: 0)
    let lap = Route(skierID: UUID(), legs: [RouteLeg(edgeID: "x", enterS: 300, exitS: 560)],
                    eta: ETA(meanS: 560, sdS: 30), hardestDifficulty: .green, liftCount: 1, lengthM: 0)
    var early = ride
    early.eta.meanS = 300
    let option = MeetOption(rendezvous: "r", routes: (early, ride), score: 0, expectedWaitS: 300,
                            reasons: [], lapWhileWaiting: lap)
    let metrics = Tradeoffs.metrics(option, graph: Mountain().bundle().graph)
    #expect(abs(metrics.idleS - 40) < 1e-9)
}
