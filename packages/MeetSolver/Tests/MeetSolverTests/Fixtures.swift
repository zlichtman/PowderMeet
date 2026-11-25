import Foundation
import MountainCore
@testable import MeetSolver

/// A small synthetic resort, built node by node and edge by edge so each
/// reference scenario keeps its exact graph. It skips `BundleLoader`, so nothing here
/// has to satisfy geometry integrity.
struct Mountain {
    var nodes: [Node] = []
    var edges: [Edge] = []
    var points: [Rendezvous] = []
    var timezone = "America/Denver"

    @discardableResult
    mutating func node(
        _ id: String, _ kind: NodeKind = .junction, lon: Double, lat: Double = 40,
        ele: Double = 2_500
    ) -> Node {
        let node = Node(id: NodeID(id), lon: lon, lat: lat, eleM: ele, kind: kind)
        nodes.append(node)
        return node
    }

    private func line(_ from: Node, _ to: Node) -> [GeoPoint] {
        [GeoPoint(lon: from.lon, lat: from.lat, eleM: from.eleM),
         GeoPoint(lon: to.lon, lat: to.lat, eleM: to.eleM)]
    }

    /// `drop` is metres descended over the run.
    @discardableResult
    mutating func run(
        _ id: String, _ from: Node, _ to: Node, length: Double, difficulty: Difficulty? = .blue,
        groomed: Bool? = true, drop: Double = 0, grade: Double? = nil, aspect: Double? = nil,
        group: String? = nil, name: String? = nil
    ) -> Edge {
        let edge = Edge(
            id: EdgeID(id), from: from.id, to: to.id, kind: .run, group: group.map(GroupID.init),
            name: name, difficulty: difficulty, geometry: line(from, to), lengthM: length,
            verticalM: -drop, gradeMaxDeg: grade, groomedDefault: groomed, aspectDeg: aspect
        )
        edges.append(edge)
        return edge
    }

    @discardableResult
    mutating func lift(
        _ id: String, _ from: Node, _ to: Node, ride: Double, length: Double = 500,
        rise: Double = 200, type: LiftType = .chair, hours: [OperatingHours] = [],
        group: String? = nil, name: String? = nil, twoWay: Bool = false
    ) -> Edge {
        let edge = Edge(
            id: EdgeID(id), from: from.id, to: to.id, kind: .lift, group: group.map(GroupID.init),
            name: name, geometry: line(from, to), lengthM: length, verticalM: rise,
            oneWay: !twoWay,
            lift: LiftInfo(
                type: type, rideS: ride, operatingHours: hours, queueEntry: twoWay ? .both : .bottom
            )
        )
        edges.append(edge)
        return edge
    }

    @discardableResult
    mutating func connection(
        _ id: String, _ from: Node, _ to: Node, length: Double, rise: Double = 0,
        name: String? = nil
    ) -> Edge {
        let edge = Edge(
            id: EdgeID(id), from: from.id, to: to.id, kind: .connection, name: name,
            geometry: line(from, to), lengthM: length, verticalM: rise
        )
        edges.append(edge)
        return edge
    }

    mutating func meet(
        _ node: Node, _ kind: RendezvousKind = .liftBase, confidence: Double = 1,
        quality: Double = 1, amenities: [String] = []
    ) {
        points.append(Rendezvous(
            id: RendezvousID(node.id.rawValue), nodeID: node.id, kind: kind,
            name: node.id.rawValue, confidence: confidence, quality: quality, amenities: amenities
        ))
    }

    func bundle() -> ResortBundle {
        let lons = nodes.map(\.lon), lats = nodes.map(\.lat)
        let box = BoundingBox(
            minLon: (lons.min() ?? 0) - 0.01, minLat: (lats.min() ?? 0) - 0.01,
            maxLon: (lons.max() ?? 0) + 0.01, maxLat: (lats.max() ?? 0) + 0.01
        )
        let document = BundleDocument(
            resortID: "test", name: "Test", timezone: timezone, bbox: box,
            center: Coordinate(lon: (box.minLon + box.maxLon) / 2, lat: (box.minLat + box.maxLat) / 2),
            source: .init(extractID: "fixture", osmExtractAt: Clock.afternoon, manifestVersion: 1),
            builtAt: Clock.afternoon, nodes: nodes, edges: edges, groups: [], rendezvous: points
        )
        // A fresh identity per fixture: bundles hash by id alone.
        return ResortBundle(
            id: BundleID(SHA256.hex(Data(UUID().uuidString.utf8)))!, document: document
        )
    }
}

enum Clock {
    /// Wednesday 14 January 2026, 18:00 in Denver (01:00Z on the 15th). The queue
    /// curve is flat from 16:00, lifts without listed hours run until 21:00, it is
    /// a weekday and the sun is down, so a solve here prices every edge as a
    /// solve with no time of day would.
    static let afternoon = Date(timeIntervalSince1970: 1_768_438_800)

