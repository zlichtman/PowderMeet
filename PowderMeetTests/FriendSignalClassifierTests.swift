import XCTest
@testable import PowderMeet

final class FriendSignalClassifierTests: XCTestCase {
    private let now = Date(timeIntervalSinceReferenceDate: 10_000)

    func testSignalQualityThresholdsAreStable() {
        XCTAssertEqual(
            FriendSignalClassifier.classify(lastSeen: now.addingTimeInterval(-74), now: now),
            .live
        )
        XCTAssertEqual(
            FriendSignalClassifier.classify(lastSeen: now.addingTimeInterval(-75), now: now),
            .stale(minutesAgo: 1)
        )
        XCTAssertEqual(
            FriendSignalClassifier.classify(lastSeen: now.addingTimeInterval(-359), now: now),
            .stale(minutesAgo: 5)
        )
        XCTAssertEqual(
            FriendSignalClassifier.classify(lastSeen: now.addingTimeInterval(-360), now: now),
            .cold(minutesAgo: 6)
        )
        XCTAssertEqual(
            FriendSignalClassifier.classify(lastSeen: now.addingTimeInterval(31), now: now),
            .cold(minutesAgo: 0)
        )
    }

    func testExternalLocationPayloadCannotPoisonMonotonicState() {
        XCTAssertTrue(FriendSignalClassifier.isAcceptableLocationPayload(
            latitude: 50.1,
            longitude: -122.9,
            capturedAt: now.addingTimeInterval(-30),
            now: now
        ))
        XCTAssertFalse(FriendSignalClassifier.isAcceptableLocationPayload(
            latitude: 91,
            longitude: -122.9,
            capturedAt: now,
            now: now
        ))
        XCTAssertFalse(FriendSignalClassifier.isAcceptableLocationPayload(
            latitude: 50.1,
            longitude: 181,
            capturedAt: now,
            now: now
        ))
        XCTAssertFalse(FriendSignalClassifier.isAcceptableLocationPayload(
            latitude: 50.1,
            longitude: -122.9,
            capturedAt: now.addingTimeInterval(31),
            now: now
        ))
        XCTAssertFalse(FriendSignalClassifier.isAcceptableLocationPayload(
            latitude: 50.1,
            longitude: -122.9,
            capturedAt: now.addingTimeInterval(-(3 * 60 * 60 + 1)),
            now: now
        ))
        XCTAssertFalse(FriendSignalClassifier.isVisibleOnMap(
            lastSeen: now.addingTimeInterval(31),
            now: now
        ))
    }

    func testOnlyLiveFriendFixCanMoveARouteOrigin() {
        XCTAssertTrue(FriendSignalClassifier.isEligibleForReroute(
            lastSeen: now.addingTimeInterval(-30),
            now: now
        ))
        XCTAssertFalse(FriendSignalClassifier.isEligibleForReroute(
            lastSeen: now.addingTimeInterval(-75),
            now: now
        ))
        XCTAssertFalse(FriendSignalClassifier.isEligibleForReroute(
            lastSeen: now.addingTimeInterval(-600),
            now: now
        ))
    }

    func testRoutingRejectsPoorAccuracyAndImplausibleFutureFixes() {
        XCTAssertTrue(FriendSignalClassifier.isEligibleForReroute(
            lastSeen: now.addingTimeInterval(-20),
            accuracyMeters: 40,
            now: now
        ))
        XCTAssertFalse(FriendSignalClassifier.isEligibleForReroute(
            lastSeen: now.addingTimeInterval(-20),
            accuracyMeters: 151,
            now: now
        ))
        XCTAssertFalse(FriendSignalClassifier.isEligibleForReroute(
            lastSeen: now.addingTimeInterval(31),
            accuracyMeters: 20,
            now: now
        ))
        XCTAssertTrue(FriendSignalClassifier.isEligibleForReroute(
            lastSeen: now.addingTimeInterval(-20),
            accuracyMeters: nil,
            now: now
        ))
    }

