import Foundation
import MeetSolver
import MountainCore
import Testing
@testable import MapScene

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

/// Two named runs and a lift. `trail:long` lists three edges, the last of which is
/// the shared run-out that belongs to `trail:cat`, so the two can close apart.
private func fixtureBundle() -> ResortBundle {
    func node(_ id: String, _ lon: Double, _ lat: Double, _ ele: Double) -> Node {
        Node(id: NodeID(id), lon: lon, lat: lat, eleM: ele, kind: .junction)
    }
    let nodes = [
        node("n1", -122.950, 50.100, 2000), node("n2", -122.948, 50.098, 1900),
        node("n3", -122.946, 50.096, 1800), node("n4", -122.944, 50.094, 1700),
    ]
    func run(_ id: String, _ a: Int, _ b: Int, group: String) -> Edge {
        let from = nodes[a], to = nodes[b]
        let mid = GeoPoint(
            lon: (from.lon + to.lon) / 2 + 0.0004, lat: (from.lat + to.lat) / 2, eleM: 0)
        return Edge(
            id: EdgeID(id), from: from.id, to: to.id, kind: .run, group: GroupID(group),
            name: group, difficulty: .blue,
            geometry: [GeoPoint(lon: from.lon, lat: from.lat, eleM: from.eleM), mid,
                       GeoPoint(lon: to.lon, lat: to.lat, eleM: to.eleM)],
            lengthM: 300, verticalM: -100)
    }
    let lift = Edge(
        id: "w9:0", from: "n4", to: "n1", kind: .lift, group: "lift:chair", name: "Chair",
        geometry: [GeoPoint(lon: -122.944, lat: 50.094, eleM: 1700),
                   GeoPoint(lon: -122.950, lat: 50.100, eleM: 2000)],
        lengthM: 800, verticalM: 300, lift: LiftInfo(type: .chair, rideS: 300))
    let edges = [
        run("w1:0", 0, 1, group: "trail:long"), run("w1:1", 1, 2, group: "trail:long"),
        run("w2:0", 2, 3, group: "trail:cat"), lift,
    ]
    let document = BundleDocument(
        resortID: "test", name: "Test", timezone: "America/Vancouver",
        bbox: BoundingBox(minLon: -122.96, minLat: 50.09, maxLon: -122.94, maxLat: 50.11),
        center: Coordinate(lon: -122.947, lat: 50.097),
        source: .init(extractID: "x", osmExtractAt: t0, manifestVersion: 1), builtAt: t0,
        nodes: nodes, edges: edges,
        groups: [
            Group(id: "trail:long", kind: .trail, name: "Long", difficulty: .blue,
                  edgeIDs: ["w1:0", "w1:1", "w2:0"]),
            Group(id: "trail:cat", kind: .trail, name: "Cat", difficulty: .green, edgeIDs: ["w2:0"]),
            Group(id: "lift:chair", kind: .lift, name: "Chair", edgeIDs: ["w9:0"]),
        ],
        rendezvous: [Rendezvous(
            id: "top", nodeID: "n1", kind: .liftTop, name: "Top", confidence: 1, quality: 1)])
    return ResortBundle(id: BundleID(String(repeating: "a", count: 64))!, document: document)
}

private func status(_ groups: [GroupID: GroupState], groomed: [GroupID] = []) -> ResortStatus {
    ResortStatus(
        resortID: "test", observedAt: t0, expiresAt: t0.addingTimeInterval(4_500), source: .epic,
        groups: groups, groomed: groomed)
}

@Test func statusChangeIsStateOnly() {
    let bundle = fixtureBundle()
    let time = SceneTime(now: t0)
    let open = SceneBuilder.build(RenderInput(bundle: bundle, status: status([:]), time: time))
    let changed = SceneBuilder.build(
        RenderInput(
            bundle: bundle, status: status(["trail:cat": .closed], groomed: ["trail:long"]),
            time: time),
        reusing: open)

    let first = SceneDiffer.diff(old: nil, new: open)
    #expect(first.hasGeometry)

    let diff = SceneDiffer.diff(old: open, new: changed)
    #expect(!diff.hasGeometry)
    #expect(diff.overlays.isEmpty)
    #expect(diff.environment == nil && diff.frame == nil && !diff.replayRouteReveal)
    #expect(diff.states.contains {
        $0.source == .edges && $0.featureID == "w2:0" && $0.state[StateKey.closed] == .bool(true)
    })
    #expect(diff.states.contains {
        $0.source == .trails && $0.featureID == "trail:long"
            && $0.state[StateKey.groomed] == .bool(true)
    })

    // Reopening sends the default state back, still with no geometry.
    let reopened = SceneDiffer.diff(old: changed, new: open)
    #expect(!reopened.hasGeometry)
    #expect(reopened.states.contains {
        $0.source == .edges && $0.featureID == "w2:0" && $0.state[StateKey.closed] == .bool(false)
    })
    #expect(SceneDiffer.diff(old: open, new: open).isEmpty)
}

