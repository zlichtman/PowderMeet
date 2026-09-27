import CoreLocation
import XCTest
@testable import PowderMeet

final class TechnicalTerrainRoutingTests: XCTestCase {
    func testExplicitPitchLimitRequiresUsablePitchData() {
        var skier = profile(technicalComfort: 0.8)
        skier.maxComfortableGradientDegrees = 20
        for pitch in [0.0, -1, 91, .nan, .infinity] {
            let edge = pitchEdge(pitch)
            XCTAssertEqual(skier.capabilityBlockers(for: edge).map(\.userFacingLabel), ["PITCH DATA UNVERIFIED"])
            XCTAssertNil(skier.traverseTime(for: edge, context: explanationWeather()))
        }
        for pitch in [0.1, 10, 20] {
            XCTAssertTrue(skier.capabilityBlockers(for: pitchEdge(pitch)).isEmpty)
            XCTAssertNotNil(skier.traverseTime(for: pitchEdge(pitch), context: explanationWeather()))
        }
    }

    func testUnknownPitchDoesNotIntroduceAnUnrequestedHardLimit() {
        let skier = profile(technicalComfort: 0.8)
        XCTAssertNil(skier.maxComfortableGradientDegrees)
        XCTAssertTrue(skier.capabilityBlockers(for: pitchEdge(0)).isEmpty)
        XCTAssertNotNil(skier.traverseTime(for: pitchEdge(0), context: explanationWeather()))
        var limited = skier
        limited.maxComfortableGradientDegrees = 20
        for kind in [GraphEdge.EdgeKind.lift, .traverse] {
            let edge = pitchEdge(0)
            let nonRun = GraphEdge(id: edge.id, sourceID: edge.sourceID, targetID: edge.targetID,
                kind: kind, geometry: edge.geometry, attributes: edge.attributes)
            XCTAssertTrue(limited.capabilityBlockers(for: nonRun).isEmpty)
        }
    }

    func testInvalidPitchLimitCannotDisableTheLimitOrCrashItsDiagnostic() {
        for cap in [-1.0, 91, .nan, .infinity, -.infinity, .greatestFiniteMagnitude] {
            var skier = profile(technicalComfort: 0.8)
            skier.maxComfortableGradientDegrees = cap
            XCTAssertEqual(skier.capabilityBlockers(for: pitchEdge(10)).map(\.userFacingLabel), ["PITCH LIMIT NEEDS REVIEW"])
            XCTAssertNil(skier.traverseTime(for: pitchEdge(10), context: explanationWeather()))
        }
    }

    private func pitchEdge(_ pitch: Double) -> GraphEdge {
        GraphEdge(id: "pitch", sourceID: "top", targetID: "base", kind: .run,
            geometry: [], attributes: EdgeAttributes(difficulty: .blue, lengthMeters: 500,
                maxGradient: pitch, isGroomed: true, isOpen: true))
    }

    func testPitchLimitChoosesKnownAlternativeInsteadOfFasterUnknownRoute() throws {
        let top = node("top", lat: 40.002, elevation: 1100, kind: .trailHead)
        let base = node("base", lat: 40, elevation: 900, kind: .liftBase)
        let unknown = GraphEdge(id: "unknown", sourceID: top.id, targetID: base.id, kind: .run,
            geometry: [top.coordinate, base.coordinate], attributes: EdgeAttributes(
                difficulty: .blue, lengthMeters: 50, maxGradient: 0, isGroomed: true))
        let known = GraphEdge(id: "known", sourceID: top.id, targetID: base.id, kind: .run,
            geometry: [top.coordinate, base.coordinate], attributes: EdgeAttributes(
                difficulty: .blue, lengthMeters: 500, maxGradient: 10, isGroomed: true))
        let solver = MeetingPointSolver(graph: MountainGraph(resortID: "pitch-choice",
            nodes: [top.id: top, base.id: base], edges: [unknown, known]))
        var skier = profile(technicalComfort: 0.8)
        XCTAssertEqual(try XCTUnwrap(solver.pathTo(target: base.id, from: top.id, skier: skier)).path.map(\.id), ["unknown"])
        skier.maxComfortableGradientDegrees = 20
        XCTAssertEqual(try XCTUnwrap(solver.pathTo(target: base.id, from: top.id, skier: skier)).path.map(\.id), ["known"])
    }

