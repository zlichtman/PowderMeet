//
//  ImportedRunsView.swift
//  PowderMeet
//
//  Imported-runs audit. Reachable from Profile → Activity → VIEW
//  IMPORTED RUNS. Lists every day of imported runs as a single
//  collapsible summary row:
//
//    > Date · Resort · Runs · Distance · Elevation
//
//  Tapping a row expands it to show per-run detail (trail, time,
//  duration, speed); tapping again collapses. Filter pills at the top
//  scope the list by recent date range or by resort. Each day row
//  carries a red trash button that wipes that day with confirmation.
//
//  The full "delete every run + reset edge speeds + reset preset"
//  flow lives on the Account tab as RESET ACTIVITY DATA — this view
//  is for selective audit + deletion only.
//
//  RLS scopes every read/write to `auth.uid() = profile_id`.
//

import SwiftUI

struct ImportedRunsView: View {
    @Environment(SupabaseManager.self) private var supabase
    @Environment(ResortDataManager.self) private var resortManager
    @Environment(\.dismiss) private var dismiss

    @State private var runs: [ImportedRunRecord] = []
    @State private var isLoading = true
    @State private var loadError: String?
    @State private var dayPendingDelete: DayDeletion?

    @State private var searchQuery: String = ""
    @State private var expandedDates: Set<Date> = []

    private struct DayDeletion: Identifiable {
        let id = UUID()
        let date: Date
        let runs: [ImportedRunRecord]
    }

