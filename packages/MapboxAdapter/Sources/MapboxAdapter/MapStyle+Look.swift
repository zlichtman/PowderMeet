// Some style APIs used here sit behind the SDK's Experimental SPI.
@_spi(Experimental) @preconcurrency import MapboxMaps
import MapScene
import PMLogging
import UIKit

extension MapStyle {
    // MARK: Look

    /// Draws the map in `appearance`: which ground shows (the photo, or
    /// relief, contours and trees), its colours, the fog, and the overlay
    /// paint that depends on a light or dark ground. Paint and visibility
    /// only, so a change of look or theme applies at once with nothing
    /// reloaded. `applyLighting` runs after it for the sun-driven parts.
    func applyLook() {
        let palette = appearance.palette
        let photo = appearance.look.usesSatellite
        func visible(_ on: Bool) -> String { on ? "visible" : "none" }

        // ── Ground ──
        set(MapLayerID.satellite, "visibility", visible(photo))
        // OpenStreetMap's lift lines duplicate the resort's own; on the photo
        // they stay as before, elsewhere they would fetch street tiles.
        set(MapLayerID.aerialway, "visibility", visible(photo))
        set(MapLayerID.ridgeLight, "visibility", visible(photo))
        set(MapLayerID.trees, "visibility", visible(!photo))
        set(MapLayerID.contours, "visibility", visible(!photo))
        // The prototype's sky is its fog alone; the atmosphere sky layer
        // would paint its own day blue over it.
        set(MapLayerID.sky, "visibility", visible(photo))
        set(MapLayerID.background, "background-color", photo ? "#10161B" : palette.background.hex)
        // The drawn ground keeps its colours at every hour: the scene's
        // lights would dim and tint it.
        set(MapLayerID.background, "background-emissive-strength", photo ? 0.0 : 1.0)

        if photo {
            // The photo's relief, as tuned for it; `applyLighting` sets its
            // strength and direction from the sun.
            set(MapLayerID.hillshade, "hillshade-shadow-color", "rgba(13, 20, 41, 0.38)")
            set(MapLayerID.hillshade, "hillshade-highlight-color", "rgba(224, 235, 255, 0.20)")
            set(MapLayerID.hillshade, "hillshade-accent-color", "#0E1218")
            set(MapLayerID.hillshade, "hillshade-illumination-anchor", "map")
            set(MapLayerID.hillshade, "hillshade-emissive-strength", 0.0)
        } else {
            set(MapLayerID.hillshade, "hillshade-shadow-color", palette.shadow.hex)
            set(MapLayerID.hillshade, "hillshade-highlight-color", palette.highlight.hex)
            set(MapLayerID.hillshade, "hillshade-accent-color", palette.reliefAccent.hex)
            set(MapLayerID.hillshade, "hillshade-exaggeration", 0.75)
            // A fixed light from the top left of the screen, as in the
            // prototype: the relief reads the same whichever way the map faces.
            set(MapLayerID.hillshade, "hillshade-illumination-anchor", "viewport")
            set(MapLayerID.hillshade, "hillshade-illumination-direction", 300.0)
            set(MapLayerID.hillshade, "hillshade-emissive-strength", 1.0)

            addTreeImage(palette)
            set(MapLayerID.trees, "fill-pattern", palette.treeImage)
            set(MapLayerID.trees, "fill-opacity", palette.treeOpacity)
            // Index contours (every fifth line) thicker and brighter.
            let index: [Any] = [">=", ["get", "index"], 5]
            set(MapLayerID.contours, "line-color", palette.contour.hex)
            set(MapLayerID.contours, "line-width", ["case", index, 1.3, 0.6])
            set(MapLayerID.contours, "line-opacity",
                ["case", index, palette.contourOpacity.index, palette.contourOpacity.minor])
            set(MapLayerID.contours, "line-blur", palette.contourBlur)

            step("look fog") {
                var atmosphere = Atmosphere()
                atmosphere.color = .constant(StyleColor(rawValue: palette.fog.hex))
                atmosphere.highColor = .constant(StyleColor(rawValue: palette.fogHigh.hex))
                atmosphere.spaceColor = .constant(StyleColor(rawValue: palette.fog.hex))
                atmosphere.horizonBlend = .constant(0.08)
                atmosphere.starIntensity = .constant(palette.starIntensity)
                atmosphere.range = .constant([2.5, 18.0])
                try map.setAtmosphere(atmosphere)
            }
        }

        applyOverlayLook(palette)
    }

