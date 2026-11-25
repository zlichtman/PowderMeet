import AppCore
import MeetSolver
import MountainCore
import SwiftUI

/// What a run or lift measures and how its snow is at the timeline's hour,
/// worked out once for the run card and the navigation card so the two always
/// say the same.
@MainActor
struct GroupFigures {
    let resort: ResortModel
    let group: MountainCore.Group
    let bundle: ResortBundle
    /// The stretch a route's step covers, when the figures are for that step:
    /// a step can leave a run early, or carry on down the next mapped run of
    /// the same name, and its figures must match the distance it names.
    var stepEdges: [EdgeID]?
    /// The step's own length. A route that starts part-way down a run covers
    /// only the rest of its first stretch, which this accounts for.
    var stepLengthM: Double?

    var edges: [MountainCore.Edge] { (stepEdges ?? group.edgeIDs).compactMap { bundle.graph.edge($0) } }

    /// How much of the first stretch is still ahead: 1 unless the step
    /// begins part-way along it.
    private var firstShare: Double {
        guard let stepLengthM, let first = edges.first, first.lengthM > 0 else { return 1 }
        let rest = edges.dropFirst().reduce(0) { $0 + $1.lengthM }
        return min(1, max(0, (stepLengthM - rest) / first.lengthM))
    }

    /// A sum over the stretches, the first counted only for what is ahead.
    private func total(_ value: (MountainCore.Edge) -> Double) -> Double {
        let share = firstShare
        return edges.enumerated().reduce(0) { $0 + value($1.element) * ($1.offset == 0 ? share : 1) }
    }

    var lengthM: Double { total(\.lengthM) }
    var verticalM: Double { abs(total(\.verticalM)) }
    var groomed: Bool {
        resort.scene.model?.groomed.contains(group.id) ?? resort.status?.groomed.contains(group.id) ?? false
    }

    var weather: ConditionsSample? { resort.conditions?.sample(at: resort.displayTime) }

    /// The surface at the timeline's hour, from what the bundle and the
    /// weather say (the meters' limits are on `TrailConditions`).
    var surface: TrailConditions {
        let edges = edges
        let aspects = edges.compactMap(\.aspectDeg)
        let length = lengthM
        let drop = verticalM
        return TrailConditions.score(
            groomed: groomed || edges.contains { $0.groomedDefault == true } ? true : nil,
            mogulRun: edges.contains { $0.moguls },
            averagePitchDeg: length > 0 ? atan(drop / length) * 180 / .pi : 0,
            aspectDeg: aspects.isEmpty ? nil : aspects.reduce(0, +) / Double(aspects.count),
            weather: weather)
    }

    var rideS: Double? {
        guard edges.contains(where: { $0.lift != nil }) else { return nil }
        return total { $0.lift?.rideS ?? 0 }
    }

    var length: String { UnitFormatter.distance(lengthM) }

    /// A run's height along its length for the card's profile; none for a
    /// lift, or a run too flat for its vertical to be shown ("—").
    var elevationProfile: [ElevationProfile.Point] {
        guard group.kind != .lift, verticalM >= 5 else { return [] }
        return ElevationProfile.points(along: edges)
    }

    /// Near-zero vertical on a short flat is not a real measurement.
    var vertical: String { verticalM < 5 ? "—" : UnitFormatter.verticalDrop(verticalM) }

    var grade: String {
        lengthM > 0 ? String(format: "%.0f°", atan(verticalM / lengthM) * 180 / .pi) : "—"
    }
}

/// The current run's or lift's figures on the navigation card, so the run
/// card need not be opened for each step: length, vertical and grade (ride
/// time for a lift) in words, and a run's three surface meters beside them.
struct StepFiguresRow: View {
    let figures: GroupFigures

    private var isLift: Bool { figures.group.kind == .lift }

    private var words: String {
        if isLift {
            return ([figures.rideS.map { "\(Wording.minutes($0)) ride" }, figures.length, figures.vertical] as [String?])
                .compactMap { $0 }.filter { $0 != "—" }.joined(separator: " · ")
        }
        return [figures.length, figures.vertical, figures.grade].filter { $0 != "—" }.joined(separator: " · ")
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .bottom, spacing: 12) {
                measures
                Spacer(minLength: 0)
                meters
            }
            VStack(alignment: .leading, spacing: 8) {
                measures
                meters
            }
        }
    }

    private var measures: some View {
        Text(words)
            .textRole(.label)
            .monospacedDigit()
            .foregroundStyle(HUDTheme.primaryText)
            .lineLimit(1)
            .fixedSize()
            .accessibilityLabel(isLift ? "This lift: \(words)" : "This run: \(words)")
    }

    @ViewBuilder
    private var meters: some View {
        if !isLift {
            let surface = figures.surface
            HStack(spacing: 12) {
                SurfaceMeter(label: "Grooming", level: surface.grooming, tint: HUDTheme.accentGreen)
                SurfaceMeter(label: "Moguls", level: surface.moguls, tint: HUDTheme.accentAmber)
                SurfaceMeter(label: "Glide", level: surface.glide, tint: HUDTheme.accentCyan)
            }
        }
    }
}
