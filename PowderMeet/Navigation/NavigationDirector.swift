//
//  NavigationDirector.swift
//  PowderMeet
//
//  Orchestrates cross-cutting navigation UX: deviation handling, camera
//  refit, recalculate cooldown, ETA broadcast. One place to read the full
//  deviation-response UX instead of scattered callbacks.
//

import Foundation
import CoreLocation
import UIKit
import Observation

/// Camera operations the director needs; an abstraction so the MountainMap
/// coordinator can be swapped for a test double.
@MainActor protocol CameraController: AnyObject {
    /// Optional `bearing` keeps north-up from fighting terrain that reads better at an angle.
    func frame(
        coordinates: [CLLocationCoordinate2D],
        padding: UIEdgeInsets,
        duration: TimeInterval,
        bearing: CLLocationDirection?
    )
}

extension CameraController {
    /// Default: north-up framing.
    func frame(coordinates: [CLLocationCoordinate2D], padding: UIEdgeInsets, duration: TimeInterval) {
        frame(coordinates: coordinates, padding: padding, duration: duration, bearing: nil)
    }
}

@MainActor @Observable
final class NavigationDirector {
    private let tracker: RouteProgressTracker
    private let graph: MountainGraph
    private let camera: CameraController?
    private let haptics: HapticService

    // Deviation UX state observed by views.
    var flashAmber: Bool = false

    /// Last time we refit the camera in response to a deviation. RouteProgressTracker's
    /// sticky debounce still lets `.deviated` fire more than once (on fresh
    /// re-deviation after a brief recovery), so gate the camera here too —
    /// without this, two deviation events in quick succession snap the
    /// camera twice in a row and the map feels like it's fighting the user.
    private var lastDeviationRefitAt: Date?
    private let deviationRefitCooldown: TimeInterval = 5

    /// Held so rapid-fire deviations don't stack flash timers.
    private var flashResetTask: Task<Void, Never>?

    init(
        tracker: RouteProgressTracker,
        graph: MountainGraph,
        camera: CameraController? = nil,
        haptics: HapticService? = nil
    ) {
        self.tracker = tracker
        self.graph = graph
        self.camera = camera
        self.haptics = haptics ?? HapticService.shared
    }

    // MARK: - Event Handling

    func handle(
        _ event: RouteEvent,
        currentLocation: CLLocationCoordinate2D,
        allowRouteFraming: Bool = true
    ) {
        switch event {
        case .deviated(let currentNodeId):
            onDeviated(currentNodeId: currentNodeId, userLocation: currentLocation,
                       allowRouteFraming: allowRouteFraming)
        case .advanced, .skippedAhead, .completed:
            // Clear deviation UI on any forward progress.
            lastDeviationRefitAt = nil
            flashAmber = false
            flashResetTask?.cancel(); flashResetTask = nil
        }
    }

    private func onDeviated(
        currentNodeId: String, userLocation: CLLocationCoordinate2D, allowRouteFraming: Bool
    ) {
        haptics.play(.warning)
        flashAmber = true
        flashResetTask?.cancel()
        flashResetTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            self?.flashAmber = false
        }

        // Camera refit: frame user + nearest point on the real route
        // polyline. Long ski runs can have junction nodes hundreds of metres
        // apart, so node-only framing often pointed past the actual recovery
        // point. Gated by
        // `deviationRefitCooldown` so rapid re-fires don't dogpile the
        // camera.
        let now = Date()
        let canRefit = lastDeviationRefitAt.map { now.timeIntervalSince($0) >= deviationRefitCooldown } ?? true
        if allowRouteFraming, canRefit,
           let nearCoord = nearestOnRouteCoordinate(to: userLocation) {
            let refitBearing = Self.bearingForDeviationFraming(
                from: userLocation,
                toward: nearCoord
            )
            camera?.frame(
                coordinates: [userLocation, nearCoord],
                padding: UIEdgeInsets(top: 120, left: 60, bottom: 220, right: 60),
                duration: 0.6,
                bearing: refitBearing
            )
            lastDeviationRefitAt = now
        }

    }

    /// Bearing to frame user → back-on-route; nil when too close to avoid noisy orientation.
    private static func bearingForDeviationFraming(
        from user: CLLocationCoordinate2D,
        toward target: CLLocationCoordinate2D
    ) -> CLLocationDirection? {
        let a = CLLocation(latitude: user.latitude, longitude: user.longitude)
        let t = CLLocation(latitude: target.latitude, longitude: target.longitude)
        guard a.distance(from: t) >= 4 else { return nil }
        let rad = FriendChipLayoutEngine.bearingRadians(
            fromLat: user.latitude, fromLon: user.longitude,
            toLat: target.latitude, toLon: target.longitude
        )
        return (rad * 180 / .pi + 360).truncatingRemainder(dividingBy: 360)
    }

    // MARK: - Nearest On-Route Point

    private func nearestOnRouteCoordinate(
        to coord: CLLocationCoordinate2D
    ) -> CLLocationCoordinate2D? {
        if let routeLocation = RouteGeometryLocator.nearest(
            to: coord,
            in: tracker.path,
            startingAt: tracker.currentEdgeIndex
        ) {
            return routeLocation.closestCoordinate
        }

        // Legacy/degenerate edges may lack usable geometry. Preserve a node
        // fallback so recovery framing still works for an old cached route.
        let remaining = tracker.path[tracker.currentEdgeIndex...]
        guard !remaining.isEmpty else { return nil }
        let target = CLLocation(latitude: coord.latitude, longitude: coord.longitude)
        var bestCoordinate: CLLocationCoordinate2D?
        var bestDist = Double.infinity
        for edge in remaining {
            for nodeId in [edge.sourceID, edge.targetID] {
                guard let node = graph.nodes[nodeId] else { continue }
                let loc = CLLocation(latitude: node.coordinate.latitude, longitude: node.coordinate.longitude)
                let d = target.distance(from: loc)
                if d < bestDist {
                    bestDist = d
                    bestCoordinate = node.coordinate
                }
            }
        }
        return bestCoordinate
    }
}
