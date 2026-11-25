// Some style APIs used here sit behind the SDK's Experimental SPI.
@_spi(Experimental) @preconcurrency import MapboxMaps
import MapScene
import PMLogging
import UIKit

extension MapStyle {
    // MARK: Layers

    func addLayers() {
        let trailsSource = SceneSourceID.trails.rawValue
        let liftsSource = SceneSourceID.lifts.rawValue
        let edgesSource = SceneSourceID.edges.rawValue
        let placesSource = SceneSourceID.rendezvous.rawValue
        let friendsSource = SceneSourceID.friends.rawValue
        let userSource = SceneSourceID.user.rawValue
        let labelFont = ["DIN Pro Medium", "Arial Unicode MS Regular"]
        let boldFont = ["DIN Pro Bold", "Arial Unicode MS Bold"]
        let halo = StyleColor(UIColor(white: 0, alpha: 0.8))

        // ── 1. Trails: soft bloom, dark casing, difficulty colour ──
        step(MapLayerID.trailGlow) {
            var layer = LineLayer(id: MapLayerID.trailGlow, source: trailsSource)
            layer.lineColor = .expression(Exp(.get) { "color" })
            layer.lineWidth = zoom((10, 4.0), (12, 7.0), (14, 10.0), (16, 14.0))
            layer.lineOpacity = .constant(0.15)
            layer.lineBlur = .constant(4)
            layer.lineCap = .constant(.round)
            layer.lineJoin = .constant(.round)
            layer.lineEmissiveStrength = .constant(1.0)
            try map.addLayer(layer)
        }
        step(MapLayerID.trailCasing) {
            var layer = LineLayer(id: MapLayerID.trailCasing, source: trailsSource)
            layer.lineColor = .constant(StyleColor(UIColor.black.withAlphaComponent(0.62)))
            layer.lineWidth = zoom((10, 1.4), (12, 2.2), (14, 3.5), (16, 5.4))
            layer.lineCap = .constant(.round)
            layer.lineJoin = .constant(.round)
            layer.lineOpacity = .expression(Self.overviewOpacity(
                far: 0.18, mid: (0.10, 0.28, 0.42), near: (0.08, 0.30, 0.55), close: 0.72, closest: 0.82))
            try map.addLayer(layer)
        }
        step(MapLayerID.trails) {
            var layer = LineLayer(id: MapLayerID.trails, source: trailsSource)
            layer.lineColor = .expression(Exp(.get) { "color" })
            layer.lineWidth = zoom((10, 0.6), (12, 1.1), (14, 2.2), (16, 3.6))
            layer.lineCap = .constant(.round)
            layer.lineJoin = .constant(.round)
            layer.lineOpacity = .expression(Self.overviewOpacity(
                far: 0.36, mid: (0.12, 0.40, 0.64), near: (0.10, 0.54, 0.76), close: 0.9, closest: 0.97))
            // The difficulty colour is the same at noon and at dusk: the scene's
            // light does not shade it.
            layer.lineEmissiveStrength = .constant(1.0)
            try map.addLayer(layer)
        }

        // ── 2. Lifts: warm gold on the ground ──
        step(MapLayerID.lifts) {
            var layer = LineLayer(id: MapLayerID.lifts, source: liftsSource)
            layer.lineColor = .constant(StyleColor(UIColor(hex: "FFD166")))
            layer.lineWidth = zoom((10, 1.0), (12, 1.6), (14, 2.2), (16, 3.0))
            layer.lineOpacity = .constant(0.68)
            layer.lineCap = .constant(.round)
            layer.lineEmissiveStrength = .constant(0.6)
            // The lines carry no altitude; a sea-level reference hides them behind terrain.
            layer.lineElevationReference = .constant(.ground)
            try map.addLayer(layer)
        }
        step(MapLayerID.liftEnds) {
            var layer = SymbolLayer(id: MapLayerID.liftEnds, source: SceneSourceID.liftEnds.rawValue)
            layer.iconImage = .constant(.name("cablecar.fill"))
            layer.iconSize = zoom((12, 0.4), (14, 0.55), (16, 0.7))
            layer.iconColor = .constant(StyleColor(UIColor(hex: "FFD166")))
            layer.iconHaloColor = .constant(StyleColor(UIColor(white: 0, alpha: 0.7)))
            layer.iconHaloWidth = .constant(1.5)
            layer.iconAllowOverlap = .constant(false)
            layer.minZoom = 13.0
            try map.addLayer(layer)
        }

        // ── 3. Connections ──
        step(MapLayerID.connections) {
            var layer = LineLayer(id: MapLayerID.connections, source: SceneSourceID.connections.rawValue)
            layer.lineColor = .constant(StyleColor(UIColor(white: 0.65, alpha: 1)))
            layer.lineWidth = .constant(0.9)
            layer.lineOpacity = .constant(0.22)
            layer.lineDasharray = .constant([3, 4])
            layer.lineCap = .constant(.round)
            layer.lineJoin = .constant(.round)
            layer.minZoom = 12.5
            try map.addLayer(layer)
        }

        // ── 4. Selection: the tapped run or lift, drawn again on top ──
        let selectionSource = SceneSourceID.selection.rawValue
        step(MapLayerID.selectedTrailGlow) {
            var layer = LineLayer(id: MapLayerID.selectedTrailGlow, source: selectionSource)
            layer.lineColor = .constant(StyleColor(.white))
            layer.lineWidth = zoom((10, 10.0), (13, 14.0), (16, 18.0))
            layer.lineOpacity = .constant(0.45)
            layer.lineBlur = .constant(6)
            layer.lineCap = .constant(.round)
            layer.lineJoin = .constant(.round)
            try map.addLayer(layer)
        }
        step(MapLayerID.selectedTrail) {
            var layer = LineLayer(id: MapLayerID.selectedTrail, source: selectionSource)
            layer.lineColor = .expression(Exp(.get) { "color" })
            layer.lineWidth = zoom((10, 3.5), (13, 5.0), (16, 7.0))
            layer.lineCap = .constant(.round)
            layer.lineJoin = .constant(.round)
            try map.addLayer(layer)
        }

        // ── 5. Routes ──
        for (glowID, lineID, source, hex) in [
            (MapLayerID.routeAGlow, MapLayerID.routeA, SceneSourceID.routeA, MapPalette.routeA),
            (MapLayerID.routeBGlow, MapLayerID.routeB, SceneSourceID.routeB, MapPalette.routeB),
        ] {
            let color = StyleColor(UIColor(hex: hex))
            step(glowID) {
                var layer = LineLayer(id: glowID, source: source.rawValue)
                layer.lineColor = .constant(color)
                layer.lineWidth = zoom((10, 12.0), (13, 16.0), (16, 22.0))
                layer.lineOpacity = .constant(0.38)
                layer.lineCap = .constant(.round)
                layer.lineBlur = .constant(4)
                try map.addLayer(layer)
            }
            step(lineID) {
                var layer = LineLayer(id: lineID, source: source.rawValue)
                layer.lineColor = .constant(color)
                // The boldest line on the map, over the brighter runs.
                layer.lineWidth = zoom((10, 4.6), (13, 6.4), (16, 8.5))
                layer.lineOpacity = .constant(1.0)
                layer.lineCap = .constant(.round)
                layer.lineJoin = .constant(.round)
                layer.lineBorderColor = .constant(StyleColor(UIColor(white: 0, alpha: 0.75)))
                layer.lineBorderWidth = .constant(1.2)
                layer.lineEmissiveStrength = .constant(1.2)
                try map.addLayer(layer)
            }
        }

        // ── 6. Closures: exact segments, above both routes. Safety beats
        // navigation styling: a leg that just closed shows red through the route. ──
        step(MapLayerID.closedCasing) {
            var layer = LineLayer(id: MapLayerID.closedCasing, source: edgesSource)
            layer.lineColor = .constant(StyleColor(UIColor(white: 0.02, alpha: 1)))
            layer.lineWidth = zoom((11, 3.0), (14, 6.0), (17, 9.0))
            layer.lineOpacity = Self.when(StateKey.closed, 0.92)
            layer.lineCap = .constant(.round)
            layer.lineJoin = .constant(.round)
            try map.addLayer(layer)
        }
        step(MapLayerID.closed) {
            var layer = LineLayer(id: MapLayerID.closed, source: edgesSource)
            layer.lineColor = .constant(StyleColor(UIColor(hex: MapPalette.closed)))
            layer.lineWidth = zoom((11, 1.5), (14, 2.8), (17, 4.2))
            layer.lineOpacity = Self.when(StateKey.closed, 1.0)
            layer.lineDasharray = .constant([1.2, 1.2])
            layer.lineCap = .constant(.round)
            layer.lineJoin = .constant(.round)
            try map.addLayer(layer)
        }
        step(MapLayerID.closedLabels) {
            var layer = SymbolLayer(id: MapLayerID.closedLabels, source: edgesSource)
            layer.textField = .expression(Exp(.get) { "closedLabel" })
            layer.textFont = .constant(["DIN Pro Bold", "Arial Unicode MS Regular"])
            layer.textSize = .constant(9)
            layer.textColor = .constant(StyleColor(UIColor(hex: "FF6374")))
            layer.textHaloColor = .constant(StyleColor(UIColor(white: 0, alpha: 0.92)))
            layer.textHaloWidth = .constant(1.5)
            layer.textOpacity = Self.when(StateKey.closed, 1.0)
            layer.symbolPlacement = .constant(.line)
            // Below the line; trail names sit above it. An open segment's hidden
            // label must not take a place from a visible one.
            layer.textOffset = .constant([0, 0.9])
            layer.textAllowOverlap = .constant(false)
            layer.textIgnorePlacement = .constant(true)
            layer.minZoom = 13.5
            try map.addLayer(layer)
        }

        // ── 7. Meeting point: every rendezvous is in the source; state shows one ──
        step(MapLayerID.meetingBeam) {
            var layer = FillExtrusionLayer(id: MapLayerID.meetingBeam, source: SceneSourceID.beams.rawValue)
            layer.fillExtrusionColor = .constant(StyleColor(UIColor(hex: MapPalette.meet)))
            layer.fillExtrusionHeight = Self.when(StateKey.meeting, 400)
            layer.fillExtrusionBase = .constant(0)
            layer.fillExtrusionOpacity = .constant(0.22)
            layer.fillExtrusionEmissiveStrength = .constant(2.0)
            layer.fillExtrusionVerticalGradient = .constant(false)
            try map.addLayer(layer)
        }
        step(MapLayerID.meetingPulse) {
            var layer = CircleLayer(id: MapLayerID.meetingPulse, source: placesSource)
            layer.circleColor = .constant(StyleColor(UIColor(hex: MapPalette.meet)))
            layer.circleRadius = .constant(18)
            layer.circleOpacity = Self.when(StateKey.meeting, 0.18)
            layer.circleBlur = .constant(1)
            try map.addLayer(layer)
        }
        step(MapLayerID.meeting) {
            var layer = CircleLayer(id: MapLayerID.meeting, source: placesSource)
            layer.circleColor = .constant(StyleColor(UIColor(hex: MapPalette.meet)))
            layer.circleRadius = .constant(6)
            layer.circleOpacity = Self.when(StateKey.meeting, 1.0)
            layer.circleStrokeColor = .constant(StyleColor(.black))
            layer.circleStrokeWidth = .constant(2)
            layer.circleStrokeOpacity = Self.when(StateKey.meeting, 1.0)
            try map.addLayer(layer)
        }

        // ── 7b. The timeline off Live: friends' paths behind, meet ghosts ahead ──
        step(MapLayerID.breadcrumbs) {
            var layer = LineLayer(id: MapLayerID.breadcrumbs, source: SceneSourceID.breadcrumbs.rawValue)
            layer.lineColor = .expression(Exp(.get) { "color" })
            layer.lineWidth = zoom((10, 1.6), (13, 2.6), (16, 3.8))
            layer.lineOpacity = .constant(0.85)
            layer.lineCap = .constant(.round)
            layer.lineJoin = .constant(.round)
            layer.lineBorderColor = .constant(StyleColor(UIColor(white: 0, alpha: 0.55)))
            layer.lineBorderWidth = .constant(0.6)
            layer.lineEmissiveStrength = .constant(1.0)
            layer.lineElevationReference = .constant(.ground)
            try map.addLayer(layer)
        }
        let ghostsSource = SceneSourceID.ghosts.rawValue
        step(MapLayerID.ghostDots) {
            var layer = CircleLayer(id: MapLayerID.ghostDots, source: ghostsSource)
            layer.circleColor = .expression(Exp(.get) { "color" })
            layer.circleRadius = zoom((11, 2.0), (14, 3.0), (17, 4.0))
            layer.circleOpacity = .constant(0.75)
            layer.circleStrokeColor = .constant(StyleColor(UIColor(white: 0, alpha: 0.6)))
            layer.circleStrokeWidth = .constant(0.8)
            layer.circleEmissiveStrength = .constant(1.0)
            layer.filter = Exp(.eq) { Exp(.get) { "kind" }; "dot" }
            try map.addLayer(layer)
        }
        step(MapLayerID.ghostHeads) {
            var layer = CircleLayer(id: MapLayerID.ghostHeads, source: ghostsSource)
            layer.circleColor = .expression(Exp(.get) { "color" })
            layer.circleRadius = .constant(9)
            layer.circleOpacity = .constant(0.55)
            layer.circleStrokeColor = .constant(StyleColor(.white))
            layer.circleStrokeWidth = .constant(2)
            layer.circleEmissiveStrength = .constant(1.0)
            layer.filter = Exp(.eq) { Exp(.get) { "kind" }; "head" }
            try map.addLayer(layer)
        }
        step(MapLayerID.ghostLabels) {
            var layer = SymbolLayer(id: MapLayerID.ghostLabels, source: ghostsSource)
            layer.textField = .expression(Exp(.get) { "label" })
            layer.textFont = .constant(boldFont)
            layer.textSize = .constant(11)
            layer.textColor = .constant(StyleColor(.white))
            layer.textHaloColor = .constant(StyleColor(UIColor(white: 0, alpha: 0.85)))
            layer.textHaloWidth = .constant(1.6)
            layer.textOffset = .constant([0, -1.7])
            layer.textAllowOverlap = .constant(true)
            layer.textIgnorePlacement = .constant(true)
            layer.textEmissiveStrength = .constant(1.1)
            layer.filter = Exp(.eq) { Exp(.get) { "kind" }; "head" }
            try map.addLayer(layer)
        }

        // ── 8. Friends ──
        step(MapLayerID.friendHalo) {
            // GPS uncertainty, in screen pixels by zoom.
            var layer = CircleLayer(id: MapLayerID.friendHalo, source: friendsSource)
            layer.circleColor = .constant(StyleColor(.white))
            layer.circleOpacity = .constant(0.18)
            layer.circleStrokeColor = .constant(StyleColor(.white))
            layer.circleStrokeWidth = .constant(0.75)
            layer.circleStrokeOpacity = .constant(0.35)
            layer.circleBlur = .constant(0.4)
            layer.circleRadius = .expression(
                Exp(.interpolate) {
                    Exp(.linear)
                    Exp(.zoom)
                    11; Exp(.product) { Exp(.get) { "accuracyMeters" }; 0.012 }
                    14; Exp(.product) { Exp(.get) { "accuracyMeters" }; 0.10 }
                    17; Exp(.product) { Exp(.get) { "accuracyMeters" }; 0.80 }
                }
            )
            layer.filter = Exp(.gt) { Exp(.get) { "accuracyMeters" }; 0 }
            try map.addLayer(layer)
        }
        step(MapLayerID.friendPulse) {
            var layer = CircleLayer(id: MapLayerID.friendPulse, source: friendsSource)
            layer.circleColor = .constant(StyleColor(UIColor(hex: "F59E0B")))
            layer.circleRadius = .constant(22)
            layer.circleOpacity = .expression(
                Exp(.match) {
                    Exp(.get) { "signalState" }
                    "live"; 0.20
                    "stale"; 0.12
                    "cold"; 0.06
                    0.12
                }
            )
            layer.circleBlur = .constant(1)
            try map.addLayer(layer)
        }
        step(MapLayerID.friendDots) {
            // Amber while there is signal; grey once it is lost.
            var layer = CircleLayer(id: MapLayerID.friendDots, source: friendsSource)
            layer.circleColor = .expression(
                Exp(.match) {
                    Exp(.get) { "signalState" }
                    "cold"; "#6B7280"
                    "#F59E0B"
                }
            )
            layer.circleRadius = .constant(11)
            layer.circleOpacity = .expression(Exp(.get) { "diskOpacity" })
            layer.circleStrokeColor = .constant(StyleColor(.white))
            layer.circleStrokeWidth = .expression(
                Exp(.match) {
                    Exp(.get) { "signalState" }
                    "cold"; 1.0
                    2.0
                }
            )
            layer.circleStrokeOpacity = .expression(
                Exp(.match) {
                    Exp(.get) { "signalState" }
                    "cold"; 0.5
                    1.0
                }
            )
            layer.circleSortKey = .constant(999)
            try map.addLayer(layer)
        }
        step(MapLayerID.friendLabels) {
            var layer = SymbolLayer(id: MapLayerID.friendLabels, source: friendsSource)
            layer.textField = .expression(Exp(.get) { "initials" })
            layer.textSize = .constant(9)
            layer.textColor = .constant(StyleColor(.white))
            layer.textFont = .constant(["DIN Pro Bold"])
            layer.textAllowOverlap = .constant(true)
            layer.textOpacity = .expression(Exp(.get) { "diskOpacity" })
            layer.textEmissiveStrength = .constant(1.3)
            layer.textOcclusionOpacity = .constant(0.15)
            try map.addLayer(layer)
        }
        step(MapLayerID.friendAge) {
            // "4M AGO" under a friend whose fix is no longer live.
            var layer = SymbolLayer(id: MapLayerID.friendAge, source: friendsSource)
            layer.textField = .expression(Exp(.get) { "signalLabel" })
            layer.textSize = .constant(10)
            layer.textColor = .constant(StyleColor(.white))
            layer.textFont = .constant(["DIN Pro Bold"])
            layer.textOffset = .constant([0, 1.6])
            layer.textAllowOverlap = .constant(true)
            layer.textHaloColor = .constant(StyleColor(UIColor(white: 0, alpha: 0.7)))
            layer.textHaloWidth = .constant(1.5)
            layer.textHaloBlur = .constant(0.5)
            layer.textEmissiveStrength = .constant(1.0)
            layer.textOcclusionOpacity = .constant(0.1)
            layer.filter = Exp(.neq) { Exp(.get) { "signalLabel" }; "" }
            try map.addLayer(layer)
        }

        step(MapLayerID.friendPhotos) {
            // The friend's own photo over their disc (owner, 21 Nov: "the
            // literal profile pic"), ringed in the friend amber. A friend with
            // no photo has no image, so the disc and initials show instead.
            var layer = SymbolLayer(id: MapLayerID.friendPhotos, source: friendsSource)
            layer.iconImage = .expression(Exp(.concat) { MapPhotos.prefix; Exp(.get) { "userId" } })
            layer.iconAllowOverlap = .constant(true)
            layer.iconIgnorePlacement = .constant(true)
            layer.iconOpacity = .expression(Exp(.get) { "diskOpacity" })
            layer.iconEmissiveStrength = .constant(1.0)
            layer.iconOcclusionOpacity = .constant(0.15)
            layer.symbolSortKey = .constant(999)
            try map.addLayer(layer)
        }
        step(MapLayerID.friendPlace) {
            // "On Pika's Traverse" just above a live friend's photo.
            var layer = SymbolLayer(id: MapLayerID.friendPlace, source: friendsSource)
            layer.textField = .expression(Exp(.get) { "place" })
            layer.textSize = .constant(11)
            layer.textColor = .constant(StyleColor(.white))
            layer.textFont = .constant(["DIN Pro Bold"])
            layer.textAnchor = .constant(.bottom)
            layer.textOffset = .constant([0, -1.5])
            layer.textMaxWidth = .constant(12)
            layer.textAllowOverlap = .constant(true)
            layer.textHaloColor = .constant(StyleColor(UIColor(white: 0, alpha: 0.8)))
            layer.textHaloWidth = .constant(1.5)
            layer.textHaloBlur = .constant(0.5)
            layer.textEmissiveStrength = .constant(1.0)
            layer.textOcclusionOpacity = .constant(0.1)
            layer.filter = Exp(.neq) { Exp(.get) { "place" }; "" }
            try map.addLayer(layer)
        }

        // ── 9. You ──
        step(MapLayerID.userPulse) {
            var layer = CircleLayer(id: MapLayerID.userPulse, source: userSource)
            layer.circleColor = .constant(StyleColor(UIColor(hex: "3B82F6")))
            layer.circleRadius = .constant(16)
            layer.circleOpacity = .constant(0.15)
            layer.circleBlur = .constant(1)
            try map.addLayer(layer)
        }
        step(MapLayerID.userOuter) {
            var layer = CircleLayer(id: MapLayerID.userOuter, source: userSource)
            layer.circleColor = .constant(StyleColor(.white))
            layer.circleRadius = .constant(8)
            try map.addLayer(layer)
        }
        step(MapLayerID.userDot) {
            var layer = CircleLayer(id: MapLayerID.userDot, source: userSource)
            layer.circleColor = .constant(StyleColor(UIColor(hex: "3B82F6")))
            layer.circleRadius = .constant(7)
            layer.circleSortKey = .constant(1000)
            try map.addLayer(layer)
        }
        step(MapLayerID.userPhoto) {
            // Your photo over your dot, ringed in your blue; none, the dot.
            var layer = SymbolLayer(id: MapLayerID.userPhoto, source: userSource)
            layer.iconImage = .constant(.name(MapPhotos.prefix + MapPhotos.me))
            layer.iconAllowOverlap = .constant(true)
            layer.iconIgnorePlacement = .constant(true)
            layer.iconEmissiveStrength = .constant(1.0)
            try map.addLayer(layer)
        }

        // ── Landmarks: a few at whole-mountain zoom, the rest close in ──
        step(MapLayerID.overviewLabels) {
            var layer = SymbolLayer(id: MapLayerID.overviewLabels, source: placesSource)
            layer.textField = .expression(Exp(.get) { "name" })
            layer.textFont = .constant(boldFont)
            layer.textSize = zoom((11, 10), (13, 12))
            layer.textColor = .expression(
                Exp(.match) {
                    Exp(.get) { "overview" }
                    "summit"; "#FFFFFF"
                    "#FBBF24"
                }
            )
            layer.textHaloColor = .constant(StyleColor(UIColor(white: 0, alpha: 0.88)))
            layer.textHaloWidth = .constant(1.8)
            layer.textOffset = .constant([0, 1.0])
            layer.textAllowOverlap = .constant(false)
            layer.textOptional = .constant(true)
            // The meeting label names this place while it is the meeting point.
            layer.textOpacity = Self.unless(StateKey.meeting)
            layer.textEmissiveStrength = .constant(1.1)
            layer.textOcclusionOpacity = .constant(0)
            layer.minZoom = 11
            layer.maxZoom = 13.5
            layer.filter = Exp(.has) { "overview" }
            try map.addLayer(layer)
        }
        step(MapLayerID.poiIcons) {
            var layer = SymbolLayer(id: MapLayerID.poiIcons, source: placesSource)
            layer.iconImage = .expression(Exp(.get) { "icon" })
            layer.iconSize = zoom((12, 0.5), (14, 0.7), (16, 0.9))
            layer.iconColor = .expression(Self.placeColor)
            layer.iconHaloColor = .constant(StyleColor(UIColor(white: 0, alpha: 0.7)))
            layer.iconHaloWidth = .constant(1)
            layer.iconAllowOverlap = .constant(false)
            // Lower keys are placed first: food, first aid and restrooms win a
            // collision over lift stations and junctions.
            layer.symbolSortKey = .expression(
                Exp(.subtract) { 10; Exp(.coalesce) { Exp(.get) { "iconPriority" }; 0 } })
            layer.minZoom = 13.0
            try map.addLayer(layer)
        }
        step(MapLayerID.poiLabels) {
            var layer = SymbolLayer(id: MapLayerID.poiLabels, source: placesSource)
            layer.textField = .expression(Exp(.get) { "name" })
            layer.textFont = .constant(boldFont)
            layer.textSize = zoom((13, 8), (15, 10), (17, 12))
            layer.textColor = .expression(Self.placeColor)
            layer.textHaloColor = .constant(halo)
            layer.textHaloWidth = .constant(1.5)
            layer.textOffset = .constant([0, 1.2])
            layer.textAllowOverlap = .constant(false)
            layer.textOptional = .constant(true)
            // The meeting label names this place while it is the meeting point.
            layer.textOpacity = Self.unless(StateKey.meeting)
            layer.textEmissiveStrength = .constant(1.1)
            layer.textOcclusionOpacity = .constant(0)
            layer.minZoom = 13.5
            try map.addLayer(layer)
        }

        // ── 10. Names, on top ──
        for (id, source, minZoom, color) in [
            (MapLayerID.trailLabels, trailsSource, 14.0, UIColor.white),
            (MapLayerID.liftLabels, liftsSource, 13.0, UIColor(red: 0.95, green: 0.82, blue: 0.35, alpha: 1)),
        ] {
            step(id) {
                var layer = SymbolLayer(id: id, source: source)
                layer.textField = .expression(Exp(.coalesce) { Exp(.get) { "mapLabel" }; Exp(.get) { "name" } })
                layer.textFont = .constant(labelFont)
                layer.textSize = id == MapLayerID.trailLabels
                    ? zoom((13, 8), (15, 11), (17, 14)) : zoom((12, 9), (14, 12), (16, 14))
                layer.textColor = .constant(StyleColor(color))
                layer.textHaloColor = .constant(halo)
                layer.textHaloWidth = .constant(1.5)
                layer.textEmissiveStrength = .constant(0.7)
                // Hidden behind terrain, not ghosted through it: a run's label
                // behind a ridge drew as white fragments on the near slope,
                // flickering as the depth test flipped with every zoom step
                // (owner, 21 Nov). Same for the place and summit labels.
                layer.textOcclusionOpacity = .constant(0)
                layer.symbolPlacement = .constant(.line)
                layer.textOffset = .constant([0, -0.8])
                layer.textAllowOverlap = .constant(false)
                layer.textIgnorePlacement = .constant(false)
                layer.symbolSortKey = .expression(Exp(.get) { "verticalDrop" })
                layer.minZoom = minZoom
                layer.filter = Exp(.any) { Exp(.has) { "mapLabel" }; Exp(.has) { "name" } }
                try map.addLayer(layer)
            }
        }
        step(MapLayerID.meetingLabel) {
            // The one label that must survive a dense resort: it ignores collisions
            // and shows from whole-mountain zoom.
            var layer = SymbolLayer(id: MapLayerID.meetingLabel, source: placesSource)
            layer.textField = .expression(Exp(.get) { "meetLabel" })
            layer.textFont = .constant(labelFont)
            layer.textSize = zoom((10, 10), (13, 12), (16, 14))
            layer.textColor = .constant(StyleColor(UIColor(hex: MapPalette.meet)))
            layer.textHaloColor = .constant(StyleColor(UIColor(white: 0, alpha: 0.92)))
            layer.textHaloWidth = .constant(2)
            layer.textHaloBlur = .constant(0.4)
            layer.textOpacity = Self.when(StateKey.meeting, 1.0)
            layer.textEmissiveStrength = .constant(1.2)
            // Above the dot: the ordinary place labels hang below theirs.
            layer.textOffset = .constant([0, -1.5])
            layer.textMaxWidth = .constant(20)
            layer.textAllowOverlap = .constant(true)
            layer.textIgnorePlacement = .constant(true)
            layer.textOcclusionOpacity = .constant(0.85)
            layer.minZoom = 10
            try map.addLayer(layer)
        }
    }
}
