import Foundation
import MeetSolver
import MountainCore

public enum SceneBuilder {
    public static func build(_ input: RenderInput) -> RenderModel {
        build(input, reusing: nil)
    }

    /// As `build(_:)`, but takes the static geometry from `previous` when it was
    /// built for the same bundle, so geometry is produced once per bundle.
    public static func build(_ input: RenderInput, reusing previous: RenderModel?) -> RenderModel {
        let bundle = input.bundle
        let geometry = previous?.geometry.bundleID == bundle.id && previous?.geometry.skied == input.skied
            ? previous!.geometry : Self.geometry(for: bundle, skied: input.skied)

        // Closure truth, edge by edge, from the status the solver was given.
        let closures = Closures(input.status, at: input.time.now)
        var closedEdges: Set<EdgeID> = []
        var edgeStates: [String: FeatureState] = [:]
        for edge in bundle.graph.edges where closures.closed.contains(edge.group) {
            closedEdges.insert(edge.id)
            edgeStates[edge.id.rawValue] = [StateKey.closed: .bool(true)]
        }

        var availability: [GroupID: TerrainAvailability] = [:]
        var trailStates: [String: FeatureState] = [:]
        var liftStates: [String: FeatureState] = [:]
        for group in bundle.groups {
            let members = group.edgeIDs.filter { bundle.graph.edge($0) != nil }
            let open = members.filter { !closedEdges.contains($0) }.count
            let state = TerrainAvailability(open: open, total: members.count)
            if state != .open { availability[group.id] = state }
            let selected = input.selection == group.id

            switch group.kind {
            case .trail:
                let groomed = closures.groomed.contains(group.id)
                guard state != .open || groomed || selected else { continue }
                trailStates[group.id.rawValue] = [
                    StateKey.availability: .number(state.code),
                    StateKey.groomed: .bool(groomed),
                    StateKey.selected: .bool(selected),
                ]
            case .lift:
                let status: Double = state == .closed ? 2 : closures.hold.contains(group.id) ? 1 : 0
                guard status != 0 || selected else { continue }
                liftStates[group.id.rawValue] = [
                    StateKey.status: .number(status), StateKey.selected: .bool(selected),
                ]
            }
        }

        var meetingStates: [String: FeatureState] = [:]
        if let meeting = input.meeting, bundle.rendezvous(meeting) != nil {
            meetingStates[meeting.rawValue] = [StateKey.meeting: .bool(true)]
        }

        // Small dynamic sources.
        var remaining: [SceneRoute.Slot: RemainingRoute] = [:]
        for route in input.routes {
            remaining[route.slot] = RemainingRoute.remaining(
                of: route.route, legIndex: route.legIndex, fractionAlongLeg: route.fractionAlongLeg)
        }
        func routeFeatures(_ slot: SceneRoute.Slot, id: String, color: String) -> [SceneFeature] {
            guard let slice = remaining[slot] else { return [] }
            let line = slice.coordinates(in: bundle)
            guard line.count >= 2 else { return [] }
            return [SceneFeature(id: id, shape: .line(line), properties: [
                "color": .string(color), "edgeCount": .number(Double(slice.edgeIDs.count)),
            ])]
        }
        let overlays: [SceneSourceID: [SceneFeature]] = [
            .routeA: routeFeatures(.a, id: "route-a", color: MapPalette.routeA),
            .routeB: routeFeatures(.b, id: "route-b", color: MapPalette.routeB),
            .friends: friendFeatures(input.friends, now: input.time.now),
            .user: input.user.map { [SceneFeature(id: "user", shape: .point($0))] } ?? [],
            .selection: selectionFeatures(input.selection, in: geometry),
            .breadcrumbs: breadcrumbFeatures(input.breadcrumbs),
            .ghosts: ghostFeatures(input.ghosts),
        ]

        let sun = Solar.position(
            at: input.time.display, latitude: bundle.center.lat, longitude: bundle.center.lon)

        return RenderModel(
            geometry: geometry,
            featureStates: [
                .trails: trailStates, .edges: edgeStates, .lifts: liftStates,
                .rendezvous: meetingStates, .beams: meetingStates,
            ],
            overlays: overlays,
            environment: SceneEnvironment(
                solarAltitudeDeg: sun.altitudeDeg.rounded(), solarAzimuthDeg: sun.azimuthDeg.rounded(),
                theme: input.theme),
            frame: SceneFrame(bundle: bundle, camera: input.camera),
            availability: availability,
            groomed: closures.groomed,
            statusFreshness: closures.freshness,
            routeA: remaining[.a]?.edgeIDs ?? [],
            routeB: remaining[.b]?.edgeIDs ?? [],
            routePreview: remaining.isEmpty ? [] : RoutePreviewFraming.coordinates(
                routes: [remaining[.a]?.edgeIDs ?? [], remaining[.b]?.edgeIDs ?? []],
                meeting: input.meeting, in: bundle)
        )
    }

