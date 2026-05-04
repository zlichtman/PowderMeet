//
//  MountainMapView.swift
//  PowderMeet
//
//  UIViewRepresentable wrapping MapboxMaps with 3D terrain,
//  trail/lift GeoJSON layers, route overlays, and meeting point.
//
//  REQUIRES: MapboxMaps SDK added via Swift Package Manager.
//  Add package: https://github.com/mapbox/mapbox-maps-ios.git
//  Add MBXAccessToken to Info.plist with your Mapbox access token.

import SwiftUI
@_spi(Experimental) import MapboxMaps
@_spi(Restricted) import MapboxMaps
import CoreLocation
import Observation

/// Bridge exposing map-coordinator capabilities to SwiftUI (ContentView).
/// Set by MountainMapView.Coordinator on style load.
@MainActor @Observable
final class MapBridge {
    var cinemaDirector: CinemaDirector?

    /// Trigger the meeting-point pulse animation.
    var triggerMeetingPulse: (() -> Void)?

    /// Trigger the arrival bloom — fired by RouteChoreographer.playArrival().
    var triggerArrivalBloom: (() -> Void)?

    /// User toggle for optional temperature overlay.
    var showTemperatureOverlay: Bool = false

    var projectToScreen: ((CLLocationCoordinate2D) -> CGPoint?)?

    /// Current map viewport size.
    var viewportSize: CGSize = .zero

    /// Current camera bearing in radians (Mapbox bearing converted to
    /// `atan2`-style: 0 = east, counter-clockwise positive). Used by
    /// the off-screen friend chip overlay so the arrow rotation
    /// stays consistent under map rotation.
    var cameraBearingRadians: Double = 0

    /// Bumped on every Mapbox camera change. SwiftUI overlays that
    /// derive screen positions from `projectToScreen` (e.g. the
    /// off-screen friend chip layer) read this to re-evaluate after
    /// each pan/zoom/rotate without polling.
    var cameraGeneration: Int = 0
}

/// Bundle of every per-frame input the SwiftUI `MountainMapView` hands
/// down to its UIKit coordinator. Replaces the previous fan-out of ~30
/// mirror properties so adding a new input updates one struct instead
/// of three places in lockstep (SwiftUI property + Coordinator field +
/// `updateUIView` assignment). Not Hashable — holds a closure
/// (`onTrailTapped`) and a class reference (`mapBridge`); per-layer diff
/// gating still lives on the `MapLayerState` structs.
struct MountainMapInputs {
    var resortEntry: ResortEntry? = nil
    var graph: MountainGraph? = nil
    var routeA: [GraphEdge]? = nil
    var routeB: [GraphEdge]? = nil
    var meetingNode: GraphNode? = nil
    var userLocation: CLLocationCoordinate2D? = nil
    var friendLocations: [UUID: RealtimeLocationService.FriendLocation] = [:]
    var replayPositions: [UUID: CLLocationCoordinate2D] = [:]
    var replayTrails: [UUID: [CLLocationCoordinate2D]] = [:]
    var ghostPositions: [UUID: [(coordinate: CLLocationCoordinate2D, label: String)]] = [:]
    var selectedEdgeId: String? = nil
    var onTrailTapped: ((String) -> Void)? = nil
    var routeAnimationTrigger: Int = 0
    var showDebugLayers: Bool = false
    var isActiveMeetup: Bool = false
    var meetupPartnerId: UUID? = nil
    var isMapVisible: Bool = true
    var mapBridge: MapBridge? = nil
    var selectedTime: Date = .now
    var isScrubbingTimeline: Bool = false
    var resortLatitude: Double? = nil
    var resortLongitude: Double? = nil
    var temperatureC: Double = -2
    var cloudCoverPercent: Int = 0
    var snowfallCmPerHour: Double = 0
    var windSpeedKph: Double = 0
    var windDirectionDeg: Int = 0
    var visibilityKm: Double = 10
    var mapFriendLayerClock: Int = 0
    var friendSignalQualities: [UUID: FriendSignalQuality] = [:]
}

