//
//  ActivityImportRows.swift
//  PowderMeet
//
//  Two reusable rows + the shared UTType list that drive the activity
//  import flow on both the onboarding combined step and the Profile →
//  Activity tab. They were copy-pasted byte-for-byte across both
//  screens; this file is the single source of truth so the copy and
//  styling can't drift.
//
//  The two rows describe genuinely different ingestion paths so their
//  subtitles are different — but their voice is consistent:
//    Apple Health pulls *workouts* from Apple's HealthKit DB
//      (anything that publishes there: Apple Watch native, Slopes,
//      Strava, Garmin Connect with sync, etc.)
//    Import Activity File parses *files* the user obtained via export
//      from another app (.gpx / .tcx / .fit / .slopes / .powdermeet
//      backup).
//
//  Subtitles:
//    HK   → "APPLE WATCH · SLOPES · STRAVA · GARMIN"   (sources)
//    File → "GPX · TCX · FIT · .SLOPES · .POWDERMEET"  (formats)
//

import SwiftUI
import UniformTypeIdentifiers

// MARK: - Shared UTType list

enum ActivityImportTypes {
    /// File-picker types accepted by the activity importer. `.xml`,
    /// `.archive`, and `.database` cover Slopes (a ZIP containing a
    /// SQLite DB) on devices where the `.slopes` UTI hasn't been
    /// dynamically registered. Format detection sniffs the actual
    /// bytes after the OS picker; this list just keeps the picker
    /// from showing every file on the device.
    static let supported: [UTType] = {
        var types: [UTType] = [.xml, .archive, .database]
        if let gpx = UTType(filenameExtension: "gpx") { types.append(gpx) }
        if let tcx = UTType(filenameExtension: "tcx") { types.append(tcx) }
        if let fit = UTType(filenameExtension: "fit") { types.append(fit) }
        if let slopes = UTType(filenameExtension: "slopes") { types.append(slopes) }
        // PowderMeet backup files — registered as a custom UTI in
        // Info.plist (`com.powdermeet.backup`, conforms to public.json).
        // Prefer the registered UTI so the picker shows the right
        // type name + icon; fall back to a dynamic UTI if the
        // registration hasn't reached the system yet on first install.
        if let pmRegistered = UTType("com.powdermeet.backup") {
            types.append(pmRegistered)
        } else if let pmDynamic = UTType(filenameExtension: "powdermeet") {
            types.append(pmDynamic)
        }
        types.append(.json)
        return types
    }()
}

// MARK: - Connect Apple Health row

/// Self-contained Apple Health connect button. Owns the
/// `ActivityImporter` construction and kicks off
/// `ActivityImportSession.startHealthKit(importer:)` on tap. Renders
/// nothing on devices that don't have HealthKit (matches the existing
/// `HealthKitImporter.isAvailable` gate).
struct ConnectAppleHealthRow: View {
    @Environment(SupabaseManager.self) private var supabase
    @Environment(ActivityImportSession.self) private var importSession

    var body: some View {
        if HealthKitImporter.isAvailable {
            Button {
                let importer = ActivityImporter(supabase: supabase)
                importSession.startHealthKit(importer: importer)
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "applelogo")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(HUDTheme.accent)
                        .frame(width: 20)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("CONNECT APPLE HEALTH")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundColor(HUDTheme.accent)
                            .tracking(1)
                        Text("APPLE WATCH · SLOPES · STRAVA · GARMIN")
                            .font(.system(size: 7, weight: .medium, design: .monospaced))
                            .foregroundColor(HUDTheme.secondaryText)
                            .tracking(0.5)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(HUDTheme.accent.opacity(0.5))
                }
                .padding(12)
                .background(HUDTheme.accent.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(HUDTheme.accent.opacity(0.3), lineWidth: 0.5)
                )
            }
            .buttonStyle(.plain)
            // In-flight import state is owned by `ViewLogsRow` — this
            // row stays visually static so tapping HK doesn't appear
            // to mutate the file row (or vice-versa). The session
            // ignores duplicate kickoffs internally.
        }
    }
}

// MARK: - Import activity file row

