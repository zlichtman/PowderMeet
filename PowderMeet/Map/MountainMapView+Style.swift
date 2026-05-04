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
            "admin", "boundary", "park", "landuse", "natural",
            "waterway", "ferry", "path", "pedestrian", "rail",
            "shield", "motorway", "trunk",
            "contour", "landcover", "vegetation", "wetland",
            "grass", "wood", "scrub", "crop", "sand", "ice",
            "national", "state"
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

        // Darken background, soften water to barely-visible
        try? map.setLayerProperty(for: "background", property: "background-color", value: "#06080B")
        try? map.setLayerProperty(for: "water", property: "fill-opacity", value: 0.12)
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
        let symbols = ["cablecar.fill", "triangle.fill", "house.fill"]
        for name in symbols {
            guard let image = UIImage(systemName: name, withConfiguration: config)?
                .withTintColor(.white, renderingMode: .alwaysTemplate) else {
                print("[MountainMap] SF Symbol not available: \(name)")
                continue
            }
            try? map.addImage(image, id: name, sdf: true)
        }
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

        var traverseSrc = GeoJSONSource(id: MountainMapView.SourceID.traverses)
        traverseSrc.data = .feature(Feature(geometry: nil))
        try? map.addSource(traverseSrc)

        var deadEndSrc = GeoJSONSource(id: MountainMapView.SourceID.deadEnds)
        deadEndSrc.data = .feature(Feature(geometry: nil))
        try? map.addSource(deadEndSrc)

        var phantomSrc = GeoJSONSource(id: MountainMapView.SourceID.phantomTrails)
        phantomSrc.data = .feature(Feature(geometry: nil))
        try? map.addSource(phantomSrc)
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
        //   3. Traverses, dead-ends, phantom trails
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
        trailCasing.lineColor = .constant(StyleColor(.black.withAlphaComponent(0.82)))
        trailCasing.lineWidth = .expression(
            Exp(.interpolate) {
                Exp(.linear)
                Exp(.zoom)
                10; 2.0
                12; 3.0
                14; 4.6
                16; 7.0
            }
        )
        trailCasing.lineCap = .constant(.round)
        trailCasing.lineJoin = .constant(.round)
        trailCasing.lineOpacity = .constant(0.92)
        try? map.addLayer(trailCasing, layerPosition: .above(MountainMapView.LayerID.trailGlow))

        // ── Trail lines: color-coded by difficulty ──
        var trails = LineLayer(id: MountainMapView.LayerID.trails, source: MountainMapView.SourceID.trails)
        trails.lineColor = .expression(Exp(.get) { "color" })
        trails.lineWidth = .expression(
            Exp(.interpolate) {
                Exp(.linear)
                Exp(.zoom)
                10; 1.2
                12; 2.0
                14; 3.2
                16; 5.2
            }
        )
        trails.lineCap = .constant(.round)
        trails.lineJoin = .constant(.round)
        trails.lineOpacity = .constant(1.0)
        try? map.addLayer(trails, layerPosition: .above(MountainMapView.LayerID.trailCasing))

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
        sunLayer.lineOpacity = .constant(0.35)
        sunLayer.lineBlur = .constant(2)
        sunLayer.lineCap = .constant(.round)
        sunLayer.lineJoin = .constant(.round)
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
        liftGlow.lineOpacity = .constant(0.10)
        liftGlow.lineBlur = .constant(3.0)
        liftGlow.lineCap = .constant(LineCap.round)
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
        try? map.addLayer(lifts, layerPosition: .above(MountainMapView.LayerID.liftGlow))

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
        gondolasGlow.circleOpacity = .constant(0.32)
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
        gondolas.circleOpacity = .constant(1.0)
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
        routeAGlow.lineWidth = .constant(10)
        routeAGlow.lineOpacity = .constant(0.28)
        routeAGlow.lineCap = .constant(.round)
        routeAGlow.lineBlur = .constant(4)
        try? map.addLayer(routeAGlow, layerPosition: .above(MountainMapView.LayerID.selectedTrail))

        var routeALine = LineLayer(id: MountainMapView.LayerID.routeA, source: MountainMapView.SourceID.routeA)
        routeALine.lineColor = .constant(StyleColor(UIColor(hex: HUDTheme.mapboxRouteAHex)))
        routeALine.lineWidth = .constant(3.2)
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
        routeBGlow.lineWidth = .constant(10)
        routeBGlow.lineOpacity = .constant(0.28)
        routeBGlow.lineCap = .constant(.round)
        routeBGlow.lineBlur = .constant(4)
        try? map.addLayer(routeBGlow, layerPosition: .above(MountainMapView.LayerID.routeA))

        var routeBLine = LineLayer(id: MountainMapView.LayerID.routeB, source: MountainMapView.SourceID.routeB)
        routeBLine.lineColor = .constant(StyleColor(UIColor(hex: HUDTheme.mapboxRouteBHex)))
        routeBLine.lineWidth = .constant(3.2)
        routeBLine.lineOpacity = .constant(1.0)
        routeBLine.lineCap = .constant(.round)
        routeBLine.lineJoin = .constant(.round)
        routeBLine.lineBorderColor = .constant(StyleColor(UIColor(white: 0, alpha: 0.6)))
        routeBLine.lineBorderWidth = .constant(0.8)
        routeBLine.lineEmissiveStrength = .constant(1.2)
        try? map.addLayer(routeBLine, layerPosition: .above(MountainMapView.LayerID.routeBGlow))

        // ── 6. Meeting point layers ──
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
        try? map.addLayer(beam, layerPosition: .above(MountainMapView.LayerID.routeB))

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

        // Identity disk: 11pt radius, white stroke, opacity by signal state
        var friendDots = CircleLayer(id: MountainMapView.LayerID.friendDots, source: MountainMapView.SourceID.friendLocations)
        friendDots.circleColor = .constant(StyleColor(UIColor(hex: "#F59E0B")))
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

        // ── POI icons + labels (summit, base, lift termini) ──
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
        try? map.addLayer(poiIcons, layerPosition: .above(MountainMapView.LayerID.userDot))

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
        trailLabels.minZoom = 13.5
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
    }}
