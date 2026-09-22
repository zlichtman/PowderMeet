import CoreLocation
import XCTest
@testable import PowderMeet

final class ETAEstimatorTests: XCTestCase {
    private func livePaceEstimator() -> BlendedETAEstimator {
        let estimator = BlendedETAEstimator()
        estimator.reset(solverEstimateSeconds: 500, remainingMeters: 1000)
        estimator.updateRouteEstimate(.init(totalSeconds: 500, currentEdgeSeconds: 200),
                                      currentEdgeRemainingMeters: 500,
                                      edgeID: "run", edgeKind: .run)
        return estimator
    }

    private func paceFix(_ estimator: BlendedETAEstimator, second: Double, meters: Double) {
        estimator.ingest(location: .init(latitude: 40, longitude: -106 + meters / 85000),
                         timestamp: Date(timeIntervalSinceReferenceDate: second), remainingMeters: 1000)
    }

    func testPaceConfidenceUsesElapsedMovementNotGPSUpdateCount() {
        func estimate(interval: Double, slowingDown: Bool) -> Double {
            let estimator = livePaceEstimator()
            for index in 0...Int(12 / interval) {
                let second = Double(index) * interval
                let meters = slowingDown && second > 8 ? 80 + (second - 8) * 5 : second * 10
                paceFix(estimator, second: second, meters: meters)
            }
            return estimator.smoothedETASeconds
        }
        for slowingDown in [false, true] {
            let oneHz = estimate(interval: 1, slowingDown: slowingDown)
            XCTAssertLessThan(oneHz, 500)
            XCTAssertEqual(estimate(interval: 0.25, slowingDown: slowingDown), oneHz, accuracy: 0.1)
            XCTAssertEqual(estimate(interval: 2, slowingDown: slowingDown), oneHz, accuracy: 0.1)
        }
    }

    func testLongSignalGapDropsOldPaceAndRequiresNewWarmup() {
        let estimator = livePaceEstimator()
        for second in 0...40 { paceFix(estimator, second: Double(second), meters: Double(second) * 10) }
        XCTAssertLessThan(estimator.smoothedETASeconds, 450)
        // Plausible displacement across a minute cannot tell us whether
        // skiing continued, stopped, or took another path during the gap.
        paceFix(estimator, second: 100, meters: 1000)
        XCTAssertEqual(estimator.smoothedETASeconds, 500, accuracy: 0.001)
        for second in 101...103 { paceFix(estimator, second: Double(second), meters: Double(second) * 10) }
        XCTAssertEqual(estimator.smoothedETASeconds, 500, accuracy: 0.001)
        paceFix(estimator, second: 104, meters: 1040)
        XCTAssertLessThan(estimator.smoothedETASeconds, 500)
        XCTAssertGreaterThan(estimator.smoothedETASeconds, 490)
    }

    func testLongStopExpiresPaceWithoutMakingETAInfinite() {
        let estimator = livePaceEstimator()
        for second in 0...40 { paceFix(estimator, second: Double(second), meters: Double(second) * 10) }
        let movingETA = estimator.smoothedETASeconds
        paceFix(estimator, second: 41, meters: 400)
        XCTAssertEqual(estimator.smoothedETASeconds, movingETA, accuracy: 0.001)
        for second in 42...71 { paceFix(estimator, second: Double(second), meters: 400) }
        XCTAssertEqual(estimator.smoothedETASeconds, 500, accuracy: 0.001)
        paceFix(estimator, second: 72, meters: 410)
        XCTAssertEqual(estimator.smoothedETASeconds, 500, accuracy: 0.001)
    }

    func testCompletedCurrentEdgeIgnoresClosureBehindTheSkier() throws {
        let closed = GraphEdge(
            id: "closed-behind",
            sourceID: "a",
            targetID: "b",
            kind: .run,
            geometry: [],
            attributes: EdgeAttributes(
                difficulty: .green,
                lengthMeters: 1_000,
                isOpen: false
            )
        )
        let open = GraphEdge(
            id: "open-ahead",
            sourceID: "b",
            targetID: "c",
            kind: .run,
            geometry: [],
            attributes: EdgeAttributes(
                difficulty: .green,
                lengthMeters: 500,
                isOpen: true
            )
        )
        let profile = UserProfile.defaultProfile(id: UUID())
        let context = TraversalContext(
            solveTime: nil,
            latitude: nil,
            longitude: nil,
            temperatureCelsius: 0,
            stationElevationM: 0,
            windSpeedKmh: 0,
            visibilityKm: 20,
            freshSnowCm: 0,
            cloudCoverPercent: 0
        )
        let remaining = try XCTUnwrap(ActiveRouteETA.seconds(
            path: [closed, open],
            currentEdgeIndex: 0,
            currentEdgeFraction: 1,
            profile: profile,
            context: context
        ))
        XCTAssertEqual(
            remaining,
            try XCTUnwrap(profile.traverseTime(for: open, context: context)),
            accuracy: 0.01
        )
    }