    /// The overlay colours that depend on the ground under them. On the
    /// backdrop these layers do not exist and are skipped.
    private func applyOverlayLook(_ palette: MapLookPalette) {
        let halo = palette.halo
        set(MapLayerID.trailGlow, "line-color", palette.runColor(appearance.overlay))
        set(MapLayerID.trailGlow, "line-opacity", palette.isLight ? 0.18 : 0.15)
        set(MapLayerID.trailCasing, "line-color", palette.trailCasing)
        set(MapLayerID.trails, "line-color", palette.runColor(appearance.overlay))
        // Runs on Whiteout's white ground (owner, 21 Nov: "thin and faint"):
        // wider, nearly opaque at every zoom, with a dark edge. The dark looks
        // keep the widths and the whole-mountain fade they were tuned with.
        if palette.isLight {
            set(MapLayerID.trails, "line-width", Self.zoomRamp([(10, 1.2), (12, 2.0), (14, 3.2), (16, 4.8)]))
            set(MapLayerID.trails, "line-opacity", Self.overviewRamp(
                far: 0.62, mid: (0.40, 0.75, 0.92), near: (0.45, 0.85, 0.97), close: 1, closest: 1))
            set(MapLayerID.trailCasing, "line-width", Self.zoomRamp([(10, 2.2), (12, 3.3), (14, 5.0), (16, 7.0)]))
            set(MapLayerID.trailCasing, "line-opacity", Self.overviewRamp(
                far: 0.35, mid: (0.25, 0.5, 0.65), near: (0.3, 0.6, 0.75), close: 0.85, closest: 0.9))
        } else if appearance.look.usesSatellite {
            // Over the photo (owner, 21 Nov: v1's "bright line drawing"):
            // saturated, nearly opaque and wider at whole-mountain zoom, on a
            // thin dark casing, so both mountains read over the trees and rock.
            set(MapLayerID.trails, "line-width", Self.zoomRamp([(10, 1.2), (12, 1.9), (14, 2.8), (16, 4.0)]))
            set(MapLayerID.trails, "line-opacity", Self.overviewRamp(
                far: 0.78, mid: (0.45, 0.85, 0.96), near: (0.5, 0.9, 0.98), close: 0.98, closest: 1))
            set(MapLayerID.trailCasing, "line-width", Self.zoomRamp([(10, 2.2), (12, 3.2), (14, 4.6), (16, 6.4)]))
            set(MapLayerID.trailCasing, "line-opacity", Self.overviewRamp(
                far: 0.42, mid: (0.25, 0.5, 0.62), near: (0.3, 0.55, 0.7), close: 0.78, closest: 0.85))
        } else {
            set(MapLayerID.trails, "line-width", Self.zoomRamp([(10, 0.6), (12, 1.1), (14, 2.2), (16, 3.6)]))
            set(MapLayerID.trails, "line-opacity", Self.overviewRamp(
                far: 0.36, mid: (0.12, 0.40, 0.64), near: (0.10, 0.54, 0.76), close: 0.9, closest: 0.97))
            set(MapLayerID.trailCasing, "line-width", Self.zoomRamp([(10, 1.4), (12, 2.2), (14, 3.5), (16, 5.4)]))
            set(MapLayerID.trailCasing, "line-opacity", Self.overviewRamp(
                far: 0.18, mid: (0.10, 0.28, 0.42), near: (0.08, 0.30, 0.55), close: 0.72, closest: 0.82))
        }
        set(MapLayerID.selectedTrailGlow, "line-color", palette.selectionGlow)
        set(MapLayerID.selectedTrailGlow, "line-opacity", palette.isLight ? 0.30 : 0.45)
        set(MapLayerID.selectedTrail, "line-color", palette.lineColor)
        // Under a colouring the lifts go grey: their gold would read as one
        // of its steps.
        set(MapLayerID.lifts, "line-color",
            appearance.overlay == .difficulty ? palette.lift : (palette.isLight ? "#5a6475" : "#C2C8D2"))
        // Lifts as clear as the runs over the photo; quieter on a drawn ground.
        set(MapLayerID.lifts, "line-opacity", appearance.look.usesSatellite ? 0.92 : 0.68)
        set(MapLayerID.lifts, "line-width", appearance.look.usesSatellite
            ? Self.zoomRamp([(10, 1.4), (12, 2.0), (14, 2.6), (16, 3.2)])
            : Self.zoomRamp([(10, 1.0), (12, 1.6), (14, 2.2), (16, 3.0)]))
        set(MapLayerID.liftEnds, "icon-color", palette.lift)
        set(MapLayerID.liftEnds, "icon-halo-color", halo.css(0.7))
        set(MapLayerID.connections, "line-color", palette.connection)
        set(MapLayerID.closedLabels, "text-halo-color", halo.css(0.92))
        set(MapLayerID.ghostLabels, "text-color", palette.labelText)
        set(MapLayerID.ghostLabels, "text-halo-color", halo.css(0.85))
        set(MapLayerID.friendHalo, "circle-color", palette.friendHalo)
        set(MapLayerID.friendHalo, "circle-stroke-color", palette.friendHalo)
        set(MapLayerID.friendAge, "text-color", palette.labelText)
        set(MapLayerID.friendAge, "text-halo-color", halo.css(0.7))
        set(MapLayerID.friendPlace, "text-color", palette.labelText)
        set(MapLayerID.friendPlace, "text-halo-color", halo.css(0.8))
        set(MapLayerID.overviewLabels, "text-color", palette.overviewLabelColor)
        set(MapLayerID.overviewLabels, "text-halo-color", halo.css(0.88))
        set(MapLayerID.poiIcons, "icon-color", palette.placeColor)
        set(MapLayerID.poiIcons, "icon-halo-color", halo.css(0.7))
        set(MapLayerID.poiLabels, "text-color", palette.placeColor)
        set(MapLayerID.poiLabels, "text-halo-color", halo.css(0.8))
        set(MapLayerID.trailLabels, "text-color", palette.labelText)
        set(MapLayerID.trailLabels, "text-halo-color", halo.css(0.8))
        set(MapLayerID.liftLabels, "text-color", palette.liftLabel)
        set(MapLayerID.liftLabels, "text-halo-color", halo.css(0.8))
    }

