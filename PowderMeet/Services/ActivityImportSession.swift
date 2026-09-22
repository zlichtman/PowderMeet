//
//  ActivityImportSession.swift
//  PowderMeet
//
//  Owns the running activity-import Task at app scope so importing a 6-file
//  batch keeps running when the user switches tabs, opens settings, or
//  navigates anywhere else in the UI. Without this, the import was tied to
//  the lifecycle of `ActivityTabContent` / `OnboardingSkillStep` — leaving
//  the screen mid-upload silently dropped the in-flight RPCs.
//
//  The session also exposes a cooperative cancellation entry so a top-level
//  banner can offer an X-with-confirm. Cancellation propagates into the
//  importer's `withTaskGroup` automatically; in-flight network calls unwind
//  on their next `await` checkpoint.
//

import Foundation
import SwiftUI

@MainActor
@Observable
final class ActivityImportSession {

    enum Phase {
        case idle
        case importing(fileCount: Int)
        case completed(ActivityImportBanner)
        case cancelled

        var isImporting: Bool {
            if case .importing = self { return true }
            return false
        }

        var banner: ActivityImportBanner? {
            switch self {
            case .completed(let b): return b
            case .cancelled:        return ActivityImportBanner(message: "UPLOAD CANCELLED", isError: true)
            default:                return nil
            }
        }
    }

    private(set) var phase: Phase = .idle
    private var currentTask: Task<Void, Never>?

    /// Live per-file progress for an in-flight file-import batch. Both
    /// nil for HK pulls (no concept of "files" — workouts are pulled
    /// in a single bulk operation). UI reads these to render
    /// "UPLOADING · 3/10" instead of an indeterminate "UPLOADING…".
    private(set) var processedCount: Int? = nil
    private(set) var totalCount: Int? = nil

    /// Kicks off an import and returns immediately. If a previous import is
    /// still running, this is a no-op — the banner UI shouldn't allow a
    /// second start anyway, but guarding here keeps the state machine sane.
    func start(urls: [URL], importer: ActivityImporter) {
        guard !phase.isImporting else { return }
        guard !urls.isEmpty else { return }

        phase = .importing(fileCount: urls.count)
        processedCount = 0
        totalCount = urls.count

        currentTask = Task { [weak self] in
            // Progress callback fires from inside the importer's
            // task group. Hop to the main actor before mutating
            // observable state. The progress closure carries its own
            // `[weak self]` so the @MainActor Task can capture that
            // weak optional directly — re-weakening across the inner
            // Task boundary tripped Swift 6's "captured var 'self' in
            // concurrently-executing code" diagnostic.
            let batch = await importer.importActivities(urls: urls) { [weak self] processed, total in
                // Bind the weak capture into an explicit `let` before
                // crossing into the Sendable @MainActor Task — Swift 6
                // strict mode rejects capturing the implicitly-mutable
                // `self` form across concurrent boundaries even when the
                // outer scope already declared `[weak self]`.
                let weakSelf = self
                Task { @MainActor in
                    weakSelf?.processedCount = processed
                    weakSelf?.totalCount = total
                }
            }
            guard let self else { return }

            // Honor cancellation: if the task was cancelled, report it as
            // such instead of pretending the partial result is "completed".
            if Task.isCancelled {
                self.phase = .cancelled
                self.processedCount = nil
                self.totalCount = nil
                return
            }

            self.phase = .completed(Self.summariseBanner(for: batch))
            self.processedCount = nil
            self.totalCount = nil
            Self.postNotifyForBatch(batch)
        }
    }

    /// Apple Health entry — kicks off `HealthKitImporter.importAll` and
    /// reuses the same Phase machine + banner copy as a file import. The
    /// running task survives navigation past Profile / Onboarding for the
    /// same reason file imports do: HealthKit pulls can be slow when a
    /// user has hundreds of workouts (every workout fans out into a
    /// route-sample query).
    func startHealthKit(importer: ActivityImporter, since: Date? = nil) {
        guard !phase.isImporting else { return }

        // We don't know the workout count up front (the auth + fetch
        // happens inside the task). Surface a placeholder count of 1 so
        // the banner reads "UPLOADING…" without lying about scale.
        phase = .importing(fileCount: 1)

        currentTask = Task { [weak self] in
            do {
                let batch = try await HealthKitImporter.shared.importAll(
                    via: importer,
                    since: since
                )
                guard let self else { return }
                if Task.isCancelled { self.phase = .cancelled; return }
                self.phase = .completed(Self.summariseBanner(for: batch))
                Self.postNotifyForBatch(batch)
            } catch {
                guard let self else { return }
                if Task.isCancelled { self.phase = .cancelled; return }
                self.phase = .completed(ActivityImportBanner(
                    message: error.localizedDescription.uppercased(),
                    isError: true
                ))
            }
        }
    }