    func testSharedRoutingAccuracyPolicyHasExplicitBounds() {
        XCTAssertTrue(RoutingFixPolicy.isUsable(horizontalAccuracyMeters: nil))
        XCTAssertTrue(RoutingFixPolicy.isUsable(horizontalAccuracyMeters: 150))
        XCTAssertFalse(RoutingFixPolicy.isUsable(horizontalAccuracyMeters: 150.1))
        XCTAssertFalse(RoutingFixPolicy.isUsable(horizontalAccuracyMeters: -1))

        XCTAssertTrue(RoutingFixPolicy.isUsable(
            horizontalAccuracyMeters: 20,
            capturedAt: now.addingTimeInterval(-74),
            now: now
        ))
        XCTAssertFalse(RoutingFixPolicy.isUsable(
            horizontalAccuracyMeters: 20,
            capturedAt: now.addingTimeInterval(-75),
            now: now
        ))
        XCTAssertFalse(RoutingFixPolicy.isUsable(
            horizontalAccuracyMeters: 20,
            capturedAt: now.addingTimeInterval(31),
            now: now
        ))
        XCTAssertFalse(RoutingFixPolicy.isUsable(
            horizontalAccuracyMeters: 20,
            capturedAt: nil,
            now: now
        ))
        XCTAssertTrue(RoutingFixPolicy.isFresh(
            capturedAt: now.addingTimeInterval(-74),
            now: now
        ))
        XCTAssertFalse(RoutingFixPolicy.isFresh(
            capturedAt: now.addingTimeInterval(-75),
            now: now
        ))
        XCTAssertEqual(
            RoutingFixPolicy.accuracyFingerprintBucket(horizontalAccuracyMeters: 104),
            10
        )
        XCTAssertEqual(
            RoutingFixPolicy.accuracyFingerprintBucket(horizontalAccuracyMeters: 15),
            2
        )
        XCTAssertEqual(
            RoutingFixPolicy.accuracyFingerprintBucket(horizontalAccuracyMeters: nil),
            -1
        )
    }

    @MainActor
    func testFriendCourseIsBackwardCompatibleAndOnlyUsedWhileMoving() throws {
        let legacyJSON = """
        {"u":"00000000-0000-0000-0000-000000000001","lat":40,"lon":-106,"at":1,"r":"test"}
        """
        let legacy = try JSONDecoder().decode(
            RealtimeLocationService.PositionPayload.self,
            from: Data(legacyJSON.utf8)
        )
        XCTAssertNil(legacy.crs)
        XCTAssertNil(legacy.spd)
        XCTAssertNil(legacy.alt)
        XCTAssertNil(legacy.vacc)

        let id = UUID()
        let stationary = RealtimeLocationService.FriendLocation(
            userId: id,
            displayName: "Friend",
            resortId: "test",
            latitude: 40,
            longitude: -106,
            capturedAt: now,
            nearestNodeId: nil,
            accuracyMeters: 10,
            courseDegrees: 180,
            speedMetersPerSecond: 0.5
        )
        XCTAssertNil(stationary.usableTravelCourse)

        let moving = RealtimeLocationService.FriendLocation(
            userId: id,
            displayName: "Friend",
            resortId: "test",
            latitude: 40,
            longitude: -106,
            capturedAt: now,
            nearestNodeId: nil,
            accuracyMeters: 10,
            courseDegrees: 180,
            speedMetersPerSecond: 4
        )
        XCTAssertEqual(moving.usableTravelCourse, 180)

        let elevated = RealtimeLocationService.FriendLocation(
            userId: id,
            displayName: "Friend",
            resortId: "test",
            latitude: 40,
            longitude: -106,
            capturedAt: now,
            nearestNodeId: nil,
            accuracyMeters: 10,
            altitudeMeters: 2_100,
            verticalAccuracyMeters: 20
        )
        XCTAssertEqual(elevated.routingAltitudeMeters, 2_100)

        let poorVerticalAccuracy = RealtimeLocationService.FriendLocation(
            userId: id,
            displayName: "Friend",
            resortId: "test",
            latitude: 40,
            longitude: -106,
            capturedAt: now,
            nearestNodeId: nil,
            accuracyMeters: 10,
            altitudeMeters: 2_100,
            verticalAccuracyMeters: 51
        )
        XCTAssertNil(poorVerticalAccuracy.routingAltitudeMeters)
    }

    func testCachedPresenceRequiresTheSelectedResortAndFreshTimestamp() {
        XCTAssertTrue(FriendSignalClassifier.establishesSameResortPresence(
            locationResortID: "whistler-blackcomb",
            selectedResortID: "whistler-blackcomb",
            lastSeen: now.addingTimeInterval(-89),
            now: now
        ))
        XCTAssertFalse(FriendSignalClassifier.establishesSameResortPresence(
            locationResortID: "whistler-blackcomb",
            selectedResortID: "park-city",
            lastSeen: now.addingTimeInterval(-10),
            now: now
        ))
        XCTAssertFalse(FriendSignalClassifier.establishesSameResortPresence(
            locationResortID: "whistler-blackcomb",
            selectedResortID: nil,
            lastSeen: now.addingTimeInterval(-10),
            now: now
        ))
        XCTAssertFalse(FriendSignalClassifier.establishesSameResortPresence(
            locationResortID: "whistler-blackcomb",
            selectedResortID: "whistler-blackcomb",
            lastSeen: now.addingTimeInterval(-90),
            now: now
        ))
    }

