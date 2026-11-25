import CoreLocation
import MapScene
@preconcurrency import MapboxMaps
import MountainCore
import PMLogging
import UIKit

/// The one owner of the camera. Three kinds of move go through it and nothing else
/// calls `camera.ease` or `setCamera`: the resort intro, route framing and
/// navigation follow. A move in flight is never raced by another: an intro
/// replaces whatever is running (the tiles under the camera changed), framing
/// waits its turn, and follow steps aside for both. A gesture clears it.
@MainActor
final class CameraQueue {
    enum Request {
        /// The landing on a new mountain; `cinematic` is the long flight.
        case intro(SceneFrame, cinematic: Bool)
        case pose(SceneFrame)
        case frame([Coordinate], bearing: Double?)
        case follow(Coordinate)
        /// A move the user asked for to one place: waits its turn like a framing.
        case center(Coordinate)
        case bearing(Double)

        var isFollow: Bool {
            if case .follow = self { return true }
            return false
        }
    }

    /// Under a second, per the brief: the map opens on the mountain.
    static let introDuration: TimeInterval = 0.8
    /// With the cinematic extras on (owner, 20 Nov: "intro flight"): a slow
    /// descending orbit onto the same landing pose. A gesture ends it at once.
    static let cinematicIntroDuration: TimeInterval = 3.6

    /// The heading from where the route starts (this phone's skier) to where
    /// it ends (the meeting point): the camera looks that way, so the skier
    /// is near and the meeting point ahead. Nil for a route that ends where
    /// it starts.
    static func alongBearing(_ points: [CLLocationCoordinate2D]) -> Double? {
        guard let first = points.first, let last = points.last else { return nil }
        let north = last.latitude - first.latitude
        let east = (last.longitude - first.longitude) * cos(first.latitude * .pi / 180)
        guard abs(north) + abs(east) > 1e-5 else { return nil }
        let heading = atan2(east, north) * 180 / .pi
        return (heading + 360).truncatingRemainder(dividingBy: 360)
    }

    /// A ski-map view down a route (owner, 21 Nov): from behind and above
    /// the skier at its start, facing the meeting point at its end, tilted
    /// so the slopes read, and zoomed so the route fills the band of map the
    /// app's chrome leaves (`band`, centred by `padding`). Worked out from
    /// distances rather than fitted on the flat map, which on tilted terrain
    /// left the skier under the card below the band.
    static func skiMapCamera(
        _ route: [CLLocationCoordinate2D], current: Double, band: CGSize, padding: UIEdgeInsets
    ) -> CameraOptions {
        #if DEBUG
        // A capture can face the skiable fronts of both mountains consistently.
        let captureBearing: Double? = UserDefaults.standard.object(forKey: "demoCameraBearing") == nil
            ? nil : UserDefaults.standard.double(forKey: "demoCameraBearing")
        let pitch = captureBearing == nil ? 58.0 : 45.0
        #else
        let pitch = 58.0
        #endif
        let first = route[0], last = route[route.count - 1]
        let latitude = (first.latitude + last.latitude) / 2
        let metresPerDegree = 111_320.0, east = cos(latitude * .pi / 180)
        #if DEBUG
        let heading = captureBearing ?? alongBearing(route) ?? current
        #else
        let heading = alongBearing(route) ?? current
        #endif
        let rad = heading * .pi / 180
        // Every point's distance along the view and across it, from the
        // route's middle, in metres.
        let middle = CLLocationCoordinate2D(latitude: latitude, longitude: (first.longitude + last.longitude) / 2)
        var along = (lo: 0.0, hi: 0.0), across = 0.0
        for point in route {
            let north = (point.latitude - middle.latitude) * metresPerDegree
            let eastM = (point.longitude - middle.longitude) * metresPerDegree * east
            let a = north * cos(rad) + eastM * sin(rad)
            let c = -north * sin(rad) + eastM * cos(rad)
            along = (min(along.lo, a), max(along.hi, a))
            across = max(across, abs(c))
        }
        // The view's depth is foreshortened by the tilt, its far half more
        // than the near (so the factor over 1); a margin all round.
        let depth = max(200, (along.hi - along.lo) * cos(pitch * .pi / 180))
        let metresPerPoint = max(depth / (band.height * 1.1), across * 2 / (band.width * 0.92))
        let zoom = min(16.5, log2(78_271.517 * east / max(0.5, metresPerPoint)))
        let centre = CLLocationCoordinate2D(
            latitude: middle.latitude + (along.lo + along.hi) / 2 * cos(rad) / metresPerDegree,
            longitude: middle.longitude + (along.lo + along.hi) / 2 * sin(rad) / (metresPerDegree * east))
        return CameraOptions(center: centre, padding: padding, zoom: zoom, bearing: heading, pitch: pitch)
    }

