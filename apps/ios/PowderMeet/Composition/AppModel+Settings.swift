import AppCore
import Foundation
import MapScene
import MapboxAdapter
import MeetSolver
import MountainCore
import Observation
import PMLogging
import PowderMeetAPI

/// Settings → Notifications: what this account has muted, per push kind
/// (`notification_prefs`, migration 0018). The push worker leaves a muted kind
/// out; the in-app banner and lists are unaffected.
nonisolated struct NotificationPrefsState: Sendable, Hashable {
    var muted: Set<PushKind> = []
    /// The server has answered once, so the toggles show its choice.
    var isLoaded = false
    var failure: PowderMeetError?

    func isOn(_ kind: PushKind) -> Bool { !muted.contains(kind) }
}

extension AppModel {
    // MARK: Notification preferences

    func loadNotificationPrefs() {
        notificationPrefs.failure = nil
        run("notification-prefs") { [weak self, deps] in
            do {
                let muted = try await deps.backend.notificationPrefs()
                guard !Task.isCancelled else { return }
                self?.notificationPrefs = NotificationPrefsState(muted: muted, isLoaded: true)
            } catch {
                guard !Task.isCancelled else { return }
                self?.notificationPrefs.failure = PowderMeetError(error)
            }
        }
    }

    /// Turns one kind on or off. The toggle moves at once; the whole set is
    /// sent, so a quick second tap replaces the first save, and a refused save
    /// puts the toggles back as the server last had them.
    func setNotification(_ kind: PushKind, on: Bool) {
        let before = notificationPrefs.muted
        var muted = before
        if on { muted.remove(kind) } else { muted.insert(kind) }
        notificationPrefs.muted = muted
        notificationPrefs.failure = nil
        run("notification-prefs") { [weak self, deps] in
            do {
                let stored = try await deps.backend.notificationPrefsSet(muted: muted)
                guard !Task.isCancelled else { return }
                self?.notificationPrefs = NotificationPrefsState(muted: stored, isLoaded: true)
            } catch {
                guard !Task.isCancelled else { return }
                let failure = PowderMeetError(error)
                self?.notificationPrefs.muted = before
                self?.notificationPrefs.failure = failure
            }
        }
    }

    // MARK: Permission intents

    func requestLocationPermission() {
        locationAccess.requestWhenInUse()
    }

    func requestNotificationPermission() {
        guard let push else { return }
        run("notifications") { [weak self] in
            do {
                self?.notificationPermission = try await push.requestPermission()
            } catch {
                self?.notificationPermission = .denied
                await self?.deps.toasts.post(.permission(.notifications))
            }
        }
    }

    func refreshNotificationPermission() {
        guard let push else { return }
        run("notification-state") { [weak self] in
            self?.notificationPermission = await push.permission()
        }
    }

    // MARK: Settings intents

    /// Writes the flight recorder's redacted log to a file the share sheet can
    /// send. Nil (with a toast) when the file could not be written.
    func exportBugReport() -> URL? {
        let header = "PowderMeet \(appVersion) (\(appBuild))\n"
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("PowderMeet-bug-report.txt")
        do {
            try Data((header + deps.recorder.export()).utf8).write(to: url, options: .atomic)
            return url
        } catch {
            let toasts = deps.toasts
            run("bug-report") {
                await toasts.post(message: "The bug report couldn't be written. Free some space and try again.")
            }
            return nil
        }
    }
}
