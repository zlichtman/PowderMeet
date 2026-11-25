import Foundation

/// What a run, lift or connector is called wherever it is shown: the map's
/// label, the context card, a route's steps and an imported run's sections.
/// One rule, so a skier who reads "Unnamed blue run" on a step finds the same
/// words on the map. Without a name, a run is told apart by its rating and a
/// lift by its kind, the two things a skier can see from the line itself.
public enum TerrainName {
    /// "Franz's Run", or "Unnamed blue run" / "Unnamed park" / "Unnamed run".
    public static func run(_ name: String?, difficulty: Difficulty?) -> String {
        if let name = named(name) { return name }
        return switch difficulty {
        case .green: "Unnamed green run"
        case .blue: "Unnamed blue run"
        case .black: "Unnamed black run"
        case .doubleBlack: "Unnamed double black run"
        case .park: "Unnamed park"
        case .unknown, nil: "Unnamed run"
        }
    }

    /// "Peak Express", or "Unnamed chairlift" / "Unnamed lift".
    public static func lift(_ name: String?, type: LiftType?) -> String {
        if let name = named(name) { return name }
        return switch type {
        case .chair: "Unnamed chairlift"
        case .gondola: "Unnamed gondola"
        case .tbar: "Unnamed T-bar"
        case .magicCarpet: "Unnamed magic carpet"
        case .ropeTow: "Unnamed rope tow"
        case .cableCar: "Unnamed cable car"
        case nil: "Unnamed lift"
        }
    }

    /// A mapped link between runs: its name, else "Connector".
    public static func connector(_ name: String?) -> String {
        named(name) ?? "Connector"
    }

    /// A run or lift of the bundle by `run` or `lift`, reading the rating or
    /// lift kind off its edges when the group itself does not carry it.
    public static func of(_ group: Group, in graph: Graph) -> String {
        let edges = group.edgeIDs.lazy.compactMap(graph.edge)
        switch group.kind {
        case .trail: return run(group.name, difficulty: group.difficulty ?? edges.compactMap(\.difficulty).first)
        case .lift: return lift(group.name, type: edges.compactMap(\.lift).first?.type)
        }
    }

    /// The name with surrounding space trimmed, or nil when nothing is left.
    public static func named(_ name: String?) -> String? {
        guard let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}