@Test func runAvailabilityAcrossMemberEdges() {
    let bundle = fixtureBundle()
    func model(_ groups: [GroupID: GroupState]) -> RenderModel {
        SceneBuilder.build(RenderInput(bundle: bundle, status: status(groups), time: SceneTime(now: t0)))
    }

    #expect(model([:]).availability(of: "trail:long") == .open)

    // Only the shared run-out is closed: the long run is partial, never open, and
    // exactly that segment is marked.
    let partial = model(["trail:cat": .closed])
    #expect(partial.availability(of: "trail:long") == .partiallyOpen(open: 2, total: 3))
    #expect(partial.availability(of: "trail:cat") == .closed)
    #expect(partial.featureStates[.edges].map { Set($0.keys) } == ["w2:0"])
    #expect(partial.featureStates[.trails]?["trail:long"]?[StateKey.availability] == .number(1))

    let closed = model(["trail:cat": .closed, "trail:long": .closed])
    #expect(closed.availability(of: "trail:long") == .closed)
    #expect(closed.featureStates[.edges].map { Set($0.keys) } == ["w1:0", "w1:1", "w2:0"])

    // Stale status keeps its closures; status past the stale window says nothing.
    let stale = SceneBuilder.build(RenderInput(
        bundle: bundle, status: status(["trail:cat": .closed]),
        time: SceneTime(now: t0.addingTimeInterval(3 * 3_600))))
    #expect(stale.availability(of: "trail:cat") == .closed)
    let expired = SceneBuilder.build(RenderInput(
        bundle: bundle, status: status(["trail:cat": .closed]),
        time: SceneTime(now: t0.addingTimeInterval(9 * 3_600))))
    #expect(expired.availability(of: "trail:cat") == .open)
}

/// Smoothing the whole route used to cut the corners of the lift's tower line,
/// so the route drifted off the lift it rides.
@Test func aRouteRidesTheLiftOnItsOwnLine() throws {
    let bundle = fixtureBundle()
    let lift = try #require(bundle.graph.edge("w9:0")).coordinates
    let line = RemainingRoute(edgeIDs: ["w2:0", "w9:0"], initialEdgeFraction: 0).coordinates(in: bundle)
    #expect(Array(line.suffix(lift.count)) == lift)
    #expect(line.count > lift.count + 3)
}

@Test func remainingRouteSlice() {
    let bundle = fixtureBundle()
    let route = Route(
        skierID: UUID(),
        legs: [
            RouteLeg(edgeID: "w1:0", enterS: 0, exitS: 60, startFraction: 0.25),
            RouteLeg(edgeID: "w1:1", enterS: 60, exitS: 120),
            RouteLeg(edgeID: "w2:0", enterS: 120, exitS: 180),
        ],
        eta: ETA(meanS: 180, sdS: 10), hardestDifficulty: .blue, liftCount: 0, lengthM: 900)

    // Before any fix, the first edge is still clipped to where the route began.
    let start = RemainingRoute.remaining(of: route, legIndex: 0, fractionAlongLeg: 0)
    #expect(start.edgeIDs == ["w1:0", "w1:1", "w2:0"])
    #expect(start.initialEdgeFraction == 0.25)

    let mid = RemainingRoute.remaining(of: route, legIndex: 1, fractionAlongLeg: 0.5)
    #expect(mid.edgeIDs == ["w1:1", "w2:0"])
    #expect(mid.initialEdgeFraction == 0.5)
    let line = mid.coordinates(in: bundle)
    let full = RemainingRoute.remaining(of: route, legIndex: 1, fractionAlongLeg: 0)
        .coordinates(in: bundle)
    #expect(line.count >= 2)
    #expect(Geo.lengthM(line) < Geo.lengthM(full))
    // It starts part-way down the second edge and ends at the route's end.
    #expect(line.first != full.first)
    #expect(line.last == Coordinate(lon: -122.944, lat: 50.094))

    #expect(RemainingRoute.remaining(of: route, legIndex: 3, fractionAlongLeg: 0) == .none)

    // Dropping a finished leg is progress, not a new plan.
    #expect(!MapRouteAnimationPolicy.shouldReplay(
        previousA: start.edgeIDs, previousB: [], nextA: mid.edgeIDs, nextB: [], forced: false))
    #expect(MapRouteAnimationPolicy.shouldReplay(
        previousA: [], previousB: [], nextA: mid.edgeIDs, nextB: [], forced: false))
}

