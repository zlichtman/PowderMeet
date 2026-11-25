// Some style APIs used here sit behind the SDK's Experimental SPI.
@_spi(Experimental) @preconcurrency import MapboxMaps
import MapScene
import PMLogging
import UIKit

/// Layer ids, bottom to top. The order and paint are the v1 map's.
enum MapLayerID {
    static let trailGlow = "trail-glow-layer"
    static let trailCasing = "trail-casing-layer"
    static let trails = "trail-layer"
    static let lifts = "lift-layer"
    static let liftEnds = "lift-endpoints-layer"
    static let connections = "traverse-layer"
    static let selectedTrailGlow = "selected-trail-glow-layer"
    static let selectedTrail = "selected-trail-layer"
    static let routeAGlow = "route-a-glow-layer"
    static let routeA = "route-a-layer"
    static let routeBGlow = "route-b-glow-layer"
    static let routeB = "route-b-layer"
    static let closedCasing = "closed-terrain-casing-layer"
    static let closed = "closed-terrain-layer"
    static let closedLabels = "closed-terrain-labels-layer"
    static let meetingBeam = "meeting-beam-layer"
    static let meetingPulse = "meeting-pulse-layer"
    static let meeting = "meeting-layer"
    static let breadcrumbs = "breadcrumbs-layer"
    static let ghostDots = "ghost-dots-layer"
    static let ghostHeads = "ghost-heads-layer"
    static let ghostLabels = "ghost-labels-layer"
    static let friendHalo = "friend-accuracy-halo-layer"
    static let friendPulse = "friend-pulse-layer"
    static let friendDots = "friend-dots-layer"
    static let friendLabels = "friend-labels-layer"
    static let friendAge = "friend-age-badge-layer"
    static let friendPhotos = "friend-photos-layer"
    static let friendPlace = "friend-place-layer"
    static let userPhoto = "user-photo-layer"
    static let userPulse = "user-pulse-layer"
    static let userOuter = "user-dot-outer-layer"
    static let userDot = "user-dot-layer"
    static let overviewLabels = "overview-poi-labels-layer"
    static let poiIcons = "poi-icons-layer"
    static let poiLabels = "poi-labels-layer"
    static let trailLabels = "trail-labels-layer"
    static let liftLabels = "lift-labels-layer"
    static let meetingLabel = "meeting-label-layer"

    static let routeLayers = [routeAGlow, routeA, routeBGlow, routeB]
    /// Stepped aside while a route is drawn, so the route reads end to end:
    /// place icons and names, lift-station icons and the overview landmarks.
    static let routeClutter = [poiIcons, poiLabels, liftEnds, overviewLabels]
    static let hillshade = "hillshade-layer"
    static let ridgeLight = "hillshade-ridge"
    /// Tree cover as small dots, and contour lines: the drawn looks' ground
    /// (`MapLook`), from mapbox-terrain-v2. Their ids avoid the words
    /// `tuneBasemap` hides.
    static let trees = "terrain-trees"
    static let contours = "terrain-contours"
    static let sky = "sky-layer"
    /// The base style's own layers a look turns on or off.
    static let satellite = "satellite"
    static let aerialway = "aerialway"
    static let background = "background"

}

/// Everything added to the Mapbox style, once per style load: terrain, light, sky,
/// the GeoJSON sources (empty until a bundle arrives) and the layers. After this
/// runs, nothing adds or removes a source or layer again; a bundle replaces source
/// data, and all other change is feature-state. A new look or theme
/// (`applyLook`) is paint and visibility on the same layers.
///
/// The base style stays satellite-streets: its style pack carries the glyphs
/// and sprite offline, and with its photo and street layers hidden a drawn
/// look fetches none of their tiles (a source with no visible layer loads
/// nothing).
@MainActor
struct MapStyle {
    static let styleURI = StyleURI(rawValue: "mapbox://styles/mapbox/satellite-streets-v12")
        ?? .satelliteStreets
    /// Loaded when the base style keeps failing (no signal and nothing cached):
    /// a plain ground, needing no network, that `install` builds on as usual,
    /// so trails, routes, friends and you still draw. The glyphs are the base
    /// style's, so labels show wherever the cache has them.
    static let fallbackStyleJSON = """
        {"version":8,"name":"PowderMeet plain","glyphs":"mapbox://fonts/mapbox/{fontstack}/{range}.pbf",\
        "sources":{},"layers":[{"id":"background","type":"background","paint":{"background-color":"#10161B"}}]}
        """
    static let demSourceID = "mapbox-dem"
    static let demTileset = "mapbox://mapbox.mapbox-terrain-dem-v1"
    /// Contours and land cover, for the drawn looks.
    static let terrainSourceID = "mapbox-terrain-v2"
    static let terrainTileset = "mapbox://mapbox.mapbox-terrain-v2"
    static let emptyCollection = "{\"type\":\"FeatureCollection\",\"features\":[]}"

