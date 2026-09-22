import Foundation

/// A remote ETA is not arrival evidence. Require a recent packet from this
/// mountain and a reported accuracy radius wholly within the meeting area.
/// This remains GPS-based proximity, not proof that two people have reunited.
nonisolated enum MeetArrivalStatusClassifier {
    static func partnerHasArrived(
        etaSeconds: Double,
        signalQuality: FriendSignalQuality?,
        distanceToMeetingMeters: Double?,
        capturedAt: Date?,
        accuracyMeters: Double?,
        locationResortID: String?,
        meetingResortID: String,
        now: Date = .now
    ) -> Bool {
        guard etaSeconds.isFinite, (0...5).contains(etaSeconds),
              signalQuality?.isLive == true,
              !meetingResortID.isEmpty, locationResortID == meetingResortID,
              RoutingFixPolicy.isFresh(capturedAt: capturedAt, now: now),
              let distance = distanceToMeetingMeters, distance.isFinite, distance >= 0,
              let accuracy = accuracyMeters, accuracy.isFinite, accuracy >= 0 else { return false }
        let radius = RouteProgressTracker.meetingArrivalMaxDistanceMeters
        return distance <= radius && accuracy <= radius - distance
    }

    static func partnerETAStatus(etaSeconds: Double, hasArrived: Bool) -> String? {
        guard etaSeconds.isFinite, etaSeconds >= 0,
              Int(exactly: etaSeconds.rounded(.down)) != nil else { return "UNAVAILABLE" }
        if hasArrived { return "NEAR MEETING POINT" }
        return needsPartnerArrivalConfirmation(etaSeconds: etaSeconds, hasArrived: hasArrived)
            ? "ARRIVAL UNCONFIRMED" : nil
    }

    static func needsPartnerArrivalConfirmation(etaSeconds: Double, hasArrived: Bool) -> Bool {
        !hasArrived && etaSeconds.isFinite && (0...5).contains(etaSeconds)
    }
}

/// Only remote ETA values depend on friend-signal availability.
nonisolated struct ActiveETASignalPresentation: Equatable, Sendable {
    let statusText: String?
    let isLive: Bool
    var estimateContext: String? { isLive ? nil : "LAST ESTIMATE" }

    init(isRemote: Bool, quality: FriendSignalQuality?) {
        guard isRemote else {
            statusText = nil
            isLive = true
            return
        }
        let presentation = FriendSignalPresentation(quality: quality)
        statusText = presentation.statusText
        isLive = presentation.isLive
    }
}
