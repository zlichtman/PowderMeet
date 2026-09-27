import XCTest
@testable import PowderMeet

final class SnapshotBuildProgressTests: XCTestCase {
    func testLargeMountainContinuesBeyondTwelveChunks() throws {
        var progress = SnapshotBuildProgress()
        for processed in stride(from: 0, through: 30_000, by: 600) {
            try progress.record(processed: processed, total: 30_000)
        }
    }

    func testStalledJobStopsAfterThreeRepeatedCheckpoints() throws {
        var progress = SnapshotBuildProgress()
        try progress.record(processed: 600, total: 6_000)
        try progress.record(processed: 600, total: 6_000)
        try progress.record(processed: 600, total: 6_000)
        XCTAssertThrowsError(try progress.record(processed: 600, total: 6_000))
    }

    func testRejectsChangedTotalRegressionAndInvalidProgress() throws {
        for (processed, total) in [(0, 6_000), (1_200, 7_000), (-1, 6_000), (6_001, 6_000)] {
            var progress = SnapshotBuildProgress()
            try progress.record(processed: 600, total: 6_000)
            XCTAssertThrowsError(try progress.record(processed: processed, total: total))
        }
        var progress = SnapshotBuildProgress()
        XCTAssertThrowsError(try progress.record(processed: 0, total: 0))
    }
}