    /// One look property, on a layer that may not be in this style (the
    /// backdrop has no overlay; a style version may lack a base layer).
    private func set(_ layer: String, _ property: String, _ value: Any) {
        guard map.layerExists(withId: layer) else { return }
        step("\(layer).\(property)") {
            try map.setLayerProperty(for: layer, property: property, value: value)
        }
    }

    /// The tree pattern in the look's colour: four 1.8 pt dots scattered in a
    /// 24 pt tile, under half the old density and a third of the dot
    /// (owner, 21 Nov: "too dense and too big"). A pattern cannot be tinted,
    /// so each colour is its own image.
    private func addTreeImage(_ palette: MapLookPalette) {
        let name = palette.treeImage
        guard !map.imageExists(withId: name) else { return }
        let tree = palette.tree
        let side = 24.0, dot = 1.8
        let image = UIGraphicsImageRenderer(size: CGSize(width: side, height: side)).image { context in
            context.cgContext.setFillColor(UIColor(red: tree.r, green: tree.g, blue: tree.b, alpha: 1).cgColor)
            // Off a grid, so the tiling does not read as rows.
            for (x, y) in [(3.0, 4.0), (15.0, 2.0), (9.0, 13.0), (19.0, 17.0)] {
                context.cgContext.fillEllipse(in: CGRect(x: x, y: y, width: dot, height: dot))
            }
        }
        step("image \(name)") { try map.addImage(image, id: name) }
    }

