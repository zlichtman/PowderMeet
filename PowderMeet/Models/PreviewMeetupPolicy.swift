//
//  PreviewMeetupPolicy.swift
//  PowderMeet
//
//  TestFlight/Debug-only test meetups on a mountain's frozen preview map.
//

import Foundation

/// A pre-release build may run the complete two-phone meetup flow (send,
/// push, accept, activate, route progress) on a mountain's frozen preview
/// map, so the social pipeline is testable before the mountain has a
/// published dataset or reports ski-season status. Such a meet:
///   - is identified by the preview map's own immutable identity
///     (`mlegacy-…`, no manifest), stamped by the sender exactly as a live
///     meet stamps its canonical identity and verified exactly by the
///     receiver after rebuilding the same pinned snapshot;
///   - is stamped `.nonCanonicalDataset` and labeled TEST on both phones;
///   - never reads or claims operational status or lift hours, so it
///     cannot masquerade as live navigation.
/// App Store builds never send, accept, or activate one.
nonisolated enum PreviewMeetupPolicy {
    /// True for a well-formed legacy (preview-map) dataset identity.
    static func isPreviewIdentity(_ identifier: String?) -> Bool {
        guard let identifier,
              let version = MountainDatasetVersion(identifier: identifier) else {
            return false
        }
        return version.manifestVersion == nil
    }

    /// Sender gate: a strict solve on the loaded preview map, pre-release only.
    static func canSend(
        isPreRelease: Bool,
        solveAttempt: SolveAttempt?,
        datasetSource: MountainDataset.Source?
    ) -> Bool {
        isPreRelease
            && solveAttempt == .nonCanonicalDataset
            && datasetSource == .legacySnapshot
    }

    /// Receiver and activation gate: the locally loaded preview map must be
    /// the exact one the sender solved on.
    static func canActivate(
        isPreRelease: Bool,
        requestDatasetVersion: String?,
        datasetSource: MountainDataset.Source?,
        datasetVersion: String?
    ) -> Bool {
        isPreRelease
            && isPreviewIdentity(requestDatasetVersion)
            && datasetSource == .legacySnapshot
            && datasetVersion == requestDatasetVersion
    }

    /// Shown when a build that cannot run test meets receives one.
    static let unsupportedReceiverMessage =
        "This is a TestFlight test meetup on a preview map. It can't start in this version of PowderMeet."
}
