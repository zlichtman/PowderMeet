//
//  MountainGraph.swift
//  PowderMeet
//
//  Directed graph representation of a ski mountain.
//  Nodes = junctions (lift bases, lift tops, trail intersections).
//  Edges = runs (downhill) and lifts (uphill), each with attributes
//  that feed into the per-skier weight function.
//

import Foundation
import CoreLocation

// MARK: - Node

// `nonisolated` — pure value type, must be constructible from
// detached graph build / snapshot decode. Same rationale as GraphEdge
// above. Project default isolation is MainActor; opt out.
nonisolated struct GraphNode: Identifiable, Hashable, Codable {
    let id: String
    let coordinate: CLLocationCoordinate2D
    let elevation: Double  // meters
    let kind: NodeKind

    enum NodeKind: String, Codable {
        case liftBase, liftTop, junction, trailHead, trailEnd, midStation
    }

    enum CodingKeys: String, CodingKey { case id, lat, lon, elevation, kind }

    init(id: String, coordinate: CLLocationCoordinate2D, elevation: Double, kind: NodeKind) {
        self.id = id; self.coordinate = coordinate; self.elevation = elevation; self.kind = kind
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        let lat = try c.decode(Double.self, forKey: .lat)
        let lon = try c.decode(Double.self, forKey: .lon)
        coordinate = CLLocationCoordinate2D(latitude: lat, longitude: lon)
        elevation = try c.decode(Double.self, forKey: .elevation)
        kind = try c.decode(NodeKind.self, forKey: .kind)
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(coordinate.latitude, forKey: .lat)
        try c.encode(coordinate.longitude, forKey: .lon)
        try c.encode(elevation, forKey: .elevation)
        try c.encode(kind, forKey: .kind)
    }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
    static func == (lhs: GraphNode, rhs: GraphNode) -> Bool { lhs.id == rhs.id }
}

// MARK: - Edge

// `nonisolated` — pure value type, must be constructible/decodable from
// detached tasks (curated overlay, graph build, snapshot fetch all run
// off the main actor). Project default isolation is MainActor; opt out
// here so model construction doesn't need an actor hop.
nonisolated struct GraphEdge: Identifiable, Codable {
    let id: String
    let sourceID: String
    let targetID: String
    let kind: EdgeKind
    let geometry: [CLLocationCoordinate2D]
    let attributes: EdgeAttributes

    enum EdgeKind: String, Codable {
        case run, lift, traverse
    }

    enum CodingKeys: String, CodingKey {
        case id, sourceID, targetID, kind, geometryPairs, attributes
    }
    init(id: String, sourceID: String, targetID: String, kind: EdgeKind,
         geometry: [CLLocationCoordinate2D], attributes: EdgeAttributes) {
        self.id = id; self.sourceID = sourceID; self.targetID = targetID
        self.kind = kind; self.geometry = geometry; self.attributes = attributes
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        sourceID = try c.decode(String.self, forKey: .sourceID)
        targetID = try c.decode(String.self, forKey: .targetID)
        kind = try c.decode(EdgeKind.self, forKey: .kind)
        attributes = try c.decode(EdgeAttributes.self, forKey: .attributes)
        let pairs = try c.decode([[Double]].self, forKey: .geometryPairs)
        geometry = try pairs.enumerated().map { index, pair in
            guard pair.count == 2 else {
                throw DecodingError.dataCorruptedError(
                    forKey: .geometryPairs,
                    in: c,
                    debugDescription: "geometryPairs[\(index)] must contain exactly [longitude, latitude]"
                )
            }
            return CLLocationCoordinate2D(latitude: pair[1], longitude: pair[0])
        }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id); try c.encode(sourceID, forKey: .sourceID)
        try c.encode(targetID, forKey: .targetID); try c.encode(kind, forKey: .kind)
        try c.encode(attributes, forKey: .attributes)
        let pairs = geometry.map { [$0.longitude, $0.latitude] }
        try c.encode(pairs, forKey: .geometryPairs)
    }
}

// MARK: - Edge Attributes

