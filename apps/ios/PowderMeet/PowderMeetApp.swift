import SwiftUI
import UIKit

@main
struct PowderMeetApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(delegate.root.model)
                // Nil outside Debug and TestFlight builds; readers take it as optional.
                .environment(delegate.root.developer)
        }
    }
}

/// Owns the composition root and forwards the APNs callbacks to it.
final class AppDelegate: NSObject, UIApplicationDelegate {
    let root = CompositionRoot()

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        root.start()
        return true
    }

    func application(
        _ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        root.push?.didRegister(tokenData: deviceToken)
    }

    func application(
        _ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: any Error
    ) {
        root.push?.didFailToRegister()
    }
}