    func testRoutingUsesFreshPacketResortInsteadOfProfileState() {
        XCTAssertTrue(FriendSignalClassifier.isEligibleForRouting(
            locationResortID: "whistler-blackcomb",
            selectedResortID: "whistler-blackcomb",
            lastSeen: now.addingTimeInterval(-10),
            accuracyMeters: 25,
            now: now
        ))
        XCTAssertFalse(FriendSignalClassifier.isEligibleForRouting(
            locationResortID: "park-city",
            selectedResortID: "whistler-blackcomb",
            lastSeen: now.addingTimeInterval(-10),
            accuracyMeters: 25,
            now: now
        ))
        XCTAssertFalse(FriendSignalClassifier.isEligibleForRouting(
            locationResortID: "whistler-blackcomb",
            selectedResortID: "whistler-blackcomb",
            lastSeen: now.addingTimeInterval(-80),
            accuracyMeters: 25,
            now: now
        ))
    }

    func testPartnerArrivalRequiresAZeroishETAAndLiveSignal() {
        func arrives(etaSeconds: Double, signalQuality: FriendSignalQuality?, distanceToMeetingMeters: Double?) -> Bool {
            MeetArrivalStatusClassifier.partnerHasArrived(etaSeconds: etaSeconds, signalQuality: signalQuality,
                distanceToMeetingMeters: distanceToMeetingMeters, capturedAt: now, accuracyMeters: 0,
                locationResortID: "test", meetingResortID: "test", now: now)
        }
        XCTAssertTrue(arrives(
            etaSeconds: 4.9,
            signalQuality: .live,
            distanceToMeetingMeters: 109.9
        ))
        XCTAssertFalse(arrives(
            etaSeconds: 6,
            signalQuality: .live,
            distanceToMeetingMeters: 10
        ))
        XCTAssertFalse(arrives(
            etaSeconds: 0,
            signalQuality: .stale(minutesAgo: 1),
            distanceToMeetingMeters: 10
        ))
        XCTAssertFalse(arrives(
            etaSeconds: 0,
            signalQuality: nil,
            distanceToMeetingMeters: 10
        ))
        XCTAssertFalse(arrives(
            etaSeconds: 0,
            signalQuality: .live,
            distanceToMeetingMeters: 110.1
        ))
        XCTAssertFalse(arrives(
            etaSeconds: 0,
            signalQuality: .live,
            distanceToMeetingMeters: nil
        ))
    }

    func testSignalPresentationIsSharedAndFailClosed() {
        let live = FriendSignalPresentation(quality: .live)
        XCTAssertNil(live.statusText)
        XCTAssertEqual(live.tone, .live)
        XCTAssertTrue(live.isLive)
        XCTAssertEqual(
            FriendSignalPresentation(quality: .stale(minutesAgo: 0)).statusText,
            "1M AGO"
        )
        let offline = FriendSignalPresentation(quality: .cold(minutesAgo: 20))
        XCTAssertEqual(offline.statusText, "OFFLINE")
        XCTAssertEqual(offline.tone, .unavailable)
        XCTAssertFalse(offline.isLive)
        let unknown = FriendSignalPresentation(quality: nil)
        XCTAssertEqual(unknown.statusText, "NO SIGNAL")
        XCTAssertEqual(unknown.tone, .unavailable)
        XCTAssertFalse(unknown.isLive)
    }

    func testArrivalRequiresCapturedFreshnessAndSameMountainDespiteLiveBadge() {
        func arrived(age: Double?, resort: String? = "test") -> Bool {
            MeetArrivalStatusClassifier.partnerHasArrived(etaSeconds: 0, signalQuality: .live,
                distanceToMeetingMeters: 10, capturedAt: age.map { now.addingTimeInterval(-$0) },
                accuracyMeters: 10, locationResortID: resort, meetingResortID: "test", now: now)
        }
        XCTAssertTrue(arrived(age: 74))
        XCTAssertFalse(arrived(age: 75))
        XCTAssertFalse(arrived(age: -31))
        XCTAssertFalse(arrived(age: nil))
        XCTAssertFalse(arrived(age: 0, resort: "other"))
        XCTAssertFalse(arrived(age: 0, resort: nil))
    }

