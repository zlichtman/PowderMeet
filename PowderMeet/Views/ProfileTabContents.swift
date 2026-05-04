//
//  ProfileTabContents.swift
//  PowderMeet
//
//  Inline content views for the Profile page's ACTIVITY and ACCOUNT tabs.
//  - ActivityTabContent: GPX/TCX/FIT import + data management (reset/export/import).
//  - AccountTabContent:  email, password reset, sign out, delete account.
//
//  (Formerly "AlgorithmSettingsSheet.swift" — legacy name from when this
//  file held solver toggles. Renamed for searchability.)
//

import SwiftUI
import Supabase
import UniformTypeIdentifiers

// MARK: - ACTIVITY TAB

struct ActivityTabContent: View {
    @Environment(SupabaseManager.self) private var supabase
    /// App-scoped import session — survives tab switches, owns the running
    /// Task, exposes cancel + global banner state. See ActivityImportSession.swift.
    @Environment(ActivityImportSession.self) private var importSession

    @State private var showActivityImporter = false
    @State private var importError: String?
    /// Confirm-cancel alert for the in-progress import. Tapping the X on
    /// the import button raises this; confirming cancels the session.
    @State private var showCancelImportConfirm = false

    @State private var preparedExportURL: URL?
    @State private var isPreparingExport = false
    @State private var showImportedRunsViewer = false
    /// Distinct from `importError` so an export-time failure doesn't
    /// surface under the misleading "IMPORT FAILED" alert title.
    @State private var exportError: String?
    @State private var showResetActivityConfirm = false
    @State private var isResettingActivity = false
    @State private var resetActivityError: String?

    private var isImporting: Bool { importSession.phase.isImporting }
    private var importResultBanner: ActivityImportBanner? { importSession.phase.banner }

    private var profile: UserProfile? { supabase.currentUserProfile }

