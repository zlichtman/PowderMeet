//
//  Notify.swift
//  PowderMeet
//
//  Single notification surface for the events users care about. Every
//  delivery is a standard iOS system notification — no in-app banner
//  overlay. Foreground deliveries get the same system banner as
//  backgrounded ones (iOS draws it; we don't reskin it).
//
//    self    : runsImported, meetArrival, calibrationStale
//              (local notifications scheduled inside the app)
//    peer    : friendAdded, friendRequest, meetRequest, meetStarted
//              (APNs push fan-out via the `send-push` edge function)
//
//  Why not in-app banners: meeting flows on a chairlift / on the snow
//  benefit from the consistent system surface (lock-screen, notification
//  center, badge counts, Do Not Disturb honored, watch mirroring).
//  Reskinning that into a custom in-app banner buys nothing and loses
//  every system integration.
//

import SwiftUI
import UserNotifications
import UIKit

@MainActor @Observable
final class Notify: NSObject {
    static let shared = Notify()

    /// True once the user has been asked for notification permission.
    /// Driven by the system status — checked lazily on first post.
    private var didRequestAuthorization = false

    /// Captured at `didRegisterForRemoteNotificationsWithDeviceToken`.
    /// Pushed to Supabase's `device_tokens` table so server triggers
    /// can fan out via the `send-push` edge function.
    private(set) var deviceToken: String?

    private override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
    }

    // MARK: - Posting

    /// Fire a notification for an event. Self events schedule a local
    /// notification (renders as a normal iOS banner whether the app is
    /// foreground or background). Peer events are no-ops here — the
    /// server-side `send-push` edge function handles those via APNs;
    /// keeping the call sites symmetrical lets services post events
    /// without caring whether the path is local or remote.
    func post(_ event: Event) {
        guard event.isSelf else { return }
        scheduleLocalNotification(for: event)
    }

    private func scheduleLocalNotification(for event: Event) {
        Task {
            await ensureAuthorized()
            let content = UNMutableNotificationContent()
            content.title = event.title
            content.body = event.body
            content.sound = .default
            // Stamp the kind so the tap handler can deep-link later.
            content.userInfo = ["kind": event.kindKey]
            let req = UNNotificationRequest(
                identifier: UUID().uuidString,
                content: content,
                trigger: nil  // immediate
            )
            try? await UNUserNotificationCenter.current().add(req)
        }
    }

    // MARK: - Authorization

    /// Asks for alert + sound + badge permission the first time it's
    /// needed. Idempotent — system caches the user's answer.
    func ensureAuthorized() async {
        guard !didRequestAuthorization else { return }
        didRequestAuthorization = true
        let center = UNUserNotificationCenter.current()
        do {
            let granted = try await center.requestAuthorization(options: [.alert, .sound, .badge])
            if granted {
                await MainActor.run {
                    UIApplication.shared.registerForRemoteNotifications()
                }
            }
        } catch {
            // Not fatal — events still post; nothing displays if denied.
        }
    }

    /// Called from the AppDelegate shim once iOS hands us an APNs token.
    func captureDeviceToken(_ data: Data) {
        let hex = data.map { String(format: "%02x", $0) }.joined()
        deviceToken = hex
        Task {
            await SupabaseManager.shared.upsertDeviceToken(hex)
        }
    }
}

// MARK: - UNUserNotificationCenterDelegate

extension Notify: UNUserNotificationCenterDelegate {
    /// Foreground deliveries — both local notifications we scheduled
    /// and APNs pushes from peer events. Returning the banner option
    /// tells iOS to render its standard banner UI even with the app in
    /// the foreground (default behavior would suppress it).
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound, .list, .badge])
    }

    /// Tap handler — parses the APNs payload's `kind` field (mirrors
    /// the discriminator the `send-push` edge function spreads onto the
    /// top-level userInfo: `meet_request`, `friend_request`,
    /// `friend_added`, `meet_started`) and posts a NotificationCenter
    /// event so ContentView can switch to the right tab. The lists in
    /// MeetView surface the actual request card, so a tab switch is
    /// enough — no scroll-to / highlight needed.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        let kind = userInfo["kind"] as? String
        let link = DeepLink(kind: kind, userInfo: userInfo)
        if let link {
            Task { @MainActor in
                NotificationCenter.default.post(name: .powderMeetDeepLink, object: link)
            }
        }
        completionHandler()
    }
}

// MARK: - Deep-link routing

extension Notification.Name {
    /// Posted by `Notify` when the user taps a remote-notification
    /// banner. `object` is a `DeepLink`. ContentView observes this and
    /// switches tabs accordingly.
    static let powderMeetDeepLink = Notification.Name("PowderMeetDeepLink")
}

enum DeepLink: Equatable, Sendable {
    case meetRequest(senderId: UUID, meetingNodeId: String)
    case meetStarted(receiverId: UUID)
    case friendRequest(requesterId: UUID)
    case friendAdded(addresseeId: UUID)