nonisolated struct EdgeAttributes: Codable {
    let difficulty: RunDifficulty?
    let lengthMeters: Double
    let verticalDrop: Double
    let averageGradient: Double
    let maxGradient: Double
    let aspect: Double?
    /// 0 = straight trail (consistent direction), 1 = switchbacks/highly variable direction.
    /// Used to attenuate sun exposure effects on winding trails.
    let aspectVariance: Double
    let trailName: String?

    var hasMoguls: Bool
    /// Tri-state: `true` = groomed, `false` = not groomed, `nil` = unknown
    /// (OSM tag absent, no enrichment data). Callers treat unknown as an
    /// uncertainty — travel time penalties sit midway between groomed/ungroomed.
    var isGroomed: Bool?
    var isGladed: Bool

    let liftType: LiftType?
    let liftCapacity: Int?
    let rideTimeSeconds: Double?
    let waitTimeMinutes: Double?
    /// Canonical, non-live queue baselines. The solver selects one at the
    /// skier's resort-local arrival day; live waitTimeMinutes still wins.
    let weekdayWaitMinutes: Double?
    let weekendWaitMinutes: Double?
    /// True only on the entry segment of a physical lift chain. Nil preserves
    /// the pre-v11 meaning: a legacy lift edge charges one queue.
    let chargesLiftWait: Bool?

    var isOpen: Bool

    /// Whether this edge has been matched to an official resort data source
    /// (Epic terrain feed, MtnPowder, or bundled curated whitelist).
    /// Edges that remain `false` after enrichment are potential phantom trails.
    var isOfficiallyValidated: Bool

    // MARK: - Skill-precision fields (Phase 3)
    //
    // Continuous 0..1 signals (or nil when unknown) that let the solver's
    // weight function match a route to each skier's specific comfort zone,
    // rather than collapse every blue/black into a single bucket.

    /// Estimated centre-line width of the ski corridor (meters, 10–200).
    /// Derived from OSM `width` tag if present, else from parallel way density.
    var estimatedTrailWidthMeters: Double?
    /// 0..1 — rocks, trees, cornices, ungroomed chop. Drives obstacle penalty
    /// separately from the mogul flag.
    var obstacleDensity: Double?
    /// 0..1 — how "fall-line" the trail runs. Steep + straight = 1.0
    /// (exposure amplifies fall consequences); twisty = near 0.
    var fallLineExposure: Double?
    /// Trail is groomed at night — applicable for night-skiing oriented resorts.
    var nightGroomedFlag: Bool
    /// Hours since last grooming (from Epic/MtnPowder feeds). Nil = unknown.
    var lastGroomedHoursAgo: Int?
    /// One of "corduroy", "crust", "choppy", "hero" — estimated surface
    /// quality given grooming time + recent weather. Nil = no estimate.
    var estimatedSurfaceCondition: String?

    /// Groups edges that form the same logical trail (e.g., multiple OSM way segments
    /// of "Peak to Creek" become one visual trail on the map). Assigned after graph build.
    var trailGroupId: String?

    /// Average elevation of the edge midpoint (meters above sea level).
    /// Used for lapse-rate temperature interpolation.
    let midpointElevation: Double?

    init(difficulty: RunDifficulty? = nil, lengthMeters: Double = 0,
         verticalDrop: Double = 0, averageGradient: Double = 0,
         maxGradient: Double = 0, aspect: Double? = nil, aspectVariance: Double = 0,
         trailName: String? = nil,
         hasMoguls: Bool = false, isGroomed: Bool? = nil, isGladed: Bool = false,
         liftType: LiftType? = nil, liftCapacity: Int? = nil,
         rideTimeSeconds: Double? = nil, waitTimeMinutes: Double? = nil,
         weekdayWaitMinutes: Double? = nil, weekendWaitMinutes: Double? = nil,
         chargesLiftWait: Bool? = nil,
         isOpen: Bool = true, isOfficiallyValidated: Bool = false,
         trailGroupId: String? = nil, midpointElevation: Double? = nil,
         estimatedTrailWidthMeters: Double? = nil,
         obstacleDensity: Double? = nil,
         fallLineExposure: Double? = nil,
         nightGroomedFlag: Bool = false,
         lastGroomedHoursAgo: Int? = nil,
         estimatedSurfaceCondition: String? = nil) {
        self.difficulty = difficulty; self.lengthMeters = lengthMeters
        self.verticalDrop = verticalDrop; self.averageGradient = averageGradient
        self.maxGradient = maxGradient; self.aspect = aspect
        self.aspectVariance = aspectVariance
        self.trailName = trailName
        self.hasMoguls = hasMoguls; self.isGroomed = isGroomed; self.isGladed = isGladed
        self.liftType = liftType; self.liftCapacity = liftCapacity
        self.rideTimeSeconds = rideTimeSeconds; self.waitTimeMinutes = waitTimeMinutes
        self.weekdayWaitMinutes = weekdayWaitMinutes
        self.weekendWaitMinutes = weekendWaitMinutes
        self.chargesLiftWait = chargesLiftWait
        self.isOpen = isOpen
        self.isOfficiallyValidated = isOfficiallyValidated
        self.trailGroupId = trailGroupId
        self.midpointElevation = midpointElevation
        self.estimatedTrailWidthMeters = estimatedTrailWidthMeters
        self.obstacleDensity = obstacleDensity
        self.fallLineExposure = fallLineExposure
        self.nightGroomedFlag = nightGroomedFlag
        self.lastGroomedHoursAgo = lastGroomedHoursAgo
        self.estimatedSurfaceCondition = estimatedSurfaceCondition
    }
}

