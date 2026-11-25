import AppCore
import MountainCore
import SwiftUI

/// Logs, pushed from Activity: every ski day, newest first, searchable by day
/// or resort. Each day is one glass card (date, resort, distance, vertical)
/// that opens to its runs; a run opens its detail; a day or a run can be
/// deleted.
struct ActivityLogsView: View {
    @Environment(AppModel.self) private var model

    /// How the days are ordered.
    private enum Sort: String, CaseIterable {
        case newest, oldest, resort, runs, vertical
    }

    @State private var query = ""
    @AppStorage("powdermeet.logs.sort") private var sortChoice = Sort.newest.rawValue
    @State private var expanded: Set<String> = []
    @State private var pendingDay: ActivityHistory.Day?
    @State private var pendingRun: ActivityHistory.Run?

    private var activity: ActivityModel { model.activity }

    var body: some View {
        content
            .confirmCard(
                item: $pendingDay, title: { $0.runs.count == 1 ? "Delete 1 run?" : "Delete \($0.runs.count) runs?" },
                message: { "This deletes every run from \(ActivityDates.day($0.day)) and recalculates your stats and pace." },
                confirm: "Delete"
            ) { activity.delete($0) }
            .confirmCard(
                item: $pendingRun, title: { _ in "Delete this run?" },
                message: { _ in "Your stats and pace are recalculated from the runs that remain." },
                confirm: "Delete"
            ) { activity.delete($0) }
    }

    @ViewBuilder
    private var content: some View {
        if activity.history.isEmpty {
            Group {
                if activity.isLoading && !activity.hasLoaded {
                    ProgressView()
                } else if let failure = activity.failure, !activity.hasLoaded {
                    EmptyStateView(
                        icon: "exclamationmark.triangle", title: failure.userMessage,
                        actionTitle: "Retry", action: { activity.refresh() })
                } else {
                    EmptyStateView(
                        icon: "tray", title: "No runs yet",
                        detail: "Import a GPX, TCX, FIT, Slopes or Ski Tracks file from Activity, or turn on live recording.")
                }
            }
            .frame(maxWidth: .infinity)
            .glassCard()
            .pageScroll()
        } else {
            Group {
                let shown = days
                if shown.isEmpty {
                    EmptyStateView(
                        icon: "magnifyingglass", title: "No runs match “\(query)”",
                        actionTitle: "Clear search", action: { query = "" })
                        .glassCard()
                } else {
                    ForEach(shown) { day in
                        daySection(day)
                    }
                }
            }
            .pageScroll(spacing: GlassLayout.gap) {
                HStack(spacing: GlassLayout.gap) {
                    BottomSearchBar(text: $query, prompt: "Search by day or resort")
                    FloatingSortButton(
                        selection: Binding(
                            get: { Sort(rawValue: sortChoice) ?? .newest }, set: { sortChoice = $0.rawValue }),
                        options: [
                            (.newest, "Newest", "calendar"),
                            (.oldest, "Oldest", "calendar.badge.clock"),
                            (.resort, "Resort", "mountain.2"),
                            (.runs, "Most Runs", "figure.skiing.downhill"),
                            (.vertical, "Most Vertical", "arrow.down.right"),
                        ])
                        .frame(width: GlassLayout.barHeight, height: GlassLayout.barHeight)
                }
            }
        }
    }