struct MountainMapView: UIViewRepresentable {
    let resortEntry: ResortEntry?
    let graph: MountainGraph?
    let routeA: [GraphEdge]?
    let routeB: [GraphEdge]?
    let meetingNode: GraphNode?
    let userLocation: CLLocationCoordinate2D?
    let friendLocations: [UUID: RealtimeLocationService.FriendLocation]
    var replayPositions: [UUID: CLLocationCoordinate2D] = [:]
    var replayTrails: [UUID: [CLLocationCoordinate2D]] = [:]
    var selectedEdgeId: String?
    var onTrailTapped: ((String) -> Void)?
    /// Incremented every time user taps "Show Route on Map" — forces animation replay
    /// even when the same route is already displayed.
    var routeAnimationTrigger: Int = 0
    /// Show debug visualization layers (traverses, dead-ends, phantom trails).
    /// Default false — only enable from dev tools.
    var showDebugLayers: Bool = false
    /// True when a meetup is active — triggers FollowPuck viewport transition.
    var isActiveMeetup: Bool = false
    /// When `isActiveMeetup`, the other participant — used to pick their
    /// dot from `friendLocations` for pre-reveal camera framing.
    var meetupPartnerId: UUID? = nil
    /// Ghost skier positions along the path at the scrubbed time. Populated by
    /// `RouteProjection.skierPosition(...)` when the timeline is scrubbed
    /// forward during an active meetup.
    var ghostPositions: [UUID: [(coordinate: CLLocationCoordinate2D, label: String)]] = [:]
    /// Selected time from timeline scrubber — drives sun exposure overlay.
    var selectedTime: Date = .now
    /// True while the user is actively dragging the timeline thumb.
    /// While dragging, we coarsen the sun-exposure bucket (15 min vs 5 min)
    /// and skip the fog/sky recompute on every tick — full fidelity snaps
    /// in when the gesture ends.
    var isScrubbingTimeline: Bool = false
    /// Resort latitude/longitude for sun position calculation.
    var resortLatitude: Double?
    var resortLongitude: Double?
    /// Temperature (°C) at the scrubbed time. Used by sun exposure snow
    /// condition modeling and the elevation temperature overlay.
    var temperatureC: Double = -2
    /// Cloud cover (0–100) at the scrubbed time. Drives sky/atmosphere tint
    /// and the sun exposure overlay's direct-beam attenuation.
    var cloudCoverPercent: Int = 0
    /// Snowfall rate in cm/hour at the scrubbed time. Drives particle overlay.
    var snowfallCmPerHour: Double = 0
    /// Wind speed (kph) at the scrubbed time. Drives particle streak velocity.
    var windSpeedKph: Double = 0
    /// Wind direction (degrees, meteorological — "from" direction). Drives
    /// particle emission angle for slanted snowfall.
    var windDirectionDeg: Int = 0
    /// Visibility (km) at the scrubbed time. Tightens the fog range in
    /// low-visibility hours so distant terrain softens like real haze.
    var visibilityKm: Double = 10
    /// Bridge for exposing coordinator capabilities to ContentView.
    var mapBridge: MapBridge?
    /// False when the map tab isn't on screen — pauses CADisplayLinks
    /// (gondola animation, beam pulse, friend motion pulse) so the map
    /// doesn't burn GPU/CPU while the user is on Profile or Meet.
    var isMapVisible: Bool = true
    /// Bumped every 60s on the Map tab so friend age pills / 3h visibility update without a GPS event.
    var mapFriendLayerClock: Int = 0
    /// Live / stale / cold for each friend; drives signal styling and re-renders the friend layer.
    var friendSignalQualities: [UUID: FriendSignalQuality] = [:]

    /// `internal` (default) so `MountainMapView+Style.swift` and
    /// `MountainMapView+Animations.swift` extensions on `Coordinator`
    /// can reference the same identifier set as the primary file.
    enum SourceID {
        static let trails           = "trails-source"
        static let lifts            = "lifts-source"
        static let routeA           = "route-a-source"
        static let routeB           = "route-b-source"
        static let meetingPoint     = "meeting-point-source"
        static let meetingBeam      = "meeting-beam-source"
        static let selectedTrail    = "selected-trail-source"
        static let userLocation     = "user-location-source"
        static let friendLocations  = "friend-locations-source"
        static let ghostPositions   = "ghost-positions-source"
        static let liftEndpoints    = "lift-endpoints-source"
        static let replayTrails     = "replay-trails-source"
        static let replayPositions  = "replay-positions-source"
        static let sunExposure      = "sun-exposure-source"
        static let temperature      = "temperature-source"
        static let pois             = "pois-source"
        static let traverses        = "traverses-source"
        static let deadEnds         = "dead-ends-source"
        static let phantomTrails    = "phantom-trails-source"
        static let gondolas         = "gondolas-source"
    }

    /// `internal` (default) — same rationale as `SourceID`.
    enum LayerID {
        static let trailGlow          = "trail-glow-layer"
        static let trailCasing        = "trail-casing-layer"
        static let trails             = "trails-layer"
        static let liftGlow           = "lift-glow-layer"
        static let lifts              = "lifts-layer"
        static let traverses          = "traverses-layer"
        static let deadEndDots        = "dead-end-dots-layer"
        static let phantomTrails      = "phantom-trails-layer"
        static let routeAGlow         = "route-a-glow-layer"
        static let routeA             = "route-a-layer"
        static let routeBGlow         = "route-b-glow-layer"
        static let routeB             = "route-b-layer"
        static let meetingBeam        = "meeting-beam-layer"
        static let meeting            = "meeting-layer"
        static let meetingPulse       = "meeting-pulse-layer"
        static let selectedTrailGlow  = "selected-trail-glow-layer"
        static let selectedTrail      = "selected-trail-layer"
        static let userPulse          = "user-pulse-layer"
        static let userDotOuter       = "user-dot-outer-layer"
        static let userDot            = "user-dot-layer"
        static let friendAccuracyHalo = "friend-accuracy-halo-layer"
        static let friendPulse        = "friend-pulse-layer"
        static let friendMotionPulse  = "friend-motion-pulse-layer"
        static let friendDots         = "friend-dots-layer"
        static let friendLabels       = "friend-labels-layer"
        static let friendAgeBadge     = "friend-age-badge-layer"
        static let ghostDots          = "ghost-dots-layer"
        static let ghostLabels        = "ghost-labels-layer"
        static let sunExposure        = "sun-exposure-layer"
        static let temperature        = "temperature-layer"
        static let poiIcons           = "poi-icons-layer"
        static let poiLabels          = "poi-labels-layer"
        static let trailLabels        = "trail-labels-layer"
        static let liftEndpoints      = "lift-endpoints-layer"
        static let gondolas           = "gondolas-layer"
        static let gondolasGlow       = "gondolas-glow-layer"
        static let liftLabels         = "lift-labels-layer"
        static let replayTrails       = "replay-trails-layer"
        static let replayDots         = "replay-dots-layer"
    }

