import AppCore
import MountainCore
import PowderMeetAPI
import SwiftUI
import UniformTypeIdentifiers

/// Profile → Activity: View logs, Live recording, the upload in
/// progress, Import (activity files and `.powdermeet` backups) and Apple
/// Health; then Data: Back up (the
/// `.powdermeet` file, shared) and Reset. Gear and the skill level are on the
/// Gear page.
struct ProfileActivityPage: View {
    @Environment(AppModel.self) private var model

    @State private var showPicker = false
    @State private var confirmReset = false

    private var activity: ActivityModel { model.activity }

    var body: some View {
        Group {
                // Where to go and what to bring in: tiles that spin out, like
                // the profile panel's.
                PanelTileGrid {
                    PanelTile(icon: "list.bullet.rectangle", title: "Logs", value: logsSubtitle) {
                        model.pushPanel(.logs)
                    }
                    .spinOut(0)
                    PanelTile(icon: "square.and.arrow.down", title: "Import", value: "Files") {
                        showPicker = true
                    }
                    .spinOut(1)
                    if ActivityModel.isHealthAvailable {
                        PanelTile(icon: "heart.text.square", title: "Health", value: healthValue) {
                            activity.importFromHealth()
                        }
                        .disabled(activity.isReadingHealth || activity.isImporting)
                        .opacity(activity.isReadingHealth || activity.isImporting ? 0.5 : 1)
                        .spinOut(2)
                    }
                    PanelTile(icon: "externaldrive.fill", title: backupTitle, value: "A .powdermeet file") {
                        activity.exportBackup()
                    }
                    .disabled(isBackingUp || activity.history.isEmpty)
                    .opacity(isBackingUp || activity.history.isEmpty ? 0.5 : 1)
                    .spinOut(3)
                }
                GlassSection {
                    recordingRow
                    if case .working(let done, let total) = activity.importPhase {
                        GlassDivider(inset: 54)
                        uploadingRow(done: done, total: total)
                    }
                }

                GlassSection("Data") {
                    GlassNavRow(
                        icon: "arrow.counterclockwise",
                        title: resetTitle,
                        detail: "Remove all runs · reset edge speeds",
                        titleTint: HUDTheme.accentRed
                    ) {
                        confirmReset = true
                    }
                    .disabled(activity.isResetting || activity.history.isEmpty)
                    .opacity(activity.isResetting || activity.history.isEmpty ? 0.5 : 1)
                }
        }
        .pageScroll()
        .fileImporter(
            isPresented: $showPicker, allowedContentTypes: ActivityFileTypes.importable,
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case .success(let urls): activity.enqueue(urls)
            case .failure: break   // the picker was closed, or Files reported its own error
            }
        }
        .sheet(item: Binding(
            get: { if case .ready(let url) = activity.backup { ShareItem(url: url) } else { nil } },
            set: { if $0 == nil { activity.finishBackup() } }
        )) { item in
            ShareSheet(fileURL: item.url)
                .ignoresSafeArea()
        }
        .confirmCard(
            "Reset activity data?", isPresented: $confirmReset,
            message: "This deletes all \(activity.history.totals.runs) runs and puts your pace back to the usual for your level. Back up first to keep them: runs recorded live or read from Apple Health have no file to import again.",
            confirm: "Reset"
        ) { activity.resetAll() }
    }

    private var isBackingUp: Bool {
        if case .exporting = activity.backup { true } else { false }
    }

    /// "Resetting… 120 of 672": a reset of a whole season takes a while.
    private var resetTitle: String {
        guard activity.isResetting else { return "Reset activity data" }
        guard let progress = activity.resetProgress, progress.total > 0 else { return "Resetting…" }
        return "Resetting… \(progress.done) of \(progress.total)"
    }

    private var backupTitle: String {
        if case .exporting(let count) = activity.backup {
            return count > 0 ? "Backing up \(count) runs…" : "Backing up…"
        }
        return "Back up"
    }

    // MARK: Live recording

    /// The LIVE RECORDING row: what the recorder is doing, and its state
    /// badge ("ON · RECORDING" / "OFF"), which is the control.
    private var recordingRow: some View {
        GlassRow(icon: "dot.radiowaves.left.and.right", title: "Live recording", detail: recordingSubtitle) {
            Toggle("Live recording", isOn: Binding(
                get: { activity.isRecordingOn }, set: { activity.setRecording($0) }
            ))
            .labelsHidden()
            .tint(HUDTheme.accent)
            .accessibilityHint(activity.isRecordingOn
                ? "Stops recording and saves the run in progress" : "Records runs by itself at a resort")
        }
    }

    /// Recording keeps going with the phone locked only with "Always".
    private var recordingNeedsSettings: Bool {
        activity.isRecordingOn && (model.locationPermission == .denied || !model.locationAlways)
    }

    private var recordingSubtitle: String {
        guard activity.isRecordingOn else { return "Auto-log runs while you ski" }
        if model.locationPermission == .denied { return "Location is off · Allow it in Settings" }
        guard let status = activity.recording, let resort = status.resortName else {
            return model.locationAlways
                ? "Waiting for a resort"
                : "Waiting for a resort · Allow location “Always” to record with the phone locked"
        }
        var text = "At \(resort)"
        if status.runsToday > 0 {
            text += " · \(status.runsToday) \(status.runsToday == 1 ? "run" : "runs") today"
        }
        if status.queued > 0 { text += " · \(status.queued) waiting for signal" }
        if !model.locationAlways { text += " · Allow “Always” to record when locked" }
        return text
    }

    // MARK: Apple Health

    /// Under the Health tile: whether it has been read, and when.
    private var healthValue: String {
        if activity.isReadingHealth { return "Reading…" }
        guard let at = activity.healthImportedAt else { return "Not connected" }
        return "Read \(at.formatted(date: .abbreviated, time: .omitted))"
    }

    private var logsSubtitle: String {
        let totals = activity.history.totals
        guard totals.runs > 0 else { return "No runs yet" }
        return "\(totals.runs) \(totals.runs == 1 ? "run" : "runs") · \(totals.days) \(totals.days == 1 ? "day" : "days")"
    }

    private func uploadingRow(done: Int, total: Int) -> some View {
        GlassRow(icon: "arrow.up.circle", title: "Uploading \(done) of \(total)") {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                IconButton(systemImage: "xmark", label: "Cancel import", tint: HUDTheme.secondaryText) {
                    activity.cancelImport()
                }
            }
        }
    }
}