    /// The tapped group's own line, copied so the map can draw it brighter on top.
    /// It is a feature of its own rather than feature-state on the static source:
    /// state on those large sources did not repaint reliably on device.
    private static func selectionFeatures(
        _ selection: GroupID?, in geometry: SceneGeometry
    ) -> [SceneFeature] {
        guard let selection else { return [] }
        for source in [SceneSourceID.trails, .lifts] {
            if let feature = geometry.source(source)?.features.first(where: { $0.id == selection.rawValue }) {
                return [SceneFeature(id: "selection", shape: feature.shape, properties: feature.properties)]
            }
        }
        return []
    }

    /// Status as the map applies it. The rules are the solver's (`CostModel`'s
    /// `EffectiveStatus`): fresh status is taken whole; stale status keeps only its
    /// closures; anything older says nothing.
    struct Closures {
        let freshness: StatusFreshness
        let closed: GroupSet
        let hold: Set<GroupID>
        let groomed: Set<GroupID>

        struct GroupSet {
            var ids: Set<GroupID>
            func contains(_ group: GroupID?) -> Bool { group.map(ids.contains) ?? false }
        }

        init(_ status: ResortStatus?, at now: Date) {
            freshness = .of(status, at: now)
            let groups = freshness == .unavailable ? [:] : status?.groups ?? [:]
            closed = GroupSet(ids: Set(groups.filter { $0.value == .closed }.keys))
            if freshness == .fresh, let status {
                hold = Set(groups.filter { $0.value == .hold }.keys)
                groomed = Set(status.groomed)
            } else {
                hold = []
                groomed = []
            }
        }
    }

    /// One line per friend, thinned to `maximumTrailPoints` so a whole day
    /// rewrites a small source on every scrub frame.
    static func breadcrumbFeatures(_ trails: [BreadcrumbTrail]) -> [SceneFeature] {
        trails.sorted { $0.id.uuidString < $1.id.uuidString }.compactMap { trail in
            let line = thinned(trail.coordinates, to: maximumTrailPoints)
            guard line.count >= 2 else { return nil }
            return SceneFeature(
                id: "crumbs-\(trail.id.uuidString)", shape: .line(line),
                properties: ["color": .string(MapPalette.friend)])
        }
    }

    public static let maximumTrailPoints = 400

    /// Every nth point, keeping the last (where the friend is at the instant).
    static func thinned(_ points: [Coordinate], to limit: Int) -> [Coordinate] {
        guard points.count > limit, limit > 1 else { return points }
        let stride = Int((Double(points.count) / Double(limit - 1)).rounded(.up))
        var kept = Swift.stride(from: 0, to: points.count - 1, by: stride).map { points[$0] }
        kept.append(points[points.count - 1])
        return kept
    }