/// Tappable row that opens the activity-file picker. Parent owns the
/// `.fileImporter` state binding (SwiftUI gets twitchy when that
/// modifier is attached to a conditionally-rendered view), so this
/// row exposes `onTap` only — progress + cancel for an in-flight
/// import is rendered by `ViewLogsRow` above the two import buttons,
/// not by mutating this row in place. Tap is disabled during an
/// in-flight import via the parent's `disabled` modifier.
struct ImportActivityFileRow: View {
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 10) {
                Image(systemName: "square.and.arrow.down")
                    .font(.system(size: 14))
                    .foregroundColor(HUDTheme.accent)
                    .frame(width: 20)

                VStack(alignment: .leading, spacing: 2) {
                    Text("IMPORT ACTIVITY FILE")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundColor(HUDTheme.accent)
                        .tracking(1)
                    Text("GPX · TCX · FIT · .SLOPES · .POWDERMEET")
                        .font(.system(size: 7, weight: .medium, design: .monospaced))
                        .foregroundColor(HUDTheme.secondaryText)
                        .tracking(0.3)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(HUDTheme.accent.opacity(0.5))
            }
            .padding(12)
            .background(HUDTheme.accent.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(HUDTheme.accent.opacity(0.3), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - View logs / progress row

/// Sits ABOVE the two import rows. Two responsibilities:
///   1. Idle — taps open the per-run logs viewer (`onTap`).
///   2. Importing — owns the spinner + cancel chip so the user has
///      one consistent "import status" surface, no matter which path
///      kicked off the import (HK pull or file picker). Earlier the
///      progress UI lived inside `ImportActivityFileRow`, which made
///      tapping the Apple Health row visually mutate the file row.
///
/// Title is "LOGS" — same surface for imports AND live recordings,
/// since both write to `imported_runs`.
struct ViewLogsRow: View {
    @Environment(ActivityImportSession.self) private var importSession

    let onTap: () -> Void
    let onCancel: () -> Void

    private var isImporting: Bool { importSession.phase.isImporting }

    /// "UPLOADING · 3/10" when the session is importing files and
    /// the per-file counter is populated. Falls back to "UPLOADING…"
    /// for HK pulls (no file count) and the idle case shows
    /// "VIEW LOGS".
    private var titleText: String {
        guard isImporting else { return "VIEW LOGS" }
        if let processed = importSession.processedCount,
           let total = importSession.totalCount, total > 0 {
            return "UPLOADING · \(processed)/\(total)"
        }
        return "UPLOADING…"
    }

    var body: some View {
        HStack(spacing: 10) {
            // Fixed-frame icon column — spinner and idle icon
            // render at the same dimensions so the title doesn't
            // shift sideways when an import begins.
            ZStack {
                if isImporting {
                    ProgressView()
                        .scaleEffect(0.6)
                        .tint(HUDTheme.spinnerInteractive)
                } else {
                    Image(systemName: "list.bullet.rectangle")
                        .font(.system(size: 13))
                        .foregroundColor(HUDTheme.primaryText)
                }
            }
            .frame(width: 20, height: 18)

            VStack(alignment: .leading, spacing: 2) {
                Text(titleText)
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundColor(HUDTheme.primaryText)
                    .tracking(1)
                Text(isImporting
                     ? "TAP X TO CANCEL"
                     : "IMPORTED & LIVE-RECORDED RUNS")
                    .font(.system(size: 7, weight: .medium, design: .monospaced))
                    .foregroundColor(HUDTheme.secondaryText)
                    .tracking(0.3)
            }

            Spacer()

            // Fixed-frame trailing column — chevron (idle) and
            // cancel button (importing) share the same footprint
            // so swapping between them doesn't change row width or
            // push the title around.
            ZStack {
                if isImporting {
                    Button(action: onCancel) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundColor(HUDTheme.secondaryText)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Cancel upload")
                } else {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(HUDTheme.secondaryText)
                }
            }
            .frame(width: 24, height: 20)
        }
        .padding(12)
        .background(HUDTheme.cardBackground.opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(HUDTheme.cardBorder, lineWidth: 0.5)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            guard !isImporting else { return }
            onTap()
        }
    }
}