    /// A Denver wall-clock time on Wednesday 14 January 2026 (UTC−7).
    static func denver(_ hour: Int, _ minute: Int = 0, _ second: Int = 0) -> Date {
        Date(timeIntervalSince1970: 1_768_438_800 - 18 * 3_600
            + Double(hour * 3_600 + minute * 60 + second))
    }
}

/// The reference test profile: 10 m/s on everything the tier may ski.
func profile(_ ability: Ability = .intermediate, speed: Double = 10) -> SkierProfile {
    var speeds: [Difficulty: Double] = [.green: speed, .blue: speed]
    if ability == .expert {
        speeds[.black] = speed
        speeds[.doubleBlack] = speed
        speeds[.park] = speed
    }
    return SkierProfile(
        userID: UUID(), ability: ability,
        maxDifficulty: ability == .expert ? .doubleBlack : .blue, baselineSpeedMS: speeds
    )
}

/// The reference scenarios assume no stops, so they run with a zero learned stop
/// rate.
func skier(_ profile: SkierProfile = profile(), at origin: RoutingOrigin) -> SkierInput {
    SkierInput(
        id: profile.userID, profile: profile,
        pace: PaceModel(ownerID: profile.userID, computedAt: Clock.afternoon, stopsPerKm: 0),
        origin: origin
    )
}

func skier(_ profile: SkierProfile = profile(), at node: Node) -> SkierInput {
    skier(profile, at: .node(node.id))
}

func input(
    _ bundle: ResortBundle, _ a: SkierInput, _ b: SkierInput, at: Date = Clock.afternoon,
    status: ResortStatus? = nil, conditions: Conditions? = nil,
    options: SolveOptions = SolveOptions()
) -> SolveInput {
    SolveInput(
        bundle: bundle, status: status, conditions: conditions, at: at, skiers: (a, b),
        options: options
    )
}

/// A fresh status row closing the given groups, with live waits in minutes.
func status(
    closed: [String] = [], hold: [String] = [], waits: [String: Double] = [:],
    at: Date = Clock.afternoon
) -> ResortStatus {
    var groups: [GroupID: GroupState] = [:]
    for id in closed { groups[GroupID(id)] = .closed }
    for id in hold { groups[GroupID(id)] = .hold }
    var minutes: [GroupID: Double] = [:]
    for (id, wait) in waits { minutes[GroupID(id)] = wait }
    return ResortStatus(
        resortID: "test", observedAt: at.addingTimeInterval(-600),
        expiresAt: at.addingTimeInterval(65 * 60), source: .epic, groups: groups,
        waitMinutes: minutes
    )
}

func weather(
    at: Date = Clock.afternoon, tempC: Double = -2, windKmh: Double = 0, visibilityKm: Double = 10,
    cloudPct: Double = 0, snowCM: Double = 0, hourly: [ConditionsSample] = []
) -> Conditions {
    Conditions(
        resortID: "test", observedAt: at, expiresAt: at.addingTimeInterval(90 * 60),
        current: sample(at: at, tempC: tempC, windKmh: windKmh, visibilityKm: visibilityKm,
                        cloudPct: cloudPct, snowCM: snowCM),
        hourly: hourly
    )
}

func sample(
    at: Date, tempC: Double = -2, windKmh: Double = 0, visibilityKm: Double = 10,
    cloudPct: Double = 0, snowCM: Double = 0
) -> ConditionsSample {
    ConditionsSample(
        at: at, tempC: tempC, windMS: windKmh / 3.6, visibilityM: visibilityKm * 1_000,
        cloudPct: cloudPct, snow24hCM: snowCM
    )
}

/// The real Whistler Blackcomb bundle from MountainCore's test fixtures, for the
/// ranking scenarios that only show up on a full resort graph.
enum Whistler {
    static func bundle() throws -> ResortBundle {
        let prefix = "whistler-blackcomb."
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../../MountainCore/Tests/Fixtures").standardizedFileURL
        let files = try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        )
        guard let url = files.first(where: { $0.lastPathComponent.hasPrefix(prefix) }),
              let id = BundleID(rawValue: String(url.lastPathComponent.dropFirst(prefix.count).prefix(64)))
        else { throw CocoaError(.fileNoSuchFile) }
        return try BundleLoader.load(data: Data(contentsOf: url), expectedID: id)
    }

    /// A Whistler wall-clock time on Wednesday 14 January 2026 (UTC−8).
    static func time(_ hour: Int, _ minute: Int = 0) -> Date {
        Date(timeIntervalSince1970: 1_768_348_800 + Double((hour + 8) * 3_600 + minute * 60))
    }

    /// An onboarding-preset skier standing at a named stop.
    static func skier(_ ability: Ability = .intermediate, at stop: String, in bundle: ResortBundle)
        throws -> SkierInput {
        guard let point = bundle.rendezvous.first(where: { $0.name == stop }) else {
            throw CocoaError(.fileNoSuchFile)
        }
        let id = UUID()
        return SkierInput(
            id: id, profile: .preset(ability, userID: id), pace: nil, origin: .node(point.nodeID)
        )
    }
}
