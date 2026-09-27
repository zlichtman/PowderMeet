import SwiftUI

struct ImportedRunDetailsView: View {
    @Environment(\.dismiss) private var dismiss
    let run: ImportedRunRecord
    let trailName: String
    let route: ImportedRunRouteDetails

    var body: some View {
        Group {
            ScrollView {
                ImportedRunDetailsContent(run: run, trailName: trailName, route: route)
                    .padding(20)
            }
            .background(HUDTheme.mapBackground)
            .powderSheet(title: "Run details")
        }
        .preferredColorScheme(.dark)
    }
}

/// Separate content allows the actual sheet layout to be rendered in tests.
struct ImportedRunDetailsContent: View {
    let run: ImportedRunRecord
    let trailName: String
    let route: ImportedRunRouteDetails

    var body: some View {
        let status = ImportedRunMatchStatus(method: run.matchMethod, confidence: run.matchConfidence,
            dataset: run.datasetVersion, edgeID: run.edgeId, segments: run.matchedSegmentIds)
        VStack(alignment: .leading, spacing: 18) {
            Text(trailName).hudType(.title).foregroundStyle(HUDTheme.primaryText)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 7) {
                Text(status.label).hudType(.label)
                    .foregroundStyle(status == .connected ? HUDTheme.accentCyan : HUDTheme.accentAmber)
                Text(status.explanation).hudType(.body).foregroundStyle(HUDTheme.secondaryText)
            }
            VStack(alignment: .leading, spacing: 12) {
                Text("RECORDED ROUTE ORDER").hudType(.label).foregroundStyle(HUDTheme.accentCyan)
                if let reason = route.unavailableReason {
                    Text(reason.explanation).hudType(.body).foregroundStyle(HUDTheme.secondaryText)
                } else {
                    Text("Sections are shown in travel order. Unnamed sections are kept.")
                        .hudType(.body).foregroundStyle(HUDTheme.secondaryText)
                    ForEach(Array(route.sections.enumerated()), id: \.element.id) { index, section in
                        HStack(alignment: .top, spacing: 10) {
                            Text("\(index + 1)").hudType(.label).foregroundStyle(HUDTheme.accentCyan)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(section.title).hudType(.bodyEmph).foregroundStyle(HUDTheme.primaryText)
                                Text("\(section.segmentIDs.count) map \(section.segmentIDs.count == 1 ? "segment" : "segments")")
                                    .hudType(.caption).foregroundStyle(HUDTheme.secondaryText)
                            }
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }
            if let version = run.datasetVersion {
                DisclosureGroup {
                    Text(version).hudType(.caption).foregroundStyle(HUDTheme.secondaryText)
                        .textSelection(.enabled)
                } label: {
                    Text("Recorded mountain version").hudType(.body)
                        .foregroundStyle(HUDTheme.secondaryText)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }
}
