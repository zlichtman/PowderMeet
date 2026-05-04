//
//  MountainMapView+Animations.swift
//  PowderMeet
//
//  Animation, ambient-effect, and overlay-builder methods extracted from
//  MountainMapView.swift to keep the primary file focused on the SwiftUI
//  representable + makeUIView/updateUIView wiring + the single
//  source-update path (updateDataLayers).
//
//  Stays in the SAME module as the primary file so all `Coordinator`
//  stored properties (which were demoted from `private` to `internal` in
//  the same commit) are visible here. The `BeamPulseTarget`,
//  `FriendPulseTarget`, and `GondolaTickTarget` @objc shims live here too
//  — they are only used by the animation methods in this file.
//
//  Behaviour-equivalent to the pre-split code; verify with the
//  resort-intro fly-to + active-meetup beam pulse + scrubber sun position
//  smoke checks before touching anything in this file.
//

import Foundation
import UIKit
import CoreLocation
import MapboxMaps
import QuartzCore

extension MountainMapView.Coordinator {

    // MARK: - Dynamic Sky Sun Position & Weather-Tinted Atmosphere

    /// Recomputes sun azimuth/altitude from the scrubbed time and repaints
    /// the sky + atmosphere colors based on the hourly cloud cover and
    /// visibility. The goal is that dragging the scrubber visibly morphs
    /// the whole map's mood: bluebird mornings are warm and deep, stormy
    /// afternoons go flat-gray with tight fog, blue hour turns dusky.
    ///
    /// Bucketed to 5-minute windows at rest / 15-minute while scrubbing
    /// so we're not repainting the atmosphere on every pixel of drag.
    func updateSkyLayerSunPosition(_ map: MapboxMap) {
        let calendar = Calendar.current
        let minute = calendar.component(.hour, from: inputs.selectedTime) * 60
                   + calendar.component(.minute, from: inputs.selectedTime)
        let bucketMinutes = inputs.isScrubbingTimeline ? 15 : 5
        let bucket = minute / bucketMinutes

        let lat = inputs.resortLatitude ?? 39.6
        let lon = inputs.resortLongitude
        let solar = SunExposureCalculator.solarPosition(
            date: inputs.selectedTime, latitude: lat, longitude: lon
        )

        // Sun position: cheap, always push — lets the sky's built-in
        // sun glow track the thumb smoothly.
        try? map.setLayerProperty(
            for: "sky-layer",
            property: "sky-atmosphere-sun",
            value: [solar.azimuth, max(0, solar.altitude)]
        )

        if bucket != lastSkyBucket {
            lastSkyBucket = bucket

            // Sun intensity dims heavily with cloud cover: 0% → clear
            // bluebird (full intensity), 100% → overcast (low punch).
            let cloudDim = 1.0 - Double(inputs.cloudCoverPercent) / 100.0 * 0.75
            let baseIntensity = solar.altitude > 0 ? 5.0 + solar.altitude / 15.0 : 2.0
            let intensity = max(1.0, baseIntensity * cloudDim)
            try? map.setLayerProperty(
                for: "sky-layer",
                property: "sky-atmosphere-sun-intensity",
                value: intensity
            )

            // Recolor the sky atmosphere to match the hour + weather.
            let skyColors = skyPalette(
                solarAltitude: solar.altitude,
                cloudCover: inputs.cloudCoverPercent
            )
            try? map.setLayerProperty(
                for: "sky-layer",
                property: "sky-atmosphere-color",
                value: skyColors.atmosphere
            )
            try? map.setLayerProperty(
                for: "sky-layer",
                property: "sky-atmosphere-halo-color",
                value: skyColors.halo
            )
        }

        // Fog / atmosphere (terrain depth haze) — separate bucket so
        // visibility-driven range updates even when the sky palette
        // hasn't changed.
        if bucket != lastAtmosphereBucket {
            lastAtmosphereBucket = bucket
            applyAtmosphereTint(
                map,
                solarAltitude: solar.altitude,
                cloudCover: inputs.cloudCoverPercent,
                visibilityKm: inputs.visibilityKm
            )
        }
    }