    var body: some View {
        VStack(spacing: 16) {
            // Activity section now hosts the compact skill preset above
            // the import controls — same surface, two related concerns
            // collapsed into one section header.
            // Calibration block — preset bar + Apple Health pull + file
            // import. ACTIVITY header was redundant once CALIBRATION
            // labelled the same group.
            sectionHeader("CALIBRATION")
            skillLevelSection
            activityImportSection

            sectionHeader("DATA")
            dataManagementSection
        }
        .fileImporter(
            isPresented: $showActivityImporter,
            allowedContentTypes: ActivityImportTypes.supported,
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case .success(let urls):
                let importer = ActivityImporter(supabase: supabase)
                importSession.start(urls: urls, importer: importer)
            case .failure(let error):
                importError = error.localizedDescription
            }
        }
        .sheet(isPresented: Binding(
            get: { preparedExportURL != nil },
            set: { if !$0 { preparedExportURL = nil } }
        )) {
            if let url = preparedExportURL {
                ExportShareSheet(fileURL: url)
                    .ignoresSafeArea()
            }
        }
        .fullScreenCover(isPresented: $showImportedRunsViewer) {
            ImportedRunsView()
        }
        .alert("IMPORT FAILED", isPresented: Binding(
            get: { importError != nil },
            set: { if !$0 { importError = nil } }
        )) {
            Button("OK", role: .cancel) { importError = nil }
        } message: {
            Text(importError ?? "Could not process the file.")
        }
        .alert("EXPORT FAILED", isPresented: Binding(
            get: { exportError != nil },
            set: { if !$0 { exportError = nil } }
        )) {
            Button("OK", role: .cancel) { exportError = nil }
        } message: {
            Text(exportError ?? "Could not generate the backup file.")
        }
        .alert("CANCEL UPLOAD?", isPresented: $showCancelImportConfirm) {
            Button("KEEP UPLOADING", role: .cancel) {}
            Button("CANCEL UPLOAD", role: .destructive) { importSession.cancel() }
        } message: {
            Text("Files already processed will stay imported. Files still in the queue will be skipped.")
        }
        .alert("RESET ACTIVITY DATA?", isPresented: $showResetActivityConfirm) {
            Button("CANCEL", role: .cancel) {}
            Button("RESET", role: .destructive) {
                Task { await performResetActivity() }
            }
        } message: {
            Text("Deletes every imported run, wipes per-edge speed history, and rolls your skill preset back to INTERMEDIATE. Account, friends, and meet requests are kept. Cannot be undone.")
        }
        .alert("RESET FAILED", isPresented: Binding(
            get: { resetActivityError != nil },
            set: { if !$0 { resetActivityError = nil } }
        )) {
            Button("OK", role: .cancel) { resetActivityError = nil }
        } message: {
            Text(resetActivityError ?? "")
        }
    }

    private func sectionHeader(_ label: String) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundColor(HUDTheme.secondaryText.opacity(0.5))
                .tracking(2)
            Rectangle().fill(HUDTheme.cardBorder).frame(height: 0.5)
        }
    }

    /// Smaller, line-rule-free label one tier below `sectionHeader`.
    /// Used to name an inner grouping (e.g. CALIBRATION inside the
    /// ACTIVITY section) without competing visually with the
    /// section's own header rule.
    private func subsectionLabel(_ label: String) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 8, weight: .bold, design: .monospaced))
                .foregroundColor(HUDTheme.secondaryText.opacity(0.6))
                .tracking(1.5)
            Spacer(minLength: 0)
        }
    }

    /// Re-picking here persists immediately and does NOT auto-reapply
    /// the preset speeds — a user who has calibrated via imports would
    /// lose their work on an accidental tap. RESET STATS is the
    /// explicit opt-in for that.
    private var skillLevelSection: some View {
        SkillLevelPicker(
            selection: profile?.skillLevel ?? "intermediate",
            onSelect: { updateSkillLevel($0) }
        )
    }

    private func updateSkillLevel(_ key: String) {
        guard profile?.skillLevel != key else { return }
        Task {
            do {
                try await supabase.updateProfile(["skill_level": .string(key)])
            } catch {
                importError = "Couldn't update skill level: \(error.localizedDescription)"
            }
        }
    }

    private var activityImportSection: some View {
        VStack(spacing: 8) {
            // Order, top to bottom:
            //   1. View Logs (also owns in-flight import progress + cancel)
            //   2. Apple Health (broadest historical source — Slopes /
            //      Apple Watch / Strava / Garmin Connect all mirror to it)
            //   3. File import (one-off Slopes / GPX / TCX / FIT / .powdermeet)
            //   4. Live recording toggle (passive on-device capture)
            //
            // Logs sits at the TOP because the user's mental anchor is
            // "what's in my history" — and so the upload progress UI
            // doesn't appear to mutate one of the import buttons (it
            // used to live inside the file-import row, which made
            // tapping HK visually shrink the file row).

            ViewLogsRow(
                onTap: { showImportedRunsViewer = true },
                onCancel: { showCancelImportConfirm = true }
            )
            ConnectAppleHealthRow()
            ImportActivityFileRow(
                onTap: { showActivityImporter = true }
            )

            // Import-result feedback is delivered as an iOS system
            // notification, not an inline banner. The session's banner
            // payload still drives onboarding completion state but is
            // no longer rendered here.

            // Live recording lives at the bottom of the imports section —
            // it's a *future-capture* control, conceptually adjacent to
            // imports but distinct from "what's already here."
            liveRecordingToggle
        }
    }

    /// Compact two-line toggle row: ON · RECORDING / OFF status pill on
    /// the right, label + description on the left. Mirrors the
    /// `dataRow` styling so the ACTIVITY tab reads as one visual
    /// system top-to-bottom.
    private var liveRecordingToggle: some View {
        let isOn = profile?.liveRecordingEnabled ?? true
        let pillColor: Color = isOn ? HUDTheme.accentGreen : HUDTheme.secondaryText
        let pillText: String = isOn ? "ON · RECORDING" : "OFF"
        return Button { toggleLiveRecording() } label: {
            HStack(spacing: 12) {
                Image(systemName: isOn ? "dot.radiowaves.left.and.right" : "pause.circle")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(isOn ? HUDTheme.accentGreen : HUDTheme.secondaryText)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 2) {
                    Text("LIVE RECORDING")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundColor(HUDTheme.primaryText)
                        .tracking(1)
                    Text("AUTO-LOG RUNS WHILE YOU SKI")
                        .font(.system(size: 7, weight: .medium, design: .monospaced))
                        .foregroundColor(HUDTheme.secondaryText)
                        .tracking(0.5)
                }
                Spacer()
                Text(pillText)
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .foregroundColor(pillColor)
                    .tracking(1)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(pillColor.opacity(0.12))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .stroke(pillColor.opacity(0.5), lineWidth: 0.5)
                    )
            }
            .padding(12)
            .background(HUDTheme.cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(HUDTheme.cardBorder, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private func toggleLiveRecording() {
        let next = !(profile?.liveRecordingEnabled ?? true)
        Task {
            do {
                try await supabase.updateProfile([
                    "live_recording_enabled": .bool(next),
                ])
            } catch {
                importError = "Couldn't update live recording: \(error.localizedDescription)"
            }
        }
    }

    private var dataManagementSection: some View {
        VStack(spacing: 8) {
            // RESET ACTIVITY DATA — destructive sibling of EXPORT, sits
            // above it because the user thinks of "wipe everything" as
            // belonging next to the export/backup row, not buried in
            // the Account tab.
            Button { showResetActivityConfirm = true } label: {
                dataRow(
                    icon: "arrow.counterclockwise",
                    label: isResettingActivity ? "RESETTING…" : "RESET ACTIVITY DATA",
                    description: "REMOVE ALL RUNS · RESET EDGE SPEEDS",
                    color: HUDTheme.accent
                )
            }
            .buttonStyle(.plain)
            .disabled(isResettingActivity)

            Button { exportData() } label: {
                dataRow(
                    icon: isPreparingExport ? "hourglass" : "square.and.arrow.up",
                    label: isPreparingExport ? "PREPARING…" : "EXPORT DATA",
                    description: "DOWNLOAD .POWDERMEET BACKUP",
                    color: HUDTheme.accentCyan
                )
            }
            .disabled(isPreparingExport)
            .buttonStyle(.plain)

            // The activity importer (above) accepts .powdermeet backups
            // alongside Slopes / Strava GPX / Garmin TCX/FIT, so a
            // separate IMPORT DATA button is redundant.
        }
    }

    private func performResetActivity() async {
        guard !isResettingActivity else { return }
        isResettingActivity = true
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
        defer { isResettingActivity = false }
        do {
            try await supabase.purgeUserData()
        } catch {
            resetActivityError = "Reset failed: \(error.localizedDescription)"
        }
    }

    private func dataRow(icon: String, label: String, description: String, color: Color) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(color)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundColor(HUDTheme.primaryText)
                    .tracking(1)
                Text(description)
                    .font(.system(size: 7, weight: .medium, design: .monospaced))
                    .foregroundColor(HUDTheme.secondaryText)
                    .tracking(0.5)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(color.opacity(0.5))
        }
        .padding(12)
        .background(HUDTheme.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(HUDTheme.cardBorder, lineWidth: 1)
        )
    }

    private func exportData() {
        guard let profile else {
            exportError = "Profile not loaded yet — give it a second and try again."
            return
        }
        guard !isPreparingExport else { return }

        isPreparingExport = true
        Task {
            defer { Task { @MainActor in isPreparingExport = false } }

            // ── 1. Per-run history ────────────────────────────────
            // Round-trip raw runs alongside profile + stats so derived
            // signals (per-edge speed, condition multipliers, day /
            // run counts) can be restored on the other side.
            var runs: [ImportedRunBackup] = []
            do {
                let records = try await supabase.fetchImportedRuns()
                runs = records.map(ImportedRunBackup.init(from:))
            } catch {
                print("[Export] imported_runs fetch failed: \(error.localizedDescription)")
            }

            // ── 2. Avatar bytes ───────────────────────────────────
            // Embed the avatar image so the backup is self-contained.
            // If the storage object disappears or the user imports
            // into a fresh account, the photo still comes back.
            // Failures here are non-fatal; we just skip embedding.
            var avatarBase64: String?
            if let urlStr = profile.avatarUrl, let url = URL(string: urlStr) {
                do {
                    let (data, response) = try await URLSession.shared.data(from: url)
                    if let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) {
                        avatarBase64 = data.base64EncodedString()
                    }
                } catch {
                    print("[Export] avatar fetch failed: \(error.localizedDescription)")
                }
            }

            // ── 3. Encode ─────────────────────────────────────────
            // .sortedKeys would alphabetize, pushing
            // `avatar_image_base64` (huge) ahead of the
            // `export_schema_version` / `exported_at` schema markers
            // and shoving them past the import-side content sniff
            // window. We rely on JSONEncoder writing keys in struct
            // member order, with markers declared first.
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted]
            encoder.dateEncodingStrategy = .iso8601
            // JSONEncoder defaults to throwing on non-finite floats
            // (NaN / +Inf / -Inf). A single bad ProfileStats column
            // (e.g. avg_speed_ms when runs_count = 0 and the server
            // computed 0/0 → NaN) was enough to fail the whole backup.
            // Convert non-finite to sentinels; importer tolerates them.
            encoder.nonConformingFloatEncodingStrategy = .convertToString(
                positiveInfinity: "+inf",
                negativeInfinity: "-inf",
                nan: "nan"
            )

            // Argument order matches the struct member order so the
            // synthesized memberwise init lines up with the JSON
            // encode order (no .sortedKeys → struct order is the JSON
            // order). Schema markers go first so the import-side
            // sniff catches them before the avatar payload.
            let payload = PowderMeetExport(
                exportSchemaVersion: PowderMeetExport.currentSchemaVersion,
                exportedAt: Date(),
                profile: profile,
                stats: supabase.currentUserStats,
                runs: runs.isEmpty ? nil : runs,
                avatarImageBase64: avatarBase64
            )

            let data: Data
            do {
                data = try encoder.encode(payload)
            } catch {
                await MainActor.run {
                    exportError = "Couldn't encode backup: \(error.localizedDescription)"
                }
                return
            }

            // ── 4. Write to a stable location ────────────────────
            // Documents/Backups/ persists across app launches and is
            // exposed to the share sheet reliably. The previous temp-
            // dir path was getting cleaned up before iOS handed the
            // URL to share extensions, which is the most-likely cause
            // of "the file isn't creating." File is overwritten on
            // each export — no accumulation.
            // Filename is intentionally anonymous — no display name, no
            // user id, just the date. A user transferring their account
            // to a new device shouldn't have to rename the file or
            // explain why "alice-2026-05-03.powdermeet" is showing up
            // on Bob's device. Just `powdermeet-2026-05-03.powdermeet`.
            // Profile identity inside the file is handled by the
            // cross-user-import branch in ActivityImporter.processBackup.
            let dateStr: String = {
                let f = DateFormatter()
                f.dateFormat = "yyyy-MM-dd"
                f.timeZone = TimeZone(identifier: "UTC")
                return f.string(from: Date())
            }()
            let filename = "powdermeet-\(dateStr).powdermeet"

            let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            let backupsDir = docs.appendingPathComponent("Backups", isDirectory: true)
            do {
                try FileManager.default.createDirectory(
                    at: backupsDir,
                    withIntermediateDirectories: true
                )
            } catch {
                await MainActor.run {
                    exportError = "Couldn't create backups folder: \(error.localizedDescription)"
                }
                return
            }
            let fileURL = backupsDir.appendingPathComponent(filename)

            do {
                try data.write(to: fileURL, options: [.atomic, .completeFileProtection])
            } catch {
                await MainActor.run {
                    exportError = "Couldn't write backup file: \(error.localizedDescription)"
                }
                return
            }

            print("[Export] wrote \(data.count) bytes to \(fileURL.lastPathComponent) — runs: \(runs.count), avatar: \(avatarBase64?.count ?? 0) chars")
            await MainActor.run {
                preparedExportURL = fileURL
            }
        }
    }

    /// Legacy entry — kept for compatibility, but the unified activity
    /// importer now handles .powdermeet files directly. Future work can
    /// drop this method once nothing references it.
    private func importProfileData(from url: URL) async {
        guard url.startAccessingSecurityScopedResource() else {
            importError = "Could not access the file."
            return
        }
        defer { url.stopAccessingSecurityScopedResource() }

        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601

            // Three export shapes accepted:
            //   v2 wrapper: profile + stats + runs + version (current)
            //   v1 wrapper: profile + stats (no runs)
            //   bare UserProfile JSON (oldest)
            // Pick whichever decodes; runs/stats fall through nil-safe.
            let imported: UserProfile
            let importedRuns: [ImportedRunBackup]
            if let wrapper = try? decoder.decode(PowderMeetExport.self, from: data) {
                imported = wrapper.profile
                importedRuns = wrapper.runs ?? []
            } else {
                imported = try decoder.decode(UserProfile.self, from: data)
                importedRuns = []
            }

            guard var current = supabase.currentUserProfile else { return }
            // Copy every preference field — bucketed speeds AND the
            // continuous tolerances. Earlier code missed the tolerances,
            // which meant an import silently dropped half the user's
            // calibration and the algorithm reverted to skill-preset
            // defaults for those fields. Display name and skill level
            // also flow over so the receiving account reads as the same
            // skier.
            current.displayName = imported.displayName
            current.skillLevel = imported.skillLevel
            current.speedGreen = imported.speedGreen
            current.speedBlue = imported.speedBlue
            current.speedBlack = imported.speedBlack
            current.speedDoubleBlack = imported.speedDoubleBlack
            current.speedTerrainPark = imported.speedTerrainPark
            current.conditionMoguls = imported.conditionMoguls
            current.conditionUngroomed = imported.conditionUngroomed
            current.conditionIcy = imported.conditionIcy
            current.conditionGladed = imported.conditionGladed
            current.maxComfortableGradientDegrees = imported.maxComfortableGradientDegrees
            current.mogulTolerance = imported.mogulTolerance
            current.narrowTrailTolerance = imported.narrowTrailTolerance
            current.exposureTolerance = imported.exposureTolerance
            current.crustConditionTolerance = imported.crustConditionTolerance

            let saved = try await supabase.sendFullProfileUpdate(current)

            // Restore raw runs server-side, then let `recompute_profile_stats`
            // derive the aggregates from ground truth. This replaces the
            // old "stamp imported stats locally" behavior — the backup
            // now carries enough data for the server to compute identical
            // numbers, so the local-only stamp is unnecessary and would
            // briefly disagree with whatever recompute returns.
            if !importedRuns.isEmpty {
                _ = try? await supabase.restoreImportedRuns(importedRuns)
            }

            await MainActor.run {
                supabase.currentUserProfile = saved
            }
            // Reload stats from the server so the lifetime card reflects
            // the restored runs (loadProfileStats also runs inside
            // restoreImportedRuns, but reloading here covers the
            // no-runs-in-backup branch and the fetch-failed-during-export
            // branch alike).
            await supabase.loadProfileStats()
        } catch {
            importError = error.localizedDescription
        }
    }

    // Import flow now lives in `ActivityImportSession` (Services/) so the
    // running task survives tab switches and exposes a cancel entry. This
    // view just reads `importSession.phase` for the banner + button states.
}