// MARK: - Run Difficulty

nonisolated enum RunDifficulty: String, Codable, CaseIterable, Comparable, Hashable {
    case green, blue, black, doubleBlack, terrainPark

    var displayName: String {
        switch self {
        case .green: return "Green"; case .blue: return "Blue"
        case .black: return "Black"; case .doubleBlack: return "Double Black"
        case .terrainPark: return "Terrain Park"
        }
    }

    var icon: String {
        switch self {
        case .green:       return "circle.fill"
        case .blue:        return "square.fill"
        case .black:       return "diamond.fill"
        case .doubleBlack: return "diamond.fill"
        case .terrainPark: return "star.fill"
        }
    }

    nonisolated var sortOrder: Int {
        switch self {
        case .green: return 0; case .blue: return 1; case .black: return 2
        case .doubleBlack: return 3; case .terrainPark: return 4
        }
    }

    nonisolated static func < (lhs: RunDifficulty, rhs: RunDifficulty) -> Bool {
        lhs.sortOrder < rhs.sortOrder
    }

    /// Parse from OpenStreetMap piste:difficulty values
    nonisolated static func fromOSM(_ value: String?) -> RunDifficulty? {
        guard let val = value?.lowercased() else { return nil }
        switch val {
        case "novice", "easy":              return .green
        case "intermediate":                return .blue
        case "advanced":                    return .black
        case "expert", "freeride", "extreme": return .doubleBlack
        default:                            return nil
        }
    }
}

// MARK: - Mountain Graph

