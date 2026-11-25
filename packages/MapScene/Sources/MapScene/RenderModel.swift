import Foundation
import MountainCore

/// Whether a named run or lift can be used, across every member edge. One open
/// segment never makes a partly closed run read as open (invariant I-15).
public enum TerrainAvailability: Sendable, Hashable {
    case open
    case partiallyOpen(open: Int, total: Int)
    case closed

    public init(open: Int, total: Int) {
        if total == 0 || open >= total {
            self = .open
        } else if open <= 0 {
            self = .closed
        } else {
            self = .partiallyOpen(open: open, total: total)
        }
    }

    /// The `StateKey.availability` value.
    public var code: Double {
        switch self {
        case .open: 0
        case .partiallyOpen: 1
        case .closed: 2
        }
    }

    public var label: String {
        switch self {
        case .open: "OPEN"
        case .partiallyOpen(let open, let total): "PARTIAL · \(open)/\(total)"
        case .closed: "CLOSED"
        }
    }
}

/// The static half of a scene: every source that depends on the bundle alone.
/// Built once per bundle (and again when the skier's run counts change) and carried
/// from model to model unchanged, so equality is the bundle's identity and those counts.
public struct SceneGeometry: Sendable, Equatable {
    public let bundleID: BundleID
    /// In `SceneSourceID.staticSources` order.
    public let sources: [SceneSource]
    /// The skier's run counts the run colours were worked out from.
    public let skied: [String: Int]

    public init(bundleID: BundleID, skied: [String: Int] = [:], sources: [SceneSource]) {
        self.bundleID = bundleID
        self.sources = sources
        self.skied = skied
    }

    public func source(_ id: SceneSourceID) -> SceneSource? { sources.first { $0.id == id } }

    public static func == (lhs: SceneGeometry, rhs: SceneGeometry) -> Bool {
        lhs.bundleID == rhs.bundleID && lhs.skied == rhs.skied
    }
}

/// Light, sky and theme: the only scene inputs that are not features.
public struct SceneEnvironment: Sendable, Hashable {
    /// Whole degrees, so a scrub only produces a change when the light moves.
    public var solarAltitudeDeg: Double
    public var solarAzimuthDeg: Double
    public var theme: MapTheme

    public init(solarAltitudeDeg: Double, solarAzimuthDeg: Double, theme: MapTheme) {
        self.solarAltitudeDeg = solarAltitudeDeg
        self.solarAzimuthDeg = solarAzimuthDeg
        self.theme = theme
    }

    /// 0 at night to 1 in full day, from the sun's altitude: the one curve
    /// the light, the sky and the hillshade follow.
    public var daylight: Double { max(0, min(1, (solarAltitudeDeg + 4) / 34)) }

    /// 1 with the sun on the horizon, falling to 0 ten degrees either side:
    /// how much dawn or dusk colour the sky takes.
    public var twilight: Double { max(0, 1 - abs(solarAltitudeDeg) / 10) }
}

/// One complete description of the map. Two models are compared by
/// `SceneDiffer`; nothing here is Mapbox-specific.
public struct RenderModel: Sendable {
    public let geometry: SceneGeometry
    /// Per static source, per feature id: the state of every feature that differs
    /// from its source's `defaultState`. Sparse on purpose.
    public let featureStates: [SceneSourceID: [String: FeatureState]]
    /// Every dynamic source, always present, possibly empty.
    public let overlays: [SceneSourceID: [SceneFeature]]
    public let environment: SceneEnvironment
    public let frame: SceneFrame
    /// Groups that are not fully open. Read `availability(of:)`.
    public let availability: [GroupID: TerrainAvailability]
    public let groomed: Set<GroupID>
    public let statusFreshness: StatusFreshness
    /// Remaining edges per route slot, for the reveal policy.
    public let routeA: [EdgeID]
    public let routeB: [EdgeID]
    /// What an explicit "show route on map" frames (`RoutePreviewFraming`): the
    /// remaining routes and the meeting point, confined to the resort.
    public let routePreview: [Coordinate]

    public var bundleID: BundleID { geometry.bundleID }

    /// What the trail card shows, from the same status the solver was given.
    public func availability(of group: GroupID) -> TerrainAvailability {
        availability[group] ?? .open
    }
}

/// What changed between two models. A status, grooming or selection change is
/// `states` only; `geometry` is non-nil only when the bundle itself changed.
public struct SceneDiff: Sendable, Equatable {
    public struct StateChange: Sendable, Hashable {
        public var source: SceneSourceID
        public var featureID: String
        /// The feature's complete new state (defaults included), ready to set.
        public var state: FeatureState
    }

    public struct OverlayChange: Sendable, Hashable {
        public var source: SceneSourceID
        public var features: [SceneFeature]
    }

    /// New static sources. The receiver replaces all of them and clears every
    /// feature-state before applying `states`.
    public var geometry: SceneGeometry?
    public var states: [StateChange]
    public var overlays: [OverlayChange]
    public var environment: SceneEnvironment?
    /// Set with new geometry, or when the catalog camera changed.
    public var frame: SceneFrame?
    /// A new plan appeared (not mere progress along the old one).
    public var replayRouteReveal: Bool

    public var hasGeometry: Bool { geometry != nil }

    public var isEmpty: Bool {
        geometry == nil && states.isEmpty && overlays.isEmpty && environment == nil
            && frame == nil && !replayRouteReveal
    }
}

public enum SceneDiffer {
    /// `old == nil` is the first frame: everything in `new` is a change.
    public static func diff(old: RenderModel?, new: RenderModel) -> SceneDiff {
        let sameBundle = old?.geometry == new.geometry
        let previous = sameBundle ? old : nil

        var states: [SceneDiff.StateChange] = []
        for source in SceneSourceID.staticSources {
            let before = previous?.featureStates[source] ?? [:]
            let after = new.featureStates[source] ?? [:]
            guard before != after else { continue }
            let defaults = source.defaultState
            for id in Set(before.keys).union(after.keys).sorted() where before[id] != after[id] {
                states.append(.init(source: source, featureID: id, state: after[id] ?? defaults))
            }
        }

        var overlays: [SceneDiff.OverlayChange] = []
        for source in SceneSourceID.dynamicSources {
            let after = new.overlays[source] ?? []
            // A dynamic source left over from another bundle is always rewritten.
            if previous == nil || previous?.overlays[source] != after {
                overlays.append(.init(source: source, features: after))
            }
        }

        return SceneDiff(
            geometry: sameBundle ? nil : new.geometry,
            states: states,
            overlays: overlays,
            environment: old?.environment == new.environment ? nil : new.environment,
            frame: (!sameBundle || old?.frame != new.frame) ? new.frame : nil,
            replayRouteReveal: MapRouteAnimationPolicy.shouldReplay(
                previousA: previous?.routeA ?? [], previousB: previous?.routeB ?? [],
                nextA: new.routeA, nextB: new.routeB, forced: false
            )
        )
    }
}