    /// Each ghost as its dots (`kind` "dot") and a head carrying the label
    /// (`kind` "head"), in the skier's route colour.
    static func ghostFeatures(_ ghosts: [GhostMarker]) -> [SceneFeature] {
        ghosts.sorted { $0.id.uuidString < $1.id.uuidString }.flatMap { ghost -> [SceneFeature] in
            let color = SceneValue.string(ghost.isSelf ? MapPalette.routeA : MapPalette.routeB)
            let key = ghost.id.uuidString
            var features = ghost.trail.dropLast().enumerated().map { index, point in
                SceneFeature(
                    id: "ghost-\(key)-\(index)", shape: .point(point),
                    properties: ["kind": .string("dot"), "color": color])
            }
            features.append(SceneFeature(
                id: "ghost-\(key)", shape: .point(ghost.coordinate),
                properties: ["kind": .string("head"), "color": color, "label": .string(ghost.label)]))
            return features
        }
    }

    static func friendFeatures(_ friends: [FriendMarker], now: Date) -> [SceneFeature] {
        let shown = friends
            .filter { FriendSignal.isVisibleOnMap(lastSeen: $0.capturedAt, now: now) }
            .sorted { $0.id.uuidString < $1.id.uuidString }
        let drawnAt = FriendSpread.positions(shown.map { ($0.id, $0.coordinate) })
        return shown
            .map { friend in
                let words = friend.displayName.split(separator: " ")
                let initials = words.prefix(2).map { $0.prefix(1).uppercased() }.joined()
                let firstName = words.first.map { $0.uppercased() } ?? initials
                let signal = FriendSignal.classify(lastSeen: friend.capturedAt, now: now)
                // A halo is drawn only for a fix loose enough to matter.
                let accuracy = friend.accuracyM.map { $0 >= 20 ? min(500, $0) : 0 } ?? 0
                return SceneFeature(
                    id: friend.id.uuidString, shape: .point(drawnAt[friend.id] ?? friend.coordinate),
                    properties: [
                        "userId": .string(friend.id.uuidString),
                        "displayName": .string(friend.displayName),
                        "initials": .string(initials.isEmpty ? "?" : initials),
                        "firstName": .string(firstName),
                        "signalState": .string(signal.name),
                        "signalLabel": .string(signal.label),
                        "diskOpacity": .number(signal.diskOpacity),
                        "accuracyMeters": .number(accuracy.isFinite ? accuracy : 0),
                        // Only a live fix says where they are now.
                        "place": .string(signal == .live ? friend.place ?? "" : ""),
                    ])
            }
    }
}

/// Friends standing together would draw one marker on top of another. Markers
/// closer than `clusterM` are drawn evenly round a small ring about their middle,
/// far enough apart that two 22 pt discs do not touch at the zoom a meet is
/// planned at (about 3 m a point at zoom 15). Display only: the fix itself is
/// unchanged everywhere else.
public enum FriendSpread {
    public static let clusterM = 70.0
    /// Distance between neighbours on the ring.
    public static let spacingM = 70.0

    public static func positions(_ friends: [(id: UUID, coordinate: Coordinate)]) -> [UUID: Coordinate] {
        var result: [UUID: Coordinate] = [:]
        var assigned = Set<UUID>()
        for (index, friend) in friends.enumerated() where !assigned.contains(friend.id) {
            // Greedy, in the given (stable) order: everyone near this friend.
            var group = [friend]
            for other in friends[(index + 1)...] where !assigned.contains(other.id) {
                if group.contains(where: { Geo.haversineM($0.coordinate, other.coordinate) < clusterM }) {
                    group.append(other)
                }
            }
            for member in group { assigned.insert(member.id) }
            guard group.count > 1 else {
                result[friend.id] = friend.coordinate
                continue
            }
            let lat = group.map(\.coordinate.lat).reduce(0, +) / Double(group.count)
            let lon = group.map(\.coordinate.lon).reduce(0, +) / Double(group.count)
            let radiusM = spacingM / (2 * sin(.pi / Double(group.count)))
            let latPerM = 1.0 / 111_000.0
            let lonPerM = 1.0 / (111_000.0 * max(cos(lat * .pi / 180), 0.0001))
            for (slot, member) in group.enumerated() {
                let angle = Double(slot) / Double(group.count) * 2 * .pi
                result[member.id] = Coordinate(
                    lon: lon + radiusM * sin(angle) * lonPerM, lat: lat + radiusM * cos(angle) * latPerM)
            }
        }
        return result
    }
}
