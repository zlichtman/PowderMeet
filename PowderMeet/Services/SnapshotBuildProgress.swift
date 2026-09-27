import Foundation

/// Large mountains need more than a fixed dozen elevation chunks. Continue
/// while the same snapshot makes progress; reject stalled or changing jobs.
nonisolated struct SnapshotBuildProgress {
    static let maximumSteps = 256
    private var previousProcessed: Int?
    private var expectedTotal: Int?
    private var stalledSteps = 0

    mutating func record(processed: Int, total: Int) throws {
        guard total > 0, processed >= 0, processed <= total,
              expectedTotal == nil || expectedTotal == total,
              previousProcessed == nil || processed >= previousProcessed! else {
            throw URLError(.badServerResponse)
        }
        stalledSteps = previousProcessed == processed ? stalledSteps + 1 : 0
        guard stalledSteps < 3 else { throw URLError(.timedOut) }
        expectedTotal = total
        previousProcessed = processed
    }
}
