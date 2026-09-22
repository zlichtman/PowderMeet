//
//  MountainMapView+Style.swift
//  PowderMeet
//
//  Style + source/layer setup extracted from MountainMapView.swift.
//  Called from `Coordinator.onStyleLoaded()` once the Mapbox style has
//  finished loading. Adds the DEM/hillshade, sky+atmosphere, every
//  GeoJSON source we feed via `updateSource`, every Mapbox layer we
//  ever address by `LayerID`, and the SF Symbol image registrations
//  used by symbol layers.
//
//  These methods do NOT depend on Coordinator state beyond the mapView
//  itself — they're pure setup. Behaviour-equivalent to the pre-split
//  code; the file is just a bulk move.
//

import Foundation
import UIKit
import CoreLocation
import MapboxMaps

extension MountainMapView.Coordinator {

    // MARK: - Terrain & Hillshade

    func configureTerrain(_ mapView: MapboxMaps.MapView) {
        guard let map = mapView.mapboxMap else { return }

        var demSource = RasterDemSource(id: "mapbox-dem")
        demSource.url = "mapbox://mapbox.mapbox-terrain-dem-v1"
        demSource.tileSize = 512
        demSource.maxzoom = 14
        try? map.addSource(demSource)

        // More aggressive exaggeration makes the mountain profile dramatic
        var terrain = Terrain(sourceId: "mapbox-dem")
        terrain.exaggeration = .constant(1.7)
        try? map.setTerrain(terrain)

        // Mapbox v11 3D lighting — the missing piece that makes the
        // satellite-draped terrain read as a real lit mountain instead
        // of a flat photo. Sun direction from the same solar math the
        // sky uses, seeded from the (flattering daylight) baseline time.
        let solar = SunExposureCalculator.solarPosition(
            date: inputs.selectedTime,
            latitude: inputs.resortLatitude ?? 39.6,
            longitude: inputs.resortLongitude)
        let polar = max(3.0, 90.0 - solar.altitude)   // 0 = straight up
        var sun = DirectionalLight(id: "sun")
        sun.direction = .constant([solar.azimuth, polar])
        sun.color = .constant(StyleColor(UIColor(red: 1.0, green: 0.96,
                                                 blue: 0.88, alpha: 1)))
        sun.intensity = .constant(solar.altitude > 0 ? 0.85 : 0.35)
        sun.castShadows = .constant(true)
        sun.shadowIntensity = .constant(0.7)
        var amb = AmbientLight(id: "ambient")
        amb.color = .constant(StyleColor(UIColor(red: 0.62, green: 0.72,
                                                 blue: 0.88, alpha: 1)))
        amb.intensity = .constant(0.6)
        try? map.setLights(ambient: amb, directional: sun)

        var hillshadeSource = RasterDemSource(id: "hillshade-dem")
        hillshadeSource.url = "mapbox://mapbox.mapbox-terrain-dem-v1"
        hillshadeSource.tileSize = 512
        try? map.addSource(hillshadeSource)

        // Two hillshade layers: one for cool-blue shadows, one for warm highlights.
        // This gives the mountain depth and a snowy feel.

        var hillshade = HillshadeLayer(id: "hillshade-layer", source: "hillshade-dem")
        hillshade.hillshadeExaggeration = .constant(0.55)
        // Cool blue-tinted shadows evoke snow/ice in the shade
        hillshade.hillshadeShadowColor = .constant(StyleColor(UIColor(red: 0.04, green: 0.06, blue: 0.14, alpha: 0.82)))
        // Brighter highlights on sun-facing slopes
        hillshade.hillshadeHighlightColor = .constant(StyleColor(UIColor(red: 0.75, green: 0.80, blue: 0.90, alpha: 0.14)))
        hillshade.hillshadeAccentColor = .constant(StyleColor(UIColor(hex: "0E1218")))
        // Illuminate from upper-left for natural sun feel
        hillshade.hillshadeIlluminationDirection = .constant(315)
        try? map.addLayer(hillshade)

        // Second hillshade: subtle warm fill on exposed ridges
        var ridgeLight = HillshadeLayer(id: "hillshade-ridge", source: "hillshade-dem")
        ridgeLight.hillshadeExaggeration = .constant(0.30)
        ridgeLight.hillshadeShadowColor = .constant(StyleColor(.clear))
        ridgeLight.hillshadeHighlightColor = .constant(StyleColor(UIColor(red: 0.90, green: 0.88, blue: 0.82, alpha: 0.08)))
        ridgeLight.hillshadeAccentColor = .constant(StyleColor(.clear))
        ridgeLight.hillshadeIlluminationDirection = .constant(280)
        try? map.addLayer(ridgeLight)
    }

    // MARK: - Sky & Atmosphere

    func configureSkyAndAtmosphere(_ mapView: MapboxMaps.MapView) {
        guard let map = mapView.mapboxMap else { return }

        // Sky layer: dark gradient that transitions from near-black
        // at the horizon to deep navy overhead. Gives the mountain
        // a backdrop instead of flat void.
        var sky = SkyLayer(id: "sky-layer")
        sky.skyType = .constant(.atmosphere)
        sky.skyAtmosphereSun = .constant([0, 12])
        sky.skyAtmosphereSunIntensity = .constant(5)
        sky.skyAtmosphereColor = .constant(StyleColor(UIColor(red: 0.08, green: 0.10, blue: 0.18, alpha: 1.0)))
        sky.skyAtmosphereHaloColor = .constant(StyleColor(UIColor(red: 0.12, green: 0.14, blue: 0.24, alpha: 1.0)))
        try? map.addLayer(sky)

        // Fog: distant terrain fades into atmosphere,
        // creating aerial perspective and isolating the mountain.
        var atmosphere = Atmosphere()
        atmosphere.color = .constant(StyleColor(UIColor(red: 0.06, green: 0.07, blue: 0.12, alpha: 1.0)))
        atmosphere.highColor = .constant(StyleColor(UIColor(red: 0.08, green: 0.10, blue: 0.18, alpha: 1.0)))
        atmosphere.horizonBlend = .constant(0.08)
        atmosphere.starIntensity = .constant(0.12)
        atmosphere.spaceColor = .constant(StyleColor(UIColor(red: 0.03, green: 0.04, blue: 0.07, alpha: 1.0)))
        // Depth fog range — distant peaks fade, nearby terrain stays sharp.
        // [start, end] in screen-relative units; tighter than default [2, 12].
        atmosphere.range = .constant([0.8, 7.0])
        try? map.setAtmosphere(atmosphere)
    }

    // MARK: - Base Map Style

    func configureBaseMapStyle(_ mapView: MapboxMaps.MapView) {
        guard let map = mapView.mapboxMap else { return }

        try? map.setLayerProperty(for: "background", property: "background-color", value: "#06080B")
        try? map.setLayerProperty(for: "water", property: "fill-color", value: "#080C14")
        try? map.setLayerProperty(for: "land", property: "background-color", value: "#06080B")
    }

    func suppressBasemapClutter(_ mapView: MapboxMaps.MapView) {
        guard let map = mapView.mapboxMap else { return }

        // Keyword-based suppression: hide any basemap layer whose ID
        // contains one of these substrings. This catches new layers that
        // future style versions might add without needing a manual list.
        let keywords = [
            "road", "street", "place", "settlement", "poi", "label",
            "building", "transit", "airport", "bridge", "tunnel",
            "admin", "boundary", "ferry", "path", "pedestrian", "rail",
            "shield", "motorway", "trunk",
            "crop", "national", "state"
        ]

        // IDs to keep even if they match a keyword (e.g. our own layers)
        let keepPrefixes = [
            "trail", "lift", "route", "meeting", "hillshade", "sky", "selected",
            "user", "friend", "replay", "dead-end", "phantom", "traverse"
        ]

        for layer in map.allLayerIdentifiers {
            let id = layer.id.lowercased()

            // Never hide our own layers
            if keepPrefixes.contains(where: { id.hasPrefix($0) }) { continue }

            if keywords.contains(where: { id.contains($0) }) {
                try? map.setLayerProperty(for: layer.id, property: "visibility", value: "none")
            }
        }

        try? map.setLayerProperty(for: "background", property: "background-color", value: "#10161B")
        try? map.setLayerProperty(for: "water", property: "fill-opacity", value: 0.35)
    }

