import XCTest
@testable import PowderMeet

final class MeetSolverReadinessTests: XCTestCase {
    private func conditions(fetchedAt: Date) -> ResortConditions {
        ResortConditions(
            resortId: "test-resort",
            temperatureC: -5,
            windSpeedKph: 20,
            windGustsKph: 30,
            snowfallLast24hCm: 12,
            snowfallLast72hCm: 20,
            snowDepthCm: 100,
            weatherCode: 71,
            visibilityKm: 5,
            cloudCoverPercent: 80,
            windDirectionDeg: 270,
            stationElevationM: 1_800,
            fetchedAt: fetchedAt
        )
    }

    func testCanonicalSolveRequiresFreshOperationalStatus() {
        let failure = MeetSolver.Readiness.failure(
            isAuthoritativeDataset: true,
            hasFreshOperationalStatus: false,
            isMountainOffSeason: false
        )
        guard case .operationalStatusUnavailable? = failure else {
            return XCTFail("Expected stale canonical status to block a live solve")
        }
    }

    func testFreshCanonicalAndLegacyPreviewCanProceed() {
        XCTAssertNil(MeetSolver.Readiness.failure(
            isAuthoritativeDataset: true,
            hasFreshOperationalStatus: true,
            isMountainOffSeason: false
        ))
        XCTAssertNil(MeetSolver.Readiness.failure(
            isAuthoritativeDataset: false,
            hasFreshOperationalStatus: false,
            isMountainOffSeason: false
        ))
    }

    func testOffSeasonHasSpecificFailureCopy() {
        let failure = MeetSolver.Readiness.failure(
            isAuthoritativeDataset: true,
            hasFreshOperationalStatus: false,
            isMountainOffSeason: true
        )
        guard case .mountainOffSeason? = failure else {
            return XCTFail("Expected a specific off-season failure")
        }
    }

    func testRoutingWeatherFreshnessRejectsOldAndImplausiblyFutureSnapshots() {
        let now = Date(timeIntervalSince1970: 2_000_000)
        XCTAssertTrue(conditions(
            fetchedAt: now.addingTimeInterval(-ResortConditions.routingFreshnessWindow)
        ).isFreshForRouting(at: now))
        XCTAssertFalse(conditions(
            fetchedAt: now.addingTimeInterval(-ResortConditions.routingFreshnessWindow - 0.1)
        ).isFreshForRouting(at: now))
        XCTAssertTrue(conditions(
            fetchedAt: now.addingTimeInterval(ResortConditions.allowableFutureClockSkew)
        ).isFreshForRouting(at: now))
        XCTAssertFalse(conditions(
            fetchedAt: now.addingTimeInterval(ResortConditions.allowableFutureClockSkew + 0.1)
        ).isFreshForRouting(at: now))

        XCTAssertNotNil(MeetSolver.routingConditions(
            conditions(fetchedAt: now.addingTimeInterval(-60)),
            at: now
        ))
        XCTAssertNil(MeetSolver.routingConditions(
            conditions(
                fetchedAt: now.addingTimeInterval(
                    -ResortConditions.routingFreshnessWindow - 1
                )
            ),
            at: now
        ))
    }

    func testExplicitSessionParticipantIsAvailableWithoutFriendCache() {
        let localID = UUID()
        let friendID = UUID()
        let local = UserProfile.defaultProfile(id: localID)
        var friend = UserProfile.defaultProfile(id: friendID)
        friend.preferredSkiId = UUID()

        let resolved = MeetupSessionController.resolvedRoutingProfiles(
            currentUser: local,
            cachedFriends: [],
            participants: [local, friend]
        )

        XCTAssertEqual(resolved[localID], local)
        XCTAssertEqual(resolved[friendID], friend)
    }

    func testExplicitSessionParticipantOverridesStaleCachedSkiSelection() {
        let friendID = UUID()
        let staleSkiID = UUID()
        let selectedSkiID = UUID()
        var cachedFriend = UserProfile.defaultProfile(id: friendID)
        cachedFriend.displayName = "Cached Friend"
        cachedFriend.preferredSkiId = staleSkiID
        var sessionFriend = cachedFriend
        sessionFriend.displayName = "Session Friend"
        sessionFriend.preferredSkiId = selectedSkiID

        let resolved = MeetupSessionController.resolvedRoutingProfiles(
            currentUser: nil,
            cachedFriends: [cachedFriend],
            participants: [sessionFriend]
        )

        XCTAssertEqual(resolved.count, 1)
        XCTAssertEqual(resolved[friendID]?.displayName, "Session Friend")
        XCTAssertEqual(resolved[friendID]?.preferredSkiId, selectedSkiID)
    }
}