    func makeUIView(context: Context) -> MapboxMaps.MapView {
        // Photo-real Satellite-Streets: real trees, rocks, and terrain show
        // through the satellite texture; street/place labels overlay. The
        // previous dark vector style looked abstract, not premium — the
        // satellite base is what makes the "FATMAP merged with Find My"
        // comparison land.
        let options = MapInitOptions(
            cameraOptions: initialCamera(),
            styleURI: StyleURI(rawValue: "mapbox://styles/mapbox/satellite-streets-v12") ?? .satelliteStreets
        )

        // Mapbox rejects tiny / zero initial frames as invalid and falls
        // back to {64, 64} — the Metal view then briefly runs with a NaN
        // content scale and the style load trips a `MBMMapLoadingError`
        // type 2 before SwiftUI applies the real frame. Net effect: a
        // visible jank on first map open. Seeding with the device screen
        // bounds sidesteps the fallback entirely; SwiftUI's layout pass
        // resizes to the actual container a moment later.
        let placeholder = UIScreen.main.bounds
        let mapView = MapboxMaps.MapView(frame: placeholder, mapInitOptions: options)
        // Mapbox TOS requires the logo wordmark AND the attribution button to
        // remain visible. Scale bar + compass are left at their default
        // .visible so users get a sense of map size and a tap-to-north
        // affordance during navigation.

        context.coordinator.mapView = mapView
        context.coordinator.inputs.onTrailTapped = onTrailTapped

        mapView.mapboxMap.onStyleLoaded.observeNext { _ in
            context.coordinator.onStyleLoaded()
        }
        .store(in: &context.coordinator.cancelBag)

        // Camera-change observer drives the off-screen friend chip
        // layer. Bumping `cameraGeneration` is observed by SwiftUI
        // (MapBridge is @Observable), so the chip overlay re-projects
        // after every pan/zoom/rotate without a polling timer.
        mapView.mapboxMap.onCameraChanged.observe { _ in
            Task { @MainActor in
                guard let bridge = context.coordinator.inputs.mapBridge,
                      let mv = context.coordinator.mapView else { return }
                let state = mv.mapboxMap.cameraState
                // Mapbox `bearing` is degrees, clockwise from north.
                // FriendChipLayoutEngine uses atan2-radians (counter-
                // clockwise from east) — convert here so the layout
                // engine stays untouched.
                bridge.cameraBearingRadians = -state.bearing * .pi / 180
                bridge.cameraGeneration &+= 1
            }
        }
        .store(in: &context.coordinator.cancelBag)

        mapView.mapboxMap.onMapLoadingError.observe { event in
            let desc = "\(event.type)"
            print("[MountainMapView] map loading error: \(desc)")
            if desc.contains("-1011") || desc.contains("BadServerResponse") || event.type == .style {
                context.coordinator.retryStyleLoad()
            }
        }
        .store(in: &context.coordinator.cancelBag)

        return mapView
    }