    func testActiveRouteETARejectsRemainingLiftReachedAfterHours() {
        let lift = GraphEdge(
            id: "late-lift",
            sourceID: "base",
            targetID: "top",
            kind: .lift,
            geometry: [],
            attributes: EdgeAttributes(
                lengthMeters: 1_000,
                liftType: .chairLift,
                rideTimeSeconds: 300,
                isOpen: true
            )
        )
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(secondsFromGMT: 0)!
        let late = utc.date(from: DateComponents(
            year: 2026,
            month: 1,
            day: 15,
            hour: 22
        ))!
        let context = TraversalContext(
            solveTime: late,
            latitude: nil,
            longitude: nil,
            utcOffsetSeconds: 0,
            temperatureCelsius: -5,
            stationElevationM: 0,
            windSpeedKmh: 0,
            visibilityKm: 20,
            freshSnowCm: 0,
            cloudCoverPercent: 0
        )

        XCTAssertNil(ActiveRouteETA.seconds(
            path: [lift],
            currentEdgeIndex: 0,
            currentEdgeFraction: 0,
            profile: UserProfile.defaultProfile(id: UUID()),
            context: context
        ))
    }

    func testActiveRouteETAChargesOnlyRemainingFractionOfCurrentRun() throws {
        let run = GraphEdge(
            id: "run",
            sourceID: "top",
            targetID: "base",
            kind: .run,
            geometry: [],
            attributes: EdgeAttributes(
                difficulty: .green,
                lengthMeters: 700,
                isGroomed: true,
                isOpen: true
            )
        )
        let context = TraversalContext(
            solveTime: nil,
            latitude: nil,
            longitude: nil,
            temperatureCelsius: 0,
            stationElevationM: 0,
            windSpeedKmh: 0,
            visibilityKm: 20,
            freshSnowCm: 0,
            cloudCoverPercent: 0
        )

        XCTAssertEqual(
            try XCTUnwrap(ActiveRouteETA.seconds(
                path: [run],
                currentEdgeIndex: 0,
                currentEdgeFraction: 0.5,
                profile: UserProfile.defaultProfile(id: UUID()),
                context: context
            )),
            50,
            accuracy: 0.001
        )
    }

    func testSolverPriorCountsDownWithRouteProgressBeforeSpeedConfidence() {
        let estimator = BlendedETAEstimator()
        estimator.reset(solverEstimateSeconds: 600, remainingMeters: 1_000)
        let start = Date(timeIntervalSinceReferenceDate: 0)

        estimator.ingest(
            location: .init(latitude: 40, longitude: -106),
            timestamp: start,
            remainingMeters: 1_000
        )
        estimator.ingest(
            location: .init(latitude: 40, longitude: -106),
            timestamp: start.addingTimeInterval(1),
            remainingMeters: 500
        )

        XCTAssertEqual(estimator.smoothedETASeconds, 300, accuracy: 0.001)
    }

    func testExactRouteRecostPreservesFutureLiftAndQueueTime() {
        let estimator = BlendedETAEstimator()
        estimator.reset(solverEstimateSeconds: 1_000, remainingMeters: 2_000)
        estimator.updateRouteEstimate(
            .init(totalSeconds: 900, currentEdgeSeconds: 100),
            currentEdgeRemainingMeters: 1_000,
            edgeID: "downhill-run",
            edgeKind: .run
        )
        let start = Date(timeIntervalSinceReferenceDate: 0)
        let metersPerLongitudeDegree = 85_000.0
        func location(meters: Double) -> CLLocationCoordinate2D {
            .init(latitude: 40, longitude: -106 + meters / metersPerLongitudeDegree)
        }

        // Warm up and establish ~10m/s, exactly matching the current run's
        // planned 100 seconds. The 800 seconds after it (lift/queue/etc.) must
        // remain untouched by the measured downhill pace.
        for second in 0...4 {
            estimator.ingest(
                location: location(meters: Double(second * 10)),
                timestamp: start.addingTimeInterval(Double(second)),
                remainingMeters: 2_000 - Double(second * 10)
            )
        }

        XCTAssertEqual(estimator.smoothedETASeconds, 900, accuracy: 0.1)
    }

