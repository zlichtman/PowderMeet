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
    var showRecalculateButton: Bool = false
    var flashAmber: Bool = false

    // Reroute gating.
    private var lastRecalculateAt: Date?
    private var positionAtLastRecalculate: CLLocationCoordinate2D?
    private let recalculateCooldown: TimeInterval = 30
    private let recalculateMinDisplacementMeters: Double = 50

    private var deviationStart: Date?
    private let recalculateButtonDelay: TimeInterval = 8

    /// Last time we refit the camera in response to a deviation. RouteProgressTracker's
    /// sticky debounce still lets `.deviated` fire more than once (on fresh
    /// re-deviation after a brief recovery), so gate the camera here too —
    /// without this, two deviation events in quick succession snap the
    /// camera twice in a row and the map feels like it's fighting the user.
    private var lastDeviationRefitAt: Date?
    private let deviationRefitCooldown: TimeInterval = 5

    /// Held so rapid-fire deviations don't stack timers. A fresh deviation
    /// cancels the previous flash + recalculate-button sleeps before
    /// scheduling new ones. Without this, a user zig-zagging briefly
    /// off-route could flip `flashAmber` back on from a stale sleep, or
    /// surface the recalculate button after they'd already snapped back
    /// on-route for more than 8 seconds.
    private var flashResetTask: Task<Void, Never>?
    private var recalculateRevealTask: Task<Void, Never>?

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

    func handle(_ event: RouteEvent, currentLocation: CLLocationCoordinate2D) {
        switch event {
        case .deviated(let currentNodeId):
            onDeviated(currentNodeId: currentNodeId, userLocation: currentLocation)
        case .advanced, .skippedAhead, .completed:
            // Clear deviation UI on any forward progress.
            deviationStart = nil
            lastDeviationRefitAt = nil
            showRecalculateButton = false
            flashAmber = false
            flashResetTask?.cancel(); flashResetTask = nil
            recalculateRevealTask?.cancel(); recalculateRevealTask = nil
        }
    }

    private func onDeviated(currentNodeId: String, userLocation: CLLocationCoordinate2D) {
        haptics.play(.warning)
        flashAmber = true
        flashResetTask?.cancel()
        flashResetTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            self?.flashAmber = false
        }

        // Camera refit: frame user + nearest on-route node. Gated by
        // `deviationRefitCooldown` so rapid re-fires don't dogpile the
        // camera.
        let now = Date()
        let canRefit = lastDeviationRefitAt.map { now.timeIntervalSince($0) >= deviationRefitCooldown } ?? true
        if canRefit,
           let nearest = nearestOnRouteNode(to: userLocation),
           let nearestNode = graph.nodes[nearest] {
            let nearCoord = nearestNode.coordinate
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

        // Recalculate button appears after 8s of persistent deviation.
        deviationStart = Date()
        recalculateRevealTask?.cancel()
        recalculateRevealTask = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: .seconds(self.recalculateButtonDelay))
            guard !Task.isCancelled else { return }
            guard self.tracker.isOffRoute else { return }
            self.showRecalculateButton = true
        }
    }

    // MARK: - Recalculate Gating

    /// Caller invokes on "RECALCULATE" tap. Returns true only when the
    /// reroute is actually safe to run.
    func canRecalculate(at now: Date, userLocation: CLLocationCoordinate2D) -> Bool {
        if let last = lastRecalculateAt, now.timeIntervalSince(last) < recalculateCooldown {
            return false
        }
        if let priorPos = positionAtLastRecalculate {
            let a = CLLocation(latitude: priorPos.latitude, longitude: priorPos.longitude)
            let b = CLLocation(latitude: userLocation.latitude, longitude: userLocation.longitude)
            if a.distance(from: b) < recalculateMinDisplacementMeters {
                return false
            }
        }
        return true
    }

    func recordRecalculate(at now: Date, userLocation: CLLocationCoordinate2D) {
        lastRecalculateAt = now
        positionAtLastRecalculate = userLocation
        showRecalculateButton = false
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

    // MARK: - Nearest On-Route Node

    /// Linear scan over remaining path nodes — ~500 points max per resort
    /// route, ~5µs scan; not worth a spatial index yet.
    private func nearestOnRouteNode(to coord: CLLocationCoordinate2D) -> String? {
        let remaining = tracker.path[tracker.currentEdgeIndex...]
        guard !remaining.isEmpty else { return nil }
        let target = CLLocation(latitude: coord.latitude, longitude: coord.longitude)
        var bestId: String?
        var bestDist = Double.infinity
        for edge in remaining {
            for nodeId in [edge.sourceID, edge.targetID] {
                guard let node = graph.nodes[nodeId] else { continue }
                let loc = CLLocation(latitude: node.coordinate.latitude, longitude: node.coordinate.longitude)
                let d = target.distance(from: loc)
                if d < bestDist {
                    bestDist = d
                    bestId = nodeId
                }
            }
        }
        return bestId
    }
}