    func testBlockedStartingPitchIsExplainedWithoutReturningARelaxedRoute() {
        let top = node("top", lat: 40.002, elevation: 1100, kind: .trailHead)
        let base = node("base", lat: 40, elevation: 900, kind: .liftBase)
        let edge = GraphEdge(id: "unknown", sourceID: top.id, targetID: base.id, kind: .run,
            geometry: [top.coordinate, base.coordinate], attributes: EdgeAttributes(
                difficulty: .blue, lengthMeters: 200, maxGradient: 0, isGroomed: true))
        var skier = profile(technicalComfort: 0.8)
        skier.maxComfortableGradientDegrees = 20
        let friend = profile(technicalComfort: 0.8)
        for isOpen in [true, false] {
            let solver = MeetingPointSolver(graph: MountainGraph(resortID: "pitch-start",
                nodes: [top.id: top, base.id: base], edges: [edge.withAttributes(edge.attributes.enriched(isOpen: isOpen))]))
            XCTAssertNil(solver.solve(skierA: skier, positionA: top.id, skierB: friend, positionB: base.id))
            if isOpen {
                guard case .startingTerrainBlocked(let diagnostic) = solver.lastFailureReason else {
                    return XCTFail("Expected the pitch requirement, not a generic dead-end message")
                }
                XCTAssertEqual(diagnostic.blockers, [.gradientDataUnverified])
                XCTAssertTrue(solver.lastFailureReason?.userMessage.contains("PITCH DATA UNVERIFIED") == true)
            } else {
                guard case .skierAtDeadEnd = solver.lastFailureReason else {
                    return XCTFail("A closed route must not be diagnosed by relaxing closures")
                }
            }
        }
    }

    func testMarkedDifficultyPermissionsAreExplicitForEveryTier() {
        let difficulties: [RunDifficulty] = [.green, .blue, .black, .doubleBlack, .terrainPark]
        let cases: [(String, [RunDifficulty])] = [
            ("beginner", [.green]),
            ("intermediate", [.green, .blue]),
            ("advanced", [.green, .blue, .black, .terrainPark]),
            ("expert", difficulties),
            ("legacy-unknown", [.green, .blue])
        ]
        for (tier, allowed) in cases {
            var skier = UserProfile.defaultProfile(id: UUID())
            skier.skillLevel = tier
            // Historical imports or a downgrade may leave speeds for terrain
            // above the chosen tier. Speed is not permission to route there.
            skier.speedGreen = 5
            skier.speedBlue = 5
            skier.speedBlack = 5
            skier.speedDoubleBlack = 5
            skier.speedTerrainPark = 5
            for difficulty in difficulties {
                XCTAssertEqual(skier.canTraverseRun(difficulty), allowed.contains(difficulty),
                               "\(tier) / \(difficulty)")
            }
        }
        var beginner = UserProfile.defaultProfile(id: UUID())
        beginner.applyPreset("beginner")
        XCTAssertNotNil(beginner.speedBlue)
        XCTAssertFalse(beginner.canTraverseRun(.blue))
    }

    func testInvalidPaceCannotGrantMarkedTerrainPermission() {
        for value: Double? in [nil, 0, -1, .nan, .infinity, -.infinity] {
            var skier = UserProfile.defaultProfile(id: UUID())
            skier.skillLevel = "expert"
            skier.speedGreen = value
            skier.speedBlue = value
            skier.speedBlack = value
            skier.speedDoubleBlack = value
            skier.speedTerrainPark = value
            for difficulty: RunDifficulty in [.green, .blue, .black, .doubleBlack, .terrainPark] {
                XCTAssertFalse(skier.canTraverseRun(difficulty))
            }
        }
    }

    func testTerrainComfortChoiceMapsContinuousCalibrationToStableControls() {
        XCTAssertEqual(TerrainComfortChoice.nearest(to: 0.05), .avoid)
        XCTAssertEqual(TerrainComfortChoice.nearest(to: 0.55), .okay)
        XCTAssertEqual(TerrainComfortChoice.nearest(to: 0.95), .confident)
    }