    /// Returns atmospheric colors tuned to both the hour (via solar
    /// altitude) and the weather (cloud cover). Colors are emitted as
    /// `rgba()` strings the Mapbox style property accepts directly.
    private func skyPalette(
        solarAltitude: Double,
        cloudCover: Int
    ) -> (atmosphere: String, halo: String) {
        // Map solar altitude (-20° → sub-horizon, 60° → near zenith) to
        // a warm-cool mix; cloud cover washes the warmth toward gray.
        let altT = max(0.0, min(1.0, (solarAltitude + 10.0) / 70.0))  // 0 = night/dusk, 1 = noon
        let cloudT = max(0.0, min(1.0, Double(cloudCover) / 100.0))

        // Clear-sky ramp: deep navy at night → warm amber at dawn/dusk →
        // bright blue at noon.
        func mix(_ a: Double, _ b: Double, _ t: Double) -> Double { a + (b - a) * t }

        // Night → noon target atmosphere RGB (0..1)
        let nightR = 0.08, nightG = 0.10, nightB = 0.18
        let noonR  = 0.40, noonG  = 0.60, noonB  = 0.92
        var r = mix(nightR, noonR, altT)
        var g = mix(nightG, noonG, altT)
        var b = mix(nightB, noonB, altT)

        // Golden-hour bias near the horizon (altT ~0.1–0.3)
        let goldenBias = max(0.0, 1.0 - abs(altT - 0.2) * 4.0) * 0.25
        r += goldenBias
        g += goldenBias * 0.5

        // Overcast wash — pull toward neutral gray proportional to cloud.
        let grayT = cloudT * 0.75
        r = mix(r, 0.55, grayT)
        g = mix(g, 0.57, grayT)
        b = mix(b, 0.60, grayT)

        let atmos = rgbaString(r: r, g: g, b: b, a: 1.0)

        // Halo is a lighter tint of the atmosphere; under heavy cloud it
        // fades to almost nothing so there's no bright rim on a gray sky.
        let haloA = (1.0 - cloudT * 0.7)
        let halo = rgbaString(
            r: min(1, r + 0.08),
            g: min(1, g + 0.08),
            b: min(1, b + 0.10),
            a: haloA
        )
        return (atmos, halo)
    }

    private func uiColor(r: Double, g: Double, b: Double, a: Double) -> UIColor {
        UIColor(
            red: CGFloat(max(0, min(1, r))),
            green: CGFloat(max(0, min(1, g))),
            blue: CGFloat(max(0, min(1, b))),
            alpha: CGFloat(max(0, min(1, a)))
        )
    }

    /// Applies depth-fog / atmosphere tint to the full map. In-range
    /// values scale with visibility: <2 km visibility tightens fog so
    /// distant terrain washes out, matching real storm haze.
    private func applyAtmosphereTint(
        _ map: MapboxMap,
        solarAltitude: Double,
        cloudCover: Int,
        visibilityKm: Double
    ) {
        let altT = max(0.0, min(1.0, (solarAltitude + 10.0) / 70.0))
        let cloudT = max(0.0, min(1.0, Double(cloudCover) / 100.0))

        // Base low-atmosphere color (near ground) — darkens in stormy
        // conditions, warms at dawn/dusk, cools at noon.
        func mix(_ a: Double, _ b: Double, _ t: Double) -> Double { a + (b - a) * t }
        let baseR = mix(0.06, 0.45, altT)
        let baseG = mix(0.07, 0.55, altT)
        let baseB = mix(0.12, 0.75, altT)
        let stormyR = mix(baseR, 0.32, cloudT * 0.85)
        let stormyG = mix(baseG, 0.36, cloudT * 0.85)
        let stormyB = mix(baseB, 0.42, cloudT * 0.85)

        let highR = mix(0.08, 0.55, altT)
        let highG = mix(0.10, 0.70, altT)
        let highB = mix(0.18, 0.92, altT)
        let highStormyR = mix(highR, 0.45, cloudT * 0.75)
        let highStormyG = mix(highG, 0.48, cloudT * 0.75)
        let highStormyB = mix(highB, 0.55, cloudT * 0.75)

        // Visibility → fog range. 10+ km = clear (default 0.8, 7.0);
        // 5 km = moderate haze; 1 km = whiteout (range clamps in tight).
        let vis = max(0.2, min(20.0, visibilityKm))
        let rangeStart = 0.4 + (vis / 20.0) * 0.6      // 0.4 → 1.0
        let rangeEnd   = 3.0 + (vis / 20.0) * 6.0      // 3.0 → 9.0

        let stars = max(0.0, 0.2 * (1.0 - altT) * (1.0 - cloudT * 0.6))
        let horizon = min(0.3, 0.08 + (1.0 - vis / 10.0) * 0.15)

        var atmosphere = Atmosphere()
        atmosphere.color = .constant(StyleColor(uiColor(r: stormyR, g: stormyG, b: stormyB, a: 1.0)))
        atmosphere.highColor = .constant(StyleColor(uiColor(r: highStormyR, g: highStormyG, b: highStormyB, a: 1.0)))
        atmosphere.range = .constant([rangeStart, rangeEnd])
        atmosphere.starIntensity = .constant(stars)
        atmosphere.horizonBlend = .constant(max(0.08, horizon))
        try? map.setAtmosphere(atmosphere)
    }