    let map: MapboxMap
    let log: PMLog
    var appearance: MapAppearance = .standard
    /// Cloud greys the light and the sky; haze brings the fog in.
    var weather: WeatherEffect = .clear

    /// Runs one style mutation and logs a failure with its name. A layer that fails
    /// to install must not stop the ones after it.
    func step(_ name: String, _ body: () throws -> Void) {
        do { try body() } catch {
            log.error(.map, "style: \(name) failed: \(error.localizedDescription)")
        }
    }

    func install() {
        addTerrain()
        addSky()
        tuneBasemap()
        addImages()
        addSources()
        addLayers()
        applyLook()
    }


    // MARK: Terrain, light, sky

    private func addTerrain() {
        step("dem source") {
            var dem = RasterDemSource(id: Self.demSourceID)
            dem.url = Self.demTileset
            dem.tileSize = 512
            dem.maxzoom = 14
            try map.addSource(dem)
        }
        step("terrain") {
            // Relief that reads at whole-mountain zoom, eased back close in so
            // the near slope does not swallow the runs.
            var terrain = Terrain(sourceId: Self.demSourceID)
            terrain.exaggeration = .expression(Exp(.interpolate) {
                Exp(.linear)
                Exp(.zoom)
                11; 1.32
                14; 1.2
                16; 1.1
            })
            try map.setTerrain(terrain)
        }
        // Hillshade reads the terrain's own source. A second DEM source fetched
        // the same tileset again at higher zoom: nearly half the bytes of a
        // first view (measured: about 7.5 MB with two sources, 4 MB with one).
        let shadeSource = Self.demSourceID
        step("hillshade") {
            // Cool shadows for snow in shade.
            var shade = HillshadeLayer(id: MapLayerID.hillshade, source: shadeSource)
            shade.hillshadeExaggeration = .constant(0.36)
            // The light comes from the scene's sun (`applyLighting`), on the map.
            shade.hillshadeIlluminationAnchor = .constant(.map)
            shade.hillshadeShadowColor = .constant(StyleColor(UIColor(red: 0.05, green: 0.08, blue: 0.16, alpha: 0.38)))
            shade.hillshadeHighlightColor = .constant(StyleColor(UIColor(red: 0.88, green: 0.92, blue: 1.0, alpha: 0.20)))
            shade.hillshadeAccentColor = .constant(StyleColor(UIColor(hex: "0E1218")))
            shade.hillshadeIlluminationDirection = .constant(315)
            try map.addLayer(shade)
        }
        step("ridge light") {
            // A faint warm fill on exposed ridges.
            var ridge = HillshadeLayer(id: MapLayerID.ridgeLight, source: shadeSource)
            ridge.hillshadeExaggeration = .constant(0.14)
            ridge.hillshadeShadowColor = .constant(StyleColor(.clear))
            ridge.hillshadeHighlightColor = .constant(StyleColor(UIColor(red: 1.0, green: 0.91, blue: 0.78, alpha: 0.10)))
            ridge.hillshadeAccentColor = .constant(StyleColor(.clear))
            ridge.hillshadeIlluminationDirection = .constant(280)
            try map.addLayer(ridge)
        }
        // The drawn looks' ground; `applyLook` colours it, or hides it under
        // the photo.
        step("terrain vectors") {
            var terrain = VectorSource(id: Self.terrainSourceID)
            terrain.url = Self.terrainTileset
            try map.addSource(terrain)
        }
        step(MapLayerID.trees) {
            var layer = FillLayer(id: MapLayerID.trees, source: Self.terrainSourceID)
            layer.sourceLayer = "landcover"
            layer.filter = Exp(.eq) { Exp(.get) { "class" }; "wood" }
            layer.fillEmissiveStrength = .constant(1)
            layer.visibility = .constant(.none)
            try map.addLayer(layer)
        }
        step(MapLayerID.contours) {
            var layer = LineLayer(id: MapLayerID.contours, source: Self.terrainSourceID)
            layer.sourceLayer = "contour"
            layer.lineJoin = .constant(.round)
            layer.lineEmissiveStrength = .constant(1)
            layer.visibility = .constant(.none)
            try map.addLayer(layer)
        }
    }