// MARK: Shared pieces

/// The file kinds the importer reads. Slopes and Ski Tracks have no system
/// type, so they are declared in Info.plist (`project.yml`), as is the
/// `.powdermeet` backup, which PowderMeet exports (`com.powdermeet.backup`).
nonisolated enum ActivityFileTypes {
    static let backup = "com.powdermeet.backup"

    static var importable: [UTType] {
        var types: [UTType] = [.xml, .zip]
        for name in ["gpx", "tcx", "fit", "slopes", "skiz", ActivityBackup.fileExtension] {
            if let type = UTType(filenameExtension: name) { types.append(type) }
        }
        for identifier in ["com.topografix.gpx", "com.garmin.tcx", "com.garmin.fit",
                           "com.consumedbycode.slopes", "com.corecoders.skitracks.skiz", backup] {
            if let type = UTType(identifier) { types.append(type) }
        }
        return types
    }
}

nonisolated enum ActivityDates {
    /// "Sat 10 Jan 2026" for a stored `yyyy-MM-dd`, which is already the day
    /// at the resort and must not move with the phone's time zone.
    static func day(_ day: String) -> String {
        guard let date = ActivityDay.date(day) else { return day }
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.setLocalizedDateFormatFromTemplate("EEE d MMM yyyy")
        return formatter.string(from: date)
    }

    /// "APR 25": the log's date column. The year shows only when it is not this one.
    static func short(_ day: String) -> String {
        guard let date = ActivityDay.date(day) else { return day }
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        let thisYear = Calendar.current.component(.year, from: Date())
        let sameYear = day.hasPrefix(String(thisYear))
        formatter.setLocalizedDateFormatFromTemplate(sameYear ? "MMM d" : "MMM d yy")
        return formatter.string(from: date)
    }
}