    func updateUIView(_ mapView: MapboxMaps.MapView, context: Context) {
        let coord = context.coordinator

        // Capture the values needed for edge-trigger comparisons BEFORE
        // the wholesale `inputs` swap — otherwise prev/next would always
        // be equal and `pauseAnimations` / `resumeAnimationsIfNeeded`
        // would never fire on visibility flips.
        let prevIsMapVisible = coord.inputs.isMapVisible

        coord.inputs = MountainMapInputs(
            resortEntry: resortEntry,
            graph: graph,
            routeA: routeA,
            routeB: routeB,
            meetingNode: meetingNode,
            userLocation: userLocation,
            friendLocations: friendLocations,
            replayPositions: replayPositions,
            replayTrails: replayTrails,
            ghostPositions: ghostPositions,
            selectedEdgeId: selectedEdgeId,
            onTrailTapped: onTrailTapped,
            routeAnimationTrigger: routeAnimationTrigger,
            showDebugLayers: showDebugLayers,
            isActiveMeetup: isActiveMeetup,
            meetupPartnerId: meetupPartnerId,
            isMapVisible: isMapVisible,
            mapBridge: mapBridge,
            selectedTime: selectedTime,
            isScrubbingTimeline: isScrubbingTimeline,
            resortLatitude: resortLatitude,
            resortLongitude: resortLongitude,
            temperatureC: temperatureC,
            cloudCoverPercent: cloudCoverPercent,
            snowfallCmPerHour: snowfallCmPerHour,
            windSpeedKph: windSpeedKph,
            windDirectionDeg: windDirectionDeg,
            visibilityKm: visibilityKm,
            mapFriendLayerClock: mapFriendLayerClock,
            friendSignalQualities: friendSignalQualities
        )

        if let mapBridge {
            mapBridge.viewportSize = mapView.bounds.size
        }

        if isMapVisible != prevIsMapVisible {
            if isMapVisible {
                coord.resumeAnimationsIfNeeded()
            } else {
                coord.pauseAnimations()
            }
        }

        // Active meetup: do not move the camera. The user explicitly
        // wants the post-accept viewport to stay where they were — every
        // implementation that tried to frame routes / follow the puck
        // kept landing on a stale or unprimed location subject ("middle
        // of nowhere"), and the route still animates in place so a
        // careful user can find it. Only the deactivation side touches
        // the camera, releasing any viewport state that might have been
        // installed in some earlier session without a jarring fly-back.
        //
        // (The resort-change block below DOES still play the resort
        // intro on cross-resort accepts — without it the tiles swap out
        // from under a camera still pointing at the old resort. That
        // intro lands at the resort center, which is predictable and
        // not the "random place" failure the user reported.)
        if isActiveMeetup != coord.wasActiveMeetup {
            coord.wasActiveMeetup = isActiveMeetup
            if !isActiveMeetup {
                coord.cinemaDirector?.exitToFreeNav()
            }
        }

        if let entry = resortEntry, entry.id != coord.lastResortID {
            coord.lastResortID = entry.id

            let camera = CameraOptions(
                center: entry.coordinate,
                zoom: entry.preferredZoom ?? entry.defaultZoom,
                bearing: entry.preferredBearing ?? 0,
                pitch: entry.preferredPitch ?? 62
            )

            // The resort intro plays on every resort change, including
            // cross-resort meetup activations. Without it, the tiles
            // swap out from under a camera that's still pointing at the
            // old resort and the user sees an empty patch of terrain
            // until they pan to find the new mountain. The landing
            // pose (resort center, preferred bearing/pitch) is a
            // predictable, well-known location — not the "lands
            // somewhere random" failure mode of the old meetup
            // overview, which tried to frame routes + pucks and kept
            // missing on stale location subjects.
            //
            // Three-stage cinematic intro (Phase 6.1). Falls back to a
            // plain fly-to if the director isn't ready yet (first tick
            // before onStyleLoaded fires).
            if let director = coord.cinemaDirector {
                Task { @MainActor in await director.playResortIntro(landing: camera) }
            } else {
                mapView.camera.fly(to: camera, duration: 1.5)
            }

            // Lock camera to orbit the mountain — restrict pan to resort bounds
            // with generous padding so the user can rotate but not fly away.
            let padLat = (entry.bounds.maxLat - entry.bounds.minLat) * 0.5
            let padLon = (entry.bounds.maxLon - entry.bounds.minLon) * 0.5
            let cameraBounds = CameraBoundsOptions(
                bounds: CoordinateBounds(
                    southwest: CLLocationCoordinate2D(
                        latitude: entry.bounds.minLat - padLat,
                        longitude: entry.bounds.minLon - padLon
                    ),
                    northeast: CLLocationCoordinate2D(
                        latitude: entry.bounds.maxLat + padLat,
                        longitude: entry.bounds.maxLon + padLon
                    )
                ),
                maxZoom: 17,
                minZoom: 10.5,
                maxPitch: 75,
                minPitch: 40
            )
            try? mapView.mapboxMap.setCameraBounds(with: cameraBounds)
        }

        coord.updateDataLayers()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    private func initialCamera() -> CameraOptions {
        let center = resortEntry?.coordinate ?? CLLocationCoordinate2D(latitude: 39.6, longitude: -106.35)
        return CameraOptions(
            center: center,
            zoom: resortEntry?.preferredZoom ?? resortEntry?.defaultZoom ?? 13,
            bearing: resortEntry?.preferredBearing ?? 0,
            pitch: resortEntry?.preferredPitch ?? 62
        )
    }

    final class Coordinator {
        var mapView: MapboxMaps.MapView?
        var cancelBag: [AnyCancelable] = []
        var lastResortID: String?
        /// Every per-frame input from the SwiftUI struct. Replaces the
        /// fan-out of mirror properties — `inputs.graph`, `inputs.routeA`,
        /// etc. The single field means new inputs only land in one
        /// place; `updateUIView` pushes the entire bundle in one assign.
        var inputs = MountainMapInputs()
        /// Tracks the previous value of `inputs.isActiveMeetup` so the
        /// active-meetup edge transition still fires exactly once even
        /// after the bulk-assign in `updateUIView` overwrites the live
        /// value before the comparison runs.
        var wasActiveMeetup: Bool = false
        var cinemaDirector: CinemaDirector?
        var styleLoaded = false
        var styleRetryCount = 0
        let maxStyleRetries = 3
        var snowEmitter: CAEmitterLayer?

        // Route animation state
        var animationTimer: Timer?
        var animationProgress: Double = 0
        var animationStartTime: CFTimeInterval = 0
        let animationDuration: CFTimeInterval = 2.0
        var lastRouteTrim: Double = -1
        /// Sticky per-UUID color for ghost trails. Populated lazily in
        /// buildGhostGeoJSON; cleared when ghostPositions goes empty.
        var ghostColorAssignment: [UUID: String] = [:]
        var ghostNextColorIndex: Int = 0
        var lastAnimationTrigger: Int = 0
        /// Edge-id snapshot consumed by `checkAndAnimateRoutes` — separate
        /// from `lastRouteLayerState` because the animation gate fires
        /// independently of GeoJSON source rebuilds.
        var lastAnimatedRouteAEdgeIds: [String] = []
        var lastAnimatedRouteBEdgeIds: [String] = []
        var meetingPulsePhase: Double = 0
        var meetingPulseTimer: Timer?
        /// Flipped by `pauseAnimations` so `resumeAnimationsIfNeeded` knows
        /// the route reveal was in-flight when the tab went away — we snap
        /// to full-drawn instead of restarting.
        var wasRouteAnimating = false
        var wasMeetingPulsing = false

        // Diff state — compared before rebuilding GeoJSON. Updating a GeoJSON
        // source costs ~1-4ms; on a 30-layer style that adds up across 5s
        // friend broadcasts and every SwiftUI re-evaluation. We only rebuild
        // what actually changed.
        //
        // Three of the previous `lastXxxHash` fields collapsed into Hashable
        // structs (see `MapLayerState.swift`):
        //   - `MapTrailLayerState`   → trails / lifts / debug / temperature
        //   - `MapFriendLayerState`  → friend dots (now includes the
        //                              `signalQualities` and 60s `clock`
        //                              that were missing from the old hash)
        //   - `MapRouteLayerState`   → route A / route B / meeting node
        //
        // Optional initial value (`nil`) means "never set" so the first
        // `updateDataLayers` call always rebuilds — matches the original
        // sentinel-based first-run behavior.
        var lastTrailLayerState: MapTrailLayerState?
        var lastFriendLayerState: MapFriendLayerState?
        var lastRouteLayerState: MapRouteLayerState?
        var lastUserLocationHash: Int = 0
        var lastReplayPositionsHash: Int = 0
        var lastReplayTrailsHash: Int = 0
        var lastGhostPositionsHash: Int = 0
        var lastSelectedEdgeId: String? = "__unset__"
        /// Bucket key for the sun-exposure overlay. `currentBucket`
        /// granularity is 5 min at rest / 15 min while scrubbing so a
        /// cross-day drag still shows visual feedback without rebuilding
        /// a graph-wide GeoJSON every tick.
        var lastSunExposureBucket: Int = -1
        var lastSkyBucket: Int = -1
        var lastAtmosphereBucket: Int = -1
        /// Snapshot of weather inputs that drive the sun exposure overlay —
        /// change forces a rebuild even when the time bucket hasn't flipped.
        var lastSunInputsHash: Int = 0
        /// Previous scrub state so we can force a full recompute the moment
        /// the user releases the thumb (snap to exact minute).
        var lastIsScrubbing: Bool = false
        /// Hash over (snowfall, wind speed, wind direction) — bucketed — so
        /// the CAEmitter doesn't get reconfigured on every pixel of drag.
        var lastSnowParamsHash: Int = 0

        // Beam opacity pulse (Phase 7.3). CADisplayLink drives a continuous
        // sinusoidal pulse on the meeting beam's opacity — cheap because
        // we're animating a single layer property, not a geometry rebuild.
        var beamDisplayLink: CADisplayLink?
        var beamPhase: CGFloat = 0

        // Friend motion pulse (Phase 7.2) — expanding ring under each friend
        // disk, Find My style. Shared phase across all live friends; single
        // CADisplayLink mutates layer circle-radius + circle-opacity.
        var friendPulseDisplayLink: CADisplayLink?
        var friendPulsePhase: CGFloat = 0

        // Gondola animation — single phase wraps [0,1]; per-lift offsets are
        // baked into GeoJSONBuilder.gondolaFeatures. Throttled to 10Hz to
        // keep source rebuild cost predictable across resort sizes.
        var gondolaDisplayLink: CADisplayLink?
        var gondolaPhase: Double = 0
        var lastGondolaTick: CFTimeInterval = 0

        // Used by replay GeoJSON builders in MountainMapView+Animations.swift.
        let replayColors = ["#3B82F6", "#F59E0B", "#10B981", "#EF4444", "#8B5CF6"]
        var arrivalBloomPhase: Double = 0
        var arrivalBloomTimer: Timer?

        func retryStyleLoad() {
            guard !styleLoaded, styleRetryCount < maxStyleRetries, let mapView else { return }
            styleRetryCount += 1
            let delay = Double(styleRetryCount) * 1.5
            print("[MountainMapView] retrying style load (attempt \(styleRetryCount)/\(maxStyleRetries)) in \(delay)s")
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                guard !self.styleLoaded else { return }
                let uri = StyleURI(rawValue: "mapbox://styles/mapbox/satellite-streets-v12") ?? .satelliteStreets
                mapView.mapboxMap.loadStyle(uri)
            }
        }

        func onStyleLoaded() {
            guard let mapView else { return }
            styleLoaded = true

            configureTerrain(mapView)
            configureSkyAndAtmosphere(mapView)
            configureBaseMapStyle(mapView)
            suppressBasemapClutter(mapView)
            // The custom blue user-dot layers (userPulse/userDotOuter/userDot)
            // handle the visible render from the parent-supplied `userLocation`.
            // The Mapbox puck is kept enabled but INVISIBLE (opacity 0) so that
            // `FollowPuckViewportState` — used during active meetups — keeps
            // receiving Core Location updates. Setting `puckType = .none` makes
            // Mapbox's location provider dormant (mapbox/mapbox-maps-ios#691),
            // which is why follow-puck used to snap to a stale coord on meetup
            // start.
            mapView.location.options.puckType = .puck2D(Puck2DConfiguration(opacity: 0))
            addSources(mapView)
            registerSFSymbols(mapView)
            addLayers(mapView)
            registerTapHandler(mapView)
            let director = CinemaDirector(mapView: mapView)
            cinemaDirector = director
            if let bridge = inputs.mapBridge {
                bridge.cinemaDirector = director
                bridge.triggerMeetingPulse = { [weak self] in self?.startMeetingPulse() }
                bridge.triggerArrivalBloom = { [weak self] in self?.startArrivalBloom() }
                bridge.projectToScreen = { [weak self] coord in
                    guard let mapView = self?.mapView else { return nil }
                    return mapView.mapboxMap.point(for: coord)
                }
                bridge.viewportSize = mapView.bounds.size
            }
            updateDataLayers()
        }

        // MARK: - Trail Tap

        private func registerTapHandler(_ mapView: MapboxMaps.MapView) {
            guard let map = mapView.mapboxMap else { return }
            map.addInteraction(TapInteraction(.layer(LayerID.trails), radius: 44) { [weak self] feature, _ in
                if case .string(let edgeId) = feature.properties["id"] {
                    self?.inputs.onTrailTapped?(edgeId)
                    return true
                }
                return false
            })
            map.addInteraction(TapInteraction(.layer(LayerID.lifts), radius: 44) { [weak self] feature, _ in
                if case .string(let edgeId) = feature.properties["id"] {
                    self?.inputs.onTrailTapped?(edgeId)
                    return true
                }
                return false
            })
        }


        // Single-source-update invariant: every GeoJSON source that changes
        // in response to new state (graph, routes, friends, selection, etc.)
        // is refreshed from inside this function via `updateSource`, which is
        // hash-gated per source to avoid redundant work. Do NOT push source
        // data from anywhere else.
        //
        // The one carve-out is the **animated gondola source**
        // (`SourceID.gondolas`), which is driven by a 10Hz CADisplayLink in
        // `gondolaTick()` and cleared by `stopGondolaAnimation()`. Hash-gating
        // at 10Hz would be pure overhead — the tick IS the diff. Do not add
        // new sources to that carve-out without the same reasoning.
        func updateDataLayers() {
            guard let mapView, styleLoaded, let map = mapView.mapboxMap else { return }

            // Graph-derived sources (trails, lifts, traverses, debug) only
            // rebuild when the graph itself changes. The biggest cost in
            // updateDataLayers comes from rebuilding trail/lift features at
            // ~2-10ms on a large resort; gating on fingerprint drops that to
            // zero for friend-broadcast triggered re-renders.
            let nextTrailState = MapTrailLayerState(
                graphFingerprint: inputs.graph?.fingerprint,
                showDebugLayers: inputs.showDebugLayers
            )
            let graphChanged = nextTrailState.graphFingerprint != lastTrailLayerState?.graphFingerprint
            let trailStateChanged = nextTrailState != lastTrailLayerState

            if trailStateChanged {
                lastTrailLayerState = nextTrailState

                if let graph = inputs.graph {
                    let trailGeoJSON = GeoJSONBuilder.trailFeatures(from: graph)
                    updateSource(map, id: SourceID.trails, data: trailGeoJSON)

                    let liftGeoJSON = GeoJSONBuilder.liftFeatures(from: graph)
                    updateSource(map, id: SourceID.lifts, data: liftGeoJSON)

                    // Walk/connector edges — always on (subtle) so trails that route via traverses don’t look disconnected.
                    let traverseGeoJSON = GeoJSONBuilder.traverseFeatures(from: graph)
                    updateSource(map, id: SourceID.traverses, data: traverseGeoJSON)

                    if inputs.showDebugLayers {
                        let deadEndGeoJSON = GeoJSONBuilder.deadEndNodeFeatures(from: graph)
                        updateSource(map, id: SourceID.deadEnds, data: deadEndGeoJSON)

                        let phantomGeoJSON = GeoJSONBuilder.phantomTrailFeatures(from: graph)
                        updateSource(map, id: SourceID.phantomTrails, data: phantomGeoJSON)
                    } else {
                        let emptyFC = GeoJSONBuilder.emptyFeatureCollection()
                        updateSource(map, id: SourceID.deadEnds, data: emptyFC)
                        updateSource(map, id: SourceID.phantomTrails, data: emptyFC)
                    }
                    let poiGeoJSON = GeoJSONBuilder.poiFeatures(from: graph)
                    updateSource(map, id: SourceID.pois, data: poiGeoJSON)

                    let liftEndpointsGJ = GeoJSONBuilder.liftEndpointFeatures(from: graph)
                    updateSource(map, id: SourceID.liftEndpoints, data: liftEndpointsGJ)

                    // Kick the gondola animation when the graph has any open
                    // lifts; idempotent — safe to call every graph change.
                    if graph.lifts.contains(where: { $0.attributes.isOpen }) {
                        startGondolaAnimation()
                    } else {
                        stopGondolaAnimation()
                    }

                    let baseEle = graph.nodes.values
                        .filter { $0.elevation > 0 }
                        .map(\.elevation)
                        .min() ?? 2000
                    let tempGJ = GeoJSONBuilder.temperatureFeatures(
                        from: graph,
                        baseTemperatureC: inputs.temperatureC,
                        baseElevationM: baseEle
                    )
                    updateSource(map, id: SourceID.temperature, data: tempGJ)
                } else {
                    let emptyFC = GeoJSONBuilder.emptyFeatureCollection()
                    updateSource(map, id: SourceID.traverses, data: emptyFC)
                    updateSource(map, id: SourceID.pois, data: emptyFC)
                    updateSource(map, id: SourceID.liftEndpoints, data: emptyFC)
                    updateSource(map, id: SourceID.temperature, data: emptyFC)
                }
            }

            // Routes + meeting node — single state struct, but per-field
            // diff so a route-A-only change doesn't pay route-B's GeoJSON
            // cost. The struct exists for compile-time field-membership
            // safety (the compiler enforces "if you add a route field,
            // decide whether it triggers a refresh"); the per-field
            // comparison preserves the original granular rebuild.
            let nextRouteState = MapRouteLayerState(
                routeAEdgeIds: inputs.routeA?.map(\.id) ?? [],
                routeBEdgeIds: inputs.routeB?.map(\.id) ?? [],
                meetingNode: inputs.meetingNode.map(MapRouteLayerState.MeetingNodeKey.init)
            )

            if nextRouteState.routeAEdgeIds != lastRouteLayerState?.routeAEdgeIds {
                if let routeA = inputs.routeA, !routeA.isEmpty {
                    let gj = GeoJSONBuilder.routeFeatures(
                        edges: routeA,
                        skierLabel: "A",
                        colorHex: HUDTheme.mapboxRouteAHex,
                        graph: inputs.graph
                    )
                    updateSource(map, id: SourceID.routeA, data: gj)
                } else {
                    let empty = GeoJSONBuilder.emptyFeatureCollection()
                    updateSource(map, id: SourceID.routeA, data: empty)
                }
            }

            if nextRouteState.routeBEdgeIds != lastRouteLayerState?.routeBEdgeIds {
                if let routeB = inputs.routeB, !routeB.isEmpty {
                    let gj = GeoJSONBuilder.routeFeatures(
                        edges: routeB,
                        skierLabel: "B",
                        colorHex: HUDTheme.mapboxRouteBHex,
                        graph: inputs.graph
                    )
                    updateSource(map, id: SourceID.routeB, data: gj)
                } else {
                    let empty = GeoJSONBuilder.emptyFeatureCollection()
                    updateSource(map, id: SourceID.routeB, data: empty)
                }
            }

            if nextRouteState.meetingNode != lastRouteLayerState?.meetingNode {
                if let meetingNode = inputs.meetingNode {
                    let gj = GeoJSONBuilder.meetingPointFeature(node: meetingNode)
                    updateSource(map, id: SourceID.meetingPoint, data: gj)
                    let beam = buildBeamPolygon(around: meetingNode.coordinate)
                    updateSource(map, id: SourceID.meetingBeam, data: beam)
                    startBeamPulse()
                } else {
                    let empty = GeoJSONBuilder.emptyFeatureCollection()
                    updateSource(map, id: SourceID.meetingPoint, data: empty)
                    updateSource(map, id: SourceID.meetingBeam, data: empty)
                    stopBeamPulse()
                }
            }

            lastRouteLayerState = nextRouteState

            // Sun exposure overlay — recalculates when:
            //   • the scrubbed time bucket flips (5 min at rest, 15 min mid-drag)
            //   • the graph changes
            //   • temperature / cloud cover changes (now time-synced to the
            //     scrubbed hour, so the trail tint actually warms/cools
            //     across the day instead of being frozen at "now")
            //   • the user just released the scrub — snap to exact bucket
            let calendar = Calendar.current
            let currentMinute = calendar.component(.hour, from: inputs.selectedTime) * 60
                              + calendar.component(.minute, from: inputs.selectedTime)
            let bucketMinutes = inputs.isScrubbingTimeline ? 15 : 5
            let currentBucket = currentMinute / bucketMinutes
            let scrubReleased = lastIsScrubbing && !inputs.isScrubbingTimeline

            var sunInputHasher = Hasher()
            sunInputHasher.combine(Int(inputs.temperatureC.rounded()))
            sunInputHasher.combine(inputs.cloudCoverPercent / 5)
            let sunInputsHash = sunInputHasher.finalize()

            let sunNeedsRebuild = (currentBucket != lastSunExposureBucket)
                || graphChanged
                || sunInputsHash != lastSunInputsHash
                || scrubReleased

            if sunNeedsRebuild, let graph = inputs.graph {
                lastSunExposureBucket = currentBucket
                lastSunInputsHash = sunInputsHash
                let lat = inputs.resortLatitude ?? 39.6
                let lon = inputs.resortLongitude
                let gj = GeoJSONBuilder.sunExposureFeatures(
                    from: graph,
                    at: inputs.selectedTime,
                    resortLatitude: lat,
                    resortLongitude: lon,
                    temperatureC: inputs.temperatureC,
                    cloudCoverPercent: inputs.cloudCoverPercent
                )
                updateSource(map, id: SourceID.sunExposure, data: gj)
            }
            lastIsScrubbing = inputs.isScrubbingTimeline

            // Ghost skier positions (Phase 4.6) — projected locations along
            // the route at the scrubbed time.
            let ghostHash = ghostPositionsHash(inputs.ghostPositions)
            if ghostHash != lastGhostPositionsHash {
                lastGhostPositionsHash = ghostHash
                if !inputs.ghostPositions.isEmpty {
                    let gj = buildGhostGeoJSON()
                    updateSource(map, id: SourceID.ghostPositions, data: gj)
                } else {
                    let empty = GeoJSONBuilder.emptyFeatureCollection()
                    updateSource(map, id: SourceID.ghostPositions, data: empty)
                }
            }

            // User location dot — GPS fixes land every ~1s, so this is the
            // only source that genuinely re-renders often. Still gate to skip
            // re-writes when Core Location delivers the same coordinate.
            let userHash = userLocationHash(inputs.userLocation)
            if userHash != lastUserLocationHash {
                lastUserLocationHash = userHash
                if let userLoc = inputs.userLocation {
                    let gj = GeoJSONBuilder.userLocationFeature(coordinate: userLoc)
                    updateSource(map, id: SourceID.userLocation, data: gj)
                } else {
                    let empty = GeoJSONBuilder.emptyFeatureCollection()
                    updateSource(map, id: SourceID.userLocation, data: empty)
                }
            }

            // Friend location dots — primary target of this diff: a 5s
            // presence-broadcast re-run shouldn't touch 30 other layers.
            // The struct version (vs the old hand-rolled
            // `friendLocationsHash`) deliberately includes
            // `signalQualities` and the 60s `clock` — both of which the
            // old hash silently dropped at one point, leaving live/stale/
            // cold styling and the 3h cutoff stuck until something else
            // triggered a refresh. The auto-Hashable struct closes that
            // class of bugs.
            let now = Date()
            let nextFriendState = MapFriendLayerState(
                locations: inputs.friendLocations.reduce(into: [:]) { acc, kv in
                    acc[kv.key] = MapFriendLayerState.FriendLocationKey(kv.value, now: now)
                },
                signalQualities: inputs.friendSignalQualities,
                clock: inputs.mapFriendLayerClock
            )
            if nextFriendState != lastFriendLayerState {
                lastFriendLayerState = nextFriendState
                if !inputs.friendLocations.isEmpty {
                    let gj = GeoJSONBuilder.friendLocationFeatures(
                        friends: inputs.friendLocations,
                        graph: inputs.graph,
                        signalQualities: inputs.friendSignalQualities
                    )
                    updateSource(map, id: SourceID.friendLocations, data: gj)
                    startFriendPulse()
                } else {
                    let empty = GeoJSONBuilder.emptyFeatureCollection()
                    updateSource(map, id: SourceID.friendLocations, data: empty)
                    stopFriendPulse()
                }
            }

            // Replay trails + positions
            let replayTrailsHash = replayTrailsSnapshotHash(inputs.replayTrails)
            if replayTrailsHash != lastReplayTrailsHash {
                lastReplayTrailsHash = replayTrailsHash
                if !inputs.replayTrails.isEmpty {
                    let gj = buildReplayTrailsGeoJSON()
                    updateSource(map, id: SourceID.replayTrails, data: gj)
                } else {
                    let empty = GeoJSONBuilder.emptyFeatureCollection()
                    updateSource(map, id: SourceID.replayTrails, data: empty)
                }
            }

            let replayPositionsHash = replayPositionsSnapshotHash(inputs.replayPositions)
            if replayPositionsHash != lastReplayPositionsHash {
                lastReplayPositionsHash = replayPositionsHash
                if !inputs.replayPositions.isEmpty {
                    let gj = buildReplayPositionsGeoJSON()
                    updateSource(map, id: SourceID.replayPositions, data: gj)
                } else {
                    let empty = GeoJSONBuilder.emptyFeatureCollection()
                    updateSource(map, id: SourceID.replayPositions, data: empty)
                }
            }

            // Selected trail highlight — gated on selection id change.
            if inputs.selectedEdgeId != lastSelectedEdgeId {
                lastSelectedEdgeId = inputs.selectedEdgeId
                if let selectedEdgeId = inputs.selectedEdgeId, let graph = inputs.graph {
                    let groupEdges = graph.edgesInGroup(selectedEdgeId)
                    let edgesToHighlight = groupEdges.isEmpty
                        ? (graph.edge(byID: selectedEdgeId).map { [$0] } ?? [])
                        : groupEdges

                    if !edgesToHighlight.isEmpty {
                        let representative = edgesToHighlight.first!
                        // Chain all group edges into one consolidated LineString
                        let rawCoords = GeoJSONBuilder.chainGeometryPublic(edgesToHighlight, graph: graph)
                        let coords = rawCoords // Already smoothed in display layer

                        let gj: [String: Any] = [
                            "type": "FeatureCollection",
                            "features": [[
                                "type": "Feature",
                                "properties": [
                                    "color": GeoJSONBuilder.colorHex(for: representative.attributes.difficulty)
                                ] as [String: Any],
                                "geometry": [
                                    "type": "LineString",
                                    "coordinates": coords
                                ] as [String: Any]
                            ]]
                        ]
                        updateSource(map, id: SourceID.selectedTrail, data: gj)
                    } else {
                        let empty = GeoJSONBuilder.emptyFeatureCollection()
                        updateSource(map, id: SourceID.selectedTrail, data: empty)
                    }
                } else {
                    // Clear selection
                    let empty = GeoJSONBuilder.emptyFeatureCollection()
                    updateSource(map, id: SourceID.selectedTrail, data: empty)
                }
            }

            // Temperature overlay visibility toggle
            let tempOpacity = inputs.mapBridge?.showTemperatureOverlay == true ? 0.25 : 0.0
            try? map.setLayerProperty(for: LayerID.temperature, property: "line-opacity", value: tempOpacity)

            // Dynamic sky sun position — tie sky layer to actual solar azimuth/altitude
            updateSkyLayerSunPosition(map)

            // Snow particle overlay
            updateSnowEmitter()

            // Trigger route animation if routes changed
            checkAndAnimateRoutes()
        }

        // MARK: - Diff Hashes
        //
        // The trail / friend / route diffs migrated to Hashable state
        // structs in `MapLayerState.swift`. The remaining hashes below
        // cover sources that didn't fit the three
        // logical layer groups — they're each used in exactly one place
        // and are simple enough that the Hasher walk is at least as
        // readable as a state struct would be.

        private func userLocationHash(_ coord: CLLocationCoordinate2D?) -> Int {
            guard let c = coord else { return 0 }
            var hasher = Hasher()
            hasher.combine(Int(c.latitude * 1e6))
            hasher.combine(Int(c.longitude * 1e6))
            return hasher.finalize()
        }

        private func replayPositionsSnapshotHash(_ positions: [UUID: CLLocationCoordinate2D]) -> Int {
            var hasher = Hasher()
            for id in positions.keys.sorted(by: { $0.uuidString < $1.uuidString }) {
                guard let c = positions[id] else { continue }
                hasher.combine(id)
                hasher.combine(Int(c.latitude * 1e6))
                hasher.combine(Int(c.longitude * 1e6))
            }
            return hasher.finalize()
        }

        private func replayTrailsSnapshotHash(_ trails: [UUID: [CLLocationCoordinate2D]]) -> Int {
            var hasher = Hasher()
            for id in trails.keys.sorted(by: { $0.uuidString < $1.uuidString }) {
                guard let coords = trails[id] else { continue }
                hasher.combine(id)
                hasher.combine(coords.count)
                if let last = coords.last {
                    hasher.combine(Int(last.latitude * 1e6))
                    hasher.combine(Int(last.longitude * 1e6))
                }
            }
            return hasher.finalize()
        }

        private func ghostPositionsHash(_ ghosts: [UUID: [(coordinate: CLLocationCoordinate2D, label: String)]]) -> Int {
            var hasher = Hasher()
            for id in ghosts.keys.sorted(by: { $0.uuidString < $1.uuidString }) {
                guard let trail = ghosts[id] else { continue }
                hasher.combine(id)
                hasher.combine(trail.count)
                for g in trail {
                    hasher.combine(Int(g.coordinate.latitude * 1e6))
                    hasher.combine(Int(g.coordinate.longitude * 1e6))
                    hasher.combine(g.label)
                }
            }
            return hasher.finalize()
        }

        /// Internal so animation/style extensions can update sources without
        /// duplicating the JSON marshalling + error-logging here.
        func updateSource(_ map: MapboxMap, id: String, data: [String: Any]) {
            do {
                let jsonData = try JSONSerialization.data(withJSONObject: data)
                let geojsonObject = try JSONDecoder().decode(GeoJSONObject.self, from: jsonData)
                map.updateGeoJSONSource(withId: id, geoJSON: geojsonObject)
            } catch {
                // Silent failure here manifested as "a layer is stuck stale
                // and nobody can tell why." Log with source ID so the hash
                // gate's owner is traceable.
                AppLog.mapSourceUpdateFailed(id: id, error: error)
            }
        }

    }

}

// `UIColor.init(hex:)` lives in Utilities/UIColor+Hex.swift