    private func addSky() {
        step("sky") {
            var sky = SkyLayer(id: MapLayerID.sky)
            sky.skyType = .constant(.atmosphere)
            sky.skyAtmosphereSun = .constant([0, 12])
            sky.skyAtmosphereSunIntensity = .constant(5)
            sky.skyAtmosphereColor = .constant(StyleColor(UIColor(red: 0.08, green: 0.10, blue: 0.18, alpha: 1.0)))
            sky.skyAtmosphereHaloColor = .constant(StyleColor(UIColor(red: 0.12, green: 0.14, blue: 0.24, alpha: 1.0)))
            try map.addLayer(sky)
        }
        step("atmosphere") {
            // Distant peaks fade; near terrain stays sharp.
            var atmosphere = Atmosphere()
            atmosphere.color = .constant(StyleColor(UIColor(red: 0.06, green: 0.07, blue: 0.12, alpha: 1.0)))
            atmosphere.highColor = .constant(StyleColor(UIColor(red: 0.08, green: 0.10, blue: 0.18, alpha: 1.0)))
            atmosphere.horizonBlend = .constant(0.04)
            atmosphere.starIntensity = .constant(0.12)
            atmosphere.spaceColor = .constant(StyleColor(UIColor(red: 0.03, green: 0.04, blue: 0.07, alpha: 1.0)))
            atmosphere.range = .constant([2.5, 18.0])
            try map.setAtmosphere(atmosphere)
        }
    }

    /// Keeps the photo, drops the street map: roads, places and labels are noise on
    /// a mountain. Matching is by keyword so a new style version stays quiet too.
    private func tuneBasemap() {
        let keywords = [
            "road", "street", "place", "settlement", "poi", "label", "building", "transit",
            "airport", "bridge", "tunnel", "admin", "boundary", "ferry", "path", "pedestrian",
            "rail", "shield", "motorway", "trunk", "crop", "national", "state",
        ]
        for layer in map.allLayerIdentifiers {
            let id = layer.id.lowercased()
            guard !id.hasPrefix("hillshade"), !id.hasPrefix("sky"),
                  keywords.contains(where: id.contains) else { continue }
            step("hide \(layer.id)") {
                try map.setLayerProperty(for: layer.id, property: "visibility", value: "none")
            }
        }
        // Not every style version has each of these layers, so absence is expected.
        let tweaks: [(String, String, Any)] = [
            ("satellite", "raster-brightness-min", 0.02),
            ("satellite", "raster-saturation", 0.18),
            ("land", "background-color", "#06080B"),
            ("water", "fill-color", "#080C14"),
            ("water", "fill-opacity", 0.35),
        ]
        for (layer, property, value) in tweaks where map.layerExists(withId: layer) {
            step("\(layer).\(property)") {
                try map.setLayerProperty(for: layer, property: property, value: value)
            }
        }
    }

    /// The SF Symbols the symbol layers name, as tintable (SDF) images. A symbol
    /// image has no bitmap of its own, which the style rejects ("invalid data
    /// size"), so each is drawn into one first.
    private func addImages() {
        let config = UIImage.SymbolConfiguration(pointSize: 24, weight: .bold)
        for name in PlaceIcon.all {
            guard let symbol = UIImage(systemName: name, withConfiguration: config)?
                .withTintColor(.white, renderingMode: .alwaysOriginal)
            else {
                log.error(.map, "style: symbol \(name) unavailable")
                continue
            }
            let image = UIGraphicsImageRenderer(size: symbol.size).image { _ in
                symbol.draw(at: .zero)
            }
            step("image \(name)") { try map.addImage(image, id: name, sdf: true) }
        }
    }

    private func addSources() {
        for id in SceneSourceID.allCases {
            step("source \(id.rawValue)") {
                var source = GeoJSONSource(id: id.rawValue)
                source.data = .string(Self.emptyCollection)
                // Feature-state addresses features by the scene's own string ids.
                source.promoteId2 = .constant("id")
                // The draw-on reveal trims the route line by its length.
                if id == .routeA || id == .routeB { source.lineMetrics = true }
                try map.addSource(source)
            }
        }
    }

    // MARK: Expressions