    /// Cancel the in-flight import. The user must confirm at the call site
    /// — this method assumes that confirmation has already happened.
    func cancel() {
        currentTask?.cancel()
        // Phase update happens inside the task's completion handler when it
        // observes Task.isCancelled. Setting it here too would race.
    }

    /// Caller (banner UI) calls this after the user dismisses a completed
    /// or cancelled result so the next import starts from a clean slate.
    func acknowledgeCompletion() {
        switch phase {
        case .completed, .cancelled:
            phase = .idle
            currentTask = nil
        default:
            break
        }
    }

    // MARK: - Banner summarisation
    // Lifted verbatim from ProfileTabContents.importFiles — single source
    // of truth so onboarding + profile + the global banner all phrase
    // outcomes identically.

    private static func summariseBanner(for batch: BatchImportResult) -> ActivityImportBanner {
        var totalRuns = 0
        var dupes = 0
        var fails: [String] = []
        for outcome in batch.perFile {
            switch outcome.status {
            case .imported(let n): totalRuns += n
            case .duplicate:       dupes += 1
            case .empty:           fails.append("\(outcome.url.lastPathComponent): no runs")
            case .failed(let err): fails.append("\(outcome.url.lastPathComponent): \(err.localizedDescription)")
            }
        }

        if totalRuns > 0 {
            var msg = "\(totalRuns) RUN\(totalRuns == 1 ? "" : "S") IMPORTED"
            if dupes > 0 { msg += " · \(dupes) DUP" }
            if !fails.isEmpty { msg += " · \(fails.count) FAILED" }
            if !batch.recomputeSucceeded {
                msg += " · CALIBRATION DIDN'T REFRESH"
            }
            return ActivityImportBanner(message: msg, isError: !batch.recomputeSucceeded)
        }
        if dupes > 0 && fails.isEmpty {
            return ActivityImportBanner(
                message: "\(dupes) FILE\(dupes == 1 ? "" : "S") ALREADY IMPORTED",
                isError: false
            )
        }
        if !fails.isEmpty {
            // Pure-failure batches: enumerate up to 3 filenames + "and N
            // more" so the user can see which files broke instead of
            // assuming the others succeeded.
            let names = fails.map { $0.split(separator: ":", maxSplits: 1).first.map(String.init) ?? $0 }
            let shown = names.prefix(3).joined(separator: ", ")
            let extra = names.count > 3 ? " AND \(names.count - 3) MORE" : ""
            let plural = names.count == 1 ? "FILE" : "FILES"
            return ActivityImportBanner(
                message: "\(names.count) \(plural) FAILED: \(shown)\(extra)",
                isError: true
            )
        }
        return ActivityImportBanner(message: "NO SKI RUNS DETECTED IN FILE", isError: true)
    }

    /// Counts → Notify event. Fires for every completed batch so the
    /// iOS system notification is the single source of feedback (no
    /// inline banner exists anymore). The body adapts to count==0 +
    /// fails > 0 ("3 files failed to import") so error batches still
    /// surface clearly.
    private static func postNotifyForBatch(_ batch: BatchImportResult) {
        var runs = 0, dupes = 0, fails = 0
        for outcome in batch.perFile {
            switch outcome.status {
            case .imported(let n): runs += n
            case .duplicate:       dupes += 1
            case .empty, .failed:  fails += 1
            }
        }
        // Skip purely empty batches (nothing imported, nothing failed,
        // nothing duplicate — `cancel()` paths land here).
        guard runs > 0 || fails > 0 || dupes > 0 else { return }
        Task { @MainActor in
            Notify.shared.post(.runsImported(count: runs, dupes: dupes, failed: fails))
        }
    }
}
