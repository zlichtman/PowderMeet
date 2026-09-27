//
//  NotificationObservers.swift
//  PowderMeet
//
//  Small NotificationCenter lifetime wrappers, hoisted out of
//  RealtimeLocationService so the realtime stack and the DEBUG selftest can
//  reuse them. RAII-style: each holds its observer token and removes it on
//  deinit, so owners don't need a MainActor-reading deinit.
//

import Foundation
import UIKit

/// Holds a `NotificationCenter` token and removes it on deinit so
/// `RealtimeLocationService` does not need a `deinit` that reads MainActor state.
final class NotificationCenterObservationLifetime {
    private let token: NSObjectProtocol

    init(name: Notification.Name, handler: @escaping (Notification) -> Void) {
        token = NotificationCenter.default.addObserver(
            forName: name,
            object: nil,
            queue: .main,
            using: handler
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(token)
    }
}

/// Listens for `UIApplication.willEnterForegroundNotification` and invokes the
/// supplied handler on the main queue. Held by `RealtimeLocationService` to
/// kick a forced broadcast on resume; broken out as a standalone class so the
/// DEBUG selftest can build one in isolation and verify the wiring fires.
final class ForegroundResubscriber {
    private(set) var fireCount = 0
    private var observer: NSObjectProtocol?
    private let handler: () -> Void

    init(handler: @escaping () -> Void) {
        self.handler = handler
        let name = Notification.Name("UIApplicationWillEnterForegroundNotification")
        observer = NotificationCenter.default.addObserver(
            forName: name, object: nil, queue: .main
        ) { [weak self] _ in
            self?.fireCount += 1
            self?.handler()
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }
}
