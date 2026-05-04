//
//  PowderMeetApp.swift
//  PowderMeet
//

import SwiftUI
import UIKit

@main
struct PowderMeetApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase
    @State private var supabase = SupabaseManager.shared
    @State private var resortManager = ResortDataManager()
    /// Lifted to app scope so an in-flight activity import survives tab
    /// switches and any other view churn. See ActivityImportSession.swift.
    @State private var importSession = ActivityImportSession()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(supabase)
                .environment(resortManager)
                .environment(importSession)
                .task {
                    await supabase.initialize()
                }
                .task {
                    await supabase.observeAuthChanges()
                }
                .onChange(of: scenePhase) { _, newPhase in
                    // Re-verify the session every time the app comes
                    // to the foreground. If the account was deleted
                    // server-side (Supabase dashboard, RPC, etc.), the
                    // refresh fails with a user-gone error and the
                    // Manager signs out locally — RootView immediately
                    // swaps to AuthView. Without this, a deleted user
                    // could keep poking around for up to an hour while
                    // their cached JWT was still nominally valid.
                    if newPhase == .active {
                        Task { await supabase.verifySessionStillValid() }
                    }
                }
        }
    }
}

/// Minimal AppDelegate shim — adopted via `UIApplicationDelegateAdaptor`
/// solely to receive the APNs device token callback. SwiftUI's
/// `App` protocol doesn't expose those hooks, and pre-iOS-17 there was
/// no scene-level analogue.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        Task { @MainActor in
            Notify.shared.captureDeviceToken(deviceToken)
        }
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        // APNs registration can fail in the simulator (expected) or
        // when entitlements aren't right. Banners + local notifications
        // still work; we only lose the backgrounded peer-event surface.
        print("[AppDelegate] APNs registration failed: \(error.localizedDescription)")
    }
}