    /// Construct from the APNs `userInfo` dict shape that send-push
    /// produces: `{ kind, sender_id?, meeting_node_id?, requester_id?,
    /// addressee_id?, receiver_id? }`. Returns nil for unknown kinds
    /// or missing required ids — better to no-op than to deep-link
    /// somewhere wrong.
    ///
    /// `nonisolated` so the `nonisolated` UNUserNotificationCenterDelegate
    /// tap handler can construct one without hopping through MainActor.
    /// The init touches no actor-isolated state — pure parsing.
    nonisolated init?(kind: String?, userInfo: [AnyHashable: Any]) {
        guard let kind else { return nil }
        switch kind {
        case "meet_request":
            guard let sid = (userInfo["sender_id"] as? String).flatMap(UUID.init),
                  let nid = userInfo["meeting_node_id"] as? String else { return nil }
            self = .meetRequest(senderId: sid, meetingNodeId: nid)
        case "meet_started":
            guard let rid = (userInfo["receiver_id"] as? String).flatMap(UUID.init) else { return nil }
            self = .meetStarted(receiverId: rid)
        case "friend_request":
            guard let rid = (userInfo["requester_id"] as? String).flatMap(UUID.init) else { return nil }
            self = .friendRequest(requesterId: rid)
        case "friend_added":
            guard let aid = (userInfo["addressee_id"] as? String).flatMap(UUID.init) else { return nil }
            self = .friendAdded(addresseeId: aid)
        default:
            return nil
        }
    }

    /// Which top-level tab this link should bring the user to.
    /// Tab 0 = Map, Tab 1 = PowderMeet, Tab 2 = Profile (matches
    /// ContentView's stacked-opacity layout).
    var targetTab: Int {
        switch self {
        case .meetRequest, .meetStarted, .friendRequest, .friendAdded:
            return 1
        }
    }
}

// MARK: - Event model

extension Notify {
    enum Event: Equatable {
        case runsImported(count: Int, dupes: Int, failed: Int)
        case meetArrival(at: String)
        case friendAdded(displayName: String)
        case friendRequest(from: String)
        case meetRequest(from: String)
        case meetStarted(with: String)
        /// Contact rescan finished. Surfaces the privacy reassurance
        /// (contacts are checked, never stored) as a standard iOS
        /// notification rather than an in-app banner.
        case contactsRescanned
        /// Per-edge skill recompute didn't go through. Surfaces when an
        /// import or live-record finished but the calibration RPC
        /// failed; the solver's per-edge memory is therefore one
        /// recompute behind. Quiet warning, not an error.
        case calibrationStale

        var title: String {
            switch self {
            case .runsImported(let count, _, let failed):
                if count == 0 && failed > 0 { return "Import Failed" }
                return "Runs Imported"
            case .meetArrival:       return "You're Here"
            case .friendAdded:       return "Friend Added"
            case .friendRequest:     return "Friend Request"
            case .meetRequest:       return "Meet Request"
            case .meetStarted:       return "PowderMeet Started"
            case .contactsRescanned: return "Contacts Rescanned"
            case .calibrationStale:  return "Calibration Delayed"
            }
        }

        var body: String {
            switch self {
            case .runsImported(let count, let dupes, let failed):
                if count > 0 {
                    var parts = ["\(count) run\(count == 1 ? "" : "s") imported"]
                    if dupes > 0  { parts.append("\(dupes) duplicate") }
                    if failed > 0 { parts.append("\(failed) failed") }
                    return parts.joined(separator: " · ")
                }
                if failed > 0 {
                    return "\(failed) file\(failed == 1 ? "" : "s") couldn't be imported."
                }
                if dupes > 0 {
                    return "\(dupes) file\(dupes == 1 ? "" : "s") already imported."
                }
                return "No runs detected."
            case .meetArrival(let at):
                return "Arrived at \(at)."
            case .friendAdded(let name):
                return "\(name) is now your friend."
            case .friendRequest(let from):
                return "\(from) wants to be friends."
            case .meetRequest(let from):
                return "\(from) wants to meet up."
            case .meetStarted(let with):
                return "Meetup with \(with) is live."
            case .contactsRescanned:
                return "Checked your contacts for friends. Never stored."
            case .calibrationStale:
                return "Recent runs aren't in the solver yet — will retry."
            }
        }

        /// Stable identifier used in `userInfo` for the tap handler.
        var kindKey: String {
            switch self {
            case .runsImported:      return "runs_imported"
            case .meetArrival:       return "meet_arrival"
            case .friendAdded:       return "friend_added"
            case .friendRequest:     return "friend_request"
            case .meetRequest:       return "meet_request"
            case .meetStarted:       return "meet_started"
            case .contactsRescanned: return "contacts_rescanned"
            case .calibrationStale:  return "calibration_stale"
            }
        }

        /// True for events the user themselves triggered. These get
        /// scheduled as local notifications. Peer events rely on APNs
        /// pushes from the server-side `send-push` edge function.
        var isSelf: Bool {
            switch self {
            case .runsImported, .meetArrival,
                 .contactsRescanned,
                 .calibrationStale:                return true
            case .friendAdded, .friendRequest,
                 .meetRequest, .meetStarted:       return false
            }
        }
    }
}