    func testArrivalAccuracyCircleMustFitInsideMeetingArea() {
        func arrived(distance: Double = 90, accuracy: Double?) -> Bool {
            MeetArrivalStatusClassifier.partnerHasArrived(etaSeconds: 0, signalQuality: .live,
                distanceToMeetingMeters: distance, capturedAt: now, accuracyMeters: accuracy,
                locationResortID: "test", meetingResortID: "test", now: now)
        }
        XCTAssertTrue(arrived(accuracy: 20))
        XCTAssertFalse(arrived(accuracy: 20.01))
        for accuracy in [nil, -1, .nan, .infinity, 150] as [Double?] {
            XCTAssertFalse(arrived(distance: 0, accuracy: accuracy))
        }
        for distance in [Double.nan, .infinity, -1, 111] {
            XCTAssertFalse(arrived(distance: distance, accuracy: 0))
        }
    }

    func testNearZeroRemoteETAIsUnconfirmedUntilLocationEvidenceAgrees() {
        XCTAssertEqual(MeetArrivalStatusClassifier.partnerETAStatus(etaSeconds: 0, hasArrived: false), "ARRIVAL UNCONFIRMED")
        XCTAssertEqual(MeetArrivalStatusClassifier.partnerETAStatus(etaSeconds: 5, hasArrived: false), "ARRIVAL UNCONFIRMED")
        XCTAssertEqual(MeetArrivalStatusClassifier.partnerETAStatus(etaSeconds: 0, hasArrived: true), "NEAR MEETING POINT")
        XCTAssertNil(MeetArrivalStatusClassifier.partnerETAStatus(etaSeconds: 6, hasArrived: false))
        for eta in [Double.nan, .infinity, -1, .greatestFiniteMagnitude] {
            XCTAssertEqual(MeetArrivalStatusClassifier.partnerETAStatus(etaSeconds: eta, hasArrived: false), "UNAVAILABLE")
            XCTAssertEqual(UnitFormatter.formatTime(eta), "UNAVAILABLE")
        }
        XCTAssertEqual(UnitFormatter.formatTime(65.9), "1m 5s")
        XCTAssertEqual(UnitFormatter.formatTime(3665), "1h 1m")
    }

    func testSignalTickerWakesAtFreshnessAndMinuteBoundaries() {
        func delay(_ age: Double) -> Double {
            FriendSignalClassifier.nextClassificationDelay(lastSeen: now.addingTimeInterval(-age), now: now)
        }
        XCTAssertEqual(delay(0), 30)
        XCTAssertEqual(delay(60), 15)
        XCTAssertEqual(delay(74), 1)
        XCTAssertEqual(delay(119), 1)
        XCTAssertEqual(delay(359), 1)
        XCTAssertEqual(delay(360), 30)
        XCTAssertEqual(delay(-31), 30)
        XCTAssertGreaterThan(delay(74.999), 0)
    }

    func testInvalidAndExtremeTimestampsCannotCrashSignalClassification() {
        for seconds in [Double.nan, .infinity, -.infinity] {
            let date = Date(timeIntervalSince1970: seconds)
            XCTAssertEqual(FriendSignalClassifier.classify(lastSeen: date, now: now), .cold(minutesAgo: 0))
            XCTAssertEqual(FriendSignalClassifier.nextClassificationDelay(lastSeen: date, now: now), 30)
        }
        XCTAssertEqual(FriendSignalClassifier.classify(lastSeen: Date(timeIntervalSince1970: -Double.greatestFiniteMagnitude), now: now), .cold(minutesAgo: Int.max))
    }

    func testLocalActiveETANeverClaimsMissingFriendSignal() {
        let local = ActiveETASignalPresentation(isRemote: false, quality: nil)

        XCTAssertNil(local.statusText)
        XCTAssertTrue(local.isLive)
        XCTAssertNil(local.estimateContext)
    }

    func testNonLivePartnerTimesAreExplicitlyLastEstimates() {
        for quality: FriendSignalQuality? in [nil, .stale(minutesAgo: 2), .cold(minutesAgo: 20)] {
            XCTAssertEqual(
                ActiveETASignalPresentation(isRemote: true, quality: quality).estimateContext,
                "LAST ESTIMATE"
            )
        }
        XCTAssertNil(ActiveETASignalPresentation(isRemote: true, quality: .live).estimateContext)
    }

    func testRemoteActiveETARetainsFailClosedSignalPresentation() {
        let missing = ActiveETASignalPresentation(isRemote: true, quality: nil)
        XCTAssertEqual(missing.statusText, "NO SIGNAL")
        XCTAssertFalse(missing.isLive)

        let stale = ActiveETASignalPresentation(
            isRemote: true,
            quality: .stale(minutesAgo: 2)
        )
        XCTAssertEqual(stale.statusText, "2M AGO")
        XCTAssertFalse(stale.isLive)

        let live = ActiveETASignalPresentation(isRemote: true, quality: .live)
        XCTAssertNil(live.statusText)
        XCTAssertTrue(live.isLive)
    }
}