    func testExplicitAvoidTerrainChoicesAreHardRoutingLimits() throws {
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
        var skier = profile(technicalComfort: 0.8)
        skier.mogulTolerance = 0
        skier.conditionUngroomed = 0
        skier.conditionGladed = 0

        let moguls = GraphEdge(
            id: "moguls",
            sourceID: "top",
            targetID: "base",
            kind: .run,
            geometry: [],
            attributes: EdgeAttributes(
                difficulty: .blue,
                lengthMeters: 500,
                hasMoguls: true,
                isGroomed: true,
                isOpen: true
            )
        )
        let ungroomed = moguls.withAttributes(EdgeAttributes(
            difficulty: .blue,
            lengthMeters: 500,
            isGroomed: false,
            isOpen: true
        ))
        let glades = moguls.withAttributes(EdgeAttributes(
            difficulty: .blue,
            lengthMeters: 500,
            isGroomed: true,
            isGladed: true,
            isOpen: true
        ))

        XCTAssertNil(skier.traverseTime(for: moguls, context: context))
        XCTAssertNil(skier.traverseTime(for: ungroomed, context: context))
        XCTAssertNil(skier.traverseTime(for: glades, context: context))
        XCTAssertNotNil(skier.traverseTime(
            for: moguls,
            context: context,
            ignoreSkillGates: true
        ))
    }

    func testExplicitGradientCapIsEligibilityNotJustSlowdown() throws {
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
        var skier = profile(technicalComfort: 0.8)
        skier.maxComfortableGradientDegrees = 20
        let steepBlue = GraphEdge(
            id: "steep-blue",
            sourceID: "top",
            targetID: "base",
            kind: .run,
            geometry: [],
            attributes: EdgeAttributes(
                difficulty: .blue,
                lengthMeters: 500,
                maxGradient: 24,
                isGroomed: true,
                isOpen: true
            )
        )

        XCTAssertNil(skier.traverseTime(for: steepBlue, context: context))
        XCTAssertNotNil(skier.traverseTime(
            for: steepBlue,
            context: context,
            ignoreSkillGates: true
        ))
    }

    func testCapabilityDiagnosticsUseTheExactTraversalGates() {
        var skier = profile(technicalComfort: 0)
        skier.skillLevel = "intermediate"
        skier.mogulTolerance = 0
        skier.maxComfortableGradientDegrees = 20
        let edge = GraphEdge(
            id: "all-limits",
            sourceID: "top",
            targetID: "base",
            kind: .run,
            geometry: [],
            attributes: EdgeAttributes(
                difficulty: .black,
                lengthMeters: 500,
                maxGradient: 24,
                hasMoguls: true,
                isGroomed: false,
                isGladed: true,
                isOpen: true
            )
        )

        XCTAssertEqual(skier.capabilityBlockers(for: edge), [
            .markedDifficulty(.black),
            .mogulsAvoided,
            .ungroomedAvoided,
            .gladesAvoided,
            .gradientLimit(maxDegrees: 20),
        ])
    }

    func testObstacleDensitySlowsCautiousSkierMoreThanTechnicalSkier() throws {
        let clear = run(
            id: "clear",
            from: "top",
            to: "base",
            length: 1_000,
            obstacleDensity: 0
        )
        let technical = run(
            id: "technical",
            from: "top",
            to: "base",
            length: 1_000,
            obstacleDensity: 0.9
        )
        let cautious = profile(technicalComfort: 0.15)
        let confident = profile(technicalComfort: 0.95)
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

        let cautiousClear = try XCTUnwrap(cautious.traverseTime(for: clear, context: context))
        let cautiousTechnical = try XCTUnwrap(cautious.traverseTime(for: technical, context: context))
        let confidentClear = try XCTUnwrap(confident.traverseTime(for: clear, context: context))
        let confidentTechnical = try XCTUnwrap(confident.traverseTime(for: technical, context: context))

        XCTAssertGreaterThan(cautiousTechnical, cautiousClear * 1.5)
        XCTAssertLessThan(confidentTechnical, confidentClear * 1.1)
        XCTAssertGreaterThan(
            cautiousTechnical / cautiousClear,
            confidentTechnical / confidentClear
        )
    }