    /// Compact "MAY 1" form used inside the log row. Day-of-week and
    /// year were dropped at the user's request — the search bar already
    /// accepts both, so the row stays scannable.
    private static let dayRowFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d"
        return f
    }()

    /// Long form used in confirmation alerts and accessibility labels —
    /// somewhere we still want the full unambiguous date.
    private static let dayHeaderFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEE · MMM d, yyyy"
        return f
    }()

    /// Set of stringified forms of `date` used for substring-search.
    /// Covers the natural ways someone might type a date:
    ///   "may", "may 1", "may 1, 2026", "5/1", "5/1/2026",
    ///   "2026-05-01", "2026", "friday", "fri".
    private static let dateSearchFormatters: [DateFormatter] = {
        let formats = [
            "EEEE",            // Friday
            "EEE",             // Fri
            "MMMM",            // May
            "MMM",             // May
            "MMMM d",          // May 1
            "MMM d",           // May 1
            "MMMM d, yyyy",    // May 1, 2026
            "yyyy",            // 2026
            "M/d",             // 5/1
            "M/d/yyyy",        // 5/1/2026
            "yyyy-MM-dd"       // 2026-05-01
        ]
        return formats.map { fmt in
            let f = DateFormatter()
            f.dateFormat = fmt
            return f
        }
    }()

    private static let runTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "h:mm a"
        return f
    }()

    /// Filtered grouped-by-day rows. Empty query → all days. Otherwise
    /// keep days whose date OR resort name(s) substring-match the
    /// query. Date matching covers month names, weekday names, slash
    /// + ISO formats, and year (see `dateSearchFormatters`).
    private var filteredGrouped: [(date: Date, runs: [ImportedRunRecord])] {
        let q = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let allDays = runs.groupedByDay()
        guard !q.isEmpty else { return allDays }
        return allDays.filter { day in
            if dateMatches(day.date, query: q) { return true }
            if resortMatches(day.runs, query: q) { return true }
            return false
        }
    }

    private func dateMatches(_ date: Date, query: String) -> Bool {
        for fmt in Self.dateSearchFormatters {
            if fmt.string(from: date).lowercased().contains(query) {
                return true
            }
        }
        return false
    }

    private func resortMatches(_ dayRuns: [ImportedRunRecord], query: String) -> Bool {
        for run in dayRuns {
            guard let id = run.resortId else { continue }
            // Match the catalog's display name and the raw id (slug)
            // so users can type either "vail" or the id.
            if id.lowercased().contains(query) { return true }
            if let name = ResortEntry.catalog.first(where: { $0.id == id })?.name,
               name.lowercased().contains(query) {
                return true
            }
        }
        return false
    }

    var body: some View {
        ZStack {
            HUDTheme.mapBackground.ignoresSafeArea()

            VStack(spacing: 0) {
                header
                content
            }
        }
        // Search field is pinned near the top and the list scrolls on
        // its own — opting out of keyboard avoidance stops the whole
        // sheet (background included) from lurching upward on focus.
        .ignoresSafeArea(.keyboard, edges: .bottom)
        .preferredColorScheme(.dark)
        .task { await reload() }
        .alert(
            (dayPendingDelete?.runs.count ?? 0) == 1
                ? "Delete 1 run?"
                : "Delete \(dayPendingDelete?.runs.count ?? 0) runs?",
            isPresented: Binding(
                get: { dayPendingDelete != nil },
                set: { if !$0 { dayPendingDelete = nil } }
            )
        ) {
            Button("Cancel", role: .cancel) { dayPendingDelete = nil }
            Button("Delete", role: .destructive) {
                if let day = dayPendingDelete {
                    Task { await deleteDay(day) }
                }
                dayPendingDelete = nil
            }
        } message: {
            if let day = dayPendingDelete {
                Text("This deletes every imported run from \(Self.dayHeaderFormatter.string(from: day.date)) and recomputes your profile stats.")
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Button { dismiss() } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(HUDTheme.accent)
            }
            .buttonStyle(.plain)

            Spacer()

            Text("LOGS")
                .hudType(.section)
                .foregroundColor(HUDTheme.primaryText)
                .tracking(2)

            Spacer()

            Button { Task { await reload() } } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(HUDTheme.accent.opacity(isLoading ? 0.3 : 1))
            }
            .buttonStyle(.plain)
            .disabled(isLoading)
            .accessibilityLabel("Reload runs")
        }
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .padding(.bottom, 14)
        .background(HUDTheme.headerBackground)
        .overlay(
            Rectangle()
                .fill(HUDTheme.cardBorder)
                .frame(height: 0.5),
            alignment: .bottom
        )
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if isLoading {
            loadingState
        } else if let loadError {
            errorState(message: loadError)
        } else if runs.isEmpty {
            emptyState
        } else {
            VStack(spacing: 0) {
                searchBar
                dayList
            }
        }
    }

    private var loadingState: some View {
        VStack {
            ProgressView()
                .tint(HUDTheme.accent)
                .scaleEffect(0.8)
            Text("LOADING")
                .hudType(.label)
                .foregroundColor(HUDTheme.secondaryText)
                .tracking(1.5)
                .padding(.top, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "tray")
                .font(.system(size: 28))
                .foregroundColor(HUDTheme.secondaryText.opacity(0.3))
            Text("NO LOGS YET")
                .hudType(.section)
                .foregroundColor(HUDTheme.primaryText)
                .tracking(1.5)
            Text("UPLOAD A GPX, TCX, FIT, OR SLOPES FILE\nFROM THE PROFILE PAGE TO START.")
                .hudType(.caption)
                .foregroundColor(HUDTheme.secondaryText)
                .tracking(0.5)
                .multilineTextAlignment(.center)
                .lineSpacing(4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 20)
    }

    private func errorState(message: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 24))
                .foregroundColor(HUDTheme.accentAmber)
            Text(message.uppercased())
                .hudType(.label)
                .foregroundColor(HUDTheme.primaryText)
                .tracking(0.5)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 20)
            Button { Task { await reload() } } label: {
                Text("RETRY")
                    .hudType(.label)
                    .foregroundColor(HUDTheme.accent)
                    .tracking(1.5)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(HUDTheme.accent.opacity(0.4), lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Search bar

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12))
                .foregroundColor(HUDTheme.secondaryText)

            TextField("", text: $searchQuery, prompt: Text("SEARCH BY DAY OR RESORT")
                .font(HUDTheme.font(.body))
                .foregroundColor(HUDTheme.textTertiary)
            )
            .hudType(.body)
            .foregroundColor(HUDTheme.primaryText)
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
            .submitLabel(.search)

            Button { searchQuery = "" } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 12))
                    .foregroundColor(HUDTheme.secondaryText)
            }
            .opacity(searchQuery.isEmpty ? 0 : 1)
            .accessibilityLabel("Clear search")
        }
        .padding(.horizontal, 12)
        .frame(height: 40)
        .background(HUDTheme.inputBackground)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(HUDTheme.cardBorder, lineWidth: 1)
        )
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 6)
    }

    // MARK: - Day list

    private var dayList: some View {
        ScrollView {
            columnHeader
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 6)

            let days = filteredGrouped
            if days.isEmpty {
                noMatchesState
            } else {
                LazyVStack(spacing: 8) {
                    ForEach(days, id: \.date) { day in
                        daySection(for: day)
                    }
                    Spacer().frame(height: 16)
                }
                .padding(.horizontal, 16)
            }
        }
    }

    private var noMatchesState: some View {
        VStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 24))
                .foregroundColor(HUDTheme.secondaryText.opacity(0.3))
            Text("NO RUNS MATCH \"\(searchQuery.uppercased())\"")
                .hudType(.label)
                .foregroundColor(HUDTheme.secondaryText)
                .tracking(1.2)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 20)
            Button {
                searchQuery = ""
            } label: {
                Text("CLEAR SEARCH")
                    .hudType(.label)
                    .foregroundColor(HUDTheme.accent)
                    .tracking(1.2)
            }
            .buttonStyle(.plain)
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 36)
    }

    // ── Column header ────────────────────────────────────────────────

    private var columnHeader: some View {
        HStack(spacing: 8) {
            // Reserve space for the row's chevron column.
            Color.clear.frame(width: 14)
            columnLabel("DATE",      width: dateColumnWidth, alignment: .leading)
            columnLabel("RESORT",    width: nil,             alignment: .leading)
            columnLabel("DISTANCE",  width: 64,              alignment: .trailing)
            columnLabel("ELEVATION", width: 60,              alignment: .trailing)
            Color.clear.frame(width: 28)
        }
    }

    private func columnLabel(_ text: String, width: CGFloat?, alignment: Alignment) -> some View {
        let label = Text(text)
            .hudType(.caption)
            .foregroundColor(HUDTheme.secondaryText.opacity(0.5))
            .tracking(1.5)
        if let width {
            return AnyView(label.frame(width: width, alignment: alignment))
        }
        return AnyView(label.frame(maxWidth: .infinity, alignment: alignment))
    }

    /// Compact column width sized for the "MAY 1" day-of-month form.
    private let dateColumnWidth: CGFloat = 50

    // ── Day section (collapsible) ────────────────────────────────────

    @ViewBuilder
    private func daySection(for day: (date: Date, runs: [ImportedRunRecord])) -> some View {
        let isExpanded = expandedDates.contains(day.date)
        VStack(spacing: 0) {
            dayRow(for: day, isExpanded: isExpanded)
            if isExpanded {
                VStack(spacing: 0) {
                    Rectangle()
                        .fill(HUDTheme.cardBorder.opacity(0.4))
                        .frame(height: 0.5)
                        .padding(.horizontal, 12)

                    ForEach(day.runs) { run in
                        runRow(run)
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) {
                                    Task { await deleteRun(run) }
                                } label: {
                                    Label("Delete", systemImage: "trash.fill")
                                }
                            }
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .background(HUDTheme.cardBackground.opacity(0.7))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(HUDTheme.cardBorder, lineWidth: 0.5)
        )
    }

    private func dayRow(for day: (date: Date, runs: [ImportedRunRecord]), isExpanded: Bool) -> some View {
        let totalDistance = day.runs.reduce(0.0) { $0 + $1.distanceM }
        let totalVertical = day.runs.reduce(0.0) { $0 + $1.verticalM }
        let resort = dominantResort(for: day.runs)

        return HStack(spacing: 8) {
            Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                .font(.system(size: 9, weight: .bold))
                .foregroundColor(HUDTheme.secondaryText)
                .frame(width: 14)

            Text(Self.dayRowFormatter.string(from: day.date).uppercased())
                .hudType(.label)
                .foregroundColor(HUDTheme.primaryText)
                .tracking(0.6)
                .lineLimit(1)
                .frame(width: dateColumnWidth, alignment: .leading)

            Text(resort)
                .hudType(.label)
                .foregroundColor(HUDTheme.accent)
                .tracking(0.5)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text(UnitFormatter.distance(totalDistance))
                .hudType(.label)
                .foregroundColor(HUDTheme.primaryText)
                .lineLimit(1)
                .frame(width: 64, alignment: .trailing)

            Text(UnitFormatter.elevation(totalVertical))
                .hudType(.label)
                .foregroundColor(HUDTheme.primaryText)
                .lineLimit(1)
                .frame(width: 60, alignment: .trailing)

            Button {
                dayPendingDelete = .init(date: day.date, runs: day.runs)
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(HUDTheme.accent)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Delete runs from \(Self.dayHeaderFormatter.string(from: day.date))")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.18)) {
                if isExpanded {
                    expandedDates.remove(day.date)
                } else {
                    expandedDates.insert(day.date)
                }
            }
        }
    }

    // ── Per-run row (rendered when day is expanded) ──────────────────

    /// Per-run row inside an expanded day section. Single line, every
    /// field always fits:
    ///
    ///   [ Riva Ridge        ]  10:23 AM   32.5 KM/H   2:14   HEALTH
    ///     └ name in a difficulty-colored tag (replaces the swatch —
    ///       the color *is* the difficulty signal, so the name itself
    ///       stays a plain trail name with no color/location words)
    ///                          └ time ──┘ └ speed ─┘ └ dur ┘ └ source
    ///
    /// The name tag is the only flexible element (truncates tail); the
    /// three stats and the source tag are fixed and shrink-to-fit, so
    /// the row reads identically no matter the resort, the source, or
    /// how much a given importer populated.
    private func runRow(_ run: ImportedRunRecord) -> some View {
        let tint = difficultyColor(run.difficulty ?? "")
        return HStack(spacing: 6) {
            // Tag hugs the trail name — background/stroke are applied at
            // the text's intrinsic size; the maxWidth frame comes AFTER
            // so it only contributes transparent slack (keeping the
            // stat columns aligned), never a stretched colored box.
            Text(trailNameForRow(run))
                .hudType(.caption)
                .foregroundColor(HUDTheme.primaryText)
                .tracking(0.3)
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(tint.opacity(0.22))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .stroke(tint.opacity(0.55), lineWidth: 1)
                )
                .frame(maxWidth: .infinity, alignment: .leading)

            // One right-anchored measurement cluster, fixed columns so
            // time / speed / duration line up vertically row to row.
            HStack(spacing: 6) {
                stat(Self.runTimeFormatter.string(from: run.runAt).uppercased(),
                     color: HUDTheme.accentCyan, width: 56)
                statDivider
                stat(run.speedKmh > 0 ? "\(String(format: "%.1f", run.speedKmh)) KM/H" : "—",
                     color: HUDTheme.accentAmber, width: 58)
                statDivider
                stat(run.durationDisplay, color: HUDTheme.accentGreen, width: 44)
            }

            sourcePill(for: run.sourceBadge)
                .frame(width: 62, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .overlay(
            Rectangle()
                .fill(HUDTheme.cardBorder.opacity(0.25))
                .frame(height: 0.5),
            alignment: .bottom
        )
    }

    /// One fixed-width stat cell. The three measurements each get their
    /// own color so a glance separates time / speed / duration without
    /// reading them; `minimumScaleFactor` keeps the row single-line on
    /// every device width.
    private func stat(_ text: String, color: Color, width: CGFloat) -> some View {
        Text(text)
            .hudType(.caption)
            .foregroundColor(color)
            .tracking(0.3)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .frame(width: width, alignment: .trailing)
    }

    /// Thin "|" rule between measurements so the three values read as
    /// distinct fields rather than one run-on string.
    private var statDivider: some View {
        Text("|")
            .hudType(.caption)
            .foregroundColor(HUDTheme.secondaryText.opacity(0.3))
    }

    /// Difficulty → color. Same palette `SkillLevelPicker` uses so the
    /// run-difficulty colors read identically across the app. Drives
    /// the name tag's tint, which carries the difficulty signal so the
    /// name text never has to.
    private func difficultyColor(_ difficulty: String) -> Color {
        switch difficulty.lowercased() {
        case "green":        return Color(red: 0.30, green: 0.78, blue: 0.40)
        case "blue":         return Color(red: 0.18, green: 0.55, blue: 0.96)
        case "black":        return Color(red: 0.55, green: 0.58, blue: 0.65)
        case "doubleblack":  return Color(red: 0.85, green: 0.18, blue: 0.18)
        case "terrainpark":  return .orange
        default:             return HUDTheme.secondaryText.opacity(0.5)
        }
    }

    /// Source / format pill, colored by brand so a glance distinguishes
    /// Apple Health vs Strava vs Slopes vs Garmin uploads. GPX is
    /// painted Strava-orange because in practice that's the most
    /// common origin (Strava's native export); TCX and FIT both go
    /// Garmin-teal since they're Garmin's native formats. Native
    /// PowderMeet backup + live recordings get neutral app tints.
    @ViewBuilder
    private func sourcePill(for badge: String) -> some View {
        let label = badge.isEmpty ? "—" : badge
        let color = sourceColor(for: badge)
        Text(label)
            .hudType(.caption)
            .foregroundColor(color)
            .tracking(0.6)
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(color.opacity(0.15))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .stroke(color.opacity(0.4), lineWidth: 0.5)
            )
    }

    private func sourceColor(for badge: String) -> Color {
        // Every source gets its own distinct color so a glance tells
        // origins apart. Third-party brands keep their identifying
        // hue; the two first-party sources get app colors — POWDERMEET
        // (backup restore / native picker) the theme accent, LIVE
        // (passive on-device recording) amber — matching the documented
        // palette. (They had briefly regressed to a flat grey, which
        // read as "tag lost its color".)
        switch badge.uppercased() {
        case "HEALTH":     return Color(red: 0.95, green: 0.20, blue: 0.20)  // Apple red
        case "STRAVA",
             "GPX":        return Color(red: 0.99, green: 0.30, blue: 0.01)  // Strava orange
        case "SLOPES":     return Color(red: 0.20, green: 0.55, blue: 0.95)  // Slopes blue
        case "GARMIN",
             "TCX",
             "FIT":        return Color(red: 0.00, green: 0.55, blue: 0.65)  // Garmin teal
        case "POWDERMEET": return HUDTheme.accent                            // app accent
        case "LIVE":       return HUDTheme.accentAmber                       // live = amber
        default:           return HUDTheme.secondaryText.opacity(0.8)
        }
    }

    /// Best-effort trail name for the per-run row. Resolves through
    /// `MountainNaming.edgeLabel` when the loaded graph matches the
    /// run's resort and the run actually has an edgeId. Falls back to
    /// the persisted `trail_name` (frozen at import time) otherwise,
    /// then time-stamped synthetic labels as the last resort.
    private func trailNameForRow(_ run: ImportedRunRecord) -> String {
        // Real trail name when we can resolve one — canonical from the
        // loaded graph, else the name frozen at import time.
        if let edgeId = run.edgeId,
           let graph = resortManager.currentGraph,
           resortManager.currentEntry?.id == run.resortId,
           let edge = graph.edge(byID: edgeId) {
            return Self.stripColorWords(MountainNaming(graph).edgeLabel(edge, style: .canonical))
        }
        if let persisted = run.trailName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !persisted.isEmpty {
            let cleaned = Self.stripColorWords(persisted)
            if !cleaned.isEmpty { return cleaned }
        }
        // No name available. Keep the synthetic label to the bare
        // basics — the difficulty swatch already carries the color and
        // the meta line carries the time, so neither belongs in the
        // name. A session too long to be one run reads as "Whole Day"
        // (HealthKit workouts the elevation splitter couldn't break);
        // everything else is just "Run".
        return run.durationS > 1500 ? "Whole Day" : "Run"
    }

    /// Difficulty words baked into imported trail names ("Blue Run",
    /// "International (Black)", "Riva Ridge - Double Black") are pure
    /// noise in the log now that the name sits in a difficulty-colored
    /// tag — the tag *is* the color. Strip leading and trailing color
    /// tokens; collapse a name that was only a color word down to
    /// "Run". Never returns empty (falls back to the original) so a
    /// real name like "Blue Sky Basin" can't be erased to nothing.
    /// Order matters: multi-word tokens before their substrings.
    private static let colorTokens = [
        "double black", "double-black", "terrain park", "green", "blue", "black",
    ]

    static func stripColorWords(_ raw: String) -> String {
        let original = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        var name = original

        func trimmed(_ s: Substring) -> String {
            String(s).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // Trailing decorations: the canonical "Name · Black" /
        // "Name · Double Black" middot form MountainNaming appends to
        // runs (this is the common one — froze into trail_name at
        // import), plus paren/bracket/dash/pipe variants. Strip
        // repeatedly so "Foo · Black" and "Foo (Black) · Black" both
        // collapse to "Foo".
        var changed = true
        while changed {
            changed = false
            let lower = name.lowercased()
            for token in Self.colorTokens {
                let suffixes = [
                    " \u{00B7} \(token)", " \u{00B7}\(token)", "\u{00B7}\(token)",
                    " (\(token))", " [\(token)]",
                    " - \(token)", " – \(token)", " — \(token)", " | \(token)",
                ]
                for sfx in suffixes where lower.hasSuffix(sfx) {
                    name = trimmed(name.dropLast(sfx.count))
                    changed = true
                    break
                }
                if changed { break }
            }
        }

        // Leading "Blue ", "Double Black ", … repeated.
        changed = true
        while changed {
            changed = false
            let lower = name.lowercased()
            for token in Self.colorTokens where lower.hasPrefix("\(token) ") {
                name = trimmed(name.dropFirst(token.count + 1))
                changed = true
                break
            }
        }

        // Name was only a color word, optionally trailed by Run/Trail.
        let leftover = name.lowercased()
        if leftover.isEmpty
            || leftover == "run" || leftover == "trail"
            || Self.colorTokens.contains(leftover) {
            return "Run"
        }
        return name.isEmpty ? original : name
    }

    /// Best-effort resort label for a day. When the day's runs all map
    /// to the same resort id (the common case), uses that name. When
    /// mixed, picks the resort with the most runs and appends "+N" to
    /// flag the day spanned more than one.
    private func dominantResort(for runs: [ImportedRunRecord]) -> String {
        let ids = runs.compactMap { $0.resortId }
        guard !ids.isEmpty else { return "—" }
        let unique = Set(ids)
        var counts: [String: Int] = [:]
        for id in ids { counts[id, default: 0] += 1 }
        let top = counts.max(by: { $0.value < $1.value })?.key ?? ids[0]
        let name = ResortEntry.catalog
            .first(where: { $0.id == top })?
            .name.uppercased()
            ?? top.uppercased()
        return unique.count > 1 ? "\(name) +\(unique.count - 1)" : name
    }

    // MARK: - Actions

    private func reload() async {
        isLoading = true
        loadError = nil
        do {
            runs = try await supabase.fetchImportedRuns()
        } catch {
            loadError = "Couldn't load runs: \(error.localizedDescription)"
        }
        isLoading = false
    }

    private func deleteRun(_ run: ImportedRunRecord) async {
        let snapshot = runs
        runs.removeAll { $0.id == run.id }
        do {
            try await supabase.deleteImportedRuns(ids: [run.id])
        } catch {
            runs = snapshot
            loadError = "Couldn't delete run: \(error.localizedDescription)"
        }
    }

    private func deleteDay(_ day: DayDeletion) async {
        let ids = day.runs.map(\.id)
        let snapshot = runs
        let removeSet = Set(ids)
        runs.removeAll { removeSet.contains($0.id) }
        expandedDates.remove(day.date)
        do {
            try await supabase.deleteImportedRuns(ids: ids)
        } catch {
            runs = snapshot
            loadError = "Couldn't delete day: \(error.localizedDescription)"
        }
    }
}