    /// The covered strips as camera padding, so a pose or a centred place lands in
    /// the middle of the map that shows. Held to 72% of the height between them
    /// (a meet with a run's card open covers about two thirds of the screen):
    /// a measurement taken mid-layout must not leave the camera nothing to aim at.
    static func visiblePadding(in size: CGSize, obscured: UIEdgeInsets) -> UIEdgeInsets {
        var top = max(0, obscured.top), bottom = max(0, obscured.bottom)
        let limit = size.height * 0.72
        if top + bottom > limit, top + bottom > 0 {
            let scale = limit / (top + bottom)
            top *= scale
            bottom *= scale
        }
        return UIEdgeInsets(top: top, left: 0, bottom: bottom, right: 0)
    }

    /// What the app draws over the map (top and bottom strips, in the map's points).
    var obscured: UIEdgeInsets = .zero

    private unowned let mapView: MapView
    private let log: PMLog
    private var running: Cancelable?
    /// Identifies the move in flight, so the end of an older one changes nothing.
    private final class Move {}
    private var current: Move?
    private var runningIsFollow = false
    private var pending: Request?

    init(mapView: MapView, log: PMLog) {
        self.mapView = mapView
        self.log = log
    }

    /// Returns false when the request was dropped (a follow step while another
    /// move has the camera).
    @discardableResult
    func submit(_ request: Request) -> Bool {
        switch request {
        case .follow:
            // Follow never interrupts a move the user asked for.
            guard running == nil, pending == nil else { return false }
            start(request)
        case .intro:
            pending = nil
            start(request)
        case .pose, .frame, .center, .bearing:
            if running != nil, !runningIsFollow {
                pending = request
            } else {
                start(request)
            }
        }
        return true
    }

    /// A gesture began: the SDK has already stopped the animation; forget the rest.
    func userInterrupted() {
        running?.cancel()
        running = nil
        current = nil
        pending = nil
    }

    /// The steepest tilt a finger may reach. Past about 65° the horizon band
    /// and the sky slide up under the status bar and the Mapbox row, and move
    /// in and out of view with every pan (owner, 21 Nov); the default pose is 62°.
    static let maxPitch = 65.0

    /// Pan limits and zoom range for a resort: orbit the mountain, not the planet.
    func restrict(to frame: SceneFrame) throws {
        let b = frame.bounds
        let padLat = (b.maxLat - b.minLat) * 0.5
        let padLon = (b.maxLon - b.minLon) * 0.5
        try mapView.mapboxMap.setCameraBounds(with: CameraBoundsOptions(
            bounds: CoordinateBounds(
                southwest: CLLocationCoordinate2D(latitude: b.minLat - padLat, longitude: b.minLon - padLon),
                northeast: CLLocationCoordinate2D(latitude: b.maxLat + padLat, longitude: b.maxLon + padLon)),
            maxZoom: 17, minZoom: 10.5, maxPitch: Self.maxPitch, minPitch: 40))
    }