@Test func whistlerBundleBuildsStableScene() throws {
    let name = "whistler-blackcomb.95236f0065c782dd745561fa4e153845c6a9f568cbd7cdf1e1087c43ee0ef16d"
    let url = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("MountainCore/Tests/Fixtures/\(name).json.gz")
    let id = try #require(BundleID(String(name.split(separator: ".")[1])))
    let bundle = try BundleLoader.load(data: Data(contentsOf: url), expectedID: id)

    let first = SceneBuilder.geometry(for: bundle)
    let second = SceneBuilder.geometry(for: bundle)
    #expect(first.sources == second.sources)
    #expect(first.sources.map(\.id) == SceneSourceID.staticSources)

    for source in first.sources {
        let ids = source.features.map(\.id)
        #expect(!ids.isEmpty)
        #expect(Set(ids).count == ids.count, "duplicate ids in \(source.id.rawValue)")
        // The text handed to the map is valid GeoJSON with every feature in it.
        let parsed = try JSONSerialization.jsonObject(with: Data(source.geoJSON().utf8))
        #expect(((parsed as? [String: Any])?["features"] as? [Any])?.count == ids.count)
    }
    // Every named trail and lift, every run and lift segment, every rendezvous.
    let trailGroups = bundle.groups.filter { $0.kind == .trail }.map(\.id.rawValue)
    #expect(first.source(.trails)?.features.map(\.id) == trailGroups)
    #expect(first.source(.lifts)?.features.count == bundle.groups.filter { $0.kind == .lift }.count)
    #expect(first.source(.rendezvous)?.features.count == bundle.rendezvous.count)
    let segments = Set(first.source(.edges)?.features.map(\.id) ?? [])
    #expect(bundle.graph.edges.filter { $0.kind != .connection }
        .allSatisfy { segments.contains($0.id.rawValue) })

    let model = SceneBuilder.build(RenderInput(bundle: bundle, time: SceneTime(now: t0)))
    #expect(model.featureStates.values.allSatisfy { $0.isEmpty })
}

@Test func placeIconsFollowAmenities() {
    #expect(PlaceIcon.icon(kind: .lodge, amenities: ["food", "indoor", "restrooms"]) == "fork.knife")
    #expect(PlaceIcon.icon(kind: .landmark, amenities: ["indoor"]) == "house.fill")
    #expect(PlaceIcon.icon(kind: .liftBase, amenities: []) == "cablecar.fill")
    #expect(PlaceIcon.icon(kind: .landmark, amenities: ["restrooms"]) == "toilet.fill")
    // Every icon a place can name is one the adapter registers.
    for kind in [RendezvousKind.lodge, .liftBase, .liftTop, .landmark, .junction] {
        for amenities in [[], ["food"], ["indoor"], ["restrooms"], ["first_aid"], ["parking"], ["rental"]] {
            #expect(PlaceIcon.all.contains(PlaceIcon.icon(kind: kind, amenities: amenities)))
        }
    }
    #expect(PlaceIcon.ordered(["indoor", "zz", "food"]) == ["food", "indoor", "zz"])
}

@Test func timelineReachesPastArrival() {
    let plain = TimelineWindow.range(now: t0, arrival: nil)
    #expect(plain.upperBound == t0.addingTimeInterval(12 * 3_600))
    #expect(TimelineWindow.range(now: t0, arrival: t0.addingTimeInterval(1_800)).upperBound
        == plain.upperBound)
    let late = t0.addingTimeInterval(13 * 3_600)
    #expect(TimelineWindow.range(now: t0, arrival: late).upperBound == late.addingTimeInterval(300))
}

