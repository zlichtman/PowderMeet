import Foundation
import MapScene

/// Settings → Appearance → Map (owner, 21 Nov): how the ground under the runs
/// is drawn. The first three draw the terrain from elevation data only (shaded
/// relief, contour lines, tree cover as small dots); Satellite keeps the photo.
/// A change of look or theme is paint and visibility on the loaded style,
/// never a style reload.
public enum MapLook: String, CaseIterable, Sendable, Hashable {
    // In picker order.
    /// The satellite photo. The default.
    case satellite
    /// White shaded relief: the snowy trail-map look.
    case whiteout
    /// Navy with cyan contours.
    case blueprint
    /// Black with contours and relief in PowderMeet red, whatever the theme.
    case holographic

    public var title: String {
        switch self {
        case .holographic: "PowderMeet"
        case .whiteout: "Whiteout"
        case .blueprint: "Blueprint"
        case .satellite: "Satellite"
        }
    }

    /// Whether the look needs the satellite photo's tiles (and their offline pack).
    public var usesSatellite: Bool { self == .satellite }
}

/// A colour as 0...1 RGB, so the app can hand the theme's accent to the map
/// without the adapter knowing about themes.
public struct MapRGB: Sendable, Hashable {
    public var r: Double
    public var g: Double
    public var b: Double

    public init(_ r: Double, _ g: Double, _ b: Double) {
        self.r = r
        self.g = g
        self.b = b
    }

    /// `RRGGBB`, with or without a leading `#`; black when unreadable.
    init(hex: String) {
        let digits = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        let value = UInt32(digits, radix: 16) ?? 0
        self.init(
            Double((value >> 16) & 0xFF) / 255, Double((value >> 8) & 0xFF) / 255, Double(value & 0xFF) / 255)
    }

    /// This colour moved `t` of the way to `other`.
    func mix(_ other: MapRGB, _ t: Double) -> MapRGB {
        MapRGB(r + (other.r - r) * t, g + (other.g - g) * t, b + (other.b - b) * t)
    }

    static let white = MapRGB(1, 1, 1)
    static let black = MapRGB(0, 0, 0)

    private static func byte(_ value: Double) -> Int { Int((max(0, min(1, value)) * 255).rounded()) }

    /// `#rrggbb`, for style values and image keys.
    var hex: String { String(format: "#%02x%02x%02x", Self.byte(r), Self.byte(g), Self.byte(b)) }

    /// A style colour string with alpha.
    func css(_ alpha: Double = 1) -> String {
        "rgba(\(Self.byte(r)), \(Self.byte(g)), \(Self.byte(b)), \(String(format: "%.2f", max(0, min(1, alpha)))))"
    }
}

/// What the map is drawn in: the look, and the theme's accent that
/// Holographic takes its colour from.
public struct MapAppearance: Sendable, Hashable {
    public var look: MapLook
    public var accent: MapRGB
    /// What the runs' colours say: their rating, or one of the other readings.
    public var overlay: RunOverlay

    public init(look: MapLook, accent: MapRGB, overlay: RunOverlay = .difficulty) {
        self.look = look
        self.accent = accent
        self.overlay = overlay
    }

    /// PowderMeet red: Holographic's colour in every theme.
    public static let powderMeetRed = MapRGB(0.910, 0.150, 0.160)

    /// Satellite, PowderMeet red for any accent: what a map shows before the app says.
    public static let standard = MapAppearance(look: .satellite, accent: powderMeetRed)

    /// Every colour the look sets, worked out once per change.
    var palette: MapLookPalette { MapLookPalette(self) }
}

/// The colours of one look. The ground (background, relief, contours, trees,
/// fog) is ported from the approved prototype
/// (`docs/screenshots/terrain-prototype/three-looks.jpg`); Holographic's are
/// mixed from PowderMeet red in every theme. The overlay keeps its colours' meanings: only black runs (white on the
/// dark looks, near-black on Whiteout), label text and halos, and the few
/// colours that would vanish on white change.
struct MapLookPalette: Sendable {
    let look: MapLook
    /// Whiteout: dark text with light halos instead of the reverse.
    let isLight: Bool

    // Ground
    let background: MapRGB
    let shadow: MapRGB
    let highlight: MapRGB
    let reliefAccent: MapRGB
    let contour: MapRGB
    /// Line opacity of ordinary and index (every fifth) contours.
    let contourOpacity: (minor: Double, index: Double)
    let contourBlur: Double
    let tree: MapRGB
    let treeOpacity: Double
    /// Fog: the horizon, the sky above it, and space beyond.
    let fog: MapRGB
    let fogHigh: MapRGB
    let starIntensity: Double

    // Overlay
    /// Label halos (and icon halos), in the alpha each layer asks for.
    let halo: MapRGB
    /// White label text on the dark looks.
    let labelText: String
    let trailCasing: String
    let selectionGlow: String
    let lift: String
    let liftLabel: String
    let connection: String
    let friendHalo: String
    let meetLabel: String
    /// Difficulty colours as the map draws them, keyed by the scene's own hex.
    let runColors: [(scene: String, drawn: String)]