    private func start(_ request: Request) {
        running?.cancel()
        running = nil
        current = nil
        runningIsFollow = request.isFollow
        let still = UIAccessibility.isReduceMotionEnabled

        switch request {
        case .intro(let frame, let cinematic):
            let landing = camera(frame)
            guard !still else { return jump(to: landing) }
            if cinematic {
                // High and turned away, then a long easing orbit down onto the
                // landing pose: the mountain comes round into view.
                mapView.mapboxMap.setCamera(to: CameraOptions(
                    center: landing.center, padding: landing.padding, zoom: max(10.5, frame.zoom - 2.2),
                    bearing: frame.bearing - 75, pitch: 40))
                ease(to: landing, duration: Self.cinematicIntroDuration, curve: .easeInOut)
            } else {
                // One short descending turn onto the landing pose.
                mapView.mapboxMap.setCamera(to: CameraOptions(
                    center: landing.center, padding: landing.padding, zoom: max(10.5, frame.zoom - 1.0),
                    bearing: frame.bearing - 18, pitch: 45))
                ease(to: landing, duration: Self.introDuration, curve: .easeOut)
            }

        case .pose(let frame):
            still ? jump(to: camera(frame)) : ease(to: camera(frame), duration: 0.7, curve: .easeInOut)

        case .frame(let coordinates, let bearing):
            let route = coordinates.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) }
            guard route.count >= 2 else { return finished() }
            let size = mapView.bounds.size
            let covered = Self.visiblePadding(in: size, obscured: obscured)
            var camera = Self.skiMapCamera(
                route, current: bearing ?? mapView.mapboxMap.cameraState.bearing,
                band: CGSize(width: size.width, height: size.height - covered.top - covered.bottom),
                padding: covered)
            #if DEBUG
            if UserDefaults.standard.bool(forKey: "demoCapture") {
                do {
                    camera = try mapView.mapboxMap.camera(
                        for: route,
                        camera: CameraOptions(
                            padding: covered,
                            bearing: UserDefaults.standard.double(forKey: "demoCameraBearing"), pitch: 40),
                        coordinatesPadding: UIEdgeInsets(top: 20, left: 24, bottom: 20, right: 24),
                        maxZoom: 15.5, offset: nil)
                    // Terrain can rise above the fitted plane; leave room for both avatars.
                    camera.zoom = (camera.zoom ?? 13) - 0.4
                } catch {
                    log.error(.map, "capture framing failed: \(error.localizedDescription)")
                }
            }
            #endif
            still ? jump(to: camera) : ease(to: camera, duration: 0.7, curve: .easeInOut)

        case .follow(let coordinate):
            let camera = CameraOptions(
                center: CLLocationCoordinate2D(latitude: coordinate.lat, longitude: coordinate.lon),
                padding: coveredPadding, zoom: max(mapView.mapboxMap.cameraState.zoom, 15))
            still ? jump(to: camera) : ease(to: camera, duration: 0.9, curve: .linear)

        case .center(let coordinate):
            let camera = CameraOptions(
                center: CLLocationCoordinate2D(latitude: coordinate.lat, longitude: coordinate.lon),
                padding: coveredPadding, zoom: max(mapView.mapboxMap.cameraState.zoom, 15))
            still ? jump(to: camera) : ease(to: camera, duration: 0.6, curve: .easeInOut)

        case .bearing(let bearing):
            let camera = CameraOptions(bearing: bearing)
            still ? jump(to: camera) : ease(to: camera, duration: 0.4, curve: .easeInOut)
        }
    }

    private func ease(to camera: CameraOptions, duration: TimeInterval, curve: UIView.AnimationCurve) {
        let move = Move()
        current = move
        running = mapView.camera.ease(to: camera, duration: duration, curve: curve) { [weak self] _ in
            // However the move ended, it no longer has the camera. The SDK also
            // stops a move itself (the map view changed size when a card opened,
            // for one), and a queue that waited only for a clean end would then
            // hold every later request forever. A move this queue replaced or the
            // user interrupted is no longer `current` and hands over nothing.
            MainActor.assumeIsolated {
                guard let self, self.current === move else { return }
                self.finished()
            }
        }
    }

    private func jump(to camera: CameraOptions) {
        mapView.mapboxMap.setCamera(to: camera)
        finished()
    }

    private func finished() {
        running = nil
        current = nil
        runningIsFollow = false
        if let next = pending {
            pending = nil
            start(next)
        }
    }

    private var coveredPadding: UIEdgeInsets {
        Self.visiblePadding(in: mapView.bounds.size, obscured: obscured)
    }

    private func camera(_ frame: SceneFrame) -> CameraOptions {
        CameraOptions(
            center: CLLocationCoordinate2D(latitude: frame.center.lat, longitude: frame.center.lon),
            padding: coveredPadding, zoom: frame.zoom, bearing: frame.bearing, pitch: frame.pitch)
    }
}