    /// The sources whose layers read feature-state (`when`, `unless` and the
    /// meeting drop): closed segments and the meeting point. A layer added on
    /// another source that reads state must add its source here. State for
    /// any other source is never sent: Mapbox takes it one feature per call,
    /// and opening a resort or a status refresh would send hundreds that
    /// nothing draws.
    static let stateSources: Set<SceneSourceID> = [.edges, .rendezvous, .beams]

    /// `on` while the feature's boolean state `key` is set, otherwise 0.
    static func when(_ key: String, _ on: Double) -> Value<Double> {
        .expression(Exp(.switchCase) {
            Exp(.boolean) { Exp(.featureState) { key }; false }
            on
            0.0
        })
    }

    /// 0 while the feature's boolean state `key` is set, otherwise 1.
    static func unless(_ key: String) -> Value<Double> {
        .expression(Exp(.switchCase) {
            Exp(.boolean) { Exp(.featureState) { key }; false }
            0.0
            1.0
        })
    }

    /// The whole-mountain hierarchy: at low zoom a run's opacity follows its
    /// `overviewImportance`, so a resort reads as its main fall lines rather than
    /// six hundred equally bright threads; from zoom 14 every run is drawn.
    static func overviewOpacity(
        far: Double, mid: (Double, Double, Double), near: (Double, Double, Double),
        close: Double, closest: Double
    ) -> Exp {
        Exp(.interpolate) {
            Exp(.linear)
            Exp(.zoom)
            10; Exp(.product) { Exp(.get) { "overviewImportance" }; far }
            12; Exp(.interpolate) {
                Exp(.linear)
                Exp(.get) { "overviewImportance" }
                0; 0.0
                0.40; 0.0
                0.55; mid.0
                0.75; mid.1
                1; mid.2
            }
            13; Exp(.interpolate) {
                Exp(.linear)
                Exp(.get) { "overviewImportance" }
                0; 0.02
                0.35; near.0
                0.70; near.1
                1; near.2
            }
            14; close
            16; closest
        }
    }

    /// A zoom ramp as a style expression's JSON, for paint set by look.
    static func zoomRamp(_ stops: [(Double, Double)]) -> [Any] {
        var ramp: [Any] = ["interpolate", ["linear"], ["zoom"]]
        for (zoom, value) in stops { ramp += [zoom, value] }
        return ramp
    }

    /// `overviewOpacity` as a style expression's JSON, for paint set by look.
    static func overviewRamp(
        far: Double, mid: (Double, Double, Double), near: (Double, Double, Double),
        close: Double, closest: Double
    ) -> [Any] {
        let importance: [Any] = ["get", "overviewImportance"]
        return [
            "interpolate", ["linear"], ["zoom"],
            10, ["*", importance, far],
            12, ["interpolate", ["linear"], importance, 0, 0.0, 0.40, 0.0, 0.55, mid.0, 0.75, mid.1, 1, mid.2],
            13, ["interpolate", ["linear"], importance, 0, 0.02, 0.35, near.0, 0.70, near.1, 1, near.2],
            14, close,
            16, closest,
        ] as [Any]
    }

    static var placeColor: Exp {
        Exp(.match) {
            Exp(.get) { "poiType" }
            "landmark"; "#FFFFFF"
            "lodge"; "#FBBF24"
            "#FFD166"
        }
    }

    func zoom(_ a: (Double, Double), _ b: (Double, Double)) -> Value<Double> {
        .expression(Exp(.interpolate) { Exp(.linear); Exp(.zoom); a.0; a.1; b.0; b.1 })
    }

    func zoom(_ a: (Double, Double), _ b: (Double, Double), _ c: (Double, Double)) -> Value<Double> {
        .expression(Exp(.interpolate) { Exp(.linear); Exp(.zoom); a.0; a.1; b.0; b.1; c.0; c.1 })
    }

    func zoom(
        _ a: (Double, Double), _ b: (Double, Double), _ c: (Double, Double), _ d: (Double, Double)
    ) -> Value<Double> {
        .expression(Exp(.interpolate) { Exp(.linear); Exp(.zoom); a.0; a.1; b.0; b.1; c.0; c.1; d.0; d.1 })
    }
}

extension UIColor {
    /// `RRGGBB`, with or without a leading `#`.
    convenience init(hex: String) {
        let digits = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        let value = UInt32(digits, radix: 16) ?? 0xFFFFFF
        self.init(
            red: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255, alpha: 1)
    }
}
