import Testing
@testable import MountainCore

/// A run that splits round an island: the profile follows one way down, the
/// longer one, from the top, never both branches drawn end to end.
@Test func aSplitRunsProfileFollowsOneWayDownFromTheTop() {
    func point(_ lat: Double, _ ele: Double) -> GeoPoint { GeoPoint(lon: -122.95, lat: lat, eleM: ele) }
    func edge(_ id: String, _ from: String, _ to: String, _ line: [GeoPoint]) -> Edge {
        Edge(id: EdgeID(rawValue: id), from: NodeID(rawValue: from), to: NodeID(rawValue: to), kind: .run,
             geometry: line, lengthM: Geo.lengthM(line.map(\.coordinate)),
             verticalM: line[line.count - 1].eleM - line[0].eleM)
    }
    let top = point(50.110, 1_500), split = point(50.108, 1_400), bottom = point(50.100, 1_000)
    let edges = [
        // The long way round the island.
        edge("w1:1", "b", "c", [split, GeoPoint(lon: -122.94, lat: 50.104, eleM: 1_250), bottom]),
        edge("w1:0", "a", "b", [top, split]),
        edge("w2:0", "b", "c", [split, bottom]),
    ]

    let profile = ElevationProfile.points(along: edges, samples: 11)
    #expect(profile.count == 11)
    #expect(profile.first?.eleM == 1_500)
    #expect(abs((profile.last?.eleM ?? 0) - 1_000) < 0.01)
    // Along the long branch: farther than the straight way down.
    #expect((profile.last?.distanceM ?? 0) > Geo.haversineM(top.coordinate, bottom.coordinate) + 100)
    #expect(zip(profile, profile.dropFirst()).allSatisfy { $0.distanceM < $1.distanceM && $0.eleM >= $1.eleM })
}

/// Three pieces of one name that the map does not join: no one line is half
/// the run, so there is no profile rather than a part shown as the whole.
@Test func aRunInUnjoinedPiecesHasNoProfile() {
    func piece(_ id: String, _ lat: Double) -> Edge {
        let line = [GeoPoint(lon: -122.95, lat: lat, eleM: 1_200), GeoPoint(lon: -122.95, lat: lat - 0.002, eleM: 1_100)]
        return Edge(id: EdgeID(rawValue: id), from: NodeID(rawValue: "\(id)a"), to: NodeID(rawValue: "\(id)b"),
                    kind: .run, geometry: line, lengthM: Geo.lengthM(line.map(\.coordinate)), verticalM: -100)
    }
    #expect(ElevationProfile.points(along: [piece("w1:0", 50.11), piece("w2:0", 50.10), piece("w3:0", 50.09)]).isEmpty)
}