    init(_ appearance: MapAppearance) {
        let look = appearance.look
        self.look = look
        isLight = look == .whiteout
        switch look {
        case .holographic, .satellite:
            // Satellite never shows the ground layers; its sky and photo are
            // tuned elsewhere. Its overlay is the dark one below.
            // Always PowderMeet red: a blue theme turned Holographic blue.
            let accent = MapAppearance.powderMeetRed
            let ground = MapRGB(hex: "04050a")
            background = ground
            shadow = .black
            highlight = ground.mix(accent, 0.26)
            reliefAccent = ground.mix(accent, 0.07)
            contour = accent.mix(.white, 0.18)
            contourOpacity = (0.16, 0.55)
            contourBlur = 0.6
            tree = accent.mix(.white, 0.35)
            treeOpacity = 0.35
            fog = MapRGB(hex: "06070d")
            fogHigh = fog.mix(accent, 0.07)
            starIntensity = 0.2
            halo = look == .satellite ? .black : ground
        case .whiteout:
            background = MapRGB(hex: "f3f6fa")
            shadow = MapRGB(hex: "6f82a6")
            highlight = .white
            reliefAccent = MapRGB(hex: "c3cfe2")
            contour = MapRGB(hex: "8193b3")
            contourOpacity = (0.18, 0.45)
            contourBlur = 0
            tree = MapRGB(hex: "2f5a46")
            treeOpacity = 0.45
            fog = MapRGB(hex: "dfe8f4")
            fogHigh = MapRGB(hex: "9db7da")
            starIntensity = 0
            halo = .white
        case .blueprint:
            background = MapRGB(hex: "071425")
            shadow = MapRGB(hex: "020812")
            highlight = MapRGB(hex: "1f4f86")
            reliefAccent = MapRGB(hex: "0b2341")
            contour = MapRGB(hex: "5fd4ff")
            contourOpacity = (0.14, 0.5)
            contourBlur = 0
            tree = MapRGB(hex: "7fe0b0")
            treeOpacity = 0.3
            fog = MapRGB(hex: "061226")
            fogHigh = MapRGB(hex: "0c2747")
            starIntensity = 0.2
            halo = background
        }

        if isLight {
            labelText = "#15181e"
            trailCasing = "rgba(28, 38, 58, 0.55)"
            selectionGlow = "#1b2840"
            lift = "#b8860b"
            liftLabel = "#7a5200"
            connection = "#5a6475"
            friendHalo = "#1e2a40"
            meetLabel = "#a86f00"
            // The prototype's snow colours: the scene's pale greens and blues
            // are made for a dark ground.
            runColors = [
                ("#F5F5F7", "#111111"), ("#FFFFFF", "#5a6270"), ("#5DEA8C", "#22b864"),
                ("#7AB8FF", "#3b8cff"), ("#FF5C6E", "#ff4d6a"), ("#FF8533", "#f26b12"),
                ("#FFD166", "#b8860b"),
            ]
        } else {
            labelText = "#FFFFFF"
            trailCasing = "rgba(0, 0, 0, 0.62)"
            selectionGlow = "#FFFFFF"
            lift = "#FFD166"
            liftLabel = "#F2D159"
            connection = "#a6a6a6"
            friendHalo = "#FFFFFF"
            meetLabel = "#FBBF24"
            runColors = []
        }
    }

    /// A run's line colour: under a colouring other than difficulty, that
    /// colouring's own (picked to read on every ground, so no swaps).
    func runColor(_ overlay: RunOverlay) -> Any {
        overlay == .difficulty ? lineColor : ["get", overlay.colorProperty]
    }

    /// A run or lift line's colour: the feature's own, with this look's swaps.
    var lineColor: Any {
        guard !runColors.isEmpty else { return ["get", "color"] }
        var match: [Any] = ["match", ["get", "color"]]
        for (scene, drawn) in runColors { match += [scene, drawn] }
        return match + [["get", "color"]]
    }

    /// Summits white (dark on Whiteout), everything else in the meeting gold.
    var overviewLabelColor: Any {
        ["match", ["get", "overview"], "summit", labelText, isLight ? meetLabel : "#FBBF24"]
    }

    /// Landmarks white, lodges and the rest in golds.
    var placeColor: Any {
        isLight
            ? ["match", ["get", "poiType"], "landmark", labelText, "lodge", meetLabel, "#8a6200"] as [Any]
            : ["match", ["get", "poiType"], "landmark", "#FFFFFF", "lodge", "#FBBF24", "#FFD166"]
    }

    /// The tree dot pattern's image name: one per colour, as a pattern cannot be tinted.
    var treeImage: String { "tree-dots-24-\(tree.hex.dropFirst())" }
}