    /// A day matches its resort's name or any spelling of its date: "jan",
    /// "jan 14", "2026-01-14", "14".
    private var days: [ActivityHistory.Day] {
        let all = sorted(activity.history.days)
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return all }
        return all.filter { day in
            day.resortName.lowercased().contains(needle)
                || day.day.contains(needle)
                || ActivityDates.short(day.day).lowercased().contains(needle)
                || ActivityDates.day(day.day).lowercased().contains(needle)
        }
    }

    private func sorted(_ days: [ActivityHistory.Day]) -> [ActivityHistory.Day] {
        let newestFirst: (ActivityHistory.Day, ActivityHistory.Day) -> Bool = { $0.startedAt > $1.startedAt }
        switch Sort(rawValue: sortChoice) ?? .newest {
        case .newest: return days.sorted(by: newestFirst)
        case .oldest: return days.sorted { $0.startedAt < $1.startedAt }
        case .resort:
            return days.sorted {
                let order = $0.resortName.localizedCaseInsensitiveCompare($1.resortName)
                return order == .orderedSame ? newestFirst($0, $1) : order == .orderedAscending
            }
        case .runs:
            return days.sorted { $0.runs.count == $1.runs.count ? newestFirst($0, $1) : $0.runs.count > $1.runs.count }
        case .vertical:
            return days.sorted { $0.verticalM == $1.verticalM ? newestFirst($0, $1) : $0.verticalM > $1.verticalM }
        }
    }

    // MARK: Days

    private func daySection(_ day: ActivityHistory.Day) -> some View {
        let isOpen = expanded.contains(day.id)
        return VStack(spacing: 0) {
            dayRow(day, isOpen: isOpen)
            if isOpen {
                ForEach(day.runs) { run in
                    GlassDivider()
                    ActivityLogRunRow(
                        run: run, isDeleting: activity.deleting.contains(run.id.uuidString),
                        onOpen: { model.pushPanel(.runDetail(run)) }, onDelete: { pendingRun = run }
                    )
                }
            }
        }
        .glassCard(padding: 0)
        .opacity(activity.deleting.contains(day.id) ? 0.5 : 1)
    }

    private func dayRow(_ day: ActivityHistory.Day, isOpen: Bool) -> some View {
        HStack(spacing: 4) {
            Button {
                withAnimation(.easeInOut(duration: 0.18)) {
                    if isOpen { expanded.remove(day.id) } else { expanded.insert(day.id) }
                }
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.bold))
                        .foregroundStyle(HUDTheme.secondaryText)
                        .rotationEffect(.degrees(isOpen ? 90 : 0))
                        .frame(width: 14)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(day.resortName)
                            .textRole(.bodyEmph)
                            .foregroundStyle(HUDTheme.primaryText)
                            .lineLimit(1)
                        Text("\(ActivityDates.day(day.day)) · \(day.runs.count) \(day.runs.count == 1 ? "run" : "runs")")
                            .textRole(.label)
                            .foregroundStyle(HUDTheme.secondaryText)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(day.distanceM > 0 ? UnitFormatter.distance(day.distanceM) : "—")
                            .textRole(.label).fontWeight(.semibold)
                            .foregroundStyle(HUDTheme.primaryText)
                        Text(day.verticalM > 0 ? "\(UnitFormatter.verticalDrop(day.verticalM)) down" : "—")
                            .textRole(.caption)
                            .foregroundStyle(HUDTheme.secondaryText)
                    }
                    .monospacedDigit()
                    .lineLimit(1)
                }
                .padding(.leading, GlassLayout.cardPadding)
                .frame(maxWidth: .infinity, minHeight: GlassLayout.rowHeight)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(ActivityDates.day(day.day)), \(day.resortName), \(day.runs.count) \(day.runs.count == 1 ? "run" : "runs")")
            .accessibilityValue(isOpen ? "Expanded" : "Collapsed")

            Button { pendingDay = day } label: {
                Image(systemName: "trash")
                    .font(.subheadline)
                    .foregroundStyle(HUDTheme.secondaryText)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.trailing, 6)
            .disabled(activity.deleting.contains(day.id))
            .accessibilityLabel("Delete runs from \(ActivityDates.day(day.day))")
        }
    }
}

/// One run in an open day: its difficulty, name, speed, duration and time of
/// day, and where it came from.
private struct ActivityLogRunRow: View {
    let run: ActivityHistory.Run
    let isDeleting: Bool
    let onOpen: () -> Void
    let onDelete: () -> Void

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("h:mm a")
        return formatter
    }()

    private var title: String {
        var name = run.title
        // An unnamed run's title already says its rating.
        if TerrainName.named(run.name) != nil, let difficulty = run.difficulty, difficulty != .unknown {
            name += " · \(difficulty.displayName)"
        }
        return name
    }

    /// Speed, duration, time of day and where the run came from.
    private var detail: String {
        [
            run.avgSpeedMS.map(UnitFormatter.speed) ?? "—",
            UnitFormatter.formatTime(run.durationS),
            Self.timeFormatter.string(from: run.startedAt),
            Wording.runSource(run.source),
        ].joined(separator: " · ")
    }

    var body: some View {
        HStack(spacing: 4) {
            Button(action: onOpen) {
                HStack(spacing: 12) {
                    Image(systemName: run.difficulty?.icon ?? "circle.dashed")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(run.difficulty.map(HUDTheme.color(for:)) ?? HUDTheme.secondaryText)
                        .frame(width: 14)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                            .textRole(.body)
                            .foregroundStyle(HUDTheme.primaryText)
                            .lineLimit(1)
                        Text(detail)
                            .textRole(.caption)
                            .monospacedDigit()
                            .foregroundStyle(HUDTheme.secondaryText)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    Spacer(minLength: 4)
                    GlassChevron()
                }
                .padding(.leading, GlassLayout.cardPadding)
                .frame(minHeight: GlassLayout.rowHeight)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(title)
            .accessibilityValue(detail)
            .accessibilityHint("Shows the route and figures for this run")

            Button(action: onDelete) {
                Image(systemName: "trash")
                    .font(.footnote)
                    .foregroundStyle(HUDTheme.secondaryText)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.trailing, 6)
            .disabled(isDeleting)
            .accessibilityLabel("Delete \(title)")
        }
        .opacity(isDeleting ? 0.4 : 1)
    }
}
