import SwiftUI

/// Readable, independently renderable row shared by the real activity log
/// and presentation tests. Trail identity never competes with fixed stat columns.
struct ImportedRunLogRow: View {
    let run: ImportedRunRecord
    let trailName: String
    var routeDetails: ImportedRunRouteDetails = .unavailable(.recordedDatasetNotLoaded)
    @State private var showingMatchDetails = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        return formatter
    }()

    private var status: ImportedRunMatchStatus {
        ImportedRunMatchStatus(method: run.matchMethod, confidence: run.matchConfidence,
                              dataset: run.datasetVersion, edgeID: run.edgeId, segments: run.matchedSegmentIds)
    }

    var body: some View {
        let headerLayout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
            : AnyLayout(HStackLayout(alignment: .top, spacing: 10))
        VStack(alignment: .leading, spacing: 5) {
            headerLayout {
                Text(trailName)
                    .hudType(.bodyEmph)
                    .foregroundStyle(HUDTheme.primaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(difficultyColor.opacity(0.22), in: RoundedRectangle(cornerRadius: 4))
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(difficultyColor.opacity(0.55), lineWidth: 1))
                    .frame(maxWidth: .infinity, alignment: .leading)
                sourcePill
            }
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 0) {
                    measurements
                    matchButton
                }
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) {
                        measurements
                        Spacer(minLength: 0)
                        matchButton
                    }
                    VStack(alignment: .leading, spacing: 0) {
                        measurements
                        matchButton
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .overlay(alignment: .bottom) { Rectangle().fill(HUDTheme.cardBorder.opacity(0.25)).frame(height: 0.5) }
        .sheet(isPresented: $showingMatchDetails) {
            ImportedRunDetailsView(run: run, trailName: trailName, route: routeDetails)
        }
    }

    private var measurements: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 6))
            : AnyLayout(HStackLayout(spacing: 12))
        return layout {
            Text(Self.timeFormatter.string(from: run.runAt).uppercased()).foregroundStyle(HUDTheme.accentCyan)
            Text(run.speedKmh > 0 ? "\(String(format: "%.1f", run.speedKmh)) KM/H" : "—").foregroundStyle(HUDTheme.accentAmber)
            Text(run.durationDisplay).foregroundStyle(HUDTheme.accentGreen)
        }
        .hudType(.label)
        .fixedSize(horizontal: true, vertical: true)
    }

    private var matchButton: some View {
        Button { showingMatchDetails = true } label: {
            HStack(spacing: 4) {
                Image(systemName: "info.circle")
                Text(status.label)
            }
            .hudType(.label)
            .foregroundStyle(status == .connected ? HUDTheme.accentCyan : HUDTheme.accentAmber)
            .fixedSize(horizontal: true, vertical: true)
            .minimumInteractiveTarget()
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(status.label). Match details")
        .accessibilityHint("Explains how this trail name was assigned")
    }

    private var difficultyColor: Color {
        switch run.difficulty?.lowercased() {
        case "green": return HUDTheme.color(for: .green)
        case "blue": return HUDTheme.color(for: .blue)
        case "black": return HUDTheme.color(for: .black)
        case "doubleblack": return HUDTheme.color(for: .doubleBlack)
        case "terrainpark": return HUDTheme.color(for: .terrainPark)
        default: return HUDTheme.secondaryText
        }
    }

    private var sourcePill: some View {
        Text(run.sourceBadge.isEmpty ? "—" : run.sourceBadge)
            .hudType(.label)
            .foregroundStyle(sourceColor)
            .padding(.horizontal, 5)
            .padding(.vertical, 4)
            .background(sourceColor.opacity(0.15), in: RoundedRectangle(cornerRadius: 3))
            .fixedSize()
    }

    private var sourceColor: Color {
        switch run.sourceBadge.uppercased() {
        case "HEALTH": return Color(red: 0.95, green: 0.20, blue: 0.20)
        case "STRAVA", "GPX": return Color(red: 0.99, green: 0.30, blue: 0.01)
        case "SLOPES": return Color(red: 0.20, green: 0.55, blue: 0.95)
        case "GARMIN", "TCX", "FIT": return Color(red: 0.00, green: 0.55, blue: 0.65)
        case "POWDERMEET": return HUDTheme.accent
        case "LIVE": return HUDTheme.accentAmber
        default: return HUDTheme.secondaryText
        }
    }
}