    func testRouteChoiceUsesObstacleComfortInsteadOfDifficultyAlone() throws {
        let start = node("start", lat: 40.000, elevation: 2_400, kind: .trailHead)
        let safeMid = node("safe-mid", lat: 40.004, elevation: 2_200, kind: .junction)
        let technicalMid = node("technical-mid", lat: 40.004, elevation: 2_200, kind: .junction)
        let meeting = node("meeting", lat: 40.008, elevation: 2_000, kind: .liftBase)

        let graph = MountainGraph(
            resortID: "technical-routing",
            nodes: Dictionary(uniqueKeysWithValues: [start, safeMid, technicalMid, meeting].map { ($0.id, $0) }),
            edges: [
                run(id: "safe-1", from: start.id, to: safeMid.id, length: 500, obstacleDensity: 0),
                run(id: "safe-2", from: safeMid.id, to: meeting.id, length: 500, obstacleDensity: 0),
                run(id: "technical-1", from: start.id, to: technicalMid.id, length: 400, obstacleDensity: 0.9),
                run(id: "technical-2", from: technicalMid.id, to: meeting.id, length: 400, obstacleDensity: 0.9),
            ]
        )
        let solver = MeetingPointSolver(graph: graph)

        let cautiousRoute = try XCTUnwrap(solver.pathTo(
            target: meeting.id,
            from: start.id,
            skier: profile(technicalComfort: 0.15)
        ))
        let confidentRoute = try XCTUnwrap(solver.pathTo(
            target: meeting.id,
            from: start.id,
            skier: profile(technicalComfort: 0.95)
        ))

        XCTAssertEqual(cautiousRoute.path.map(\.id), ["safe-1", "safe-2"])
        XCTAssertEqual(confidentRoute.path.map(\.id), ["technical-1", "technical-2"])
    }

    func testRouteExplanationNamesTechnicalTerrainForBothComfortProfiles() {
        let technical = run(
            id: "technical",
            from: "top",
            to: "base",
            length: 1_000,
            obstacleDensity: 0.9
        )

        XCTAssertTrue(
            RouteInstructionBuilder.reason(
                for: [technical],
                profile: profile(technicalComfort: 0.15)
            ).contains("cautious-terrain pace")
        )
        XCTAssertTrue(
            RouteInstructionBuilder.reason(
                for: [technical],
                profile: profile(technicalComfort: 0.95)
            ).contains("Technical terrain")
        )
    }

    func testRouteExplanationSurfacesConditionsAndSelectedSkis() {
        let powderRun = GraphEdge(
            id: "powder",
            sourceID: "top",
            targetID: "base",
            kind: .run,
            geometry: [],
            attributes: EdgeAttributes(
                difficulty: .blue,
                lengthMeters: 1_000,
                isGroomed: false,
                isOpen: true
            )
        )
        let powderSki = SkiPerformanceProfile(entry: SkiCatalogEntry(
            id: UUID(),
            brand: "Test",
            model: "Powder 110",
            category: "powder",
            waistWidthMm: 110,
            topsheetAssetKey: nil
        ))
        let context = TraversalContext(
            solveTime: nil,
            latitude: nil,
            longitude: nil,
            temperatureCelsius: -5,
            stationElevationM: 0,
            windSpeedKmh: 0,
            visibilityKm: 20,
            freshSnowCm: 18,
            cloudCoverPercent: 20,
            equipment: powderSki
        )

        let reason = RouteInstructionBuilder.reason(
            for: [powderRun],
            profile: profile(technicalComfort: 0.8),
            context: context
        )
        XCTAssertTrue(reason.contains("Fresh ungroomed snow"))
        XCTAssertTrue(reason.contains("wider skis"))
    }

    func testRouteExplanationSurfacesMeaningfulLiveLiftQueue() {
        let lift = GraphEdge(
            id: "busy-lift",
            sourceID: "base",
            targetID: "top",
            kind: .lift,
            geometry: [],
            attributes: EdgeAttributes(
                lengthMeters: 1_000,
                liftType: .chairLift,
                rideTimeSeconds: 300,
                waitTimeMinutes: 7,
                chargesLiftWait: true,
                isOpen: true
            )
        )

        let reason = RouteInstructionBuilder.reason(
            for: [lift],
            profile: profile(technicalComfort: 0.8)
        )
        XCTAssertTrue(reason.contains("7 minutes in line"))
    }

