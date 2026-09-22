//
//  BuildEnvironment.swift
//  PowderMeet
//
//  Build-channel detection for gating dev-only affordances that should
//  reach TestFlight testers but never ship to App Store production.
//

import Foundation

enum BuildEnvironment {
    /// True for Debug runs, TestFlight betas, and Ad-Hoc/Enterprise installs.
    /// False only for App Store production downloads.
    ///
    /// Multi-signal detection — any one of these flips the flag:
    ///
    ///   1. `#if DEBUG`              → Xcode → Run on device or sim.
    ///   2. `appStoreReceiptURL` filename == `sandboxReceipt`
    ///                              → TestFlight installs (Apple-documented).
    ///   3. `embedded.mobileprovision` present in app bundle
    ///                              → TestFlight / Ad-Hoc / Dev signing.
    ///                              App Store strips the profile during
    ///                              re-signing, so its absence flags prod.
    ///
    /// History: a TestFlight build (#16) had this returning false because
    /// the receipt URL filename came back as something other than
    /// `sandboxReceipt` on the tester's device, gating the location picker
    /// off the build it was supposed to enable. The mobileprovision check
    /// is belt-and-suspenders against that class of regression.
    static let isPreRelease: Bool = {
        #if DEBUG
        return true
        #else
        if Bundle.main.appStoreReceiptURL?.lastPathComponent == "sandboxReceipt" {
            return true
        }
        if Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision") != nil {
            return true
        }
        return false
        #endif
    }()
}
