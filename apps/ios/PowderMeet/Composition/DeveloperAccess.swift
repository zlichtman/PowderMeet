import Foundation
import StoreKit

/// Where this copy of the app came from, as far as developer testing cares.
nonisolated enum DeveloperChannel: String, Sendable, Hashable {
    /// Built from Xcode in the Debug configuration.
    case debug
    /// TestFlight (or a development-signed Release build): the App Store's
    /// sandbox environment.
    case testFlight
    /// The App Store, or anything the checks cannot place.
    case appStore

    var allowsDeveloperTesting: Bool { self != .appStore }
}

/// Who may reach developer testing (`specs/07-CLIENT.md` section 8):
/// Debug and TestFlight builds, never the App Store. The TestFlight binary is
/// the one the App Store later ships, with the same build number and the same
/// UserDefaults after an update, so the answer is worked out on every launch and
/// granted only on positive evidence; nothing remembered can grant it.
nonisolated enum DeveloperAccess {
    /// UserDefaults: StoreKit said this build is from the App Store. It only
    /// ever closes the gate, for the build it names.
    private static let refusedBuildKey = "developer.refusedBuild"

    /// The answer at launch, without waiting: a Debug build, or a sandbox
    /// receipt (TestFlight). `AppTransaction` confirms or overrules it once it
    /// answers (`confirm()`).
    static var launchChannel: DeveloperChannel {
        #if DEBUG
        return .debug
        #else
        if UserDefaults.standard.string(forKey: refusedBuildKey) == currentBuild { return .appStore }
        // Deprecated since iOS 18 but still the only answer that needs no wait;
        // App Store copies name it "receipt", sandbox (TestFlight) copies "sandboxReceipt".
        return Bundle.main.appStoreReceiptURL?.lastPathComponent == "sandboxReceipt" ? .testFlight : .appStore
        #endif
    }

    static var isAllowed: Bool { launchChannel.allowsDeveloperTesting }

    /// StoreKit's verified answer: the sandbox (TestFlight) or Xcode environment
    /// allows, production refuses. Nil when StoreKit could not answer or could
    /// not verify its answer, which changes nothing (the receipt check stands).
    /// A refusal is remembered for this build.
    static func confirm() async -> DeveloperChannel? {
        #if DEBUG
        return .debug
        #else
        let result: VerificationResult<AppTransaction>
        do {
            result = try await AppTransaction.shared
        } catch {
            return nil
        }
        guard case .verified(let transaction) = result else { return nil }
        let environment = transaction.environment
        let channel: DeveloperChannel = environment == .sandbox || environment == .xcode ? .testFlight : .appStore
        if channel == .appStore {
            UserDefaults.standard.set(currentBuild, forKey: refusedBuildKey)
        }
        return channel
        #endif
    }

    private static var currentBuild: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "0"
        let build = info["CFBundleVersion"] as? String ?? "0"
        return "\(version) (\(build))"
    }
}