    /// Lights the terrain, the sky and the hillshade from the scene's sun (the
    /// timeline's hour). `sky` false leaves the sky and atmosphere as they are:
    /// the controller re-applies them only when their colours would visibly
    /// change (`MapStyle.skyKey`), so a moving phone never re-sets the
    /// atmosphere every time the sun moves a degree.
    ///
    /// The drawn looks keep their own fixed relief light and sky
    /// (`applyLook`); there the sun moves only the scene's lights, which light
    /// the runs, lifts and markers.
    func applyLighting(_ environment: SceneEnvironment, sky: Bool = true) {
        let altitude = environment.solarAltitudeDeg
        let daylight = environment.daylight
        let twilight = environment.twilight
        let photo = appearance.look.usesSatellite
        // Cloud takes the sun's strength and its shadows and moves light into
        // the flat, cool ambient of an overcast day.
        let cloud = weather.cloud
        step("lights") {
            var sun = DirectionalLight(id: "sun")
            sun.direction = .constant([environment.solarAzimuthDeg, max(3.0, 90.0 - altitude)])
            sun.color = .constant(StyleColor(UIColor(red: 1.0, green: 0.96, blue: 0.88, alpha: 1)))
            sun.intensity = .constant((0.28 + daylight * 0.90) * (1 - 0.55 * cloud))
            // Shadows shape the photo's slopes; on a drawn look the relief
            // carries the shape and shadows would only smudge it.
            sun.castShadows = .constant(photo)
            sun.shadowIntensity = .constant((0.27 + daylight * 0.37) * (1 - 0.85 * cloud))
            var ambient = AmbientLight(id: "ambient")
            ambient.color = .constant(StyleColor(UIColor(red: 0.76, green: 0.83, blue: 0.94, alpha: 1)))
            ambient.intensity = .constant(0.36 + daylight * (0.32 + 0.14 * cloud))
            try map.setLights(ambient: ambient, directional: sun)
        }
        guard photo else {
            if sky { applyLookFog() }
            return
        }
        // Glare: push the photo back so the overlay carries the contrast in sun.
        // At night the photo dims with the light, so the runs carry the map.
        // An overcast day greys the photo a little.
        let glare = environment.theme == .glare
        step("theme") {
            try map.setLayerProperty(for: "satellite", property: "raster-contrast", value: glare ? 0.30 : 0.14)
            try map.setLayerProperty(
                for: "satellite", property: "raster-brightness-max",
                value: (glare ? 0.72 : 0.55 + 0.45 * daylight) * (1 - 0.12 * cloud))
            try map.setLayerProperty(for: "satellite", property: "raster-saturation", value: 0.18 - 0.45 * cloud)
        }
        step("hillshade light") {
            // Mapbox takes the direction the light comes from; the sun's azimuth.
            let direction = environment.solarAzimuthDeg.truncatingRemainder(dividingBy: 360)
            for layer in [MapLayerID.hillshade, MapLayerID.ridgeLight] where map.layerExists(withId: layer) {
                try map.setLayerProperty(
                    for: layer, property: "hillshade-illumination-direction",
                    value: direction < 0 ? direction + 360 : direction)
            }
            if map.layerExists(withId: MapLayerID.hillshade) {
                try map.setLayerProperty(
                    for: MapLayerID.hillshade, property: "hillshade-exaggeration", value: 0.22 + 0.18 * daylight)
            }
        }
        if sky {
            applySky(altitude: altitude, azimuth: environment.solarAzimuthDeg, daylight: daylight, twilight: twilight)
        }
    }

    /// What the sky's colours depend on, in visible steps: the sky is set
    /// again only when this changes.
    static func skyKey(_ environment: SceneEnvironment) -> [Int] {
        [Int((environment.daylight * 20).rounded()), Int((environment.twilight * 10).rounded()),
         Int((environment.solarAzimuthDeg / 15).rounded())]
    }