@Test func goToRoutesToTheEntry() throws {
    let bundle = fixtureBundle()
    // The lift's bottom station has no rendezvous; the run's top does.
    let run = try #require(GoToPlanner.target(for: "trail:long", in: bundle))
    #expect(run.rendezvous == "top" && run.isExact)
    #expect(GoToPlanner.target(for: "lift:chair", in: bundle) == nil)
    #expect(GoToPlanner.entryNode(of: try #require(bundle.group("lift:chair")), in: bundle)?.id == "n4")

    let me = UUID()
    let skier = SkierInput(
        id: me, profile: .preset(.intermediate, userID: me), origin: .node("n4"))
    let plan = try GoToPlanner.plan(
        to: "trail:long", skier: skier, bundle: bundle, status: nil, conditions: nil,
        at: t0.addingTimeInterval(11 * 3_600)
    ).get()
    #expect(plan.route.legs.map(\.edgeID) == ["w9:0"])
    #expect(plan.ascentM == 300)
    #expect(GoToPlanner.plan(
        to: "trail:long", skier: nil, bundle: bundle, status: nil, conditions: nil, at: t0
    ) == .failure(.notOnMap))
}

@Test func friendsStandingTogetherDrawApart() throws {
    let here = Coordinate(lon: -122.95, lat: 50.1)
    let a = UUID(), b = UUID(), c = UUID()
    let spread = FriendSpread.positions([
        (a, here), (b, Coordinate(lon: -122.9501, lat: 50.1)),
        (c, Coordinate(lon: -122.94, lat: 50.1)),
    ])
    let pa = try #require(spread[a]), pb = try #require(spread[b])
    #expect(Geo.haversineM(pa, pb) >= FriendSpread.spacingM - 1)
    // A friend far from the others stays exactly where they are.
    #expect(spread[c] == Coordinate(lon: -122.94, lat: 50.1))
}

/// A friend who closed the resort sends nothing more: their dot reads "Lost
/// signal" from ten minutes and leaves the map with the server's 15 minute TTL,
/// not hours later.
@Test func aFriendWhoStoppedSendingLeavesTheMapAfterFifteenMinutes() {
    let friend = FriendMarker(
        id: UUID(), displayName: "Bob Day", coordinate: Coordinate(lon: -122.95, lat: 50.1), capturedAt: t0)
    func drawn(after seconds: TimeInterval) -> Bool {
        !SceneBuilder.friendFeatures([friend], now: t0.addingTimeInterval(seconds)).isEmpty
    }
    #expect(drawn(after: 12 * 60))
    #expect(FriendSignal.classify(lastSeen: t0, now: t0.addingTimeInterval(12 * 60)).label.hasPrefix("LOST SIGNAL"))
    #expect(drawn(after: FriendSignal.forgetAfterS))
    #expect(!drawn(after: FriendSignal.forgetAfterS + 1))
}

/// Sun Bowl Chutes at Whistler: two arms leave one point, meet again and one runs
/// on. The line used to go down one arm and back up the other.
@Test func aRunWithTwoArmsIsNotDrawnFoldingBackOnItself() {
    func point(_ lon: Double, _ lat: Double) -> GeoPoint { GeoPoint(lon: lon, lat: lat, eleM: 0) }
    let top = point(-122.9440, 50.0553), bottom = point(-122.9421, 50.0544)
    func run(_ id: String, _ from: String, _ to: String, _ geometry: [GeoPoint]) -> Edge {
        Edge(
            id: EdgeID(id), from: NodeID(from), to: NodeID(to), kind: .run,
            group: GroupID("trail:chutes"), name: "Chutes", difficulty: .doubleBlack,
            geometry: geometry, lengthM: 100, verticalM: -50)
    }
    let chains = TrailChainGeometry.chains([
        run("w1:1", "top", "bottom", [top, point(-122.9436, 50.0546), bottom]),
        run("w2:0", "top", "bottom", [top, point(-122.9430, 50.0549), bottom]),
        run("w2:1", "bottom", "out", [bottom, point(-122.9414, 50.0542)]),
    ])
    let out = Coordinate(lon: -122.9414, lat: 50.0542)
    func visits(_ chain: [Coordinate], _ place: Coordinate) -> Int {
        chain.count { Polyline.coincide($0, place) }
    }
    #expect(chains.count == 2)
    // Each arm is its own pass from the split to the join, and one of them
    // carries on through the join to the run-out.
    #expect(chains.allSatisfy { visits($0, top.coordinate) == 1 && visits($0, bottom.coordinate) == 1 })
    #expect(chains.count { visits($0, out) == 1 } == 1)
}
