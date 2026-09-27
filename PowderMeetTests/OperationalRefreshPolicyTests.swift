import XCTest
@testable import PowderMeet

final class OperationalRefreshPolicyTests: XCTestCase {
    func testMissingAndExpiredStatusRefreshWhenRetryWindowAllows() {
        let now = Date(timeIntervalSince1970: 10_000)
        XCTAssertTrue(OperationalRefreshPolicy.shouldRefresh(
            status: nil,
            now: now,
            lastAttemptAt: nil
        ))
        XCTAssertTrue(OperationalRefreshPolicy.shouldRefresh(
            status: status(expiresAt: now.addingTimeInterval(-1), now: now),
            now: now,
            lastAttemptAt: nil
        ))
    }

    func testRefreshesBeforeExpiryButNotWhileStatusHasRoom() {
        let now = Date(timeIntervalSince1970: 10_000)
        XCTAssertTrue(OperationalRefreshPolicy.shouldRefresh(
            status: status(expiresAt: now.addingTimeInterval(60), now: now),
            now: now,
            lastAttemptAt: nil
        ))
        XCTAssertFalse(OperationalRefreshPolicy.shouldRefresh(
            status: status(expiresAt: now.addingTimeInterval(10 * 60), now: now),
            now: now,
            lastAttemptAt: nil
        ))
    }

    func testFailedRefreshIsThrottledBeforeRetrying() {
        let now = Date(timeIntervalSince1970: 10_000)
        XCTAssertFalse(OperationalRefreshPolicy.shouldRefresh(
            status: nil,
            now: now,
            lastAttemptAt: now.addingTimeInterval(-60)
        ))
        XCTAssertTrue(OperationalRefreshPolicy.shouldRefresh(
            status: nil,
            now: now,
            lastAttemptAt: now.addingTimeInterval(-OperationalRefreshPolicy.retryInterval)
        ))
    }

    private func status(expiresAt: Date, now: Date) -> MountainStatus {
        MountainStatus(
            resortID: "test",
            datasetVersion: MountainDatasetVersion(
                manifestVersion: 1,
                graphVersion: "v1",
                contentSHA256: String(repeating: "a", count: 64)
            ),
            observedAt: now.addingTimeInterval(-60),
            expiresAt: expiresAt,
            source: .canonicalSidecar,
            confidence: 1,
            segmentStates: [:]
        )
    }
}