    func testChangingEdgesClearsThePreviousEdgesSpeedCorrection() {
        let estimator = BlendedETAEstimator()
        estimator.reset(solverEstimateSeconds: 600, remainingMeters: 1_000)
        estimator.updateRouteEstimate(
            .init(totalSeconds: 500, currentEdgeSeconds: 200),
            currentEdgeRemainingMeters: 500,
            edgeID: "run",
            edgeKind: .run
        )
        let start = Date(timeIntervalSinceReferenceDate: 0)
        let metersPerLongitudeDegree = 85_000.0
        for second in 0...4 {
            estimator.ingest(
                location: .init(
                    latitude: 40,
                    longitude: -106 + Double(second * 10) / metersPerLongitudeDegree
                ),
                timestamp: start.addingTimeInterval(Double(second)),
                remainingMeters: 1_000 - Double(second * 10)
            )
        }
        XCTAssertNotEqual(estimator.smoothedETASeconds, 500, accuracy: 0.01)

        estimator.updateRouteEstimate(
            .init(totalSeconds: 350, currentEdgeSeconds: 300),
            currentEdgeRemainingMeters: 800,
            edgeID: "next-run",
            edgeKind: .run
        )

        XCTAssertEqual(estimator.smoothedETASeconds, 350, accuracy: 0.01)
    }

    func testCurrentLiftQueueAndRideNeverUseMeasuredSkiingSpeed() {
        let estimator = BlendedETAEstimator()
        estimator.reset(solverEstimateSeconds: 900, remainingMeters: 1_000)
        estimator.updateRouteEstimate(
            .init(totalSeconds: 900, currentEdgeSeconds: 800),
            currentEdgeRemainingMeters: 800,
            edgeID: "chairlift-entry",
            edgeKind: .lift
        )
        let start = Date(timeIntervalSinceReferenceDate: 0)
        for second in 0...35 {
            estimator.ingest(
                location: .init(
                    latitude: 40,
                    longitude: -106 + Double(second * 10) / 85_000
                ),
                timestamp: start.addingTimeInterval(Double(second)),
                remainingMeters: 1_000
            )
        }

        XCTAssertEqual(estimator.smoothedETASeconds, 900, accuracy: 0.001)
    }

    func testRebasedContextPreservesSnowAccumulatedBeforeTheNewClock() {
        let start = Date(timeIntervalSince1970: 1_000)
        let hourLater = start.addingTimeInterval(3_600)
        let context = TraversalContext(
            solveTime: start,
            latitude: 40,
            longitude: -106,
            temperatureCelsius: -5,
            stationElevationM: 2_000,
            windSpeedKmh: 10,
            visibilityKm: 10,
            freshSnowCm: 5,
            cloudCoverPercent: 80,
            hourlyWeather: [.init(
                time: hourLater,
                temperatureCelsius: -6,
                windSpeedKmh: 12,
                visibilityKm: 8,
                cloudCoverPercent: 90,
                snowfallCm: 2
            )],
            datasetVersion: "mountain-v1"
        )
        let halfway = start.addingTimeInterval(1_800)
        let rebased = context.rebased(to: halfway)

        XCTAssertEqual(rebased.solveTime, halfway)
        XCTAssertEqual(rebased.datasetVersion, "mountain-v1")
        XCTAssertEqual(rebased.freshSnowCm, 6, accuracy: 0.001)
        XCTAssertEqual(
            rebased.effectiveFreshSnowCm(at: hourLater),
            context.effectiveFreshSnowCm(at: hourLater),
            accuracy: 0.001
        )
    }

    func testCompletionProducesZeroETA() {
        let estimator = BlendedETAEstimator()
        estimator.reset(solverEstimateSeconds: 600, remainingMeters: 1_000)
        estimator.ingest(
            location: .init(latitude: 40, longitude: -106),
            timestamp: Date(timeIntervalSinceReferenceDate: 0),
            remainingMeters: 0
        )

        XCTAssertEqual(estimator.smoothedETASeconds, 0, accuracy: 0.001)
    }