// MARK: - ACCOUNT TAB

struct AccountTabContent: View {
    @Environment(SupabaseManager.self) private var supabase

    @State private var showPasswordResetConfirm = false
    @State private var passwordResetMessage: String?
    @State private var showSignOutConfirm = false
    @State private var showDeleteSheet = false
    @State private var isSigningOut = false
    @State private var isDeletingAccount = false
    @State private var accountError: String?

    private static let appVersion: String = {
        let info = Bundle.main.infoDictionary
        let v = info?["CFBundleShortVersionString"] as? String ?? "?"
        let b = info?["CFBundleVersion"] as? String ?? "?"
        return "v\(v) (\(b))"
    }()

    private var accountEmail: String {
        supabase.currentSession?.user.email ?? "—"
    }

    var body: some View {
        VStack(spacing: 8) {
            // Email row
            HStack(spacing: 12) {
                Image(systemName: "envelope.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(HUDTheme.accent)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 2) {
                    Text("EMAIL")
                        .font(.system(size: 7, weight: .bold, design: .monospaced))
                        .foregroundColor(HUDTheme.secondaryText)
                        .tracking(1)
                    Text(accountEmail)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(HUDTheme.primaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
            }
            .padding(12)
            .background(HUDTheme.cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(HUDTheme.cardBorder, lineWidth: 1)
            )

            Button { showPasswordResetConfirm = true } label: {
                accountActionRow(icon: "key.fill", label: "RESET PASSWORD", color: HUDTheme.accent)
            }
            .buttonStyle(.plain)
            .disabled(supabase.currentSession?.user.email == nil)

            Button { showSignOutConfirm = true } label: {
                accountActionRow(
                    icon: "rectangle.portrait.and.arrow.right",
                    label: isSigningOut ? "SIGNING OUT…" : "SIGN OUT",
                    color: HUDTheme.accent
                )
            }
            .buttonStyle(.plain)
            .disabled(isSigningOut || isDeletingAccount)

            Button { showDeleteSheet = true } label: {
                accountActionRow(
                    icon: "trash",
                    label: "DELETE ACCOUNT",
                    color: HUDTheme.accent
                )
            }
            .buttonStyle(.plain)
            .disabled(isSigningOut || isDeletingAccount)

            Text("POWDERMEET \(Self.appVersion)")
                .font(.system(size: 8, weight: .medium, design: .monospaced))
                .foregroundColor(HUDTheme.secondaryText.opacity(0.4))
                .tracking(1)
                .padding(.top, 8)
        }
        .alert("RESET PASSWORD?", isPresented: $showPasswordResetConfirm) {
            Button("CANCEL", role: .cancel) {}
            Button("SEND EMAIL") { Task { await sendPasswordReset() } }
        } message: {
            Text("A reset link will be sent to \(accountEmail).")
        }
        .alert("CHECK YOUR EMAIL", isPresented: Binding(
            get: { passwordResetMessage != nil },
            set: { if !$0 { passwordResetMessage = nil } }
        )) {
            Button("OK", role: .cancel) { passwordResetMessage = nil }
        } message: {
            Text(passwordResetMessage ?? "")
        }
        .alert("SIGN OUT?", isPresented: $showSignOutConfirm) {
            Button("CANCEL", role: .cancel) {}
            Button("SIGN OUT", role: .destructive) {
                Task { await performSignOut() }
            }
        } message: {
            Text("You will need to sign in again.")
        }
        .sheet(isPresented: $showDeleteSheet) {
            DeleteAccountSheet {
                await performDeleteAccount()
            }
        }
        .alert("ERROR", isPresented: Binding(
            get: { accountError != nil },
            set: { if !$0 { accountError = nil } }
        )) {
            Button("OK", role: .cancel) { accountError = nil }
        } message: {
            Text(accountError ?? "")
        }
    }

    private func accountActionRow(icon: String, label: String, color: Color) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(color)
                .frame(width: 20)
            Text(label)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundColor(HUDTheme.primaryText)
                .tracking(1)
            Spacer()
            Image(systemName: "chevron.right")
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(color.opacity(0.5))
        }
        .padding(12)
        .background(HUDTheme.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(HUDTheme.cardBorder, lineWidth: 1)
        )
    }