    private func rgbaString(r: Double, g: Double, b: Double, a: Double) -> String {
        let rr = Int((max(0, min(1, r)) * 255).rounded())
        let gg = Int((max(0, min(1, g)) * 255).rounded())
        let bb = Int((max(0, min(1, b)) * 255).rounded())
        return "rgba(\(rr), \(gg), \(bb), \(String(format: "%.2f", max(0, min(1, a)))))"
    }

    // MARK: - Snow Particle Overlay

    /// Configures or removes the snow particle emitter based on the
    /// hourly snowfall rate at the scrubbed time. Wind speed and
    /// direction drive the particle velocity + emission angle — so a
    /// still, heavy dump falls straight down and a windy squall streaks
    /// sideways. Called from `updateDataLayers` after every scrub tick.
    ///
    /// Bucketed so a continuous drag doesn't reconfigure the CAEmitter
    /// on every pixel: snowfall is binned to 0.2 cm/hr, wind speed to
    /// 5 kph, wind direction to 15° — all below the threshold where the
    /// emitter visibly changes frame-to-frame.
    func updateSnowEmitter() {
        guard let mapView else { return }

        let paramsHash: Int = {
            var h = Hasher()
            h.combine(Int((inputs.snowfallCmPerHour * 5).rounded()))
            h.combine(Int((inputs.windSpeedKph / 5).rounded()))
            h.combine(inputs.windDirectionDeg / 15)
            h.combine(Int(mapView.bounds.width))
            return h.finalize()
        }()

        if paramsHash == lastSnowParamsHash && snowEmitter != nil { return }
        if paramsHash == lastSnowParamsHash && inputs.snowfallCmPerHour <= 0.1 { return }
        lastSnowParamsHash = paramsHash

        if inputs.snowfallCmPerHour > 0.1 {
            if snowEmitter == nil {
                let emitter = CAEmitterLayer()
                emitter.emitterShape = .line
                emitter.renderMode = .additive

                let cell = CAEmitterCell()
                cell.contents = snowflakeImage()?.cgImage
                cell.birthRate = 0
                cell.lifetime = 8
                cell.scale = 0.04
                cell.scaleRange = 0.02
                cell.alphaSpeed = -0.05
                cell.spin = 0.5
                cell.spinRange = 1.0
                cell.color = UIColor.white.withAlphaComponent(0.8).cgColor

                emitter.emitterCells = [cell]
                mapView.layer.addSublayer(emitter)
                snowEmitter = emitter
            }

            // Density: clamp at 5 cm/hr = whiteout.
            let density = Float(min(inputs.snowfallCmPerHour / 5.0, 1.0))

            // Wind → particle drift. Meteorological wind direction is
            // "the direction the wind comes FROM"; flip by 180° to get
            // the direction snow is *blown toward*.
            let windToward = (Double(inputs.windDirectionDeg) + 180).truncatingRemainder(dividingBy: 360)
            // Treat wind as a horizontal component. East = +x drift in
            // screen space (top-down map). This is a stylized interpretation —
            // the map can be rotated — but it still reads as "windy from
            // that side" which is the effect we want.
            let windRad = windToward * .pi / 180
            let horizontalDrift = sin(windRad)
            // Emission longitude: downward = π; add horizontal lean from wind.
            // 60 km/h max lean = ~30° off vertical.
            let leanRadians = horizontalDrift * min(inputs.windSpeedKph / 60.0, 1.0) * (.pi / 6)
            let baseVelocity: CGFloat = 30
            let windBoost = CGFloat(min(inputs.windSpeedKph, 90) * 0.8)
            let velocity = baseVelocity + windBoost

            snowEmitter?.emitterPosition = CGPoint(x: mapView.bounds.midX, y: -20)
            snowEmitter?.emitterSize = CGSize(width: mapView.bounds.width * 1.8, height: 1)

            if let cell = snowEmitter?.emitterCells?.first {
                cell.birthRate = 30 + density * 170
                cell.velocity = velocity
                cell.velocityRange = velocity * 0.6
                cell.emissionLongitude = .pi + CGFloat(leanRadians)
                // Tighter cone in high wind — streaks align with flow;
                // in calm air, let flakes fan out for a softer fall.
                let calm = 1.0 - min(inputs.windSpeedKph / 60.0, 1.0)
                cell.emissionRange = .pi / 8 + CGFloat(calm) * (.pi / 8)
            }
        } else {
            snowEmitter?.removeFromSuperlayer()
            snowEmitter = nil
        }
    }