    func testExpertAndParkDisclosurePrecedeReassuringSurfaceCopy() {
        var expert = profile(technicalComfort: 0.8)
        expert.skillLevel = "expert"
        expert.speedDoubleBlack = 8
        expert.speedTerrainPark = 7
        expert.conditionUngroomed = 0.2

        let doubleBlack = GraphEdge(
            id: "smooth-expert",
            sourceID: "top",
            targetID: "base",
            kind: .run,
            geometry: [],
            attributes: EdgeAttributes(
                difficulty: .doubleBlack,
                lengthMeters: 600,
                isGroomed: true,
                isOpen: true
            )
        )
        let park = GraphEdge(
            id: "park",
            sourceID: "top",
            targetID: "base",
            kind: .run,
            geometry: [],
            attributes: EdgeAttributes(
                difficulty: .terrainPark,
                lengthMeters: 600,
                isGroomed: true,
                isOpen: true
            )
        )

        XCTAssertTrue(RouteInstructionBuilder.reason(
            for: [doubleBlack],
            profile: expert
        ).contains("double-black"))
        XCTAssertTrue(RouteInstructionBuilder.reason(
            for: [park],
            profile: expert
        ).contains("terrain-park features"))

        let parkContext = TraversalContext(
            solveTime: nil,
            latitude: nil,
            longitude: nil,
            temperatureCelsius: 0,
            stationElevationM: 0,
            windSpeedKmh: 0,
            visibilityKm: 20,
            freshSnowCm: 0,
            cloudCoverPercent: 0,
            equipment: SkiPerformanceProfile(entry: SkiCatalogEntry(
                id: UUID(),
                brand: "Test",
                model: "Park 95",
                category: "park",
                waistWidthMm: 95,
                topsheetAssetKey: nil
            ))
        )
        XCTAssertTrue(RouteInstructionBuilder.reason(
            for: [park],
            profile: expert,
            context: parkContext
        ).contains("selected park skis"))
    }

    func testRouteExplanationUsesForecastAtLiftArrival() {
        let approach = run(
            id: "approach",
            from: "start",
            to: "base",
            length: 1_000,
            obstacleDensity: 0
        )
        let lift = GraphEdge(
            id: "lift",
            sourceID: "base",
            targetID: "top",
            kind: .lift,
            geometry: [],
            attributes: EdgeAttributes(
                lengthMeters: 1_000,
                liftType: .chairLift,
                rideTimeSeconds: 300,
                chargesLiftWait: true,
                isOpen: true
            )
        )
        let start = Date(timeIntervalSinceReferenceDate: 0)
        let context = TraversalContext(
            solveTime: start,
            latitude: nil,
            longitude: nil,
            temperatureCelsius: 0,
            stationElevationM: 0,
            windSpeedKmh: 0,
            visibilityKm: 20,
            freshSnowCm: 0,
            cloudCoverPercent: 0,
            hourlyWeather: [
                .init(
                    time: start,
                    temperatureCelsius: 0,
                    windSpeedKmh: 0,
                    visibilityKm: 20,
                    cloudCoverPercent: 0
                ),
                .init(
                    time: start.addingTimeInterval(60),
                    temperatureCelsius: 0,
                    windSpeedKmh: 70,
                    visibilityKm: 20,
                    cloudCoverPercent: 0
                )
            ]
        )

        let reason = RouteInstructionBuilder.reason(
            for: [approach, lift],
            profile: profile(technicalComfort: 0.8),
            context: context
        )

        XCTAssertTrue(reason.contains("expected by the lift"))
    }

    func testRouteExplanationUsesSnowExpectedBeforeUngroomedRunArrival() {
        let approach = run(
            id: "long-approach",
            from: "start",
            to: "powder-top",
            length: 8_000,
            obstacleDensity: 0
        )
        let powderRun = GraphEdge(
            id: "forecast-powder",
            sourceID: "powder-top",
            targetID: "base",
            kind: .run,
            geometry: [],
            attributes: EdgeAttributes(
                difficulty: .blue,
                lengthMeters: 1_000,
                isGroomed: false,
                isOpen: true
            )
        )
        let start = Date(timeIntervalSinceReferenceDate: 10_000)
        let context = TraversalContext(
            solveTime: start,
            latitude: nil,
            longitude: nil,
            temperatureCelsius: -5,
            stationElevationM: 0,
            windSpeedKmh: 0,
            visibilityKm: 20,
            freshSnowCm: 0,
            cloudCoverPercent: 100,
            hourlyWeather: [
                .init(
                    time: start.addingTimeInterval(900),
                    temperatureCelsius: -5,
                    windSpeedKmh: 0,
                    visibilityKm: 20,
                    cloudCoverPercent: 100,
                    snowfallCm: 36
                )
            ]
        )

        let reason = RouteInstructionBuilder.reason(
            for: [approach, powderRun],
            profile: profile(technicalComfort: 0.8),
            context: context
        )

        XCTAssertTrue(reason.contains("Fresh ungroomed snow"))
    }