    private func sendPasswordReset() async {
        guard let email = supabase.currentSession?.user.email, !email.isEmpty else {
            accountError = "No email on file for this account."
            return
        }
        do {
            try await supabase.resetPassword(email: email)
            passwordResetMessage = "We've sent a password reset link to \(email)."
        } catch {
            accountError = "Password reset failed: \(error.localizedDescription)"
        }
    }

    private func performSignOut() async {
        guard !isSigningOut else { return }
        isSigningOut = true
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
        do {
            try await supabase.signOut()
        } catch {
            accountError = "Sign out failed: \(error.localizedDescription)"
        }
        isSigningOut = false
    }

    private func performDeleteAccount() async -> Bool {
        guard !isDeletingAccount else { return false }
        isDeletingAccount = true
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
        defer { isDeletingAccount = false }
        do {
            try await supabase.deleteAccount()
            return true
        } catch {
            accountError = "Delete failed: \(error.localizedDescription)"
            return false
        }
    }

}

// PowderMeetExport + ImportedRunBackup moved to Models/PowderMeetExport.swift
// so ActivityImporter can consume the same types when handling a backup
// file alongside .gpx/.tcx/.fit/.slopes activity files.

// MARK: - Activity Import Banner

struct ActivityImportBanner {
    let message: String
    let isError: Bool
}

// MARK: - Export share sheet
//
// Thin UIActivityViewController wrapper. We hand it the file URL
// directly — no custom chrome, no celebratory copy. iOS draws its
// own native share sheet, the user picks AirDrop / Save to Files /
// Mail / etc., and we dismiss when they're done.
//
// The earlier "isn't creating" symptom was the share extension
// losing the URL during hand-off because the file lived in the
// temp directory. Documents/Backups/ persists, so this works
// reliably now without needing ShareLink.

struct ExportShareSheet: UIViewControllerRepresentable {
    let fileURL: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let vc = UIActivityViewController(
            activityItems: [fileURL],
            applicationActivities: nil
        )
        // No exclusions — the system picks reasonable defaults for
        // a JSON-conforming UTI (`com.powdermeet.backup`).
        return vc
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