    private func snowflakeImage() -> UIImage? {
        let size: CGFloat = 12
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: size, height: size))
        return renderer.image { ctx in
            UIColor.white.setFill()
            ctx.cgContext.fillEllipse(in: CGRect(x: 1, y: 1, width: size - 2, height: size - 2))
        }
    }

    // MARK: - Beam Polygon

    /// 12-sided regular polygon around `center` with ~3m radius. Correct
    /// for all latitudes (scales longitude by cos(lat)). The resulting
    /// `FillExtrusionLayer` extrudes this to 400m for the beam-of-light
    /// effect.
    func buildBeamPolygon(around center: CLLocationCoordinate2D) -> [String: Any] {
        let radiusMeters: Double = 3
        let latDegPerMeter = 1.0 / 111_000.0
        let lonDegPerMeter = 1.0 / (111_000.0 * max(cos(center.latitude * .pi / 180), 0.0001))
        var ring: [[Double]] = []
        let sides = 12
        for i in 0...sides {
            let angle = Double(i) / Double(sides) * 2 * .pi
            let dLat = radiusMeters * sin(angle) * latDegPerMeter
            let dLon = radiusMeters * cos(angle) * lonDegPerMeter
            ring.append([center.longitude + dLon, center.latitude + dLat])
        }
        return [
            "type": "FeatureCollection",
            "features": [[
                "type": "Feature",
                "properties": [:] as [String: Any],
                "geometry": [
                    "type": "Polygon",
                    "coordinates": [ring]
                ] as [String: Any]
            ] as [String: Any]]
        ]
    }

    func buildGhostGeoJSON() -> [String: Any] {
        var features: [[String: Any]] = []
        let colors = ["#38D9FF", "#FF8A3D", "#FBBF24", "#A78BFA", "#10B981"]
        // Assign a sticky color per-UUID the first time we see it. Prior
        // behavior — `i % colors.count` over sorted keys — swapped colors
        // if one skier dropped out mid-session. Keys survive session
        // teardown; cleared when ghostPositions becomes empty.
        if inputs.ghostPositions.isEmpty {
            ghostColorAssignment.removeAll()
            ghostNextColorIndex = 0
        }
        let orderedKeys = inputs.ghostPositions.keys.sorted(by: { $0.uuidString < $1.uuidString })
        for key in orderedKeys {
            guard let trail = inputs.ghostPositions[key] else { continue }
            if ghostColorAssignment[key] == nil {
                ghostColorAssignment[key] = colors[ghostNextColorIndex % colors.count]
                ghostNextColorIndex += 1
            }
            let color = ghostColorAssignment[key] ?? colors[0]
            let lastIdx = trail.count - 1
            for (j, dot) in trail.enumerated() {
                let isHead = (j == lastIdx)
                features.append([
                    "type": "Feature",
                    "properties": [
                        "label": dot.label,
                        "color": color,
                        "isHead": isHead ? 1 : 0
                    ] as [String: Any],
                    "geometry": [
                        "type": "Point",
                        "coordinates": [dot.coordinate.longitude, dot.coordinate.latitude]
                    ] as [String: Any]
                ])
            }
        }
        return ["type": "FeatureCollection", "features": features]
    }

    // MARK: - Visibility-gated pause/resume

    /// Stop every CADisplayLink AND Timer the map owns. Called when the
    /// map tab goes off-screen so we don't burn cycles redrawing
    /// gondolas, beam, friend pulse, route reveal, or meeting pulse
    /// behind the Profile or Meet tab.
    func pauseAnimations() {
        stopGondolaAnimation()
        stopBeamPulse()
        stopFriendPulse()
        // Remember whether the 60Hz route-trim / meeting-pulse timers
        // were mid-animation so `resumeAnimationsIfNeeded` can bring
        // them back from the current position rather than restarting.
        if animationTimer != nil {
            wasRouteAnimating = true
            animationTimer?.invalidate()
            animationTimer = nil
        }
        if meetingPulseTimer != nil {
            wasMeetingPulsing = true
            meetingPulseTimer?.invalidate()
            meetingPulseTimer = nil
        }
    }

    /// Re-evaluate animation triggers from current state. The hash gates
    /// in `updateDataLayers` won't re-fire start* calls if the underlying
    /// data hasn't changed, so we have to do it manually on resume.
    func resumeAnimationsIfNeeded() {
        if let graph = inputs.graph, graph.lifts.contains(where: { $0.attributes.isOpen }) {
            startGondolaAnimation()
        }
        if inputs.meetingNode != nil {
            startBeamPulse()
        }
        if !inputs.friendLocations.isEmpty {
            startFriendPulse()
        }
        // Fast-forward the route-reveal so it snaps to done instead of
        // restarting mid-animation — if the user tabbed away and came
        // back, they've already watched the reveal.
        if wasRouteAnimating {
            wasRouteAnimating = false
            setRouteTrim(1.0)
        }
        // Meeting pulse is purely decorative and short-lived; skip the
        // resume and let the next `startMeetingPulse` (fired by route
        // animation completion) drive it.
        wasMeetingPulsing = false
    }

    // MARK: - Beam Pulse

    func startBeamPulse() {
        guard beamDisplayLink == nil else { return }
        let link = CADisplayLink(target: MountainMapBeamPulseTarget(coordinator: self), selector: #selector(MountainMapBeamPulseTarget.tick))
        link.add(to: .main, forMode: .common)
        beamDisplayLink = link
    }

    func stopBeamPulse() {
        beamDisplayLink?.invalidate()
        beamDisplayLink = nil
    }

    func beamPulseTick() {
        guard let map = mapView?.mapboxMap else { return }
        beamPhase = (beamPhase + 0.04).truncatingRemainder(dividingBy: .pi * 2)
        let opacity = 0.18 + 0.12 * (0.5 + 0.5 * sin(beamPhase))
        try? map.setLayerProperty(for: MountainMapView.LayerID.meetingBeam, property: "fill-extrusion-opacity", value: opacity)
    }

    // MARK: - Gondola Animation

    func startGondolaAnimation() {
        guard gondolaDisplayLink == nil else { return }
        let link = CADisplayLink(target: MountainMapGondolaTickTarget(coordinator: self), selector: #selector(MountainMapGondolaTickTarget.tick))
        link.add(to: .main, forMode: .common)
        gondolaDisplayLink = link
    }

    func stopGondolaAnimation() {
        gondolaDisplayLink?.invalidate()
        gondolaDisplayLink = nil
        guard let map = mapView?.mapboxMap else { return }
        updateSource(map, id: MountainMapView.SourceID.gondolas, data: GeoJSONBuilder.emptyFeatureCollection())
    }

    func gondolaTick() {
        guard let map = mapView?.mapboxMap, let graph = inputs.graph else { return }
        let now = CACurrentMediaTime()
        // Throttle GeoJSON rebuild to 10Hz.
        if now - lastGondolaTick < 0.1 { return }
        lastGondolaTick = now
        // Advance phase: average lift ~600m @ 5m/s = 120s per loop → Δphase = dt/120.
        gondolaPhase = (gondolaPhase + 0.0083).truncatingRemainder(dividingBy: 1.0)
        let gj = GeoJSONBuilder.gondolaFeatures(lifts: graph.lifts, phase: gondolaPhase)
        updateSource(map, id: MountainMapView.SourceID.gondolas, data: gj)
    }

    // MARK: - Friend Motion Pulse

    func startFriendPulse() {
        guard friendPulseDisplayLink == nil else { return }
        let link = CADisplayLink(target: MountainMapFriendPulseTarget(coordinator: self), selector: #selector(MountainMapFriendPulseTarget.tick))
        link.add(to: .main, forMode: .common)
        friendPulseDisplayLink = link
    }

    func stopFriendPulse() {
        friendPulseDisplayLink?.invalidate()
        friendPulseDisplayLink = nil
        guard let map = mapView?.mapboxMap else { return }
        try? map.setLayerProperty(for: MountainMapView.LayerID.friendMotionPulse, property: "circle-opacity", value: 0)
        try? map.setLayerProperty(for: MountainMapView.LayerID.friendMotionPulse, property: "circle-stroke-opacity", value: 0)
    }

    func friendPulseTick() {
        guard let map = mapView?.mapboxMap else { return }
        // 1.8s cycle; t ∈ [0,1] expands ring then fades.
        friendPulsePhase = (friendPulsePhase + 1.0 / (60.0 * 1.8)).truncatingRemainder(dividingBy: 1.0)
        let t = Double(friendPulsePhase)
        let radius = 12.0 + t * 24.0          // 12 → 36pt
        let opacity = (1.0 - t) * 0.38        // fade out as it grows
        try? map.setLayerProperty(for: MountainMapView.LayerID.friendMotionPulse, property: "circle-radius", value: radius)
        try? map.setLayerProperty(for: MountainMapView.LayerID.friendMotionPulse, property: "circle-stroke-opacity", value: opacity)
    }

    // MARK: - Replay GeoJSON Builders

    func buildReplayTrailsGeoJSON() -> [String: Any] {
        var features: [[String: Any]] = []
        for (index, (_, trail)) in inputs.replayTrails.enumerated() {
            let color = replayColors[index % replayColors.count]
            let coords = trail.map { [$0.longitude, $0.latitude] }
            features.append([
                "type": "Feature",
                "properties": ["color": color] as [String: Any],
                "geometry": [
                    "type": "LineString",
                    "coordinates": coords
                ] as [String: Any]
            ])
        }
        return ["type": "FeatureCollection", "features": features]
    }

    func buildReplayPositionsGeoJSON() -> [String: Any] {
        var features: [[String: Any]] = []
        for (index, (_, coord)) in inputs.replayPositions.enumerated() {
            let color = replayColors[index % replayColors.count]
            features.append([
                "type": "Feature",
                "properties": ["color": color] as [String: Any],
                "geometry": [
                    "type": "Point",
                    "coordinates": [coord.longitude, coord.latitude]
                ] as [String: Any]
            ])
        }
        return ["type": "FeatureCollection", "features": features]
    }

    // MARK: - Route Animation

    func checkAndAnimateRoutes() {
        let nextAEdgeIds = inputs.routeA?.map(\.id) ?? []
        let nextBEdgeIds = inputs.routeB?.map(\.id) ?? []
        let hasRoutes = !nextAEdgeIds.isEmpty || !nextBEdgeIds.isEmpty

        let forceReplay = inputs.routeAnimationTrigger != lastAnimationTrigger
        if forceReplay {
            lastAnimationTrigger = inputs.routeAnimationTrigger
        }

        let routesChanged = nextAEdgeIds != lastAnimatedRouteAEdgeIds
                         || nextBEdgeIds != lastAnimatedRouteBEdgeIds
        if routesChanged {
            lastAnimatedRouteAEdgeIds = nextAEdgeIds
            lastAnimatedRouteBEdgeIds = nextBEdgeIds
        }

        if (routesChanged || forceReplay) && hasRoutes {
            startRouteAnimation()
        } else if routesChanged && !hasRoutes {
            stopRouteAnimation()
            stopMeetingPulse()
        } else if hasRoutes, animationTimer == nil {
            // Do not call `setRouteTrim(1)` while the reveal timer is
            // running — frequent `updateDataLayers` ticks would snap the
            // lines fully open and kill the draw animation.
            setRouteTrim(1.0)
        }
    }

    // The map's overview-on-meetup-accept path was removed: every
    // implementation kept landing the camera on a stale or unprimed
    // location subject ("middle of nowhere"), and the user prefers
    // a no-camera-move policy on accept. Route lines still animate
    // in place via `setRouteTrim`; the meeting pin pulses so the
    // user has a visual target to pan to. The unused
    // `frameRoutesForMeetupOverview`, `overviewBearing`,
    // `applyMeetupFollowPuckIfReady`, and the helper functions that
    // only served them (`subsampleForOverview`, `dedupeCoords`,
    // `bearingDegrees`, `isNearMeeting`) lived between this comment
    // and `startRouteAnimation` — see the git history if you need to
    // bring any of them back for a different camera behaviour.

    private func startRouteAnimation() {
        animationTimer?.invalidate()
        meetingPulseTimer?.invalidate()
        animationProgress = 0
        animationStartTime = CACurrentMediaTime()
        // Force the first tick through the dedup guard so trim resets to 0.
        lastRouteTrim = -1
        setRouteTrim(0)
        // No camera framing here. See the meetup-activation block in
        // `updateUIView` for why the post-accept camera is intentionally
        // a no-op — the route draws in place; the user pans to see it.

        animationTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            let elapsed = CACurrentMediaTime() - self.animationStartTime
            let t = min(elapsed / self.animationDuration, 1.0)
            let eased = 1.0 - pow(1.0 - t, 3.0)
            self.animationProgress = eased
            self.setRouteTrim(eased)

            if t >= 1.0 {
                timer.invalidate()
                self.animationTimer = nil
                self.startMeetingPulse()
            }
        }
    }

    private func stopRouteAnimation() {
        animationTimer?.invalidate()
        animationTimer = nil
        setRouteTrim(1.0)
    }

    private func setRouteTrim(_ progress: Double) {
        guard let map = mapView?.mapboxMap else { return }
        // Skip redundant writes. setLayerProperty is cheap per-call but
        // was being hit four times every animation tick (60Hz) plus every
        // unrelated updateDataLayers pass — wasted work once the reveal
        // has settled at 1.0.
        if abs(progress - lastRouteTrim) < 0.001 { return }
        lastRouteTrim = progress
        let trimValue = [0.0, progress]
        try? map.setLayerProperty(for: MountainMapView.LayerID.routeA, property: "line-trim-offset", value: trimValue)
        try? map.setLayerProperty(for: MountainMapView.LayerID.routeAGlow, property: "line-trim-offset", value: trimValue)
        try? map.setLayerProperty(for: MountainMapView.LayerID.routeB, property: "line-trim-offset", value: trimValue)
        try? map.setLayerProperty(for: MountainMapView.LayerID.routeBGlow, property: "line-trim-offset", value: trimValue)
    }

    // MARK: - Meeting Point Pulse

    func startMeetingPulse() {
        guard inputs.meetingNode != nil else { return }
        meetingPulsePhase = 0

        meetingPulseTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] timer in
            guard let self, let map = self.mapView?.mapboxMap else { timer.invalidate(); return }
            self.meetingPulsePhase += 1.0 / 60.0

            let cycleDuration = 0.8
            if self.meetingPulsePhase < cycleDuration {
                let t = self.meetingPulsePhase / cycleDuration
                let radius: Double
                if t < 0.4 {
                    radius = 6 + (24 - 6) * (t / 0.4)
                } else {
                    let settleT = (t - 0.4) / 0.6
                    radius = 24 - (24 - 12) * settleT
                }
                try? map.setLayerProperty(for: MountainMapView.LayerID.meeting, property: "circle-radius", value: radius)

                let pulseRadius = 18 + 20 * t
                let pulseOpacity = 0.18 * (1 - t)
                try? map.setLayerProperty(for: MountainMapView.LayerID.meetingPulse, property: "circle-radius", value: pulseRadius)
                try? map.setLayerProperty(for: MountainMapView.LayerID.meetingPulse, property: "circle-opacity", value: pulseOpacity)
            } else {
                try? map.setLayerProperty(for: MountainMapView.LayerID.meeting, property: "circle-radius", value: 8)
                try? map.setLayerProperty(for: MountainMapView.LayerID.meetingPulse, property: "circle-radius", value: 18)
                try? map.setLayerProperty(for: MountainMapView.LayerID.meetingPulse, property: "circle-opacity", value: 0.18)
                timer.invalidate()
                self.meetingPulseTimer = nil
            }
        }
    }

    func stopMeetingPulse() {
        meetingPulseTimer?.invalidate()
        meetingPulseTimer = nil
    }

    // MARK: - Arrival Bloom (Phase 7.4)

    func startArrivalBloom() {
        guard inputs.meetingNode != nil else { return }
        arrivalBloomPhase = 0
        arrivalBloomTimer?.invalidate()

        arrivalBloomTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] timer in
            guard let self, let map = self.mapView?.mapboxMap else { timer.invalidate(); return }
            self.arrivalBloomPhase += 1.0 / 60.0

            let cycleDuration = 0.9
            if self.arrivalBloomPhase < cycleDuration {
                let t = self.arrivalBloomPhase / cycleDuration
                let radius: Double
                if t < 0.35 {
                    radius = 8 + (60 - 8) * (t / 0.35)
                } else {
                    let settleT = (t - 0.35) / 0.65
                    let eased = 1.0 - pow(1.0 - settleT, 2.0)
                    radius = 60 - (60 - 8) * eased
                }
                try? map.setLayerProperty(for: MountainMapView.LayerID.meeting, property: "circle-radius", value: radius)

                let pulseRadius = 18 + 50 * t
                let pulseOpacity = 0.35 * (1 - t)
                try? map.setLayerProperty(for: MountainMapView.LayerID.meetingPulse, property: "circle-radius", value: pulseRadius)
                try? map.setLayerProperty(for: MountainMapView.LayerID.meetingPulse, property: "circle-opacity", value: pulseOpacity)
            } else {
                try? map.setLayerProperty(for: MountainMapView.LayerID.meeting, property: "circle-radius", value: 8)
                try? map.setLayerProperty(for: MountainMapView.LayerID.meetingPulse, property: "circle-radius", value: 18)
                try? map.setLayerProperty(for: MountainMapView.LayerID.meetingPulse, property: "circle-opacity", value: 0.18)
                timer.invalidate()
                self.arrivalBloomTimer = nil
            }
        }
    }
}

// MARK: - CADisplayLink @objc shim targets
//
// CADisplayLink requires an @objc target. Concrete-class shims (rather
// than the Coordinator itself) keep the display-link reference loop
// breakable via `weak var coordinator`. File-private — only the
// animation methods above use them.

fileprivate final class MountainMapBeamPulseTarget: NSObject {
    weak var coordinator: MountainMapView.Coordinator?
    init(coordinator: MountainMapView.Coordinator) {
        self.coordinator = coordinator
        super.init()
    }
    @objc func tick() {
        coordinator?.beamPulseTick()
    }
}

fileprivate final class MountainMapFriendPulseTarget: NSObject {
    weak var coordinator: MountainMapView.Coordinator?
    init(coordinator: MountainMapView.Coordinator) {
        self.coordinator = coordinator
        super.init()
    }
    @objc func tick() {
        coordinator?.friendPulseTick()
    }
}

fileprivate final class MountainMapGondolaTickTarget: NSObject {
    weak var coordinator: MountainMapView.Coordinator?
    init(coordinator: MountainMapView.Coordinator) {
        self.coordinator = coordinator
        super.init()
    }
    @objc func tick() {
        coordinator?.gondolaTick()
    }
}
