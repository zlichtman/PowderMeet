import CoreLocation
import MapScene
// Some map APIs used here sit behind the SDK's Experimental SPI.
@_spi(Experimental) @preconcurrency import MapboxMaps
import MountainCore
import PMLogging
import UIKit

/// Owns one Mapbox map and is the only thing that talks to it.
///
/// Sources and layers are created once per style load. A `RenderModel` is turned
/// into a `SceneDiff` against the last one applied, and the diff is applied as:
/// new source data only when the bundle changed, feature-state for closed
/// segments and the meeting point, and whole replacement of the four
/// small dynamic sources. A status change therefore sends no geometry to Mapbox.
@MainActor
public final class MapboxMapController {
    /// The view to put on screen. Its camera belongs to this controller.
    public let mapView: MapView
    /// Taps, camera rest and style lifecycle. One consumer.
    public let events: AsyncStream<MapEvent>

    private let eventSink: AsyncStream<MapEvent>.Continuation
    private let log: PMLog
    private let camera: CameraQueue
    private let gestures: GestureObserver
    private let probe: MapLoadProbe
    private let attribution: MapAttribution
    private var subscriptions: Set<AnyCancelable> = []

    private var styleReady = false
    private var styleRetries = 0
    /// The base style failed after its retries and the plain one is loaded
    /// (`MapStyle.fallbackStyleJSON`) until `reloadStyle` brings it back.
    private var onFallbackStyle = false
    private var retryTask: Task<Void, Never>?
    private var revealTask: Task<Void, Never>?
    /// The newest model handed over, and the one currently on the map.
    private var latest: RenderModel?
    private var applied: RenderModel?
    /// A resort's sources as GeoJSON text, written off the main actor, kept
    /// for a style reload; and the geometry being written now.
    private var encoded: (geometry: SceneGeometry, text: [String])?
    private var encoding: SceneGeometry?
    private var encodeTask: Task<Void, Never>?
    /// `MapEvent.styleLoaded` promises the latest model is on screen, so a
    /// load that waits for its text is announced once the text is applied.
    private var styleAnnouncementPending = false
    private var following = false
    private var obscured = MapObscuredArea()
    /// The mountain the opening camera move was last made for.
    private var introduced: SceneFrame?
    /// The user has panned or pinched this map at least once.
    private var userMovedCamera = false
    /// The user position the camera was last sent to while following.
    private var lastFollowed: Coordinate?
    /// What the camera was last aimed at on request (a place, or the routes),
    /// while it is still there: when the covered area changes (a tray opens over
    /// the map), it is aimed again at what is left.
    private var lastAim: Aim?
    private enum Aim: Equatable {
        case center(Coordinate)
        case routes
    }
    private var refocusTask: Task<Void, Never>?
    /// `MapCommand.captureTaps`: the feature taps step aside for the map-wide one.
    private var capturesTaps = false
    /// Settings → Maps → Fly in: a new mountain is reached by the long
    /// descending orbit rather than the short turn.
    private var flyIn = false
    /// The weather at the timeline's hour, and whether its snow may move
    /// (the map is what the user is looking at).
    private var weather = WeatherEffect.clear
    private var weatherMoves = false
    /// The falling snow, over the map rather than in it (`SnowField`).
    private let snowField = SnowField()
    /// Place and lift-station icons are hidden while a route is drawn.
    private var clutterHidden = false
    /// Reduce Motion, Low Power Mode and the app leaving the screen turn the
    /// snow off and back on.
    private var systemObservers: [NSObjectProtocol] = []
    /// The sky's colours as last set (`MapStyle.skyKey`); nil after a style load.
    private var skyKey: [Int]?
    /// Settings → Appearance → Map, and the theme's accent.
    private var appearance = MapAppearance.standard
    #if DEBUG
    /// Frames Mapbox drew, counted per five seconds (`logFramePacing`).
    private var framesDrawn = 0
    private var framesTask: Task<Void, Never>?
    #endif

    /// Call once at launch, before the first map is created, with the public
    /// token from `Secrets.xcconfig`.
    public static func configure(accessToken: String) {
        MapboxOptions.accessToken = accessToken
    }