    /// Registers the SF Symbols referenced by `iconImage` on symbol layers
    /// (POI glyphs, lift endpoints). Mapbox doesn't resolve SF Symbol names
    /// on its own — without this, we get `Required image 'X' is missing`
    /// warnings every frame and the icon slot just... doesn't render.
    /// Registered with `sdf: true` so the `iconColor` expressions on those
    /// layers can retint them per feature.
    func registerSFSymbols(_ mapView: MapboxMaps.MapView) {
        guard let map = mapView.mapboxMap else { return }
        let config = UIImage.SymbolConfiguration(pointSize: 24, weight: .bold)
        let symbols = [
            "cablecar.fill", "triangle.fill", "house.fill",
            // Amenity glyphs (ResortAmenitiesService → amenityFeatures).
            "fork.knife", "cross.case.fill", "bag.fill",
            "parkingsign", "toilet.fill", "mappin.circle.fill",
        ]
        for name in symbols {
            guard let image = UIImage(systemName: name, withConfiguration: config)?
                .withTintColor(.white, renderingMode: .alwaysTemplate) else {
                print("[MountainMap] SF Symbol not available: \(name)")
                continue
            }
            try? map.addImage(image, id: name, sdf: true)
        }

        let stripeSize = CGSize(width: 8, height: 4)
        let stripeRenderer = UIGraphicsImageRenderer(size: stripeSize)
        let stripeImage = stripeRenderer.image { ctx in
            let cg = ctx.cgContext
            cg.clear(CGRect(origin: .zero, size: stripeSize))
            cg.setFillColor(UIColor.white.withAlphaComponent(0.7).cgColor)
            cg.fill(CGRect(x: 0, y: 1, width: 8, height: 1))
            cg.fill(CGRect(x: 0, y: 2, width: 8, height: 1))
        }
        try? map.addImage(stripeImage, id: "lift-cable-stripe", sdf: false)
    }

    func addSources(_ mapView: MapboxMaps.MapView) {
        guard let map = mapView.mapboxMap else { return }

        var trailSrc = GeoJSONSource(id: MountainMapView.SourceID.trails)
        trailSrc.data = .feature(Feature(geometry: nil))
        try? map.addSource(trailSrc)

        var liftSrc = GeoJSONSource(id: MountainMapView.SourceID.lifts)
        liftSrc.data = .feature(Feature(geometry: nil))
        try? map.addSource(liftSrc)

        var routeASrc = GeoJSONSource(id: MountainMapView.SourceID.routeA)
        routeASrc.data = .feature(Feature(geometry: nil))
        routeASrc.lineMetrics = true   // Required for line-trim-offset animation
        try? map.addSource(routeASrc)

        var routeBSrc = GeoJSONSource(id: MountainMapView.SourceID.routeB)
        routeBSrc.data = .feature(Feature(geometry: nil))
        routeBSrc.lineMetrics = true   // Required for line-trim-offset animation
        try? map.addSource(routeBSrc)

        var meetSrc = GeoJSONSource(id: MountainMapView.SourceID.meetingPoint)
        meetSrc.data = .feature(Feature(geometry: nil))
        try? map.addSource(meetSrc)

        // Meeting-point beam-of-light polygon (Phase 7.3). A small
        // 12-sided polygon at the meeting coordinate; the fill-extrusion
        // layer extrudes it to 400m. Pulsing happens on opacity, not
        // height, so vertices stay stable.
        var beamSrc = GeoJSONSource(id: MountainMapView.SourceID.meetingBeam)
        beamSrc.data = .feature(Feature(geometry: nil))
        try? map.addSource(beamSrc)

        var liftEndpointsSrc = GeoJSONSource(id: MountainMapView.SourceID.liftEndpoints)
        liftEndpointsSrc.data = .feature(Feature(geometry: nil))
        try? map.addSource(liftEndpointsSrc)

        // Animated gondola positions — CADisplayLink-driven source updates
        // at ~10Hz move each car along its lift's polyline.
        var gondolasSrc = GeoJSONSource(id: MountainMapView.SourceID.gondolas)
        gondolasSrc.data = .feature(Feature(geometry: nil))
        try? map.addSource(gondolasSrc)

        var ghostSrc = GeoJSONSource(id: MountainMapView.SourceID.ghostPositions)
        ghostSrc.data = .feature(Feature(geometry: nil))
        try? map.addSource(ghostSrc)

        var selSrc = GeoJSONSource(id: MountainMapView.SourceID.selectedTrail)
        selSrc.data = .feature(Feature(geometry: nil))
        try? map.addSource(selSrc)

        var userLocSrc = GeoJSONSource(id: MountainMapView.SourceID.userLocation)
        userLocSrc.data = .feature(Feature(geometry: nil))
        try? map.addSource(userLocSrc)

        var friendLocSrc = GeoJSONSource(id: MountainMapView.SourceID.friendLocations)
        friendLocSrc.data = .feature(Feature(geometry: nil))
        try? map.addSource(friendLocSrc)

        var replayTrailsSrc = GeoJSONSource(id: MountainMapView.SourceID.replayTrails)
        replayTrailsSrc.data = .feature(Feature(geometry: nil))
        try? map.addSource(replayTrailsSrc)

        var replayPosSrc = GeoJSONSource(id: MountainMapView.SourceID.replayPositions)
        replayPosSrc.data = .feature(Feature(geometry: nil))
        try? map.addSource(replayPosSrc)

        var tempSrc = GeoJSONSource(id: MountainMapView.SourceID.temperature)
        tempSrc.data = .feature(Feature(geometry: nil))
        try? map.addSource(tempSrc)

        var sunSrc = GeoJSONSource(id: MountainMapView.SourceID.sunExposure)
        sunSrc.data = .feature(Feature(geometry: nil))
        try? map.addSource(sunSrc)

        var poiSrc = GeoJSONSource(id: MountainMapView.SourceID.pois)
        poiSrc.data = .feature(Feature(geometry: nil))
        try? map.addSource(poiSrc)

        var amenitySrc = GeoJSONSource(id: MountainMapView.SourceID.amenities)
        amenitySrc.data = .feature(Feature(geometry: nil))
        try? map.addSource(amenitySrc)

        var traverseSrc = GeoJSONSource(id: MountainMapView.SourceID.traverses)
        traverseSrc.data = .feature(Feature(geometry: nil))
        try? map.addSource(traverseSrc)

        var deadEndSrc = GeoJSONSource(id: MountainMapView.SourceID.deadEnds)
        deadEndSrc.data = .feature(Feature(geometry: nil))
        try? map.addSource(deadEndSrc)

        var phantomSrc = GeoJSONSource(id: MountainMapView.SourceID.phantomTrails)
        phantomSrc.data = .feature(Feature(geometry: nil))
        try? map.addSource(phantomSrc)

        var closedTerrainSrc = GeoJSONSource(id: MountainMapView.SourceID.closedTerrain)
        closedTerrainSrc.data = .feature(Feature(geometry: nil))
        try? map.addSource(closedTerrainSrc)
    }