// `nonisolated` — pure value type that must travel into detached compute
// (solver, graph builder, snapshot pipeline). Project default isolation
// is MainActor; opt out so the struct's methods don't pin the caller to
// the main actor. All members already nonisolated or Sendable.
nonisolated struct MountainGraph: Sendable {
    let resortID: String
    var nodes: [String: GraphNode]
    var edges: [GraphEdge]

    // MARK: - Precomputed Indices (O(1) lookups)

    /// Adjacency list: nodeID → outgoing open edges. Rebuilt on mutation.
    private var _adjacency: [String: [GraphEdge]] = [:]
    /// Incoming edges per node. Rebuilt on mutation.
    private var _incomingAdjacency: [String: [GraphEdge]] = [:]
    /// Edge lookup by ID. Rebuilt on mutation.
    private var _edgeIndex: [String: GraphEdge] = [:]
    /// Whether indices are current.
    private var _indicesBuilt = false

    /// Precomputed fingerprint for diff-gated rendering. Composed of
    /// `nodeCount:edgeCount:versioned64BitContentHash`. Map code rebuilds
    /// GeoJSON sources only when this changes — the per-render O(E) hash
    /// walk in the Coordinator was a Whistler-scale hot path.
    private(set) var fingerprint: String = ""

    init(resortID: String, nodes: [String: GraphNode], edges: [GraphEdge]) {
        self.resortID = resortID
        self.nodes = nodes
        self.edges = edges
        rebuildIndices()
        self.fingerprint = Self.computeFingerprint(resortID: resortID, nodes: nodes, edges: edges)
    }

    /// Rebuild adjacency list and edge index after any edge mutation.
    nonisolated mutating func rebuildIndices() {
        var adj: [String: [GraphEdge]] = [:]
        var inAdj: [String: [GraphEdge]] = [:]
        var idx: [String: GraphEdge] = [:]
        for edge in edges {
            idx[edge.id] = edge
            if edge.attributes.isOpen {
                adj[edge.sourceID, default: []].append(edge)
                inAdj[edge.targetID, default: []].append(edge)
            }
        }
        _adjacency = adj
        _incomingAdjacency = inAdj
        _edgeIndex = idx
        _indicesBuilt = true
        self.fingerprint = Self.computeFingerprint(resortID: resortID, nodes: nodes, edges: edges)
    }

    nonisolated private static func computeFingerprint(
        resortID: String,
        nodes: [String: GraphNode],
        edges: [GraphEdge]
    ) -> String {
        // Versioned, domain-separated 64-bit content fingerprint. It covers
        // the complete graph wire model because the same value gates solver
        // caches and diff-based map rendering. Any field added to GraphNode or
        // EdgeAttributes must be added here and to the TypeScript mirror.
        var checksum: UInt64 = 0
        func mixUInt(_ value: UInt64) {
            checksum = checksum &* 31 &+ value
        }
        func mixString(_ value: String) {
            mixUInt(UInt64(value.utf8.count))
            for byte in value.utf8 { mixUInt(UInt64(byte)) }
        }
        func mixOptionalString(_ value: String?) {
            guard let value else {
                mixUInt(0)
                return
            }
            mixUInt(1)
            mixString(value)
        }
        func mixDouble(_ value: Double) {
            // JSON wire encoding is not required to preserve negative zero.
            // Hash its semantic value so server -0 and decoded client 0 agree.
            mixUInt(value == 0 ? Double.zero.bitPattern : value.bitPattern)
        }
        func mixOptionalDouble(_ value: Double?) {
            guard let value else {
                mixUInt(0)
                return
            }
            mixUInt(1)
            mixDouble(value)
        }
        func mixInt(_ value: Int) {
            mixUInt(UInt64(bitPattern: Int64(value)))
        }
        func mixOptionalInt(_ value: Int?) {
            guard let value else {
                mixUInt(0)
                return
            }
            mixUInt(1)
            mixInt(value)
        }
        func mixBool(_ value: Bool) {
            mixUInt(value ? 1 : 0)
        }
        func mixOptionalBool(_ value: Bool?) {
            switch value {
            case .none:        mixUInt(0)
            case .some(false): mixUInt(1)
            case .some(true):  mixUInt(2)
            }
        }

        mixString("powdermeet.graph-fingerprint.v11")
        mixString(resortID)
        mixUInt(UInt64(nodes.count))
        for node in nodes.values.sorted(by: { $0.id < $1.id }) {
            mixString(node.id)
            mixDouble(node.coordinate.latitude)
            mixDouble(node.coordinate.longitude)
            mixDouble(node.elevation)
            mixString(node.kind.rawValue)
        }
        mixUInt(UInt64(edges.count))
        for e in edges.sorted(by: { $0.id < $1.id }) {
            mixString(e.id)
            mixString(e.sourceID)
            mixString(e.targetID)
            mixString(e.kind.rawValue)
            mixUInt(UInt64(e.geometry.count))
            for coordinate in e.geometry {
                mixDouble(coordinate.latitude)
                mixDouble(coordinate.longitude)
            }
            let a = e.attributes
            mixOptionalString(a.difficulty?.rawValue)
            mixDouble(a.lengthMeters)
            mixDouble(a.verticalDrop)
            mixDouble(a.averageGradient)
            mixDouble(a.maxGradient)
            mixOptionalDouble(a.aspect)
            mixDouble(a.aspectVariance)
            mixOptionalString(a.trailName)
            mixBool(a.hasMoguls)
            mixOptionalBool(a.isGroomed)
            mixBool(a.isGladed)
            mixOptionalString(a.liftType?.rawValue)
            mixOptionalInt(a.liftCapacity)
            mixOptionalDouble(a.rideTimeSeconds)
            mixOptionalDouble(a.waitTimeMinutes)
            mixOptionalDouble(a.weekdayWaitMinutes)
            mixOptionalDouble(a.weekendWaitMinutes)
            mixOptionalBool(a.chargesLiftWait)
            mixBool(a.isOpen)
            mixBool(a.isOfficiallyValidated)
            mixOptionalDouble(a.estimatedTrailWidthMeters)
            mixOptionalDouble(a.obstacleDensity)
            mixOptionalDouble(a.fallLineExposure)
            mixBool(a.nightGroomedFlag)
            mixOptionalInt(a.lastGroomedHoursAgo)
            mixOptionalString(a.estimatedSurfaceCondition)
            mixOptionalString(a.trailGroupId)
            mixOptionalDouble(a.midpointElevation)
        }
        let rawHex = String(checksum, radix: 16, uppercase: false)
        let hex16 = String(repeating: "0", count: max(0, 16 - rawHex.count))
            + String(rawHex.suffix(16))
        return "\(nodes.count):\(edges.count):\(hex16)"
    }

    func outgoing(from nodeID: String) -> [GraphEdge] {
        _adjacency[nodeID] ?? []
    }

    func incoming(to nodeID: String) -> [GraphEdge] {
        _incomingAdjacency[nodeID] ?? []
    }

    /// O(1) edge lookup by ID.
    func edge(byID id: String) -> GraphEdge? {
        _edgeIndex[id]
    }

    var runs: [GraphEdge] { edges.filter { $0.kind == .run } }
    var lifts: [GraphEdge] { edges.filter { $0.kind == .lift } }

    /// Returns all edges belonging to a trail group (consolidated trail).
    func edgesInGroup(_ groupId: String) -> [GraphEdge] {
        edges.filter { $0.attributes.trailGroupId == groupId }
    }

    /// Returns the first edge matching a trail group ID, or falls back to edge ID lookup.
    func representativeEdge(for id: String) -> GraphEdge? {
        // Try as trail group ID first
        if let first = edges.first(where: { $0.attributes.trailGroupId == id }) {
            return first
        }
        // Fall back to direct edge ID (for lifts or legacy)
        return _edgeIndex[id]
    }

    // MARK: - Node Display Name
    //
    // Three name systems used to live here — `displayName(for:)` was
    // graph-adjacency based and broke at junctions; `displayName(near:)`
    // wrapped it; `locationPickerAlignedTitle(for:)` was a partial fix
    // that only three callers used. All three were replaced by
    // `MountainNaming` (see PowderMeet/Models/MountainNaming.swift),
    // which exposes the same picker-aligned rules to every consumer
    // through one API.

    // MARK: - GPS Snapping

    /// Finds the nearest graph node to a GPS coordinate with graduated fallback.
    ///
    /// Tiered approach (aligned with `AGENTS.md`):
    /// 1. Absolute nearest node to GPS; if it has outgoing OR incoming edges → use it.
    /// 2. Else prefer a **connected** node within **100m** of that absolute nearest
    ///    (avoids dead-end POIs), choosing the one **closest to the user** (deterministic tie-break by id).
    /// 3. Else nearest connected node to the user within **500m** (tie-break by id).
    /// 4. Last resort: absolute nearest within **1000m** (solver may use escape logic).
    ///    Returns nil if no node is within range — the user is too far from the trail network.
    func nearestNode(to coordinate: CLLocationCoordinate2D) -> GraphNode? {
        let target = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        /// Prefer lower distance; on ~equal distance, prefer lexicographically smaller node id (deterministic).
        let distEps = 1e-3
        func isCloser(_ d1: Double, _ id1: String, than d2: Double, _ id2: String) -> Bool {
            if d1 < d2 - distEps { return true }
            if abs(d1 - d2) <= distEps { return id1 < id2 }
            return false
        }

        /// A node is "connected" if it has outgoing OR incoming edges (not isolated).
        func isConnected(_ nodeId: String) -> Bool {
            !outgoing(from: nodeId).isEmpty || !incoming(to: nodeId).isEmpty
        }

        func hasOpenEdge(_ nodeId: String) -> Bool {
            outgoing(from: nodeId).contains { $0.attributes.isOpen }
                || incoming(to: nodeId).contains { $0.attributes.isOpen }
        }

        // Geometry-first: if we're on/near an open corridor polyline, prefer that
        // edge's nearer endpoint over a spurious closer junction (wide bowls).
        if let snap = bestOpenNetworkSnap(to: coordinate),
           snap.distanceToPolylineMeters <= 36,
           hasOpenEdge(snap.closerNodeId),
           let geoNode = nodes[snap.closerNodeId] {
            let dGeo = target.distance(from: CLLocation(
                latitude: geoNode.coordinate.latitude,
                longitude: geoNode.coordinate.longitude
            ))
            var absProbe: GraphNode?
            var absDist = Double.infinity
            for node in nodes.values {
                let loc = CLLocation(latitude: node.coordinate.latitude, longitude: node.coordinate.longitude)
                let d = target.distance(from: loc)
                if absProbe.map({ isCloser(d, node.id, than: absDist, $0.id) }) ?? true {
                    absProbe = node
                    absDist = d
                }
            }
            if let abs = absProbe {
                let dAbs = target.distance(from: CLLocation(
                    latitude: abs.coordinate.latitude,
                    longitude: abs.coordinate.longitude
                ))
                if snap.distanceToPolylineMeters + 6 < dAbs - 5 || dGeo < dAbs + 12 {
                    return geoNode
                }
            } else {
                return geoNode
            }
        }

        var absNearest: GraphNode?
        var absDist = Double.infinity
        for node in nodes.values {
            let loc = CLLocation(latitude: node.coordinate.latitude, longitude: node.coordinate.longitude)
            let d = target.distance(from: loc)
            if absNearest.map({ isCloser(d, node.id, than: absDist, $0.id) }) ?? true {
                absNearest = node
                absDist = d
            }
        }
        // Out-of-resort guard: if even the absolute-nearest node is more than
        // 1000m away, the user is not at this resort. Return nil so the
        // caller falls through to "no live position" instead of pinning the
        // dot to whichever lift happens to be geographically closest from
        // hundreds of km away. Without this guard, opening any resort while
        // sitting at home placed the puck on a random-looking edge.
        let outOfResortMaxMeters = 1000.0
        guard let anchor = absNearest, absDist <= outOfResortMaxMeters else { return nil }

        // Tier 1: Absolute nearest has outgoing or incoming edges → use it
        if isConnected(anchor.id) {
            return anchor
        }

        let anchorLoc = CLLocation(latitude: anchor.coordinate.latitude, longitude: anchor.coordinate.longitude)
        let snapRadiusMeters = 100.0

        // Tier 2: Connected nodes within 100m of absolute nearest → closest to user
        var nearAnchorConnected: GraphNode?
        var nearAnchorUserDist = Double.infinity
        for node in nodes.values {
            guard isConnected(node.id) else { continue }
            let loc = CLLocation(latitude: node.coordinate.latitude, longitude: node.coordinate.longitude)
            guard anchorLoc.distance(from: loc) <= snapRadiusMeters else { continue }
            let dUser = target.distance(from: loc)
            if nearAnchorConnected.map({ isCloser(dUser, node.id, than: nearAnchorUserDist, $0.id) }) ?? true {
                nearAnchorConnected = node
                nearAnchorUserDist = dUser
            }
        }
        if let picked = nearAnchorConnected { return picked }

        // Tier 3: Nearest connected node to user within 500m
        let tier3MaxMeters = 500.0
        var globalConnected: GraphNode?
        var globalUserDist = Double.infinity
        for node in nodes.values {
            guard isConnected(node.id) else { continue }
            let loc = CLLocation(latitude: node.coordinate.latitude, longitude: node.coordinate.longitude)
            let dUser = target.distance(from: loc)
            guard dUser <= tier3MaxMeters else { continue }
            if globalConnected.map({ isCloser(dUser, node.id, than: globalUserDist, $0.id) }) ?? true {
                globalConnected = node
                globalUserDist = dUser
            }
        }
        if let picked = globalConnected { return picked }

        // Tier 4: Absolute nearest within 1000m (solver will handle via escape)
        let tier4MaxMeters = 1000.0
        if absDist <= tier4MaxMeters {
            return anchor
        }

        // Too far from any node — return nil
        return nil
    }

    /// GPS-aware directed route origin. A skier between nodes keeps the
    /// current edge as a required approach, with a quantized fraction so the
    /// solver charges only the unskiied remainder. Near the target or off a
    /// mapped corridor, this degrades to an ordinary node origin.
    func routingOrigin(
        to coordinate: CLLocationCoordinate2D,
        travelCourseDegrees: CLLocationDirection? = nil,
        altitudeMeters: Double? = nil,
        verticalAccuracyMeters: Double? = nil,
        maximumSnapDistanceMeters: Double = 65,
        positionUncertaintyMeters: Double = 0
    ) -> RoutingOrigin? {
        let corridorMeters = max(0, maximumSnapDistanceMeters)
        // Do not discard the final part of a directed run merely because its
        // target junction is nearby. Thirty-five metres absorbs ordinary GPS
        // jitter while keeping another ~minute of cautious skiing on-route.
        let targetArrivalMeters = 35.0
        guard let snap = bestOpenNetworkSnap(
            to: coordinate,
            travelCourseDegrees: travelCourseDegrees,
            altitudeMeters: altitudeMeters,
            verticalAccuracyMeters: verticalAccuracyMeters
        ),
              snap.distanceToPolylineMeters <= corridorMeters,
              nodes[snap.edge.sourceID] != nil,
              let target = nodes[snap.edge.targetID] else {
            // Strict live routing may fall back to an endpoint only when that
            // endpoint is itself close and incident to an open edge. The
            // broader `nearestNode` API intentionally remains useful for map
            // labels and old wire formats, but its 1 km graduated fallback is
            // not a defensible navigation origin.
            let fix = CLLocation(
                latitude: coordinate.latitude,
                longitude: coordinate.longitude
            )
            let epsilon = 0.001
            let nearest = nodes.values
                .filter { node in
                    outgoing(from: node.id).contains { $0.attributes.isOpen }
                        || incoming(to: node.id).contains { $0.attributes.isOpen }
                }
                .compactMap { node -> (GraphNode, Double)? in
                    let distance = fix.distance(from: CLLocation(
                        latitude: node.coordinate.latitude,
                        longitude: node.coordinate.longitude
                    ))
                    guard distance <= corridorMeters else { return nil }
                    return (node, distance)
                }
                .sorted { lhs, rhs in
                    if abs(lhs.1 - rhs.1) > epsilon { return lhs.1 < rhs.1 }
                    return lhs.0.id < rhs.0.id
                }
                .first?.0
            return nearest.map {
                .node(
                    $0.id,
                    positionUncertaintyMeters: positionUncertaintyMeters
                )
            }
        }

        let fix = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        let targetLocation = CLLocation(
            latitude: target.coordinate.latitude,
            longitude: target.coordinate.longitude
        )
        if fix.distance(from: targetLocation) <= targetArrivalMeters {
            return .node(
                target.id,
                positionUncertaintyMeters: positionUncertaintyMeters
            )
        }
        return .interior(
            edge: snap.edge,
            fractionAlongEdge: snap.fractionAlongEdge,
            positionUncertaintyMeters: positionUncertaintyMeters
        )
    }

    /// Compatibility node stamp for wire formats that still carry a graph
    /// node rather than a fractional interior origin.
    func routingStartNode(to coordinate: CLLocationCoordinate2D) -> GraphNode? {
        guard let origin = routingOrigin(to: coordinate) else { return nil }
        return nodes[origin.startNodeID]
    }

    /// Snap that **sticks** to `previousNodeId` while GPS dances between two
    /// nearby junctions (e.g. Stratto Glades vs Adagio). Plain `nearestNode`
    /// is deterministic but tiny fix shifts can hop trails; tab switches re-run
    /// body and looked like the app "changed" your trail.
    ///
    /// - Switch to a new nearest node only if it is `switchCloserByM` meters
    ///   closer than the previous snap, or the user moved `clearPullM`+ away
    ///   from the previous node.
    func nearestNodeSticky(
        to coordinate: CLLocationCoordinate2D,
        previousNodeId: String?,
        clearPullMeters: Double = 55,
        switchCloserByMeters: Double = 14
    ) -> GraphNode? {
        guard let candidate = nearestNode(to: coordinate) else { return nil }
        guard let prevId = previousNodeId, let prev = nodes[prevId] else { return candidate }
        let target = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        let prevLoc = CLLocation(latitude: prev.coordinate.latitude, longitude: prev.coordinate.longitude)
        let candLoc = CLLocation(latitude: candidate.coordinate.latitude, longitude: candidate.coordinate.longitude)
        let dPrev = target.distance(from: prevLoc)
        let dCand = target.distance(from: candLoc)
        if dPrev >= clearPullMeters { return candidate }
        if dCand < dPrev - switchCloserByMeters { return candidate }
        return prev
    }

    // MARK: - Escape Node

    /// Given a node with no usable outgoing edges, finds the nearest node
    /// that a skier CAN actually use (accounts for skill gating and closures).
    /// Returns `(nodeID, walkTimeSeconds)` or nil if no escape exists.
    func findEscapeNode(
        from nodeID: String,
        profile: UserProfile,
        context: TraversalContext
    ) -> (nodeID: String, walkTime: Double)? {
        guard let startNode = nodes[nodeID] else { return nil }
        let startLoc = CLLocation(
            latitude: startNode.coordinate.latitude,
            longitude: startNode.coordinate.longitude
        )

        var bestDist = Double.infinity
        var bestId: String?

        for node in nodes.values {
            guard node.id != nodeID else { continue }

            // Must have outgoing edges the skier can actually traverse
            let usable = outgoing(from: node.id).contains { edge in
                profile.traverseTime(for: edge, context: context) != nil
            }
            guard usable else { continue }

            let loc = CLLocation(latitude: node.coordinate.latitude, longitude: node.coordinate.longitude)
            let dist = startLoc.distance(from: loc)
            if dist < bestDist && dist < 2000 {
                bestDist = dist
                bestId = node.id
            }
        }

        guard let escapeId = bestId, let escapeNode = nodes[escapeId] else { return nil }

        // Walk time: ~1.5 m/s walking speed + 6s per meter of uphill gain
        let uphillGain = max(0, escapeNode.elevation - startNode.elevation)
        let walkTime = bestDist / 1.5 + uphillGain * 6.0
        return (escapeId, walkTime)
    }

    // MARK: - Diagnostics

    /// Counts nodes with zero outgoing open edges (directed sinks).
    func directedSinkCount() -> Int {
        nodes.keys.filter { outgoing(from: $0).isEmpty }.count
    }
}