    func testRouteExplanationDoesNotApplyLaterStormToEarlierUngroomedRun() {
        let ungroomedFirst = GraphEdge(
            id: "early-ungroomed",
            sourceID: "start",
            targetID: "mid",
            kind: .run,
            geometry: [],
            attributes: EdgeAttributes(
                difficulty: .blue,
                lengthMeters: 1_000,
                isGroomed: false,
                isOpen: true
            )
        )
        let longGroomedFinish = run(
            id: "late-groomed",
            from: "mid",
            to: "base",
            length: 8_000,
            obstacleDensity: 0
        )
        let start = Date(timeIntervalSinceReferenceDate: 20_000)
        let context = TraversalContext(
            solveTime: start,
            latitude: nil,
            longitude: nil,
            temperatureCelsius: -5,
            stationElevationM: 0,
            windSpeedKmh: 0,
            visibilityKm: 20,
            freshSnowCm: 0,
            cloudCoverPercent: 100,
            hourlyWeather: [
                .init(
                    time: start.addingTimeInterval(900),
                    temperatureCelsius: -5,
                    windSpeedKmh: 0,
                    visibilityKm: 20,
                    cloudCoverPercent: 100,
                    snowfallCm: 36
                )
            ]
        )

        let reason = RouteInstructionBuilder.reason(
            for: [ungroomedFirst, longGroomedFinish],
            profile: profile(technicalComfort: 0.8),
            context: context
        )

        XCTAssertFalse(reason.contains("Fresh ungroomed snow"))
    }

    func testRouteExplanationDoesNotMoveApproachWindToLaterCalmLift() {
        let approach = run(id: "approach", from: "a", to: "b", length: 1_000, obstacleDensity: 0)
        let reason = RouteInstructionBuilder.reason(
            for: [approach, explanationLift()], profile: profile(technicalComfort: 0.8),
            context: explanationWeather(firstWind: 70, laterWind: 0)
        )
        XCTAssertFalse(reason.contains("expected by the lift"))
    }

    func testLiftOnlyRouteStillExplainsHighWind() {
        let reason = RouteInstructionBuilder.reason(
            for: [explanationLift()], profile: profile(technicalComfort: 0.8),
            context: explanationWeather(firstWind: 70, laterWind: 70)
        )
        XCTAssertTrue(reason.contains("expected by the lift"))
    }

    func testRouteExplanationDoesNotMovePoorVisibilityToLaterClearSteepRun() {
        let approach = run(id: "approach", from: "a", to: "b", length: 1_000, obstacleDensity: 0)
        let steep = approach.withAttributes(EdgeAttributes(
            difficulty: .blue, lengthMeters: 1_000, maxGradient: 25,
            isGroomed: true, isOpen: true
        ))
        let reason = RouteInstructionBuilder.reason(
            for: [approach, steep], profile: profile(technicalComfort: 0.8),
            context: explanationWeather(firstVisibility: 1, laterVisibility: 20)
        )
        XCTAssertFalse(reason.contains("Low visibility"))
    }

    func testRouteExplanationWarnsWhenSteepRunActuallyHasLowVisibility() {
        let steep = run(id: "steep", from: "a", to: "b", length: 1_000, obstacleDensity: 0)
            .withAttributes(EdgeAttributes(
                difficulty: .blue, lengthMeters: 1_000, maxGradient: 25,
                isGroomed: true, isOpen: true
            ))
        XCTAssertTrue(RouteInstructionBuilder.reason(
            for: [steep], profile: profile(technicalComfort: 0.8),
            context: explanationWeather(firstVisibility: 1, laterVisibility: 20)
        ).contains("Low visibility"))
    }