    func addLayers(_ mapView: MapboxMaps.MapView) {
        guard let map = mapView.mapboxMap else { return }

        // ────────────────────────────────────────────────────────────
        // Layers are added in explicit z-order (bottom → top).
        // Each layer after the first uses LayerPosition.above to
        // guarantee correct stacking regardless of add order.
        // ────────────────────────────────────────────────────────────
        // Z-order (bottom to top):
        //   1. Trail glow, trail casing, trail lines
        //   2. Lift glow, lift lines
        //   3. Traverses, dead-ends, phantom trails, operational closures
        //   4. Selected trail highlight
        //   5. Route A glow, Route A line, Route B glow, Route B line
        //   6. Meeting point layers
        //   7. Replay trails + dots
        //   8. Friend locations
        //   9. User location
        //  10. Trail labels, lift labels (TOP — always readable)
        // ────────────────────────────────────────────────────────────

        // ── 1. Trail glow: soft bloom behind runs so they pop off the terrain ──
        var trailGlow = LineLayer(id: MountainMapView.LayerID.trailGlow, source: MountainMapView.SourceID.trails)
        trailGlow.lineColor = .expression(Exp(.get) { "color" })
        trailGlow.lineWidth = .expression(
            Exp(.interpolate) {
                Exp(.linear)
                Exp(.zoom)
                10; 4.0
                12; 7.0
                14; 10.0
                16; 14.0
            }
        )
        trailGlow.lineOpacity = .constant(0.15)
        trailGlow.lineBlur = .constant(4)
        trailGlow.lineCap = .constant(.round)
        trailGlow.lineJoin = .constant(.round)
        try? map.addLayer(trailGlow)

        // ── Trail casing: dark outline for contrast ──
        var trailCasing = LineLayer(id: MountainMapView.LayerID.trailCasing, source: MountainMapView.SourceID.trails)
        trailCasing.lineColor = .constant(StyleColor(.black.withAlphaComponent(0.62)))
        trailCasing.lineWidth = .expression(
            Exp(.interpolate) {
                Exp(.linear)
                Exp(.zoom)
                10; 1.4
                12; 2.2
                14; 3.5
                16; 5.4
            }
        )
        trailCasing.lineCap = .constant(.round)
        trailCasing.lineJoin = .constant(.round)
        trailCasing.lineOpacity = .expression(
            Exp(.interpolate) {
                Exp(.linear)
                Exp(.zoom)
                10; Exp(.product) {
                    Exp(.get) { "overviewImportance" }
                    0.18
                }
                12; Exp(.interpolate) {
                    Exp(.linear)
                    Exp(.get) { "overviewImportance" }
                    0; 0.0
                    0.40; 0.0
                    0.55; 0.10
                    0.75; 0.28
                    1; 0.42
                }
                13; Exp(.interpolate) {
                    Exp(.linear)
                    Exp(.get) { "overviewImportance" }
                    0; 0.02
                    0.35; 0.08
                    0.70; 0.30
                    1; 0.55
                }
                14; 0.72
                16; 0.82
            }
        )
        try? map.addLayer(trailCasing, layerPosition: .above(MountainMapView.LayerID.trailGlow))

        var trailCasingPalette = LineLayer(id: MountainMapView.LayerID.trailCasingPalette, source: MountainMapView.SourceID.trails)
        trailCasingPalette.lineColor = .expression(Exp(.get) { "color" })
        trailCasingPalette.lineWidth = .expression(
            Exp(.interpolate) {
                Exp(.linear)
                Exp(.zoom)
                10; 1.8
                12; 3.0
                14; 4.8
                16; 7.8
            }
        )
        trailCasingPalette.lineCap = .constant(.round)
        trailCasingPalette.lineJoin = .constant(.round)
        trailCasingPalette.lineOpacity = .constant(0.0)
        try? map.addLayer(trailCasingPalette, layerPosition: .above(MountainMapView.LayerID.trailCasing))

        // ── Trail lines: color-coded by difficulty ──
        var trails = LineLayer(id: MountainMapView.LayerID.trails, source: MountainMapView.SourceID.trails)
        trails.lineColor = .expression(Exp(.get) { "color" })
        trails.lineWidth = .expression(
            Exp(.interpolate) {
                Exp(.linear)
                Exp(.zoom)
                10; 0.55
                12; 1.0
                14; 2.0
                16; 3.4
            }
        )
        trails.lineCap = .constant(.round)
        trails.lineJoin = .constant(.round)
        trails.lineOpacity = .expression(
            Exp(.interpolate) {
                Exp(.linear)
                Exp(.zoom)
                10; Exp(.product) {
                    Exp(.get) { "overviewImportance" }
                    0.34
                }
                12; Exp(.interpolate) {
                    Exp(.linear)
                    Exp(.get) { "overviewImportance" }
                    // Whole-mountain views need a real hierarchy. The former
                    // 0.18 floor made all ~600 Whistler trails visible at once,
                    // recreating the colored-spaghetti screenshot even though
                    // every feature carried an importance score.
                    0; 0.0
                    0.40; 0.0
                    0.55; 0.10
                    0.75; 0.35
                    1; 0.58
                }
                13; Exp(.interpolate) {
                    Exp(.linear)
                    Exp(.get) { "overviewImportance" }
                    0; 0.02
                    0.35; 0.08
                    0.70; 0.48
                    1; 0.70
                }
                14; 0.84
                16; 0.94
            }
        )
        try? map.addLayer(trails, layerPosition: .above(MountainMapView.LayerID.trailCasingPalette))

        // ── Temperature overlay: elevation-banded cold→warm ──
        var tempLayer = LineLayer(id: MountainMapView.LayerID.temperature, source: MountainMapView.SourceID.temperature)
        tempLayer.lineColor = .expression(Exp(.get) { "color" })
        tempLayer.lineWidth = .expression(
            Exp(.interpolate) {
                Exp(.linear)
                Exp(.zoom)
                10; 3.0
                12; 5.0
                14; 7.0
                16; 10.0
            }
        )
        tempLayer.lineOpacity = .constant(0.0)
        tempLayer.lineBlur = .constant(3)
        tempLayer.lineCap = .constant(.round)
        tempLayer.lineJoin = .constant(.round)
        try? map.addLayer(tempLayer, layerPosition: .above(MountainMapView.LayerID.trails))

        // ── Sun exposure overlay: color-coded shade→sun on trails ──
        var sunLayer = LineLayer(id: MountainMapView.LayerID.sunExposure, source: MountainMapView.SourceID.sunExposure)
        sunLayer.lineColor = .expression(Exp(.get) { "color" })
        sunLayer.lineWidth = .expression(
            Exp(.interpolate) {
                Exp(.linear)
                Exp(.zoom)
                10; 2.0
                12; 3.5
                14; 5.5
                16; 8.0
            }
        )
        sunLayer.lineOpacity = .constant(0.22)
        sunLayer.lineBlur = .constant(2)
        sunLayer.lineCap = .constant(.round)
        sunLayer.lineJoin = .constant(.round)
        sunLayer.minZoom = 13.25
        try? map.addLayer(sunLayer, layerPosition: .above(MountainMapView.LayerID.temperature))

        // ── 2. Lift glow: warm soft bloom ──
        var liftGlow = LineLayer(id: MountainMapView.LayerID.liftGlow, source: MountainMapView.SourceID.lifts)
        liftGlow.lineColor = .constant(StyleColor(UIColor(hex: "FFD166")))
        liftGlow.lineWidth = .expression(
            Exp(.interpolate) {
                Exp(.linear)
                Exp(.zoom)
                10; 3.0
                12; 5.0
                14; 7.0
                16; 9.0
            }
        )
        liftGlow.lineOpacity = .constant(0.0)
        liftGlow.lineBlur = .constant(3.0)
        liftGlow.lineCap = .constant(LineCap.round)
        liftGlow.lineElevationReference = .constant(.sea)
        try? map.addLayer(liftGlow, layerPosition: .above(MountainMapView.LayerID.sunExposure))

        // ── Lift lines: warm gold, solid ──
        var lifts = LineLayer(id: MountainMapView.LayerID.lifts, source: MountainMapView.SourceID.lifts)
        lifts.lineColor = .constant(StyleColor(UIColor(hex: "FFD166")))
        lifts.lineWidth = .expression(
            Exp(.interpolate) {
                Exp(.linear)
                Exp(.zoom)
                10; 1.0
                12; 1.6
                14; 2.2
                16; 3.0
            }
        )
        lifts.lineOpacity = .constant(0.72)
        lifts.lineCap = .constant(.round)
        lifts.lineEmissiveStrength = .constant(0.6)
        // Hold true (sea-referenced) elevation so the cable flies
        // straight over valleys — visibly crossing between peaks
        // (Peak-to-Peak) instead of draping into the gully.
        lifts.lineElevationReference = .constant(.sea)
        try? map.addLayer(lifts, layerPosition: .above(MountainMapView.LayerID.liftGlow))

        var liftShimmer = LineLayer(id: MountainMapView.LayerID.liftShimmer, source: MountainMapView.SourceID.lifts)
        liftShimmer.linePattern = .constant(.name("lift-cable-stripe"))
        liftShimmer.lineWidth = .expression(
            Exp(.interpolate) {
                Exp(.linear)
                Exp(.zoom)
                14; 2.2
                16; 3.0
            }
        )
        liftShimmer.lineOpacity = .constant(0.0)
        liftShimmer.lineCap = .constant(.round)
        liftShimmer.lineElevationReference = .constant(.sea)
        liftShimmer.minZoom = 14
        try? map.addLayer(liftShimmer, layerPosition: .above(MountainMapView.LayerID.lifts))

        // ── Animated gondola cars — Resort Cube 3D polish ──
        // Glow halo first so it sits under the solid dot.
        var gondolasGlow = CircleLayer(id: MountainMapView.LayerID.gondolasGlow, source: MountainMapView.SourceID.gondolas)
        gondolasGlow.circleColor = .constant(StyleColor(UIColor(hex: "FFE08A")))
        gondolasGlow.circleRadius = .expression(
            Exp(.interpolate) {
                Exp(.linear)
                Exp(.zoom)
                12; 2.5
                14; 5.0
                16; 8.0
            }
        )
        gondolasGlow.circleOpacity = .constant(0.0)
        gondolasGlow.circleBlur = .constant(1.2)
        gondolasGlow.minZoom = 12.5
        try? map.addLayer(gondolasGlow, layerPosition: .above(MountainMapView.LayerID.lifts))

        var gondolas = CircleLayer(id: MountainMapView.LayerID.gondolas, source: MountainMapView.SourceID.gondolas)
        gondolas.circleColor = .constant(StyleColor(UIColor(hex: "FFD166")))
        gondolas.circleRadius = .expression(
            Exp(.interpolate) {
                Exp(.linear)
                Exp(.zoom)
                12; 1.5
                14; 2.8
                16; 4.5
            }
        )
        gondolas.circleOpacity = .constant(0.0)
        gondolas.circleStrokeColor = .constant(StyleColor(UIColor(white: 0, alpha: 0.55)))
        gondolas.circleStrokeWidth = .constant(0.8)
        gondolas.circleEmissiveStrength = .constant(1.1)
        gondolas.circlePitchAlignment = .constant(.map)  // lie flat on tilted terrain
        gondolas.minZoom = 12.5
        try? map.addLayer(gondolas, layerPosition: .above(MountainMapView.LayerID.gondolasGlow))

        // ── Lift endpoint glyphs: cablecar icon at each station ──
        var liftEndpoints = SymbolLayer(id: MountainMapView.LayerID.liftEndpoints, source: MountainMapView.SourceID.liftEndpoints)
        liftEndpoints.iconImage = .constant(.name("cablecar.fill"))
        liftEndpoints.iconSize = .expression(
            Exp(.interpolate) {
                Exp(.linear)
                Exp(.zoom)
                12; 0.4
                14; 0.55
                16; 0.7
            }
        )
        liftEndpoints.iconColor = .constant(StyleColor(UIColor(hex: "FFD166")))
        liftEndpoints.iconHaloColor = .constant(StyleColor(UIColor(white: 0, alpha: 0.7)))
        liftEndpoints.iconHaloWidth = .constant(1.5)
        liftEndpoints.iconAllowOverlap = .constant(false)
        liftEndpoints.minZoom = 13.0
        try? map.addLayer(liftEndpoints, layerPosition: .above(MountainMapView.LayerID.lifts))

        TreeLayerBuilder.installLayer(on: map)

        // ── 3. Traverse edges ──
        var traverseLayer = LineLayer(id: MountainMapView.LayerID.traverses, source: MountainMapView.SourceID.traverses)
        traverseLayer.lineColor = .constant(StyleColor(UIColor(white: 0.65, alpha: 1)))
        traverseLayer.lineWidth = .constant(0.9)
        traverseLayer.lineOpacity = .constant(0.22)
        traverseLayer.lineDasharray = .constant([3, 4])
        traverseLayer.lineCap = .constant(.round)
        traverseLayer.lineJoin = .constant(.round)
        traverseLayer.minZoom = 12.5
        try? map.addLayer(traverseLayer, layerPosition: .above(MountainMapView.LayerID.liftEndpoints))

        // ── Dead-end dots ──
        var deadEndLayer = CircleLayer(id: MountainMapView.LayerID.deadEndDots, source: MountainMapView.SourceID.deadEnds)
        deadEndLayer.circleColor = .constant(StyleColor(UIColor(hex: "FF6B35")))
        deadEndLayer.circleRadius = .constant(4)
        deadEndLayer.circleOpacity = .constant(0.8)
        deadEndLayer.circleStrokeColor = .constant(StyleColor(.black))
        deadEndLayer.circleStrokeWidth = .constant(1)
        deadEndLayer.minZoom = 14
        try? map.addLayer(deadEndLayer, layerPosition: .above(MountainMapView.LayerID.traverses))

        // ── Phantom trails ──
        var phantomLayer = LineLayer(id: MountainMapView.LayerID.phantomTrails, source: MountainMapView.SourceID.phantomTrails)
        phantomLayer.lineColor = .constant(StyleColor(UIColor(hex: "888888")))
        phantomLayer.lineWidth = .constant(1.2)
        phantomLayer.lineOpacity = .constant(0.40)
        phantomLayer.lineDasharray = .constant([4, 4])
        phantomLayer.lineCap = .constant(.round)
        phantomLayer.lineJoin = .constant(.round)
        phantomLayer.minZoom = 14
        try? map.addLayer(phantomLayer, layerPosition: .above(MountainMapView.LayerID.deadEndDots))

        // ── 4. Selected trail highlight ──
        var selGlow = LineLayer(id: MountainMapView.LayerID.selectedTrailGlow, source: MountainMapView.SourceID.selectedTrail)
        selGlow.lineColor = .constant(StyleColor(.white))
        selGlow.lineWidth = .constant(14)
        selGlow.lineOpacity = .constant(0.35)
        selGlow.lineBlur = .constant(6)
        selGlow.lineCap = .constant(.round)
        selGlow.lineJoin = .constant(.round)
        try? map.addLayer(selGlow, layerPosition: .above(MountainMapView.LayerID.phantomTrails))

        var selLine = LineLayer(id: MountainMapView.LayerID.selectedTrail, source: MountainMapView.SourceID.selectedTrail)
        selLine.lineColor = .expression(Exp(.get) { "color" })
        selLine.lineWidth = .constant(5)
        selLine.lineOpacity = .constant(1.0)
        selLine.lineCap = .constant(.round)
        selLine.lineJoin = .constant(.round)
        try? map.addLayer(selLine, layerPosition: .above(MountainMapView.LayerID.selectedTrailGlow))

        // ── 5. Route A ──
        var routeAGlow = LineLayer(id: MountainMapView.LayerID.routeAGlow, source: MountainMapView.SourceID.routeA)
        routeAGlow.lineColor = .constant(StyleColor(UIColor(hex: HUDTheme.mapboxRouteAHex)))
        routeAGlow.lineWidth = .expression(
            Exp(.interpolate) {
                Exp(.linear)
                Exp(.zoom)
                10; 9.0
                13; 13.0
                16; 18.0
            }
        )
        routeAGlow.lineOpacity = .constant(0.28)
        routeAGlow.lineCap = .constant(.round)
        routeAGlow.lineBlur = .constant(4)
        try? map.addLayer(routeAGlow, layerPosition: .above(MountainMapView.LayerID.selectedTrail))

        var routeALine = LineLayer(id: MountainMapView.LayerID.routeA, source: MountainMapView.SourceID.routeA)
        routeALine.lineColor = .constant(StyleColor(UIColor(hex: HUDTheme.mapboxRouteAHex)))
        routeALine.lineWidth = .expression(
            Exp(.interpolate) {
                Exp(.linear)
                Exp(.zoom)
                10; 3.4
                13; 4.8
                16; 6.5
            }
        )
        routeALine.lineOpacity = .constant(1.0)
        routeALine.lineCap = .constant(.round)
        routeALine.lineJoin = .constant(.round)
        routeALine.lineBorderColor = .constant(StyleColor(UIColor(white: 0, alpha: 0.6)))
        routeALine.lineBorderWidth = .constant(0.8)
        routeALine.lineEmissiveStrength = .constant(1.2)
        try? map.addLayer(routeALine, layerPosition: .above(MountainMapView.LayerID.routeAGlow))

        // ── Route B ──
        var routeBGlow = LineLayer(id: MountainMapView.LayerID.routeBGlow, source: MountainMapView.SourceID.routeB)
        routeBGlow.lineColor = .constant(StyleColor(UIColor(hex: HUDTheme.mapboxRouteBHex)))
        routeBGlow.lineWidth = .expression(
            Exp(.interpolate) {
                Exp(.linear)
                Exp(.zoom)
                10; 9.0
                13; 13.0
                16; 18.0
            }
        )
        routeBGlow.lineOpacity = .constant(0.28)
        routeBGlow.lineCap = .constant(.round)
        routeBGlow.lineBlur = .constant(4)
        try? map.addLayer(routeBGlow, layerPosition: .above(MountainMapView.LayerID.routeA))

        var routeBLine = LineLayer(id: MountainMapView.LayerID.routeB, source: MountainMapView.SourceID.routeB)
        routeBLine.lineColor = .constant(StyleColor(UIColor(hex: HUDTheme.mapboxRouteBHex)))
        routeBLine.lineWidth = .expression(
            Exp(.interpolate) {
                Exp(.linear)
                Exp(.zoom)
                10; 3.4
                13; 4.8
                16; 6.5
            }
        )
        routeBLine.lineOpacity = .constant(1.0)
        routeBLine.lineCap = .constant(.round)
        routeBLine.lineJoin = .constant(.round)
        routeBLine.lineBorderColor = .constant(StyleColor(UIColor(white: 0, alpha: 0.6)))
        routeBLine.lineBorderWidth = .constant(0.8)
        routeBLine.lineEmissiveStrength = .constant(1.2)
        try? map.addLayer(routeBLine, layerPosition: .above(MountainMapView.LayerID.routeBGlow))

        // ── 6. Operational closures ──
        // Safety beats selection and navigation styling. Exact closed segments
        // sit above both skier routes so a newly closed leg remains visibly
        // red during the brief strict-reroute window instead of being hidden
        // beneath cyan/orange. The agreed meeting landmark is added afterward.
        var closedCasing = LineLayer(
            id: MountainMapView.LayerID.closedTerrainCasing,
            source: MountainMapView.SourceID.closedTerrain
        )
        closedCasing.lineColor = .constant(StyleColor(UIColor(white: 0.02, alpha: 0.92)))
        closedCasing.lineWidth = .expression(
            Exp(.interpolate) {
                Exp(.linear)
                Exp(.zoom)
                11; 3.0
                14; 6.0
                17; 9.0
            }
        )
        closedCasing.lineCap = .constant(.round)
        closedCasing.lineJoin = .constant(.round)
        try? map.addLayer(closedCasing, layerPosition: .above(MountainMapView.LayerID.routeB))

        var closedLine = LineLayer(
            id: MountainMapView.LayerID.closedTerrain,
            source: MountainMapView.SourceID.closedTerrain
        )
        closedLine.lineColor = .constant(StyleColor(UIColor(hex: "FF3B4E")))
        closedLine.lineWidth = .expression(
            Exp(.interpolate) {
                Exp(.linear)
                Exp(.zoom)
                11; 1.5
                14; 2.8
                17; 4.2
            }
        )
        closedLine.lineDasharray = .constant([1.2, 1.2])
        closedLine.lineCap = .constant(.round)
        closedLine.lineJoin = .constant(.round)
        try? map.addLayer(closedLine, layerPosition: .above(MountainMapView.LayerID.closedTerrainCasing))

        var closedLabels = SymbolLayer(
            id: MountainMapView.LayerID.closedTerrainLabels,
            source: MountainMapView.SourceID.closedTerrain
        )
        closedLabels.textField = .expression(Exp(.get) { "closedLabel" })
        closedLabels.textFont = .constant(["DIN Pro Bold", "Arial Unicode MS Regular"])
        closedLabels.textSize = .constant(9)
        closedLabels.textColor = .constant(StyleColor(UIColor(hex: "FF6374")))
        closedLabels.textHaloColor = .constant(StyleColor(UIColor(white: 0, alpha: 0.92)))
        closedLabels.textHaloWidth = .constant(1.5)
        closedLabels.symbolPlacement = .constant(.line)
        closedLabels.textAllowOverlap = .constant(false)
        closedLabels.textIgnorePlacement = .constant(false)
        closedLabels.minZoom = 13.5
        try? map.addLayer(closedLabels, layerPosition: .above(MountainMapView.LayerID.closedTerrain))

        // ── 7. Meeting point layers ──
        // Beam-of-light extrusion (Phase 7.3). Gold column pulsing on
        // opacity via CADisplayLink so vertices stay constant. Rendered
        // below the pulse/dot so the dot stays crisp on top.
        var beam = FillExtrusionLayer(id: MountainMapView.LayerID.meetingBeam, source: MountainMapView.SourceID.meetingBeam)
        beam.fillExtrusionColor = .constant(StyleColor(UIColor(hex: HUDTheme.mapboxMeetHex)))
        beam.fillExtrusionHeight = .constant(400)
        beam.fillExtrusionBase = .constant(0)
        beam.fillExtrusionOpacity = .constant(0.22)
        beam.fillExtrusionEmissiveStrength = .constant(2.0)
        beam.fillExtrusionVerticalGradient = .constant(false)
        try? map.addLayer(beam, layerPosition: .above(MountainMapView.LayerID.closedTerrainLabels))

        var meetPulse = CircleLayer(id: MountainMapView.LayerID.meetingPulse, source: MountainMapView.SourceID.meetingPoint)
        meetPulse.circleColor = .constant(StyleColor(UIColor(hex: HUDTheme.mapboxMeetHex)))
        meetPulse.circleRadius = .constant(18)
        meetPulse.circleOpacity = .constant(0.18)
        meetPulse.circleBlur = .constant(1)
        try? map.addLayer(meetPulse, layerPosition: .above(MountainMapView.LayerID.meetingBeam))

        var meetPoint = CircleLayer(id: MountainMapView.LayerID.meeting, source: MountainMapView.SourceID.meetingPoint)
        meetPoint.circleColor = .constant(StyleColor(UIColor(hex: HUDTheme.mapboxMeetHex)))
        meetPoint.circleRadius = .constant(6)
        meetPoint.circleOpacity = .constant(1.0)
        meetPoint.circleStrokeColor = .constant(StyleColor(.black))
        meetPoint.circleStrokeWidth = .constant(2)
        try? map.addLayer(meetPoint, layerPosition: .above(MountainMapView.LayerID.meetingPulse))

        // ── 7. Replay trails + dots ──
        var replayTrailLayer = LineLayer(id: MountainMapView.LayerID.replayTrails, source: MountainMapView.SourceID.replayTrails)
        replayTrailLayer.lineColor = .expression(Exp(.get) { "color" })
        replayTrailLayer.lineWidth = .constant(3)
        replayTrailLayer.lineOpacity = .constant(0.6)
        replayTrailLayer.lineDasharray = .constant([2, 3])
        replayTrailLayer.lineCap = .constant(.round)
        replayTrailLayer.lineJoin = .constant(.round)
        try? map.addLayer(replayTrailLayer, layerPosition: .above(MountainMapView.LayerID.meeting))

        var replayDots = CircleLayer(id: MountainMapView.LayerID.replayDots, source: MountainMapView.SourceID.replayPositions)
        replayDots.circleColor = .expression(Exp(.get) { "color" })
        replayDots.circleRadius = .constant(6)
        replayDots.circleOpacity = .constant(0.9)
        replayDots.circleStrokeColor = .constant(StyleColor(.white))
        replayDots.circleStrokeWidth = .constant(1.5)
        try? map.addLayer(replayDots, layerPosition: .above(MountainMapView.LayerID.replayTrails))

        // ── 8. Find My-style friend tokens ──
        // Accuracy halo (C1): soft white ring sized to the GPS uncertainty
        // radius. Only friends with accuracyMeters >= 20 emit a non-zero
        // value (gated in GeoJSONBuilder), so crisp fixes render no halo.
        // Radius is approximated in screen pixels using a zoom-interpolated
        // metres-per-pixel curve at ~45° latitude — close enough for visual
        // intent without per-feature reprojection math.
        var friendAccuracyHalo = CircleLayer(id: MountainMapView.LayerID.friendAccuracyHalo, source: MountainMapView.SourceID.friendLocations)
        friendAccuracyHalo.circleColor = .constant(StyleColor(UIColor.white))
        friendAccuracyHalo.circleOpacity = .constant(0.18)
        friendAccuracyHalo.circleStrokeColor = .constant(StyleColor(UIColor.white))
        friendAccuracyHalo.circleStrokeWidth = .constant(0.75)
        friendAccuracyHalo.circleStrokeOpacity = .constant(0.35)
        friendAccuracyHalo.circleBlur = .constant(0.4)
        friendAccuracyHalo.circleRadius = .expression(
            Exp(.interpolate) {
                Exp(.linear)
                Exp(.zoom)
                11; Exp(.product) { Exp(.get) { "accuracyMeters" }; 0.012 }
                14; Exp(.product) { Exp(.get) { "accuracyMeters" }; 0.10 }
                17; Exp(.product) { Exp(.get) { "accuracyMeters" }; 0.80 }
            }
        )
        friendAccuracyHalo.filter = Exp(.gt) {
            Exp(.get) { "accuracyMeters" }
            0
        }
        try? map.addLayer(friendAccuracyHalo, layerPosition: .above(MountainMapView.LayerID.replayDots))

        // Pulse: warm token glow that sits above the halo for all friends.
        var friendPulse = CircleLayer(id: MountainMapView.LayerID.friendPulse, source: MountainMapView.SourceID.friendLocations)
        friendPulse.circleColor = .constant(StyleColor(UIColor(hex: "#F59E0B")))
        friendPulse.circleRadius = .constant(22)
        friendPulse.circleOpacity = .expression(
            Exp(.match) {
                Exp(.get) { "signalState" }
                "live"; 0.20
                "stale"; 0.12
                "cold"; 0.06
                0.12
            }
        )
        friendPulse.circleBlur = .constant(1)
        try? map.addLayer(friendPulse, layerPosition: .above(MountainMapView.LayerID.friendAccuracyHalo))

        // Motion pulse: expanding ring that breathes under live friends.
        // Radius + opacity are mutated by friendPulseTick via CADisplayLink.
        // Gated to signalState==live so stale/cold tokens stay still.
        var friendMotionPulse = CircleLayer(id: MountainMapView.LayerID.friendMotionPulse, source: MountainMapView.SourceID.friendLocations)
        friendMotionPulse.circleColor = .constant(StyleColor(UIColor(hex: "#F59E0B")))
        friendMotionPulse.circleRadius = .constant(14)
        friendMotionPulse.circleOpacity = .constant(0)
        friendMotionPulse.circleStrokeColor = .constant(StyleColor(UIColor(hex: "#F59E0B")))
        friendMotionPulse.circleStrokeWidth = .constant(1.5)
        friendMotionPulse.circleStrokeOpacity = .constant(0)
        friendMotionPulse.circleBlur = .constant(0.2)
        friendMotionPulse.filter = Exp(.eq) {
            Exp(.get) { "signalState" }
            "live"
        }
        try? map.addLayer(friendMotionPulse, layerPosition: .above(MountainMapView.LayerID.friendPulse))

        // Identity disk: 11pt radius, white stroke, opacity by signal state.
        // Cold dots desaturate to a muted gray (instead of brand amber) so
        // they read as "lost signal" rather than "active friend" at a
        // glance. Live + stale stay amber. Mapbox `match` expressions
        // expect color hex strings, not StyleColor instances.
        var friendDots = CircleLayer(id: MountainMapView.LayerID.friendDots, source: MountainMapView.SourceID.friendLocations)
        friendDots.circleColor = .expression(
            Exp(.match) {
                Exp(.get) { "signalState" }
                "cold"; "#6B7280"
                "#F59E0B"
            }
        )
        friendDots.circleRadius = .constant(11)
        friendDots.circleOpacity = .expression(Exp(.get) { "diskOpacity" })
        friendDots.circleStrokeColor = .constant(StyleColor(.white))
        friendDots.circleStrokeWidth = .expression(
            Exp(.match) {
                Exp(.get) { "signalState" }
                "cold"; 1.0
                2.0
            }
        )
        friendDots.circleStrokeOpacity = .expression(
            Exp(.match) {
                Exp(.get) { "signalState" }
                "cold"; 0.5
                1.0
            }
        )
        friendDots.circleSortKey = .constant(999)
        // Independent of friendMotionPulse success — if motion pulse fails
        // to register, dots still render above friendPulse.
        try? map.addLayer(friendDots, layerPosition: .above(MountainMapView.LayerID.friendPulse))

        // Initials inside the disk
        var friendLabels = SymbolLayer(id: MountainMapView.LayerID.friendLabels, source: MountainMapView.SourceID.friendLocations)
        friendLabels.textField = .expression(Exp(.get) { "initials" })
        friendLabels.textSize = .constant(9)
        friendLabels.textColor = .constant(StyleColor(.white))
        friendLabels.textFont = .constant(["DIN Pro Bold"])
        friendLabels.textOffset = .constant([0, 0])
        friendLabels.textAllowOverlap = .constant(true)
        friendLabels.textOpacity = .expression(Exp(.get) { "diskOpacity" })
        // Friend identity text tops the hierarchy — punchy through fog.
        friendLabels.textEmissiveStrength = .constant(1.3)
        friendLabels.textOcclusionOpacity = .constant(0.15)
        try? map.addLayer(friendLabels, layerPosition: .above(MountainMapView.LayerID.friendDots))

        // Age badge (C2 surface): "4M AGO" pill below the disk for stale/
        // cold friends. signalLabel is empty for live friends — the layer
        // filter hides them so the badge only appears when meaningful.
        var friendAgeBadge = SymbolLayer(id: MountainMapView.LayerID.friendAgeBadge, source: MountainMapView.SourceID.friendLocations)
        friendAgeBadge.textField = .expression(Exp(.get) { "signalLabel" })
        friendAgeBadge.textSize = .constant(10)
        friendAgeBadge.textColor = .constant(StyleColor(UIColor.white))
        friendAgeBadge.textFont = .constant(["DIN Pro Bold"])
        friendAgeBadge.textOffset = .constant([0, 1.6])
        friendAgeBadge.textAllowOverlap = .constant(true)
        friendAgeBadge.textHaloColor = .constant(StyleColor(UIColor(white: 0, alpha: 0.7)))
        friendAgeBadge.textHaloWidth = .constant(1.5)
        friendAgeBadge.textHaloBlur = .constant(0.5)
        friendAgeBadge.textEmissiveStrength = .constant(1.0)
        friendAgeBadge.textOcclusionOpacity = .constant(0.1)
        friendAgeBadge.filter = Exp(.neq) {
            Exp(.get) { "signalLabel" }
            ""
        }
        try? map.addLayer(friendAgeBadge, layerPosition: .above(MountainMapView.LayerID.friendLabels))

        // Ghost dots (Phase 4.6) — translucent markers for projected
        // skier positions at the scrubbed time. Labels appear only at
        // zoom ≥14 to avoid cluttering the overview.
        var ghostDots = CircleLayer(id: MountainMapView.LayerID.ghostDots, source: MountainMapView.SourceID.ghostPositions)
        ghostDots.circleColor = .expression(Exp(.get) { "color" })
        // Head (the scrubbed instant) = full-size 8pt @ 0.55α; breadcrumb
        // trail dots behind it = 3.5pt @ 0.28α so the head reads as the
        // "ghost skier" and the trail reads as projected path travel.
        ghostDots.circleRadius = .expression(Exp(.switchCase) {
            Exp(.eq) { Exp(.get) { "isHead" }; 1 }
            8.0
            3.5
        })
        ghostDots.circleOpacity = .expression(Exp(.switchCase) {
            Exp(.eq) { Exp(.get) { "isHead" }; 1 }
            0.55
            0.28
        })
        ghostDots.circleStrokeColor = .constant(StyleColor(.white))
        ghostDots.circleStrokeWidth = .expression(Exp(.switchCase) {
            Exp(.eq) { Exp(.get) { "isHead" }; 1 }
            1.0
            0.0
        })
        ghostDots.circleStrokeOpacity = .constant(0.6)
        try? map.addLayer(ghostDots, layerPosition: .above(MountainMapView.LayerID.friendLabels))

        var ghostLabels = SymbolLayer(id: MountainMapView.LayerID.ghostLabels, source: MountainMapView.SourceID.ghostPositions)
        ghostLabels.textField = .expression(Exp(.get) { "label" })
        ghostLabels.textSize = .constant(9)
        ghostLabels.textColor = .constant(StyleColor(.white))
        ghostLabels.textHaloColor = .constant(StyleColor(.black))
        ghostLabels.textHaloWidth = .constant(1.5)
        ghostLabels.textOffset = .constant([0, 1.4])
        // Drop minZoom from 14 → 12 so the "YOU @ 2:15PM · +8MIN"
        // readout is visible at the typical cube framing zoom (~13).
        ghostLabels.minZoom = 12
        ghostLabels.textOptional = .constant(true)
        // Ghost dots are secondary projected positions — dimmer + more occluded.
        ghostLabels.textEmissiveStrength = .constant(0.55)
        ghostLabels.textOcclusionOpacity = .constant(0.45)
        try? map.addLayer(ghostLabels, layerPosition: .above(MountainMapView.LayerID.ghostDots))

        // ── 9. User location dot (blue, like Apple Maps) ──
        var userPulse = CircleLayer(id: MountainMapView.LayerID.userPulse, source: MountainMapView.SourceID.userLocation)
        userPulse.circleColor = .constant(StyleColor(UIColor(hex: "3B82F6")))
        userPulse.circleRadius = .constant(16)
        userPulse.circleOpacity = .constant(0.15)
        userPulse.circleBlur = .constant(1)
        try? map.addLayer(userPulse, layerPosition: .above(MountainMapView.LayerID.friendLabels))

        var userOuter = CircleLayer(id: MountainMapView.LayerID.userDotOuter, source: MountainMapView.SourceID.userLocation)
        userOuter.circleColor = .constant(StyleColor(.white))
        userOuter.circleRadius = .constant(8)
        userOuter.circleOpacity = .constant(1.0)
        try? map.addLayer(userOuter, layerPosition: .above(MountainMapView.LayerID.userPulse))

        var userDot = CircleLayer(id: MountainMapView.LayerID.userDot, source: MountainMapView.SourceID.userLocation)
        userDot.circleColor = .constant(StyleColor(UIColor(hex: "3B82F6")))
        userDot.circleRadius = .constant(7)
        userDot.circleOpacity = .constant(1.0)
        userDot.circleSortKey = .constant(1000)
        try? map.addLayer(userDot, layerPosition: .above(MountainMapView.LayerID.userDotOuter))

        // ── Resort overview landmarks ──
        // Only separated summit/base anchors appear at whole-mountain zoom.
        // Individual lift termini remain hidden until the closer POI layer.
        var overviewPOILabels = SymbolLayer(
            id: MountainMapView.LayerID.overviewPOILabels,
            source: MountainMapView.SourceID.pois
        )
        overviewPOILabels.textField = .expression(Exp(.get) { "name" })
        overviewPOILabels.textFont = .constant(["DIN Pro Bold", "Arial Unicode MS Bold"])
        overviewPOILabels.textSize = .expression(
            Exp(.interpolate) {
                Exp(.linear)
                Exp(.zoom)
                11; 10
                13; 12
            }
        )
        overviewPOILabels.textColor = .expression(
            Exp(.match) {
                Exp(.get) { "poiType" }
                "summit"; "#FFFFFF"
                "#FBBF24"
            }
        )
        overviewPOILabels.textHaloColor = .constant(
            StyleColor(UIColor(white: 0, alpha: 0.88))
        )
        overviewPOILabels.textHaloWidth = .constant(1.8)
        overviewPOILabels.textOffset = .constant([0, 1.0])
        overviewPOILabels.textAllowOverlap = .constant(false)
        overviewPOILabels.textOptional = .constant(true)
        overviewPOILabels.textEmissiveStrength = .constant(1.1)
        overviewPOILabels.textOcclusionOpacity = .constant(0.18)
        overviewPOILabels.minZoom = 11
        overviewPOILabels.maxZoom = 13.5
        overviewPOILabels.filter = Exp(.any) {
            Exp(.eq) { Exp(.get) { "poiType" }; "summit" }
            Exp(.eq) { Exp(.get) { "poiType" }; "base" }
        }
        try? map.addLayer(
            overviewPOILabels,
            layerPosition: .above(MountainMapView.LayerID.userDot)
        )

        // ── Close-zoom POI icons + labels (summit, base, lift termini) ──
        var poiIcons = SymbolLayer(id: MountainMapView.LayerID.poiIcons, source: MountainMapView.SourceID.pois)
        poiIcons.iconImage = .expression(Exp(.get) { "icon" })
        poiIcons.iconSize = .expression(
            Exp(.interpolate) {
                Exp(.linear)
                Exp(.zoom)
                12; 0.5
                14; 0.7
                16; 0.9
            }
        )
        poiIcons.iconColor = .expression(
            Exp(.match) {
                Exp(.get) { "poiType" }
                "summit"; "#FFFFFF"
                "base"; "#FBBF24"
                "liftTop"; "#FFD166"
                "liftBase"; "#FFD166"
                "#CCCCCC"
            }
        )
        poiIcons.iconHaloColor = .constant(StyleColor(UIColor(white: 0, alpha: 0.7)))
        poiIcons.iconHaloWidth = .constant(1)
        poiIcons.iconAllowOverlap = .constant(false)
        poiIcons.minZoom = 13.0
        try? map.addLayer(
            poiIcons,
            layerPosition: .above(MountainMapView.LayerID.overviewPOILabels)
        )

        var poiLabels = SymbolLayer(id: MountainMapView.LayerID.poiLabels, source: MountainMapView.SourceID.pois)
        poiLabels.textField = .expression(Exp(.get) { "name" })
        poiLabels.textFont = .constant(["DIN Pro Bold", "Arial Unicode MS Bold"])
        poiLabels.textSize = .expression(
            Exp(.interpolate) {
                Exp(.linear)
                Exp(.zoom)
                13; 8
                15; 10
                17; 12
            }
        )
        poiLabels.textColor = .expression(
            Exp(.match) {
                Exp(.get) { "poiType" }
                "summit"; "#FFFFFF"
                "base"; "#FBBF24"
                "#FFD166"
            }
        )
        poiLabels.textHaloColor = .constant(StyleColor(UIColor(white: 0, alpha: 0.8)))
        poiLabels.textHaloWidth = .constant(1.5)
        poiLabels.textOffset = .constant([0, 1.2])
        poiLabels.textAllowOverlap = .constant(false)
        poiLabels.textOptional = .constant(true)
        // POIs (summits/base) sit highest in label hierarchy — stronger emissive
        // and lower occlusion so they punch through terrain fog like beacons.
        poiLabels.textEmissiveStrength = .constant(1.1)
        poiLabels.textOcclusionOpacity = .constant(0.2)
        poiLabels.minZoom = 13.5
        try? map.addLayer(poiLabels, layerPosition: .above(MountainMapView.LayerID.poiIcons))

        // ── Amenity icons + labels (restaurants, huts, rest stops) ──
        // Side-channel POIs from ResortAmenitiesService. Per-type tint
        // (warm for food, red for first aid, neutral for utilities) so
        // the user can read the mountain's services at a glance. Higher
        // minZoom than topology POIs — amenities are dense, only worth
        // showing once the user has zoomed into a pod.
        var amenityIcons = SymbolLayer(
            id: MountainMapView.LayerID.amenityIcons,
            source: MountainMapView.SourceID.amenities
        )
        amenityIcons.iconImage = .expression(Exp(.get) { "icon" })
        amenityIcons.iconSize = .expression(
            Exp(.interpolate) {
                Exp(.linear)
                Exp(.zoom)
                13; 0.42
                15; 0.58
                17; 0.72
            }
        )
        amenityIcons.iconColor = .expression(
            Exp(.match) {
                Exp(.get) { "poiType" }
                "restaurant"; "#FBBF24"
                "lodge"; "#FB923C"
                "firstAid"; "#F87171"
                "rental"; "#A78BFA"
                "parking"; "#9CA3AF"
                "restroom"; "#7DD3FC"
                "#CCCCCC"
            }
        )
        amenityIcons.iconHaloColor = .constant(StyleColor(UIColor(white: 0, alpha: 0.75)))
        amenityIcons.iconHaloWidth = .constant(1)
        amenityIcons.iconAllowOverlap = .constant(false)
        amenityIcons.iconOptional = .constant(true)
        amenityIcons.minZoom = 14.0
        try? map.addLayer(amenityIcons, layerPosition: .below(MountainMapView.LayerID.poiIcons))

        var amenityLabels = SymbolLayer(
            id: MountainMapView.LayerID.amenityLabels,
            source: MountainMapView.SourceID.amenities
        )
        amenityLabels.textField = .expression(Exp(.get) { "name" })
        amenityLabels.textFont = .constant(["DIN Pro Medium", "Arial Unicode MS Regular"])
        amenityLabels.textSize = .expression(
            Exp(.interpolate) {
                Exp(.linear)
                Exp(.zoom)
                15; 7.5
                17; 9.5
            }
        )
        amenityLabels.textColor = .constant(StyleColor(UIColor(white: 0.92, alpha: 1)))
        amenityLabels.textHaloColor = .constant(StyleColor(UIColor(white: 0, alpha: 0.85)))
        amenityLabels.textHaloWidth = .constant(1.3)
        amenityLabels.textOffset = .constant([0, 1.1])
        amenityLabels.textAllowOverlap = .constant(false)
        amenityLabels.textOptional = .constant(true)
        amenityLabels.textOcclusionOpacity = .constant(0.15)
        // Below topology POI labels — a summit name should win a
        // collision against a nearby café label.
        amenityLabels.minZoom = 15.0
        try? map.addLayer(amenityLabels, layerPosition: .below(MountainMapView.LayerID.poiLabels))

        // ── 10. Trail & lift labels (TOP — always readable above all other layers) ──
        // SF Pro Rounded (system rounded) for names gives a friendly, premium feel.
        // DIN Pro stays for numeric chips (ETA, elevation) in SwiftUI overlays.
        var trailLabels = SymbolLayer(id: MountainMapView.LayerID.trailLabels, source: MountainMapView.SourceID.trails)
        trailLabels.textField = .expression(
            Exp(.coalesce) {
                Exp(.get) { "mapLabel" }
                Exp(.get) { "name" }
            }
        )
        trailLabels.textFont = .constant(["DIN Pro Medium", "Arial Unicode MS Regular"])
        trailLabels.textSize = .expression(
            Exp(.interpolate) {
                Exp(.linear)
                Exp(.zoom)
                13; 8
                15; 11
                17; 14
            }
        )
        trailLabels.textColor = .constant(StyleColor(.white))
        trailLabels.textHaloColor = .constant(StyleColor(UIColor(white: 0, alpha: 0.8)))
        trailLabels.textHaloWidth = .constant(1.5)
        trailLabels.textEmissiveStrength = .constant(0.7)
        trailLabels.textOcclusionOpacity = .constant(0.3)
        trailLabels.symbolPlacement = .constant(.line)
        trailLabels.textOffset = .constant([0, -0.8])
        trailLabels.textAllowOverlap = .constant(false)
        trailLabels.textIgnorePlacement = .constant(false)
        trailLabels.symbolSortKey = .expression(Exp(.get) { "verticalDrop" })
        trailLabels.minZoom = 14.0
        trailLabels.filter = Exp(.any) {
            Exp(.has) { "mapLabel" }
            Exp(.has) { "name" }
        }
        try? map.addLayer(trailLabels, layerPosition: .above(MountainMapView.LayerID.poiLabels))

        // ── Lift name labels ──
        var liftLabels = SymbolLayer(id: MountainMapView.LayerID.liftLabels, source: MountainMapView.SourceID.lifts)
        liftLabels.textField = .expression(
            Exp(.coalesce) {
                Exp(.get) { "mapLabel" }
                Exp(.get) { "name" }
            }
        )
        liftLabels.textFont = .constant(["DIN Pro Medium", "Arial Unicode MS Regular"])
        liftLabels.textSize = .expression(
            Exp(.interpolate) {
                Exp(.linear)
                Exp(.zoom)
                12; 9
                14; 12
                16; 14
            }
        )
        liftLabels.textColor = .constant(StyleColor(UIColor(red: 0.95, green: 0.82, blue: 0.35, alpha: 1)))
        liftLabels.textHaloColor = .constant(StyleColor(UIColor(white: 0, alpha: 0.8)))
        liftLabels.textHaloWidth = .constant(1.5)
        liftLabels.textEmissiveStrength = .constant(0.7)
        liftLabels.textOcclusionOpacity = .constant(0.3)
        liftLabels.symbolPlacement = .constant(.line)
        liftLabels.textOffset = .constant([0, -0.8])
        liftLabels.textAllowOverlap = .constant(false)
        liftLabels.textIgnorePlacement = .constant(false)
        liftLabels.minZoom = 13.0
        liftLabels.filter = Exp(.any) {
            Exp(.has) { "mapLabel" }
            Exp(.has) { "name" }
        }
        try? map.addLayer(liftLabels, layerPosition: .above(MountainMapView.LayerID.trailLabels))

        // The active destination is the one label that must survive a dense
        // resort view. It is added last, ignores ordinary label collisions,
        // and appears from whole-mountain zoom—unlike ambient trail labels.
        var meetingLabel = SymbolLayer(
            id: MountainMapView.LayerID.meetingLabel,
            source: MountainMapView.SourceID.meetingPoint
        )
        meetingLabel.textField = .expression(Exp(.get) { "mapLabel" })
        meetingLabel.textFont = .constant(["DIN Pro Medium", "Arial Unicode MS Regular"])
        meetingLabel.textSize = .expression(
            Exp(.interpolate) {
                Exp(.linear)
                Exp(.zoom)
                10; 10
                13; 12
                16; 14
            }
        )
        meetingLabel.textColor = .constant(
            StyleColor(UIColor(hex: HUDTheme.mapboxMeetHex))
        )
        meetingLabel.textHaloColor = .constant(
            StyleColor(UIColor(white: 0, alpha: 0.92))
        )
        meetingLabel.textHaloWidth = .constant(2)
        meetingLabel.textHaloBlur = .constant(0.4)
        meetingLabel.textEmissiveStrength = .constant(1.2)
        meetingLabel.textOffset = .constant([0, 1.5])
        meetingLabel.textMaxWidth = .constant(20)
        meetingLabel.textAllowOverlap = .constant(true)
        meetingLabel.textIgnorePlacement = .constant(true)
        meetingLabel.textOcclusionOpacity = .constant(0.85)
        meetingLabel.minZoom = 10
        try? map.addLayer(
            meetingLabel,
            layerPosition: .above(MountainMapView.LayerID.liftLabels)
        )
    }}
