import Foundation
import MountainCore

/// What the colour of a run's line says. Difficulty is the trail map's own;
/// the others read the mountain a different way, from what the bundle and
/// the skier's own days already hold.
public enum RunOverlay: String, CaseIterable, Sendable, Hashable {
    /// The marked rating: green, blue, black, double black.
    case difficulty
    /// The steepest pitch on the run.
    case steepness
    /// The way the run faces, so where the sun and the wind get at it.
    case aspect
    /// How often this skier has skied it.
    case skied

    /// The feature property a run's line reads its colour from.
    public var colorProperty: String {
        switch self {
        case .difficulty: "color"
        case .steepness: "steepColor"
        case .aspect: "aspectColor"
        case .skied: "skiedColor"
        }
    }

    /// The colours in order with what each stands for, for a legend.
    public var legend: [(hex: String, label: String)] {
        switch self {
        case .difficulty: []
        case .steepness: Self.steepnessSteps.map { ($0.hex, $0.fromDeg == 0 ? "<\(Self.steepnessSteps[1].fromDeg)°" : "\($0.fromDeg)°") }
        case .aspect: zip(Self.aspectHexes, ["N", "NE", "E", "SE", "S", "SW", "W", "NW"]).map { ($0, $1) }
        case .skied: [(Self.unknownHex, "Never"), (Self.skiedHexes[0], "Once"), (Self.skiedHexes[1], ""), (Self.skiedHexes[2], ""), (Self.skiedHexes[3], "Most")]
        }
    }

    /// Nothing known (no pitch, no facing, never skied): a quiet grey that
    /// reads on a dark ground and on a white one.
    public static let unknownHex = "#7C8494"

    static let steepnessSteps: [(fromDeg: Int, hex: String)] = [
        (0, "#4ADE80"), (15, "#A3E635"), (20, "#FACC15"), (25, "#FB923C"),
        (30, "#EF4444"), (35, "#D946EF"), (40, "#8B5CF6"), (45, "#3B82F6"),
    ]

    /// North first, clockwise in eighths: cold blues to the north, warm to the south.
    static let aspectHexes = ["#3B82F6", "#22D3EE", "#34D399", "#A3E635", "#FACC15", "#FB923C", "#F87171", "#A78BFA"]

    static let skiedHexes = ["#FDE68A", "#FBBF24", "#F97316", "#EF4444"]

    static func steepnessHex(_ pitchDeg: Double?) -> String {
        guard let pitchDeg else { return unknownHex }
        return steepnessSteps.last { Double($0.fromDeg) <= pitchDeg }?.hex ?? steepnessSteps[0].hex
    }

    static func aspectHex(_ aspectDeg: Double?) -> String {
        guard let aspectDeg else { return unknownHex }
        let turned = (aspectDeg.truncatingRemainder(dividingBy: 360) + 360 + 22.5).truncatingRemainder(dividingBy: 360)
        return aspectHexes[min(7, Int(turned / 45))]
    }

    /// `count` against the most-skied run here, on a log scale so one
    /// favourite does not flatten the rest.
    static func skiedHex(_ count: Int, most: Int) -> String {
        guard count > 0, most > 0 else { return unknownHex }
        // With nothing skied twice, every skied run is "Once", not "Most".
        let share = most > 1 ? log(Double(count)) / log(Double(most)) : 0
        return skiedHexes[min(3, Int(share * 3.999))]
    }

    /// The steepest pitch the bundle records on these edges, or their
    /// average where it records none.
    static func pitchDeg(_ edges: [Edge]) -> Double? {
        if let steepest = edges.compactMap(\.gradeMaxDeg).max() { return steepest }
        let length = edges.reduce(0) { $0 + $1.lengthM }
        let drop = abs(edges.reduce(0) { $0 + $1.verticalM })
        return length > 0 ? atan(drop / length) * 180 / .pi : nil
    }

    /// The edges' facings averaged round the compass, weighted by length.
    static func aspectDeg(_ edges: [Edge]) -> Double? {
        var east = 0.0, north = 0.0
        for edge in edges {
            guard let aspect = edge.aspectDeg else { continue }
            east += sin(aspect * .pi / 180) * edge.lengthM
            north += cos(aspect * .pi / 180) * edge.lengthM
        }
        guard east != 0 || north != 0 else { return nil }
        return (atan2(east, north) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360)
    }

    /// How a run's name is keyed in `RenderInput.skied`.
    public static func skiedKey(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