    func testNonRunExplanationsDistinguishEmptyConnectorLiftAndMixedPaths() {
        let skier = profile(technicalComfort: 0.8)
        let connector = GraphEdge(
            id: "connector", sourceID: "a", targetID: "b", kind: .traverse,
            geometry: [], attributes: EdgeAttributes(lengthMeters: 100, isOpen: true)
        )
        XCTAssertEqual(RouteInstructionBuilder.reason(for: [], profile: skier), "No travel is needed along this route.")
        XCTAssertTrue(RouteInstructionBuilder.reason(for: [connector], profile: skier).hasPrefix("Connector route"))
        XCTAssertTrue(RouteInstructionBuilder.reason(for: [explanationLift()], profile: skier).hasPrefix("Lift connection"))
        XCTAssertTrue(RouteInstructionBuilder.reason(for: [connector, explanationLift()], profile: skier).hasPrefix("Lift and connector"))
    }

    func testRouteExplanationDoesNotInventEvidenceAboutAlternativePaths() {
        let smooth = run(id: "smooth", from: "a", to: "b", length: 1_000, obstacleDensity: 0)
        let moguls = smooth.withAttributes(EdgeAttributes(
            difficulty: .blue, lengthMeters: 1_000, hasMoguls: true,
            isGroomed: false, isOpen: true
        ))
        let expert = smooth.withAttributes(EdgeAttributes(
            difficulty: .doubleBlack, lengthMeters: 1_000, isGroomed: true, isOpen: true
        ))
        for edge in [smooth, moguls, expert] {
            let reason = RouteInstructionBuilder.reason(for: [edge], profile: profile(technicalComfort: 0.3))
            XCTAssertFalse(reason.contains("fastest"))
            XCTAssertFalse(reason.contains("easiest"))
            XCTAssertFalse(reason.contains("no lower-effort path"))
        }
    }

    private func explanationLift() -> GraphEdge {
        GraphEdge(
            id: "lift", sourceID: "b", targetID: "c", kind: .lift,
            geometry: [], attributes: EdgeAttributes(
                lengthMeters: 1_000, liftType: .chairLift,
                rideTimeSeconds: 300, isOpen: true
            )
        )
    }

    private func explanationWeather(
        firstWind: Double = 0, laterWind: Double = 0,
        firstVisibility: Double = 20, laterVisibility: Double = 20
    ) -> TraversalContext {
        let start = Date(timeIntervalSinceReferenceDate: 43_200)
        return TraversalContext(
            solveTime: start, latitude: nil, longitude: nil,
            temperatureCelsius: 0, stationElevationM: 0,
            windSpeedKmh: firstWind, visibilityKm: firstVisibility,
            freshSnowCm: 0, cloudCoverPercent: 0,
            hourlyWeather: [
                .init(time: start, temperatureCelsius: 0, windSpeedKmh: firstWind,
                      visibilityKm: firstVisibility, cloudCoverPercent: 0),
                .init(time: start.addingTimeInterval(60), temperatureCelsius: 0,
                      windSpeedKmh: laterWind, visibilityKm: laterVisibility, cloudCoverPercent: 0)
            ]
        )
    }

    private func profile(technicalComfort: Double) -> UserProfile {
        UserProfile(
            id: UUID(),
            displayName: "Skier",
            skillLevel: "expert",
            speedGreen: 8,
            speedBlue: 8,
            speedBlack: 8,
            speedDoubleBlack: 8,
            speedTerrainPark: 8,
            conditionMoguls: technicalComfort,
            conditionUngroomed: technicalComfort,
            conditionIcy: 1,
            conditionGladed: technicalComfort,
            exposureTolerance: technicalComfort,
            onboardingCompleted: true
        )
    }

    private func node(
        _ id: String,
        lat: Double,
        elevation: Double,
        kind: GraphNode.NodeKind
    ) -> GraphNode {
        GraphNode(
            id: id,
            coordinate: CLLocationCoordinate2D(latitude: lat, longitude: -106),
            elevation: elevation,
            kind: kind
        )
    }

    private func run(
        id: String,
        from source: String,
        to target: String,
        length: Double,
        obstacleDensity: Double
    ) -> GraphEdge {
        GraphEdge(
            id: id,
            sourceID: source,
            targetID: target,
            kind: .run,
            geometry: [],
            attributes: EdgeAttributes(
                difficulty: .blue,
                lengthMeters: length,
                isGroomed: true,
                isOpen: true,
                isOfficiallyValidated: true,
                obstacleDensity: obstacleDensity
            )
        )
    }
}
