import AppCore
import SwiftUI

/// Settings → Maps: the resort maps this phone keeps, so they work with no
/// signal. One line on what the phone holds, Fly in, the automatic-update
/// switch, then every resort A to Z: the downloaded ones, the recent ones the
/// phone keeps by itself, then the rest. Each row has its control.
struct MapsSettings: View {
    @Environment(AppModel.self) private var model
    @State private var query = ""
    @State private var removing: MapRow?

    var body: some View {
        Group {
            // While a search is typed the page shows only the resorts found:
            // with the keyboard up there is no room for anything else.
            if query.isEmpty { settings }
            list
        }
        .pageScroll(spacing: GlassLayout.gap) {
            if model.catalog.resorts.count > 8 {
                BottomSearchBar(text: $query, prompt: "Search resorts")
            }
        }
        .confirmCard(
            item: $removing, title: { "Remove \($0.name)?" }, message: { MapsText.removeMessage($0) },
            confirm: "Remove"
        ) { model.removeMap($0.id) }
    }

    @ViewBuilder
    private var settings: some View {
        status
        // Above the list, which can run to every resort: at the bottom it
        // goes unnoticed.
        GlassSection("Look") {
            GlassToggleRow(
                icon: "airplane.departure", title: "Fly In",
                isOn: Binding(get: { model.mapFlyIn }, set: { model.mapFlyIn = $0 }))
                .accessibilityHint("Opens a mountain with a slow descending orbit instead of a short turn")
        }
        GlassSection("Updates") {
            GlassToggleRow(
                icon: "arrow.triangle.2.circlepath", title: "Update Downloaded Maps Automatically",
                isOn: Binding(get: { model.mapsUpdateAutomatically }, set: { model.mapsUpdateAutomatically = $0 }))
                .accessibilityHint("On Wi-Fi, and not in Low Power Mode")
        }
    }

    // MARK: The list

    @ViewBuilder
    private var list: some View {
        let rows = matching
        if rows.isEmpty {
            empty.glassCard()
        } else {
            section("Downloaded", rows.filter { $0.place == .downloaded })
            section("Recent", rows.filter { $0.place == .recent })
            let rest = rows.filter { $0.place == nil }
            section(rest.count == rows.count ? "Resorts" : "More Resorts", rest)
        }
    }

    @ViewBuilder
    private var empty: some View {
        if !query.isEmpty {
            EmptyStateView(
                icon: "magnifyingglass", title: "No resorts match “\(query)”",
                actionTitle: "Clear Search", action: { query = "" })
        } else if model.catalog.isLoading {
            EmptyStateView(icon: "map", title: "Loading maps")
        } else {
            EmptyStateView(
                icon: "wifi.slash", title: "No connection",
                detail: "Maps show here once the phone has a signal.",
                actionTitle: "Try Again", action: { model.loadCatalog() })
        }
    }

    private var matching: [MapRow] {
        let terms = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        let rows = model.mapRows.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        guard !terms.isEmpty else { return rows }
        return rows.filter { row in
            let text = "\(row.name) \(row.region ?? "")".lowercased()
            return terms.allSatisfy { text.contains($0) }
        }
    }

