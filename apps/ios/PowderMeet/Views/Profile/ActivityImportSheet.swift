import AppCore
import SwiftUI

/// After a batch in which a file failed: what was found in each file (resort,
/// day, runs, warnings) and, in plain words, why the others were not imported.
struct ActivityImportSheet: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let reports = model.activity.lastReports
        Group {
            SectionHeader(summary(reports))
            ForEach(reports) { report in
                card(report)
            }
        }
        .pageScroll(spacing: GlassLayout.gap)
        .onDisappear { model.activity.showsReport = false }
    }

    private func summary(_ reports: [ActivityLibrary.FileReport]) -> String {
        var added = 0, failed = 0
        for report in reports {
            switch report.outcome {
            case .imported(let imported): added += imported.runsAdded + imported.runsQueued
            case .failed: failed += 1
            }
        }
        var text = "\(added) \(added == 1 ? "run" : "runs") added"
        if failed > 0 { text += " · \(failed) \(failed == 1 ? "file" : "files") not imported" }
        return text
    }

    private func card(_ report: ActivityLibrary.FileReport) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            switch report.outcome {
            case .imported(let imported):
                header(
                    icon: imported.runsAdded + imported.runsQueued > 0 ? "checkmark.circle.fill" : "equal.circle.fill",
                    tint: imported.runsAdded + imported.runsQueued > 0 ? HUDTheme.accentGreen : HUDTheme.secondaryText,
                    title: title(imported), file: report.fileName
                )
                Text(counts(imported))
                    .textRole(.label)
                    .foregroundColor(HUDTheme.primaryText.opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(imported.notes, id: \.self) { note in
                    line(icon: "info.circle", tint: HUDTheme.accentAmber, note)
                }
            case .failed(let message):
                header(
                    icon: "xmark.octagon.fill", tint: HUDTheme.accentRed,
                    title: "Not imported", file: report.fileName
                )
                line(icon: "exclamationmark.triangle", tint: HUDTheme.accentRed, message)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
        .accessibilityElement(children: .combine)
    }

    private func header(icon: String, tint: Color, title: String, file: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.subheadline.weight(.semibold))
                .foregroundColor(tint)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .textRole(.label)
                    .foregroundColor(HUDTheme.primaryText.opacity(0.9))
                    .fixedSize(horizontal: false, vertical: true)
                Text(file)
                    .textRole(.caption)
                    .foregroundColor(HUDTheme.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }

    private func line(icon: String, tint: Color, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: icon)
                .font(.caption2.weight(.semibold))
                .foregroundColor(tint)
            Text(text)
                .textRole(.label)
                .foregroundColor(HUDTheme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.leading, 32)
    }

    private func title(_ imported: ActivityLibrary.FileReport.Imported) -> String {
        let resort = (imported.resortName ?? ActivityHistory.unknownResort)
        var day = ActivityDates.day(imported.day)
        if imported.dayCount > 1 { day += " + \(imported.dayCount - 1) more" }
        return "\(resort) · \(day)"
    }

    private func counts(_ imported: ActivityLibrary.FileReport.Imported) -> String {
        func runs(_ count: Int) -> String { count == 1 ? "1 run" : "\(count) runs" }
        var parts = ["\(runs(imported.runsFound)) found"]
        if imported.runsAdded > 0 { parts.append("\(imported.runsAdded) added") }
        if imported.runsAlreadyHad > 0 {
            parts.append(
                imported.runsAlreadyHad == imported.runsFound
                    ? "all already in your history" : "\(imported.runsAlreadyHad) already in your history"
            )
        }
        if imported.verticalM > 0 { parts.append("\(UnitFormatter.verticalDrop(imported.verticalM)) vertical") }
        if let app = imported.sourceApp { parts.append("from \(app)") }
        return parts.joined(separator: " · ")
    }
}