    /// - Parameter initialFrame: where the camera sits before the first model
    ///   arrives (the catalog row's frame), so the map never opens on open ocean.
    public init(initialFrame: SceneFrame? = nil, log: PMLog = PMLog()) {
        self.log = log
        (events, eventSink) = AsyncStream.makeStream(of: MapEvent.self, bufferingPolicy: .bufferingNewest(64))

        let start = initialFrame.map {
            CameraOptions(
                center: CLLocationCoordinate2D(latitude: $0.center.lat, longitude: $0.center.lon),
                zoom: $0.zoom, bearing: $0.bearing, pitch: $0.pitch)
        }
        // A zero frame makes the SDK fall back to 64×64 and stumble on first load;
        // layout replaces this size a moment later.
        // No multisampling (owner, 21 Nov). With 4× MSAA on the 3D terrain the
        // SDK left pinholes where symbol glyphs are drawn, even hidden ones
        // (every segment's closed label and every place's meeting label sit
        // at opacity 0): the sky showed through as white or light specks near
        // runs and lifts, flickering with every pan and zoom, on every look.
        // Tinting every layer did not colour them; they took the atmosphere's
        // colour, and black with the atmosphere removed. With one sample they
        // are gone; lines and labels are a little less smooth.
        mapView = MapView(
            frame: CGRect(x: 0, y: 0, width: 390, height: 844),
            mapInitOptions: MapInitOptions(
                cameraOptions: start, styleURI: MapStyle.styleURI, antialiasingSampleCount: 1))
        camera = CameraQueue(mapView: mapView, log: log)
        // The scale bar only adds clutter on a tilted 3D view, and the app draws
        // its own reset-north button where the compass would sit.
        mapView.ornaments.options.scaleBar.visibility = .hidden
        mapView.ornaments.options.compass.visibility = .hidden
        // The Mapbox logo with the ⓘ beside it, centred at the bottom.
        attribution = MapAttribution(mapView: mapView)
        gestures = GestureObserver()
        probe = MapLoadProbe(map: mapView.mapboxMap, log: log)
        probe.onFirstLoad = { [weak self] timing in
            self?.eventSink.yield(.firstLoad(timing))
        }

        snowField.frame = mapView.bounds
        // Attribution inserts a layout sentinel at index zero, below the map.
        // Anchor to the actual logo so flakes stay above the drawing and below credits.
        mapView.insertSubview(snowField, belowSubview: mapView.ornaments.logoView)

        gestures.onBegin = { [weak self] in self?.userTookCamera() }
        mapView.gestures.delegate = gestures

        let map: MapboxMap = mapView.mapboxMap
        map.onStyleLoaded.observe { [weak self] _ in
            MainActor.assumeIsolated { self?.styleLoaded() }
        }.store(in: &subscriptions)
        map.onMapLoadingError.observe { [weak self] event in
            let isStyle = event.type == .style
            let message = event.message
            MainActor.assumeIsolated { self?.loadingFailed(style: isStyle, message: message) }
        }.store(in: &subscriptions)
        map.onMapIdle.observe { [weak self] _ in
            MainActor.assumeIsolated { self?.cameraCameToRest() }
        }.store(in: &subscriptions)

        let center = NotificationCenter.default
        for name in [
            UIAccessibility.reduceMotionStatusDidChangeNotification,
            Notification.Name.NSProcessInfoPowerStateDidChange,
            UIApplication.didEnterBackgroundNotification,
            UIApplication.willEnterForegroundNotification,
        ] {
            systemObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshSnow() }
            })
        }

        #if DEBUG
        logFramePacing(map)
        #endif
    }

    // MARK: Input

    /// Shows a model. Cheap to call often: only the difference from the model on
    /// screen reaches Mapbox.
    public func apply(_ model: RenderModel) {
        latest = model
        guard styleReady else { return }
        let diff = SceneDiffer.diff(old: applied, new: model)
        if let geometry = diff.geometry, encoded?.geometry != geometry {
            // A new mountain waits for its text; what arrives meanwhile is
            // kept in `latest`.
            encode(geometry)
            return
        }
        applied = model
        guard !diff.isEmpty else { return }
        apply(diff, of: model)
    }

    /// Writing a whole resort as GeoJSON takes long enough to drop frames, so
    /// it runs off the main actor; the newest model is then applied with it.
    private func encode(_ geometry: SceneGeometry) {
        guard encoding != geometry else { return }
        encoding = geometry
        encodeTask?.cancel()
        encodeTask = Task { [weak self] in
            let text = await Task.detached(priority: .userInitiated) {
                geometry.sources.map { $0.geoJSON() }
            }.value
            guard let self, !Task.isCancelled, self.encoding == geometry else { return }
            self.encoding = nil
            self.encoded = (geometry, text)
            if let latest = self.latest { self.apply(latest) }
            if self.styleAnnouncementPending { self.announceStyle() }
        }
    }

    public func send(_ command: MapCommand) {
        switch command {
        case .showResort:
            guard let frame = applied?.frame else { return }
            lastAim = nil
            setFollowing(false)
            camera.submit(.pose(frame))
        case .focus(let coordinate):
            setFollowing(false)
            camera.submit(.center(coordinate))
            lastAim = .center(coordinate)
        case .showRoute:
            guard let model = applied else { return }
            lastAim = nil
            setFollowing(false)
            if model.routePreview.count >= 2 {
                camera.submit(.frame(
                    model.routePreview, bearing: mapView.mapboxMap.cameraState.bearing))
                lastAim = .routes
            }
            if !model.routeA.isEmpty || !model.routeB.isEmpty { startRouteReveal() }
        case .follow(let on):
            if on { lastAim = nil }
            setFollowing(on)
            if on, let user = userCoordinate(applied) {
                camera.submit(.center(user))
                lastFollowed = user
            }
        case .recenter:
            if let user = userCoordinate(applied) {
                camera.submit(.center(user))
            } else if let frame = applied?.frame {
                camera.submit(.pose(frame))
            }
        case .resetNorth:
            camera.submit(.bearing(0))
        case .reloadStyle:
            styleRetries = 0
            onFallbackStyle = false
            // The plain style may be up: the new load replaces it, and its
            // failures count toward the retries again.
            styleReady = false
            mapView.mapboxMap.loadStyle(MapStyle.styleURI)
        case .captureTaps(let on):
            capturesTaps = on
        }
    }

    /// What the app's floating controls cover. A pose or framing uses it from the
    /// next camera move; a place just centred on is centred again once the
    /// covered area has settled, so a tray opening over it does not hide it.
    public func setObscured(_ area: MapObscuredArea) {
        attribution.setBottom(area.badgeBottom)
        guard area != obscured else { return }
        obscured = area
        camera.obscured = UIEdgeInsets(top: area.top, left: 0, bottom: area.bottom, right: 0)
        guard let aim = lastAim else { return }
        refocusTask?.cancel()
        refocusTask = Task { [weak self] in
            // Heights change frame by frame while a card animates in.
            do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
            guard let self, self.lastAim == aim, !self.following else { return }
            switch aim {
            case .center(let coordinate):
                self.camera.submit(.center(coordinate))
            case .routes:
                guard let preview = self.applied?.routePreview, preview.count >= 2 else { return }
                self.camera.submit(.frame(preview, bearing: self.mapView.mapboxMap.cameraState.bearing))
            }
        }
    }

    /// Debug stills only: the Mapbox logo and ⓘ off the map, the credit
    /// carried as text beside the image instead.
    public func setAttributionHidden(_ hidden: Bool) {
        attribution.setHidden(hidden)
    }

    /// The camera now, for a compass.
    public var cameraSnapshot: MapCameraSnapshot {
        let state = mapView.mapboxMap.cameraState
        return MapCameraSnapshot(
            center: Coordinate(lon: state.center.longitude, lat: state.center.latitude),
            zoom: state.zoom, bearing: state.bearing, pitch: state.pitch)
    }

    /// Stops the controller's own work. Call when the view leaves the hierarchy.
    public func shutdown() {
        retryTask?.cancel()
        revealTask?.cancel()
        refocusTask?.cancel()
        encodeTask?.cancel()
        #if DEBUG
        framesTask?.cancel()
        #endif
        subscriptions.removeAll()
        for observer in systemObservers { NotificationCenter.default.removeObserver(observer) }
        systemObservers = []
        snowField.stop()
        eventSink.finish()
    }

    // MARK: Applying a diff

    private func apply(_ diff: SceneDiff, of model: RenderModel) {
        let map: MapboxMap = mapView.mapboxMap

        // `apply(_:)` lets a diff with geometry through only once `encoded`
        // holds its text.
        if let geometry = diff.geometry, let encoded {
            for (source, text) in zip(geometry.sources, encoded.text) {
                map.updateGeoJSONSource(withId: source.id.rawValue, data: .string(text))
                // State set for the previous resort's features must not leak.
                if MapStyle.stateSources.contains(source.id) {
                    map.resetFeatureStates(sourceId: source.id.rawValue, sourceLayerId: nil) { _ in }
                }
            }
            log.info(.map, "scene geometry applied: \(geometry.sources.reduce(0) { $0 + $1.features.count }) features")
        }

        // The SDK has no call that sets state on many features at once, so
        // only the sources a layer reads state from are sent (`stateSources`).
        for change in diff.states where MapStyle.stateSources.contains(change.source) {
            map.setFeatureState(
                sourceId: change.source.rawValue, sourceLayerId: nil, featureId: change.featureID,
                state: change.state.mapValues(\.json)
            ) { _ in }
        }

        for overlay in diff.overlays {
            map.updateGeoJSONSource(
                withId: overlay.source.rawValue,
                data: .string(GeoJSONWriter.featureCollection(overlay.features)))
        }

        if let environment = diff.environment {
            let key = MapStyle.skyKey(environment) + weather.skyKey
            MapStyle(map: map, log: log, appearance: appearance, weather: weather)
                .applyLighting(environment, sky: key != skyKey)
            skyKey = key
        }

        if let frame = diff.frame {
            do { try camera.restrict(to: frame) } catch {
                log.error(.map, "camera bounds rejected: \(error.localizedDescription)")
            }
            // Only a new mountain moves the camera by itself. The same
            // mountain redrawn (its runs recoloured by the skier's history, a
            // newer copy of its map) keeps the view the user has since moved.
            if diff.hasGeometry, frame != introduced {
                let firstView = introduced == nil
                introduced = frame
                // The map opens on the mountain already (its initial camera):
                // a skier who has started panning before the runs arrive keeps
                // their view.
                if !(firstView && userMovedCamera) {
                    setFollowing(false)
                    camera.submit(.intro(frame, cinematic: flyIn && !ProcessInfo.processInfo.isLowPowerModeEnabled))
                }
            }
        }

        let routed = !model.routeA.isEmpty || !model.routeB.isEmpty
        if routed != clutterHidden {
            clutterHidden = routed
            for layer in MapLayerID.routeClutter where map.layerExists(withId: layer) {
                do {
                    try map.setLayerProperty(for: layer, property: "visibility", value: routed ? "none" : "visible")
                } catch {
                    log.error(.map, "route clutter: \(error.localizedDescription)")
                }
            }
        }

        if diff.replayRouteReveal {
            startRouteReveal()
        } else if model.routeA.isEmpty, model.routeB.isEmpty {
            revealTask?.cancel()
        }

        if following, diff.overlays.contains(where: { $0.source == .user }) {
            followUser()
        }
    }

    // MARK: Weather

    /// The weather at the timeline's hour (`WeatherEffect`), applied straight
    /// to the map (like `setFlyIn`), never through the scene, so nothing else
    /// is re-applied; a no-op unless it changes. Cloud and haze are light and
    /// fog, set once per change. Snow, falling or blown off the ground, moves
    /// only while `moves` (nothing covers the map) and never under Reduce
    /// Motion, Low Power Mode or in the background.
    public func setWeather(_ new: WeatherEffect, moves: Bool) {
        guard new != weather || moves != weatherMoves else { return }
        let lightChanged = new.skyKey != weather.skyKey
        weather = new
        weatherMoves = moves
        if lightChanged, styleReady, let environment = applied?.environment {
            MapStyle(map: mapView.mapboxMap, log: log, appearance: appearance, weather: new)
                .applyLighting(environment, sky: true)
            skyKey = MapStyle.skyKey(environment) + new.skyKey
        }
        refreshSnow()
    }

    private func refreshSnow() {
        let allowed = weatherMoves && styleReady && !UIAccessibility.isReduceMotionEnabled
            && !ProcessInfo.processInfo.isLowPowerModeEnabled
            && UIApplication.shared.applicationState != .background
        // A scrub out of the snow lets the flakes in the air fall out of
        // view; anything else (a panel over the map, Reduce Motion, the
        // background) stops it at once.
        if !allowed {
            snowField.stop()
        } else if weather.hasParticles {
            snowField.show(weather.snowFall(on: appearance.look))
        } else {
            snowField.clear()
        }
    }

    // MARK: Fly in

    /// Settings → Maps → Fly in, for the next mountain opened.
    public func setFlyIn(_ on: Bool) {
        flyIn = on
    }

    // MARK: Look

    /// The photos on the people markers (`MapPhotos`). Kept, so a reloaded
    /// style gets them back.
    private var photos = MapPhotos()

    /// People's photos for their markers: added, replaced or removed as style
    /// images, which the photo layers name.
    public func setPhotos(_ new: MapPhotos) {
        guard new != photos else { return }
        let old = photos
        photos = new
        guard styleReady else { return }
        applyPhotos(replacing: old)
    }

    private func applyPhotos(replacing old: MapPhotos) {
        let map: MapboxMap = mapView.mapboxMap
        for key in old.images.keys where photos.images[key] == nil {
            let id = MapPhotos.prefix + key
            if map.imageExists(withId: id) {
                do { try map.removeImage(withId: id) } catch { log.notice(.map, "photo not removed: \(error)") }
            }
        }
        for (key, image) in photos.images where old.images[key] !== image || !map.imageExists(withId: MapPhotos.prefix + key) {
            do {
                try map.addImage(MapPhotos.marker(image, isMe: key == MapPhotos.me), id: MapPhotos.prefix + key)
            } catch {
                log.notice(.map, "photo not added: \(error)")
            }
        }
    }

    /// Settings → Appearance → Map, or a new theme accent. Applied in place:
    /// paint and visibility on the loaded style, never a reload. Before the
    /// style is ready it is kept for `styleLoaded`.
    public func setAppearance(_ new: MapAppearance) {
        guard new != appearance else { return }
        appearance = new
        probe.look = new.look
        guard styleReady else { return }
        let style = MapStyle(map: mapView.mapboxMap, log: log, appearance: new, weather: weather)
        style.applyLook()
        if let environment = applied?.environment {
            style.applyLighting(environment, sky: true)
            skyKey = MapStyle.skyKey(environment) + weather.skyKey
        }
        // The flakes take the new ground's colour.
        refreshSnow()
    }

    #if DEBUG
    /// A timing log without Instruments: how many frames Mapbox drew in each
    /// five seconds the map drew anything. A map at rest draws none; anything
    /// that keeps it drawing (an animation, a paint property changed on a
    /// timer) shows here as a steady count.
    private func logFramePacing(_ map: MapboxMap) {
        map.onRenderFrameFinished.observe { [weak self] _ in
            MainActor.assumeIsolated { self?.framesDrawn += 1 }
        }.store(in: &subscriptions)
        framesTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
                guard let self else { return }
                if framesDrawn > 0 { log.info(.map, "map frames: \(framesDrawn) in 5 s") }
                framesDrawn = 0
            }
        }
    }
    #endif

    // MARK: Style lifecycle

    private func styleLoaded() {
        let map: MapboxMap = mapView.mapboxMap
        styleRetries = 0
        MapStyle(map: map, log: log, appearance: appearance).install()
        installTaps(on: map)
        styleReady = true
        probe.styleLoaded()
        // A (re)loaded style is empty: everything in the latest model is new.
        applied = nil
        skyKey = nil
        // Nor any photos.
        applyPhotos(replacing: MapPhotos())
        // Snow waited for a style to fall over.
        refreshSnow()
        clutterHidden = false
        if let latest { apply(latest) }
        styleAnnouncementPending = true
        announceStyle()
    }

    /// Sends `styleLoaded` once the style is up and the latest model is drawn.
    private func announceStyle() {
        guard styleReady, encoding == nil else { return }
        styleAnnouncementPending = false
        eventSink.yield(.styleLoaded)
        // On the plain ground the imagery is still missing: the app keeps
        // offering to try it again.
        if onFallbackStyle { eventSink.yield(.styleFailed) }
    }

    private func loadingFailed(style: Bool, message: String) {
        log.error(.map, "map loading error: \(Self.withoutToken(message))")
        guard style, !styleReady else { return }
        guard !onFallbackStyle else {
            eventSink.yield(.styleFailed)
            return
        }
        guard styleRetries < 3 else {
            // Every PowderMeet layer is added on a style load, so without one
            // the map would stay blank: they go on a plain ground instead.
            onFallbackStyle = true
            eventSink.yield(.styleFailed)
            mapView.mapboxMap.loadStyle(MapStyle.fallbackStyleJSON)
            return
        }
        styleRetries += 1
        let delay = Double(styleRetries) * 1.5
        retryTask?.cancel()
        retryTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            guard let self, !self.styleReady else { return }
            self.mapView.mapboxMap.loadStyle(MapStyle.styleURI)
        }
    }

    /// The SDK's message can quote the failing request's URL, access token
    /// and all, and every log line goes public and into the flight recorder.
    nonisolated static func withoutToken(_ message: String) -> String {
        message
            .replacing(#/access_token=[^&\s"')]+/#, with: "access_token=redacted")
            .replacing(#/pk\.[A-Za-z0-9._-]+/#, with: "pk.redacted")
    }

    private func installTaps(on map: MapboxMap) {
        func string(_ feature: FeaturesetFeature, _ key: String) -> String? {
            if case .string(let value) = feature.properties[key] { return value }
            return nil
        }
        for layer in [MapLayerID.friendDots] {
            map.addInteraction(TapInteraction(.layer(layer), radius: 22) { [weak self] feature, _ in
                // Capturing: fall through to the map-wide tap, which has the point.
                guard self?.capturesTaps != true else { return false }
                guard let id = string(feature, "userId").flatMap(UUID.init(uuidString:)) else { return false }
                self?.eventSink.yield(.tappedFriend(id))
                return true
            })
        }
        for layer in [MapLayerID.poiIcons, MapLayerID.meeting] {
            map.addInteraction(TapInteraction(.layer(layer), radius: 22) { [weak self] feature, _ in
                guard self?.capturesTaps != true else { return false }
                guard let id = string(feature, "id") else { return false }
                self?.eventSink.yield(.tappedRendezvous(RendezvousID(id)))
                return true
            })
        }
        // A gloved thumb: a generous radius around trail and lift lines.
        for layer in [MapLayerID.lifts, MapLayerID.trails] {
            map.addInteraction(TapInteraction(.layer(layer), radius: 44) { [weak self] feature, _ in
                guard self?.capturesTaps != true else { return false }
                guard let id = string(feature, "id") else { return false }
                self?.eventSink.yield(.tappedGroup(GroupID(id)))
                return true
            })
        }
        map.addInteraction(TapInteraction { [weak self] context in
            let c = context.coordinate
            self?.eventSink.yield(.tappedMap(Coordinate(lon: c.longitude, lat: c.latitude)))
            return false
        })
    }

    // MARK: Camera

    private func userTookCamera() {
        userMovedCamera = true
        lastAim = nil
        refocusTask?.cancel()
        camera.userInterrupted()
        setFollowing(false)
        eventSink.yield(.userMovedCamera)
    }

    private func cameraCameToRest() {
        probe.idle()
        // A follow step was dropped while another move had the camera (the intro,
        // a framing): take it now. A position already followed is not repeated, so
        // a camera at rest on the user stays at rest.
        if following, let user = userCoordinate(applied), user != lastFollowed { followUser() }
        eventSink.yield(.cameraIdle(cameraSnapshot))
    }

    private func setFollowing(_ on: Bool) {
        guard following != on else { return }
        following = on
        if !on { lastFollowed = nil }
        eventSink.yield(.followingChanged(on))
    }

    private func followUser() {
        guard let user = userCoordinate(applied) else { return }
        if camera.submit(.follow(user)) { lastFollowed = user }
    }

    private func userCoordinate(_ model: RenderModel?) -> Coordinate? {
        if case .point(let coordinate)? = model?.overlays[.user]?.first?.shape { return coordinate }
        return nil
    }

    // MARK: Route reveal

    /// Draws the route on from its start, once, then leaves a solid line; as
    /// the lines near the meeting point, the point drops in (a short fall
    /// with a little overshoot). Progress along a route never replays it.
    /// Bounded: it draws for 1.2 s and stops.
    private func startRouteReveal() {
        revealTask?.cancel()
        guard !UIAccessibility.isReduceMotionEnabled else {
            setRouteTrim(shown: 1)
            return setMeetingDrop(1)
        }
        revealTask = Task { [weak self] in
            let duration = 1.2, dropStart = 0.6, dropDuration = 0.5
            let began = ContinuousClock.now
            while !Task.isCancelled {
                let elapsed = ContinuousClock.now - began
                let seconds = Double(elapsed.components.seconds)
                    + Double(elapsed.components.attoseconds) / 1e18
                let clamped = min(1, seconds / duration)
                self?.setRouteTrim(shown: 1 - pow(1 - clamped, 3))
                self?.setMeetingDrop(max(0, min(1, (seconds - dropStart) / dropDuration)))
                if clamped >= 1, seconds >= dropStart + dropDuration { break }
                do { try await Task.sleep(for: .milliseconds(16)) } catch { break }
            }
            // Cancelled or finished, the line ends fully drawn and the point down.
            self?.setRouteTrim(shown: 1)
            self?.setMeetingDrop(1)
        }
    }

    /// The meeting point `progress` of the way through its drop: from 28 pt
    /// up and invisible to its place, easing out with a slight overshoot.
    private func setMeetingDrop(_ progress: Double) {
        let map: MapboxMap = mapView.mapboxMap
        guard map.layerExists(withId: MapLayerID.meeting) else { return }
        let t = max(0, min(1, progress))
        // easeOutBack
        let c = 1.4
        let eased = 1 + (c + 1) * pow(t - 1, 3) + c * pow(t - 1, 2)
        let lift = (1 - eased) * -28
        do {
            try map.setLayerProperty(for: MapLayerID.meeting, property: "circle-translate", value: [0, lift])
            for layer in [MapLayerID.meeting] {
                try map.setLayerProperty(for: layer, property: "circle-opacity", value: t >= 1
                    ? Self.meetingOpacity : ["*", min(1, t * 2), Self.meetingOpacity])
                try map.setLayerProperty(for: layer, property: "circle-stroke-opacity", value: t >= 1
                    ? Self.meetingOpacity : ["*", min(1, t * 2), Self.meetingOpacity])
            }
        } catch {
            log.error(.map, "meeting drop failed: \(error.localizedDescription)")
        }
    }

    /// The meeting layer's own opacity: shown on the feature marked meeting.
    private static let meetingOpacity: [Any] = [
        "case", ["boolean", ["feature-state", "meeting"], false], 1.0, 0.0,
    ]

    /// Hides the part of each route line beyond `shown` (0...1 of its length).
    private func setRouteTrim(shown: Double) {
        let map: MapboxMap = mapView.mapboxMap
        let trim: [Double] = shown >= 1 ? [0, 0] : [shown, 1]
        for layer in MapLayerID.routeLayers {
            do {
                try map.setLayerProperty(for: layer, property: "line-trim-offset", value: trim)
            } catch {
                log.error(.map, "route trim failed on \(layer): \(error.localizedDescription)")
                revealTask?.cancel()
                return
            }
        }
    }
}

/// Tells the controller when a finger takes the camera. The SDK stops its own
/// camera animations at that moment; the controller's queue has to forget its
/// pending moves and navigation follow has to let go.
@MainActor
private final class GestureObserver: GestureManagerDelegate {
    var onBegin: (() -> Void)?

    // The SDK calls its gesture delegate on the main thread; the protocol does not
    // say so, hence `assumeIsolated`.
    nonisolated func gestureManager(_ gestureManager: GestureManager, didBegin gestureType: GestureType) {
        // A tap is not a camera move.
        let movesCamera = gestureType != .singleTap
        MainActor.assumeIsolated {
            if movesCamera { onBegin?() }
        }
    }

    nonisolated func gestureManager(
        _ gestureManager: GestureManager, didEnd gestureType: GestureType, willAnimate: Bool
    ) {}

    nonisolated func gestureManager(
        _ gestureManager: GestureManager, didEndAnimatingFor gestureType: GestureType
    ) {}
}

extension SceneValue {
    var json: Any {
        switch self {
        case .string(let value): value
        case .number(let value): value
        case .bool(let value): value
        }
    }
}
