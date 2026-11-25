import AppCore
import Foundation

/// The Dev page's diagnostics (`specs/07-CLIENT.md` section 8): labelled values
/// in short groups, the same on screen and on the clipboard.
struct DiagnosticsGroup: Identifiable, Hashable {
    struct Row: Identifiable, Hashable {
        let label: String
        let value: String
        /// Too long for the trailing edge: shown on a line of its own.
        var isLong = false
        var id: String { label }
    }

    let title: String
    let rows: [Row]
    var id: String { title }
}

extension DeveloperModel {
    var diagnostics: [DiagnosticsGroup] {
        [
            DiagnosticsGroup(title: "App", rows: [
                .init(label: "Version", value: "\(app.appVersion) (\(app.appBuild))"),
                .init(label: "Channel", value: channelName),
                .init(label: "Server", value: serverHost ?? "Unknown", isLong: true),
            ]),
            DiagnosticsGroup(title: "Connection", rows: connectionRows),
            DiagnosticsGroup(title: "Lifts", rows: liftStatusRows),
            DiagnosticsGroup(title: "Solver", rows: [
                .init(label: "Time", value: pretendTime == .real ? "Real (\(solveTimeText))" : "Pretend \(solveTimeText)"),
                .init(label: "Weather", value: pretendWeather.label),
            ]),
        ]
    }

    /// The Diagnostics row's value on the Dev page.
    var diagnosticsSummary: String {
        realtime.subscribedAt == nil ? "Not subscribed" : "Subscribed"
    }

    var diagnosticsText: String {
        diagnostics.map { group in
            ([group.title] + group.rows.map { "\($0.label): \($0.value)" }).joined(separator: "\n")
        }
        .joined(separator: "\n\n")
    }

    private var channelName: String {
        switch channel {
        case .debug: "Debug"
        case .testFlight: "TestFlight"
        case .appStore: "App Store"
        }
    }

    private var connectionRows: [DiagnosticsGroup.Row] {
        let network = switch app.connectionNotice {
        case .offline: "Offline"
        case .reconnecting: "Reconnecting"
        case .backOnline, nil: app.isOnline ? "Online" : "Offline"
        }
        var rows: [DiagnosticsGroup.Row] = [.init(label: "Network", value: network)]
        guard let since = realtime.subscribedAt else {
            rows.append(.init(label: "Live Updates", value: "Not subscribed"))
            return rows
        }
        rows.append(.init(label: "Live Updates", value: "Subscribed \(ago(since))"))
        rows.append(.init(label: "Last Event", value: realtime.lastEventAt.map(ago) ?? "None yet"))
        rows.append(.init(label: "Rejoins", value: "\(realtime.reconnects)"))
        return rows
    }

    private var liftStatusRows: [DiagnosticsGroup.Row] {
        guard let resort = app.resort else { return [.init(label: "Mountain", value: "None open")] }
        var rows: [DiagnosticsGroup.Row] = [
            .init(label: "Mountain", value: resortName ?? resort.resortID),
            .init(label: "Observed", value: resort.status.map { ago($0.observedAt) } ?? "No status yet"),
        ]
        if let read = realtime.lastStatusReadAt {
            rows.append(.init(label: "Last Read", value: realtime.lastStatusFound ? ago(read) : "\(ago(read)), nothing found"))
        }
        return rows
    }

    /// "12 seconds ago", "now", counted from the last refresh.
    private func ago(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        formatter.dateTimeStyle = .named
        return formatter.localizedString(for: min(date, diagnosticsAt), relativeTo: diagnosticsAt)
    }
}
