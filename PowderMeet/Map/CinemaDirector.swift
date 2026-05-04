//
//  CinemaDirector.swift
//  PowderMeet
//
//  All camera choreography lives here. Keeps the map-view Coordinator
//  focused on data-layer plumbing (sources, style layers, diff gates)
//  while this class owns cinematic intros, follow-puck transitions, and
//  frame-both compositions.
//

import Foundation
import CoreLocation
import UIKit
import QuartzCore
import MapboxMaps

@MainActor
final class CinemaDirector {
    private weak var mapView: MapView?
    private var activeIntroAnimators: [BasicCameraAnimator] = []
    /// Bumped when a meetup cancels the resort intro or a new intro starts — `playResortIntro` checks this after each await.
    private var resortIntroToken: UInt64 = 0

    init(mapView: MapView) {
        self.mapView = mapView
    }

    // MARK: - Three-stage Resort Intro (Phase 6.1)

    /// 0.5s plan-view → 1.4s descending arc → 1.1s final settle.
    /// Uses CameraAnimator (not fly(to:)) so easing is controllable per
    /// stage and camera velocity is continuous at stage joints.
    /// Stops an in-flight `playResortIntro` (async sleeps + later camera eases).
    func cancelResortIntroAnimations() {
        resortIntroToken &+= 1
        cancelActiveIntro()
    }

    func playResortIntro(landing: CameraOptions) async {
        guard let mapView else { return }
        resortIntroToken &+= 1
        let introToken = resortIntroToken
        cancelActiveIntro()

        let baseBearing = landing.bearing ?? 0
        let baseZoom = landing.zoom ?? 13
        let baseCenter = landing.center

        let stage1 = CameraOptions(
            center: baseCenter,
            zoom: baseZoom - 2.5,
            bearing: baseBearing - 35,
            pitch: 10
        )
        let stage2 = CameraOptions(
            center: baseCenter,
            zoom: baseZoom - 1.0,
            bearing: baseBearing - 15,
            pitch: 42
        )

        mapView.camera.ease(to: stage1, duration: 0.5, curve: .easeOut, completion: nil)
        await sleep(0.5)
        guard introToken == resortIntroToken else { return }
        mapView.camera.ease(to: stage2, duration: 1.4, curve: .easeInOut, completion: nil)
        await sleep(1.4)
        guard introToken == resortIntroToken else { return }
        mapView.camera.ease(to: landing, duration: 1.1, curve: .easeOut, completion: nil)
        await sleep(1.1)
    }

    // MARK: - Viewport state release

    /// Release whatever viewport state is active, leaving the camera
    /// where it is — no jarring fly-back. Used when a meetup ends.
    ///
    /// The matching `enterOverview` / `enterActiveMeetup` viewport
    /// transitions used to live here too, but every implementation
    /// kept landing the camera on a stale or unprimed location subject
    /// at the moment of accept (the long-running "middle of nowhere"
    /// bug). The current behaviour is to leave the camera exactly where
    /// the user had it on accept; route lines animate in place via the
    /// MountainMapView coordinator. See `git log` for the prior code if
    /// you want to revisit a viewport-state-driven framing.
    func exitToFreeNav() {
        mapView?.viewport.idle()
    }

    // MARK: - Frame Both (Phase 6.4)

    /// Fit the camera to include both coordinates with the given padding.
    /// `bearing` orients the frame so the route reads correctly on screen —
    /// without it Mapbox snaps to north-up, which puts the user "behind"
    /// the mountain on south-facing resorts.
    func frameBoth(
        _ a: CLLocationCoordinate2D,
        _ b: CLLocationCoordinate2D,
        padding: UIEdgeInsets = UIEdgeInsets(top: 180, left: 80, bottom: 240, right: 80),
        duration: TimeInterval = 0.8,
        bearing: CLLocationDirection? = nil
    ) {
        guard let mapView,
              let camera = try? mapView.mapboxMap.camera(
                for: [a, b],
                camera: CameraOptions(bearing: bearing, pitch: 55),
                coordinatesPadding: padding,
                maxZoom: 16.5,
                offset: nil
              ) else { return }
        mapView.camera.ease(to: camera, duration: duration, curve: .easeInOut, completion: nil)
    }

    // MARK: - CameraController Conformance
    // 3-argument `frame` is provided by `CameraController` protocol extension.

    /// Same as `frame(...)` but with an optional compass bearing. Callers
    /// pass this when the default north-up framing would show the mountain
    /// from the wrong side — e.g., a south-facing resort where "up" on the
    /// screen should mean "downhill toward the meeting pin".
    func frame(
        coordinates: [CLLocationCoordinate2D],
        padding: UIEdgeInsets,
        duration: TimeInterval,
        bearing: CLLocationDirection?
    ) {
        guard let mapView, coordinates.count >= 2,
              let camera = try? mapView.mapboxMap.camera(
                for: coordinates,
                camera: CameraOptions(bearing: bearing, pitch: 55),
                coordinatesPadding: padding,
                maxZoom: 16.5,
                offset: nil
              ) else { return }
        mapView.camera.ease(to: camera, duration: duration, curve: .easeInOut, completion: nil)
    }

    // MARK: - Internals

    private func cancelActiveIntro() {
        for animator in activeIntroAnimators { animator.stopAnimation() }
        activeIntroAnimators.removeAll()
    }

    private func sleep(_ seconds: TimeInterval) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }
}

extension CinemaDirector: CameraController {}