    @ViewBuilder
    private func section(_ title: String, _ rows: [MapRow]) -> some View {
        if !rows.isEmpty {
            GlassSection(title) {
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                    if index > 0 { GlassDivider(inset: 54) }
                    GlassRow(
                        icon: MapsText.icon(row), title: row.name, detail: MapsText.detail(row),
                        iconTint: row.failure != nil ? HUDTheme.accentAmber : nil
                    ) {
                        control(row)
                    }
                    .contextMenu { actions(row) }
                }
            }
        }
    }

    // MARK: Controls

    /// The row's one control: download, stop, update or remove. A recent
    /// resort also offers Keep, so it stays once it is no longer recent.
    @ViewBuilder
    private func control(_ row: MapRow) -> some View {
        if row.isUserJob {
            IconButton(systemImage: "xmark", label: "Stop Downloading \(row.name)", tint: HUDTheme.secondaryText) {
                model.stopMapDownload(row.id)
            }
        } else if row.place == nil {
            IconButton(systemImage: "arrow.down.circle", label: "Download \(row.name)", tint: HUDTheme.accent) {
                model.downloadMap(row.id)
            }
        } else if row.updateWaiting {
            IconButton(systemImage: "arrow.triangle.2.circlepath", label: "Update \(row.name)", tint: HUDTheme.accent) {
                model.updateMap(row.id)
            }
        } else if row.place == .recent {
            HStack(spacing: 8) {
                IconButton(systemImage: "trash", label: "Remove \(row.name)", tint: HUDTheme.secondaryText) {
                    removing = row
                }
                IconButton(systemImage: "pin", label: "Keep \(row.name) on This Phone", tint: HUDTheme.accent) {
                    model.keepMap(row.id)
                }
            }
        } else if !row.isComplete {
            IconButton(systemImage: "arrow.down.circle", label: "Finish Downloading \(row.name)", tint: HUDTheme.accent) {
                model.updateMap(row.id)
            }
        } else {
            IconButton(systemImage: "trash", label: "Remove \(row.name)", tint: HUDTheme.secondaryText) {
                removing = row
            }
        }
    }

    /// The long press: every action the row has.
    @ViewBuilder
    private func actions(_ row: MapRow) -> some View {
        if row.place == nil {
            Button { model.downloadMap(row.id) } label: { Label("Download", systemImage: "arrow.down.circle") }
        } else {
            if row.place == .recent {
                Button { model.keepMap(row.id) } label: { Label("Keep on This Phone", systemImage: "pin") }
            }
            if row.updateWaiting {
                Button { model.updateMap(row.id) } label: {
                    Label("Update", systemImage: "arrow.triangle.2.circlepath")
                }
            }
            Button(role: .destructive) { removing = row } label: { Label("Remove", systemImage: "trash") }
        }
    }

    // MARK: Status

    /// One line over the page: how many maps are on the phone and the space
    /// they take, beside Check for updates.
    private var status: some View {
        HStack(spacing: GlassLayout.gap) {
            Text(MapsText.statusLine(model))
                .textRole(.caption)
                .foregroundStyle(HUDTheme.secondaryText)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            if model.catalog.isLoading {
                ProgressView().controlSize(.small).frame(width: GlassLayout.iconButton, height: GlassLayout.iconButton)
            } else {
                IconButton(systemImage: "arrow.clockwise", label: "Check for Updates") {
                    model.checkMapUpdates()
                }
            }
        }
        .padding(.leading, GlassLayout.cardPadding)
        .padding(.trailing, 4)
        .padding(.vertical, 4)
        .glassEffect(HUDGlass.surface, in: Capsule())
        .environment(\.isOnGlass, true)
    }
}

// MARK: Wording

@MainActor
enum MapsText {
    /// The Maps tile's value in Settings.
    static func tileValue(_ model: AppModel) -> String {
        let phone = model.mapsOnPhone
        return phone.count == 0 ? "None yet" : "\(maps(phone.count)) · \(size(phone.bytes))"
    }

    /// "3 maps on this phone · 1.2 GB", led by "No connection" without one.
    static func statusLine(_ model: AppModel) -> String {
        let phone = model.mapsOnPhone
        var parts: [String] = []
        if model.connection == .offline { parts.append("No connection") }
        if phone.count == 0 {
            parts.append("No maps on this phone")
        } else {
            parts.append("\(maps(phone.count)) on this phone")
            parts.append(size(phone.bytes))
        }
        return parts.joined(separator: " · ")
    }

    static func icon(_ row: MapRow) -> String {
        if row.failure != nil { return "exclamationmark.triangle.fill" }
        switch row.place {
        case .downloaded: return "checkmark.circle.fill"
        case .recent: return "clock.fill"
        case nil: return "map"
        }
    }

    /// The line under a resort's name: what it holds, or what is happening.
    static func detail(_ row: MapRow) -> String {
        if let failure = row.failure { return failure.userMessage }
        if let progress = row.progress {
            let percent = "\(Int((progress * 100).rounded()))%"
            // The phone's own work on a map it already holds.
            if !row.isUserJob, row.bytes > 0 { return "Updating · \(percent)" }
            return "Downloading · \(percent)"
        }
        var parts: [String] = []
        switch row.place {
        case .downloaded:
            if row.bytes > 0 { parts.append(size(row.bytes)) }
            if !row.isComplete { parts.append("Not finished") }
            if row.updateWaiting { parts.append("Update ready") }
        case .recent:
            parts.append("Recent")
            if row.isComplete {
                parts.append(size(row.bytes))
            } else {
                parts.append("Saves on Wi-Fi")
            }
            if row.updateWaiting { parts.append("Update ready") }
        case nil:
            if let region = row.region { parts.append(region) }
            if let estimate = row.estimate { parts.append("About \(size(rounded(estimate)))") }
        }
        return parts.joined(separator: " · ")
    }

    static func removeMessage(_ row: MapRow) -> String {
        let frees = row.bytes > 0 ? "This frees \(size(row.bytes)). " : ""
        return frees + "You can download it again when you have a connection."
    }

    private static func maps(_ count: Int) -> String {
        count == 1 ? "1 map" : "\(count) maps"
    }

    static func size(_ bytes: Int64) -> String {
        bytes.formatted(.byteCount(style: .file))
    }

    /// An estimate to two figures: "About 120 MB", not "About 123.4 MB".
    private static func rounded(_ bytes: Int64) -> Int64 {
        guard bytes >= 100 else { return bytes }
        let digits = Int(Foundation.log10(Double(bytes)))
        let unit = Int64(pow(10, Double(digits - 1)))
        return (bytes / unit) * unit
    }
}