    func testRejectedTeleportDoesNotReplaceLastGoodSpeedBaseline() {
        let estimator = BlendedETAEstimator()
        estimator.reset(solverEstimateSeconds: 600, remainingMeters: 1_000)
        let start = Date(timeIntervalSinceReferenceDate: 0)
        let metersPerLongitudeDegree = 85_000.0
        func location(meters: Double) -> CLLocationCoordinate2D {
            .init(latitude: 40, longitude: -106 + meters / metersPerLongitudeDegree)
        }

        estimator.ingest(location: location(meters: 0), timestamp: start, remainingMeters: 1_000)
        estimator.ingest(location: location(meters: 5), timestamp: start.addingTimeInterval(1), remainingMeters: 980)
        estimator.ingest(location: location(meters: 10), timestamp: start.addingTimeInterval(2), remainingMeters: 960)
        estimator.ingest(location: location(meters: 15), timestamp: start.addingTimeInterval(3), remainingMeters: 940)
        estimator.ingest(
            location: location(meters: 10_000),
            timestamp: start.addingTimeInterval(4),
            remainingMeters: 920
        )
        estimator.ingest(
            location: location(meters: 20),
            timestamp: start.addingTimeInterval(5),
            remainingMeters: 900
        )

        // A pure distance-scaled prior is 540 seconds. The accepted 2.5 m/s
        // sample after the rejected teleport should pull the blend below it.
        XCTAssertLessThan(estimator.smoothedETASeconds, 540)
    }

    func testDuplicateOrOlderCaptureCannotRewriteRemainingETA() {
        let estimator = BlendedETAEstimator()
        let now = Date(timeIntervalSince1970: 1_000)
        let location = CLLocationCoordinate2D(latitude: 40, longitude: -106)
        estimator.reset(solverEstimateSeconds: 600, remainingMeters: 1_000)
        estimator.ingest(location: location, timestamp: now, remainingMeters: 500)
        XCTAssertEqual(estimator.smoothedETASeconds, 300, accuracy: 0.001)

        estimator.ingest(location: location, timestamp: now, remainingMeters: 0)
        estimator.ingest(
            location: location,
            timestamp: now.addingTimeInterval(-1),
            remainingMeters: 0
        )
        XCTAssertEqual(estimator.smoothedETASeconds, 300, accuracy: 0.001)

        estimator.ingest(
            location: location,
            timestamp: now.addingTimeInterval(1),
            remainingMeters: 0
        )
        XCTAssertEqual(estimator.smoothedETASeconds, 0, accuracy: 0.001)
    }

    func testResetClearsBroadcastBaseline() {
        let estimator = BlendedETAEstimator()
        let start = Date(timeIntervalSinceReferenceDate: 0)
        estimator.reset(solverEstimateSeconds: 600, remainingMeters: 1_000)
        XCTAssertTrue(estimator.shouldBroadcast(now: start))
        estimator.didBroadcast(etaSeconds: estimator.smoothedETASeconds, now: start)
        XCTAssertFalse(estimator.shouldBroadcast(now: start.addingTimeInterval(10)))

        estimator.reset(solverEstimateSeconds: 300, remainingMeters: 500)
        XCTAssertTrue(estimator.shouldBroadcast(now: start.addingTimeInterval(11)))
    }

    func testETABroadcastGateRejectsOverlappingWritesUntilCompletion() throws {
        var gate = ETABroadcastSingleFlight()
        let first = try XCTUnwrap(gate.beginOrDefer())

        XCTAssertNil(gate.beginOrDefer())
        XCTAssertTrue(gate.hasDeferredWrite)
        XCTAssertFalse(gate.finish(first &+ 1))
        XCTAssertEqual(gate.activeToken, first)
        XCTAssertTrue(gate.finish(first))
        XCTAssertNotNil(gate.beginDeferredIfNeeded())
        XCTAssertFalse(gate.hasDeferredWrite)
    }

    func testETABroadcastGateCancellationInvalidatesOlderCompletion() throws {
        var gate = ETABroadcastSingleFlight()
        let old = try XCTUnwrap(gate.beginOrDefer())
        XCTAssertNil(gate.beginOrDefer())
        gate.cancel()
        let replacement = try XCTUnwrap(gate.beginOrDefer())

        XCTAssertNotEqual(old, replacement)
        XCTAssertFalse(gate.finish(old))
        XCTAssertEqual(gate.activeToken, replacement)
        XCTAssertTrue(gate.finish(replacement))
        XCTAssertNil(gate.beginDeferredIfNeeded())
    }

    func testAcknowledgedBaselineRecordsValueActuallySent() {
        let estimator = BlendedETAEstimator()
        let start = Date(timeIntervalSinceReferenceDate: 0)
        estimator.reset(solverEstimateSeconds: 600, remainingMeters: 1_000)

        estimator.didBroadcast(etaSeconds: 600, now: start)
        estimator.ingest(
            location: .init(latitude: 40, longitude: -106),
            timestamp: start,
            remainingMeters: 500
        )

        XCTAssertEqual(estimator.smoothedETASeconds, 300, accuracy: 0.001)
        XCTAssertTrue(estimator.shouldBroadcast(now: start.addingTimeInterval(5)))
    }
}