    /// Night navy to day blue overhead, never purple (owner, 21 Nov: a purple
    /// bar flickered under the header at dusk). Dawn and dusk warm only the
    /// halo and the horizon line, low down; the band itself stays thin.
    private func applySky(altitude: Double, azimuth: Double, daylight: Double, twilight: Double) {
        func mix(_ a: (Double, Double, Double), _ b: (Double, Double, Double), _ t: Double) -> (Double, Double, Double) {
            (a.0 + (b.0 - a.0) * t, a.1 + (b.1 - a.1) * t, a.2 + (b.2 - a.2) * t)
        }
        func color(_ c: (Double, Double, Double)) -> StyleColor {
            StyleColor(UIColor(red: c.0, green: c.1, blue: c.2, alpha: 1))
        }
        let warm = (0.96, 0.58, 0.40)
        // Overcast: the blue goes to a soft grey, as bright as the hour.
        let cloud = weather.cloud * 0.85
        let haze = weather.haze
        let grey = mix((0.08, 0.09, 0.11), (0.66, 0.69, 0.74), daylight)
        let skyColor = mix(mix((0.07, 0.10, 0.18), (0.36, 0.56, 0.86), daylight), grey, cloud)
        let halo = mix(mix(mix((0.10, 0.13, 0.22), (0.86, 0.90, 0.98), daylight), warm, twilight * 0.6 * (1 - cloud)),
                       grey, cloud * 0.6)
        let horizon = mix(mix(mix((0.06, 0.08, 0.13), (0.78, 0.85, 0.94), daylight), warm, twilight * 0.35 * (1 - cloud)),
                          grey, max(cloud, haze) * 0.8)
        let high = mix(mix((0.07, 0.10, 0.18), (0.30, 0.50, 0.85), daylight), grey, cloud)
        let space = mix(mix((0.03, 0.04, 0.07), (0.22, 0.42, 0.80), daylight), grey, cloud)
        step("sky light") {
            guard map.layerExists(withId: MapLayerID.sky) else { return }
            try map.setLayerProperty(for: MapLayerID.sky, property: "sky-atmosphere-sun", value: [
                azimuth, max(0, min(180, 90 - altitude)),
            ])
            try map.setLayerProperty(
                for: MapLayerID.sky, property: "sky-atmosphere-sun-intensity",
                value: (4 + 11 * daylight) * (1 - 0.6 * cloud))
            try map.setLayerProperty(
                for: MapLayerID.sky, property: "sky-atmosphere-color", value: color(skyColor).rawValue)
            try map.setLayerProperty(
                for: MapLayerID.sky, property: "sky-atmosphere-halo-color", value: color(halo).rawValue)
        }
        step("atmosphere light") {
            var atmosphere = Atmosphere()
            atmosphere.color = .constant(color(horizon))
            atmosphere.highColor = .constant(color(high))
            atmosphere.horizonBlend = .constant(0.03 + 0.04 * daylight + 0.01 * twilight + 0.12 * haze)
            atmosphere.starIntensity = .constant(0.35 * (1 - daylight) * (1 - cloud))
            atmosphere.spaceColor = .constant(color(space))
            atmosphere.range = .constant(Self.fogRange(haze: haze))
            try map.setAtmosphere(atmosphere)
        }
    }

    /// Where the fog starts and is full, in kilometres from the camera:
    /// distant peaks fade on a clear day; in a storm the next ridge is gone.
    static func fogRange(haze: Double) -> [Double] { [2.5 - 2.0 * haze, 18.0 - 15.0 * haze] }

    /// A drawn look's fog, brought in by haze; its colours are the look's.
    private func applyLookFog() {
        let palette = appearance.palette
        let haze = weather.haze
        step("look fog weather") {
            var atmosphere = Atmosphere()
            atmosphere.color = .constant(StyleColor(rawValue: palette.fog.hex))
            atmosphere.highColor = .constant(StyleColor(rawValue: palette.fogHigh.hex))
            atmosphere.spaceColor = .constant(StyleColor(rawValue: palette.fog.hex))
            atmosphere.horizonBlend = .constant(0.08 + 0.1 * haze)
            atmosphere.starIntensity = .constant(palette.starIntensity * (1 - weather.cloud))
            atmosphere.range = .constant(Self.fogRange(haze: haze))
            try map.setAtmosphere(atmosphere)
        }
    }
}
