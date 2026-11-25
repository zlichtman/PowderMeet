import Testing
@testable import AppCore

/// "42 of 213 runs" counts each named run once, however its name is spelled
/// in the log, and never counts an unnamed piece or a name the map lacks, so
/// the first number can never pass the second.
@Test func mountainCompletionCountsDistinctNamedRunsOnTheMap() {
    let count = MountainCompletion.count(
        trailNames: ["Peak to Creek", "Peak to Creek", "Ridge Run", "", "  ", "Upper Dave Murray"],
        skied: ["peak to creek ", "Ridge Run", "Gone Since Last Season"])
    #expect(count == MountainCompletion.Count(skied: 2, total: 3))
    #expect(MountainCompletion.count(trailNames: [], skied: ["Ridge Run"]).fraction == 0)
}