// Explicit nonisolated Codable so encoding/decoding inside
// actors (MountainRepository) doesn't trigger isolation warnings.
extension MountainGraph: Codable {
    private enum CodingKeys: String, CodingKey {
        case resortID, nodes, edges
    }

    nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        resortID = try container.decode(String.self, forKey: .resortID)
        nodes = try container.decode([String: GraphNode].self, forKey: .nodes)
        edges = try container.decode([GraphEdge].self, forKey: .edges)
        // Rebuild precomputed indices after deserialization
        rebuildIndices()
    }

    nonisolated func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(resortID, forKey: .resortID)
        try container.encode(nodes, forKey: .nodes)
        try container.encode(edges, forKey: .edges)
        // _adjacency and _edgeIndex are derived — not encoded
    }
}

// MARK: - Enrichment Helpers

extension EdgeAttributes {
    /// Returns a copy with enrichment-mutable fields optionally overridden.
    /// Pass nil (or omit) any parameter to preserve the existing value.
    /// Immutable build-time fields (lengths, gradients, elevations, trailGroupId) are always preserved.
    nonisolated func enriched(
        difficulty: RunDifficulty? = nil,
        trailName: String? = nil,
        hasMoguls: Bool? = nil,
        isGroomed: Bool? = nil,
        isGladed: Bool? = nil,
        liftType: LiftType? = nil,
        liftCapacity: Int? = nil,
        waitTimeMinutes: Double? = nil,
        isOpen: Bool? = nil,
        isOfficiallyValidated: Bool? = nil
    ) -> EdgeAttributes {
        EdgeAttributes(
            difficulty: difficulty ?? self.difficulty,
            lengthMeters: self.lengthMeters,
            verticalDrop: self.verticalDrop,
            averageGradient: self.averageGradient,
            maxGradient: self.maxGradient,
            aspect: self.aspect,
            aspectVariance: self.aspectVariance,
            trailName: trailName ?? self.trailName,
            hasMoguls: hasMoguls ?? self.hasMoguls,
            isGroomed: isGroomed ?? self.isGroomed,
            isGladed: isGladed ?? self.isGladed,
            liftType: liftType ?? self.liftType,
            liftCapacity: liftCapacity ?? self.liftCapacity,
            rideTimeSeconds: self.rideTimeSeconds,
            waitTimeMinutes: waitTimeMinutes ?? self.waitTimeMinutes,
            weekdayWaitMinutes: self.weekdayWaitMinutes,
            weekendWaitMinutes: self.weekendWaitMinutes,
            chargesLiftWait: self.chargesLiftWait,
            isOpen: isOpen ?? self.isOpen,
            isOfficiallyValidated: isOfficiallyValidated ?? self.isOfficiallyValidated,
            trailGroupId: self.trailGroupId,
            midpointElevation: self.midpointElevation,
            estimatedTrailWidthMeters: self.estimatedTrailWidthMeters,
            obstacleDensity: self.obstacleDensity,
            fallLineExposure: self.fallLineExposure,
            nightGroomedFlag: self.nightGroomedFlag,
            lastGroomedHoursAgo: self.lastGroomedHoursAgo,
            estimatedSurfaceCondition: self.estimatedSurfaceCondition
        )
    }
}

extension GraphEdge {
    /// Returns a copy of this edge with its attributes replaced.
    /// Preserves identity (id, sourceID, targetID, kind, geometry).
    nonisolated func withAttributes(_ attributes: EdgeAttributes) -> GraphEdge {
        GraphEdge(
            id: id, sourceID: sourceID, targetID: targetID,
            kind: kind, geometry: geometry, attributes: attributes
        )
    }
}
