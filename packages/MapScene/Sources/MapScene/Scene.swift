import Foundation
import MountainCore

/// Every source the map renders. Static sources are built once per bundle and never
/// touched by status, selection or progress; dynamic sources are small (a route
/// line, a handful of points) and replaced whole.
public enum SceneSourceID: String, Sendable, Hashable, CaseIterable {
    /// One feature per trail group: the consolidated, smoothed run.
    case trails = "pm-trails"
    /// One feature per run or lift edge, exactly where it is. Carries `closed`.
    case edges = "pm-edges"
    /// One feature per lift group.
    case lifts = "pm-lifts"
    /// Connection edges (traverses).
    case connections = "pm-connections"
    /// Lift stations.
    case liftEnds = "pm-lift-ends"
    /// The rendezvous catalog: landmarks, and the meeting marker through state.
    case rendezvous = "pm-rendezvous"
    /// A small polygon under each rendezvous, extruded for the meeting beam.
    case beams = "pm-rendezvous-beams"

    case routeA = "pm-route-a"
    case routeB = "pm-route-b"
    case friends = "pm-friends"
    case user = "pm-user"
    /// The run or lift the user tapped, drawn again on top of itself.
    case selection = "pm-selection"
    /// Scrubbing back: each friend's path since the start of the timeline.
    case breadcrumbs = "pm-breadcrumbs"
    /// Scrubbing forward in a meet: where each skier will be, and the dots
    /// along the way.
    case ghosts = "pm-ghosts"

    public static let staticSources: [SceneSourceID] = [
        .trails, .edges, .lifts, .connections, .liftEnds, .rendezvous, .beams,
    ]
    public static let dynamicSources: [SceneSourceID] = [
        .routeA, .routeB, .friends, .user, .selection, .breadcrumbs, .ghosts,
    ]

    public var isStatic: Bool { Self.staticSources.contains(self) }

    /// State every feature of this source has until a diff says otherwise. A
    /// source with no entry takes no feature-state.
    public var defaultState: FeatureState {
        switch self {
        case .trails:
            [StateKey.availability: .number(0), StateKey.groomed: .bool(false),
             StateKey.selected: .bool(false)]
        case .edges: [StateKey.closed: .bool(false)]
        case .lifts: [StateKey.status: .number(0), StateKey.selected: .bool(false)]
        case .rendezvous, .beams: [StateKey.meeting: .bool(false)]
        case .connections, .liftEnds, .routeA, .routeB, .friends, .user, .selection, .breadcrumbs, .ghosts: [:]
        }
    }
}

/// Feature-state keys, shared by the builder and the adapter's paint expressions.
public enum StateKey {
    /// Trails: 0 open, 1 partial, 2 closed (`TerrainAvailability.code`).
    public static let availability = "availability"
    public static let groomed = "groomed"
    public static let selected = "selected"
    /// Edges: this exact segment is closed.
    public static let closed = "closed"
    /// Lifts: 0 running or unknown, 1 on hold, 2 closed.
    public static let status = "status"
    /// Rendezvous and beams: this is the agreed meeting point.
    public static let meeting = "meeting"
}

public enum SceneValue: Sendable, Hashable {
    case string(String)
    case number(Double)
    case bool(Bool)
}

public typealias FeatureState = [String: SceneValue]

public enum SceneShape: Sendable, Hashable {
    case point(Coordinate)
    case line([Coordinate])
    case lines([[Coordinate]])
    /// One closed outer ring.
    case polygon([Coordinate])
}

public struct SceneFeature: Sendable, Hashable {
    /// Stable across builds of the same bundle: a group, edge, node or rendezvous
    /// identity from the bundle, never an array position.
    public var id: String
    public var shape: SceneShape
    public var properties: [String: SceneValue]

    public init(id: String, shape: SceneShape, properties: [String: SceneValue] = [:]) {
        self.id = id
        self.shape = shape
        self.properties = properties
    }
}

public struct SceneSource: Sendable, Hashable {
    public var id: SceneSourceID
    public var features: [SceneFeature]

    public init(id: SceneSourceID, features: [SceneFeature]) {
        self.id = id
        self.features = features
    }
}

/// The map's colours.
public enum MapPalette {
    public static let lift = "#FFD166"
    public static let routeA = "#38D9FF"
    public static let routeB = "#FF8A3D"
    public static let meet = "#FBBF24"
    public static let closed = "#FF3B4E"
    /// Friends' markers and their breadcrumb trails.
    public static let friend = "#F59E0B"

    public static func hex(for difficulty: Difficulty?) -> String {
        switch difficulty {
        case .green: "#5DEA8C"
        case .blue: "#7AB8FF"
        case .black: "#F5F5F7"
        case .doubleBlack: "#FF5C6E"
        case .park: "#FF8533"
        case .unknown, nil: "#FFFFFF"
        }
    }
}
