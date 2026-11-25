import AppCore
import MountainCore
import SwiftUI

/// One run from Logs: the figures, a small drawing of
/// the recorded track, and its route: the matcher's sections in the order
/// they were skied (named and unnamed runs, connections, off the map), each
/// with its start time, distance and duration (`RunDetail`). The log row
/// keeps the run's one name (`primaryEdgeID`).
struct ActivityRunDetailSheet: View {
    @Environment(AppModel.self) private var model
    let run: ActivityHistory.Run

    private var activity: ActivityModel { model.activity }

    var body: some View {
        Group {
                titleBlock
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .glassCard()
                figures
                switch activity.details[run.id] {
                case .loaded(let detail):
                    if detail.track.count >= 2 {
                        RunTrackShape(track: detail.track)
                            .stroke(run.difficulty.map(HUDTheme.color(for:)) ?? HUDTheme.accent,
                                    style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                            .frame(height: 160)
                            .glassCard()
                            .accessibilityLabel("Drawing of the recorded track")
                    }
                    route(detail)
                case .failed(let error):
                    note(icon: "exclamationmark.triangle", tint: HUDTheme.accentAmber, error.userMessage)
                case .missing:
                    note(icon: "questionmark.circle", tint: HUDTheme.secondaryText,
                         "This run is no longer in your history.")
                case .loading, nil:
                    HStack(spacing: 8) {
                        ProgressView().tint(HUDTheme.accent).scaleEffect(0.7)
                        Text("Loading route").textRole(.label).foregroundColor(HUDTheme.secondaryText)
                    }
                    .frame(maxWidth: .infinity, minHeight: 60)
                    .glassCard()
                }
        }
        .pageScroll()
        .task { activity.loadDetail(run.id) }
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(run.title)
                .textRole(.title)
                .foregroundColor(HUDTheme.primaryText)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                if let difficulty = run.difficulty, difficulty != .unknown {
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(HUDTheme.color(for: difficulty))
                        .frame(width: 10, height: 10)
                    Text(difficulty.displayName)
                        .textRole(.label).foregroundColor(HUDTheme.secondaryText)
                }
                Text(run.startedAt.formatted(date: .abbreviated, time: .shortened))
                    .textRole(.label).foregroundColor(HUDTheme.secondaryText)
                Text(Wording.runSource(run.source))
                    .textRole(.caption).foregroundColor(HUDTheme.secondaryText.opacity(0.7))
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var figures: some View {
        let cells: [(label: String, value: String)] = [
            ("Vertical", run.verticalM.map(UnitFormatter.verticalDrop) ?? "—"),
            ("Distance", run.distanceM.map(UnitFormatter.distance) ?? "—"),
            ("Duration", UnitFormatter.formatTime(run.durationS)),
            ("Avg speed", run.avgSpeedMS.map(UnitFormatter.speed) ?? "—"),
            ("Top speed", run.topSpeedMS.map(UnitFormatter.speed) ?? "—"),
        ]
        // One card, three across then two: no figure stranded on a row of its
        // own, and labels never break mid-word.
        return Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 12) {
            GridRow { ForEach(cells.prefix(3), id: \.label) { figure($0) } }
            GridRow { ForEach(cells.suffix(2), id: \.label) { figure($0) } }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
    }

    private func figure(_ cell: (label: String, value: String)) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(cell.label).textRole(.caption).foregroundColor(HUDTheme.secondaryText)
                .lineLimit(1).minimumScaleFactor(0.8)
            Text(cell.value).textRole(.metric).foregroundColor(HUDTheme.primaryText)
                .lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func route(_ detail: RunDetail) -> some View {
        switch detail.unavailable {
        case .notMatched:
            note(icon: "map", tint: HUDTheme.secondaryText, "Not placed on a resort map")
        case .mapNotOnPhone:
            note(icon: "map", tint: HUDTheme.secondaryText, "Open this resort's map once to see its trails")
        case nil:
            GlassSection("Route") {
                ForEach(Array(detail.sections.enumerated()), id: \.element.id) { index, section in
                    if index > 0 { GlassDivider(inset: 54) }
                    sectionRow(section)
                }
            }
        }
    }

    /// One stretch of the path: its mark, name and kind, then when it began,
    /// how far and how long.
    private func sectionRow(_ section: RunDetail.Section) -> some View {
        HStack(spacing: 12) {
            sectionMark(section)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(sectionTitle(section))
                    .textRole(.body)
                    .foregroundStyle(section.name == nil ? HUDTheme.secondaryText : HUDTheme.primaryText)
                    .lineLimit(1)
                Text("\(section.enterAt.formatted(date: .omitted, time: .shortened)) · \(UnitFormatter.distance(section.lengthM)) · \(UnitFormatter.formatTime(section.durationS))")
                    .textRole(.label)
                    .foregroundStyle(HUDTheme.secondaryText)
                    .monospacedDigit()
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, GlassLayout.cardPadding)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, minHeight: GlassLayout.rowHeight, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func sectionMark(_ section: RunDetail.Section) -> some View {
        switch section.kind {
        case .run:
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(section.difficulty.map(HUDTheme.color(for:)) ?? HUDTheme.secondaryText.opacity(0.4))
                .frame(width: 10, height: 10)
        case .connection:
            Image(systemName: "arrow.left.and.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(HUDTheme.secondaryText)
        case .offMap:
            Image(systemName: "mappin.slash")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(HUDTheme.secondaryText)
        }
    }

    private func sectionTitle(_ section: RunDetail.Section) -> String {
        switch section.kind {
        case .offMap:
            return "Off the map"
        case .connection:
            return TerrainName.connector(section.name)
        case .run:
            var title = TerrainName.run(section.name, difficulty: section.difficulty)
            // An unnamed section's title already says its rating.
            if TerrainName.named(section.name) != nil, let difficulty = section.difficulty, difficulty != .unknown {
                title += " · \(difficulty.displayName)"
            }
            return title
        }
    }

    private func note(icon: String, tint: Color, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).font(.footnote).foregroundColor(tint)
            Text(text).textRole(.body).foregroundColor(HUDTheme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .glassCard()
    }
}

/// The track fitted into the frame, north up, with longitude scaled for
/// latitude so the shape is true.
private nonisolated struct RunTrackShape: Shape {
    let track: [Coordinate]

    func path(in rect: CGRect) -> Path {
        guard let first = track.first else { return Path() }
        let scale = cos(first.lat * .pi / 180)
        let xs = track.map { $0.lon * scale }, ys = track.map(\.lat)
        guard let minX = xs.min(), let maxX = xs.max(), let minY = ys.min(), let maxY = ys.max() else { return Path() }
        let span = max(maxX - minX, maxY - minY, 1e-6)
        let size = min(rect.width, rect.height)
        let offsetX = rect.minX + (rect.width - size * (maxX - minX) / span) / 2
        let offsetY = rect.minY + (rect.height - size * (maxY - minY) / span) / 2
        var path = Path()
        for (index, (x, y)) in zip(xs, ys).enumerated() {
            let point = CGPoint(x: offsetX + (x - minX) / span * size, y: offsetY + (maxY - y) / span * size)
            if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        return path
    }
}
