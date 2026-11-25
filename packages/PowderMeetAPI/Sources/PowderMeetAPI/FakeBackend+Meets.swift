import Foundation
import MountainCore

extension FakeBackend {
    // MARK: Presence RPCs

    func presenceUpdate(_ caller: UUID?, update: PresenceUpdate) throws {
        let me = try uid(caller)
        guard (-180...180).contains(update.lon), (-90...90).contains(update.lat) else {
            throw BackendError.invalid
        }
        if let resortID = update.resortID, resorts[resortID]?.published != true {
            throw BackendError.resortNotPublished
        }
        if let stored = presence[me] {
            // At most one stored fix per 2 s; extra calls are dropped, not errors.
            if let received = stored.receivedAt, received > now.addingTimeInterval(-2) { return }
            // Monotonic sender time (I-19), unless the stored time is in the future.
            if update.capturedAt <= stored.capturedAt,
               stored.capturedAt <= now.addingTimeInterval(60) { return }
        }
        let row = Presence(
            userID: me, resortID: update.resortID, lon: update.lon, lat: update.lat,
            accuracyM: update.accuracyM, speedMS: update.speedMS, headingDeg: update.headingDeg,
            capturedAt: update.capturedAt, receivedAt: now
        )
        presence[me] = row
        var payload = row
        payload.receivedAt = nil
        for recipient in presenceRecipients(of: me, resortID: update.resortID) {
            emit(to: recipient, .presence(payload))
        }
    }

    func presenceClear(_ caller: UUID?) throws {
        presence[try uid(caller)] = nil
    }

    func presenceSnapshot(_ caller: UUID?, resortID: String) throws -> [Presence] {
        let me = try uid(caller)
        return presence.values.filter { row in
            row.userID != me
                && (row.receivedAt ?? .distantPast) > now.addingTimeInterval(-15 * 60)
                && isAcceptedFriend(me, row.userID)
                && (row.resortID == resortID || hasOpenMeetBetween(me, row.userID))
        }.sorted { $0.userID.uuidString < $1.userID.uuidString }
    }

    // MARK: Device and event RPCs

    func deviceTokenRegister(_ caller: UUID?, token: String, environment: PushEnvironment) throws {
        let me = try uid(caller)
        let isHex = token.utf8.allSatisfy {
            (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)
        }
        guard (32...200).contains(token.utf8.count), isHex else { throw BackendError.invalid }
        // A token belongs to one phone: registering it here removes it elsewhere.
        for user in deviceTokens.keys where user != me { deviceTokens[user]?[token] = nil }
        deviceTokens[me, default: [:]][token] = environment
    }

    func deviceTokenUnregister(_ caller: UUID?, token: String) throws {
        let me = try uid(caller)
        deviceTokens[me]?[token] = nil
    }

    func notificationPrefs(_ caller: UUID?) throws -> Set<PushKind> {
        let me = try uid(caller)
        return mutedPushKinds[me] ?? []
    }

    func notificationPrefsSet(_ caller: UUID?, muted: Set<PushKind>) throws -> Set<PushKind> {
        let me = try uid(caller)
        mutedPushKinds[me] = muted
        return muted
    }

    func clientEvent(_ caller: UUID?, kind: String, props: [String: JSONValue]) throws {
        let me = try uid(caller)
        guard (1...64).contains(kind.count) else { throw BackendError.invalid }
        try rateLimit(me, "client_event", max: 300, window: 60)
        clientEvents.append((me, kind, props))
    }

    // MARK: Meet RPCs

    func meetPropose(
        _ caller: UUID?, meetID: UUID, invitee: UUID, resortID: String,
        rendezvousID: RendezvousID, bundleID: BundleID?, etaS: Int, etaSdS: Int, supersedes: UUID?
    ) throws -> Meet {
        let me = try uid(caller)
        guard etaS >= 0, etaSdS >= 0 else { throw BackendError.invalid }
        guard invitee != me else { throw BackendError.notFriends }

        // Idempotent retry: the same proposer sending the same meet_id again.
        if let existing = meets[meetID] {
            if existing.proposerID == me { return existing }
            throw BackendError.meetIDTaken
        }
        // A block reads as no friendship: it is never revealed.
        guard isAcceptedFriend(me, invitee) else { throw BackendError.notFriends }
        guard let resort = resorts[resortID], resort.published else {
            throw BackendError.resortNotPublished
        }
        // I-01: a meet may end only at a rendezvous in the active bundle.
        guard resort.rendezvousIDs.contains(rendezvousID) else {
            throw BackendError.rendezvousUnknown
        }

        var superseded: Meet?
        if let supersedes {
            guard let old = meets[supersedes], old.proposerID == me else {
                throw BackendError.notParticipant
            }
            guard old.inviteeID == invitee, old.status != .active else {
                throw BackendError.invalidState
            }
            if old.status == .proposed { superseded = old }
        }

        // I-23: one non-terminal meet per user, in either role. The superseded
        // proposal no longer counts, as in the SQL where it is ended first.
        func busy(_ user: UUID) -> Bool {
            meets.values.contains {
                !$0.status.isTerminal && $0.involves(user) && $0.meetID != superseded?.meetID
            }
        }
        if busy(me) { throw BackendError.meetBusyProposer }
        if busy(invitee) { throw BackendError.meetBusyInvitee }

        if var old = superseded {
            old.status = .invalidated
            old.endReason = .superseded
            old.endedAt = now
            old.supersededBy = meetID
            old.endedBy = me
            meets[old.meetID] = old
            emit(to: old.proposerID, .meetUpdated(old))
            emit(to: old.inviteeID, .meetUpdated(old))
        }

        let meet = Meet(
            meetID: meetID, resortID: resortID, bundleID: bundleID?.rawValue,
            rendezvousID: rendezvousID, proposerID: me, inviteeID: invitee, status: .proposed,
            proposerEtaS: etaS, proposerEtaSdS: etaSdS, createdAt: now,
            expiresAt: now.addingTimeInterval(30 * 60)
        )
        meets[meetID] = meet
        emit(to: invitee, .meetProposed(meet))
        return meet
    }

    func meetRespond(
        _ caller: UUID?, meetID: UUID, accept: Bool, etaS: Int?, etaSdS: Int?,
        declineReason: MeetDeclineReason?
    ) throws -> Meet {
        let me = try uid(caller)
        guard (etaS ?? 0) >= 0, (etaSdS ?? 0) >= 0 else { throw BackendError.invalid }
        guard var meet = meets[meetID], meet.involves(me) else { throw BackendError.notParticipant }
        // Only the invitee answers. The proposer cannot accept their own proposal.
        guard meet.inviteeID == me else { throw BackendError.invalidState }
        guard meet.status == .proposed else { throw BackendError.meetNotProposed }

        if accept {
            guard now < meet.expiresAt else { throw BackendError.meetExpired }
            meet.status = .active
            meet.respondedAt = now
            meet.inviteeEtaS = etaS
            meet.inviteeEtaSdS = etaSdS
        } else {
            meet.status = .declined
            meet.endReason = declineReason == .declinedCannotRoute
                ? .declinedCannotRoute : .declinedByUser
            meet.respondedAt = now
            meet.endedAt = now
            meet.endedBy = me
        }
        meets[meetID] = meet
        emit(to: meet.proposerID, .meetUpdated(meet))
        emit(to: meet.inviteeID, .meetUpdated(meet))
        return meet
    }

    func meetProgressUpdate(
        _ caller: UUID?, meetID: UUID, etaS: Int?, etaSdS: Int?, remainingM: Int?,
        state: MeetProgressState, fixAt: Date
    ) throws {
        let me = try uid(caller)
        guard let meet = meets[meetID], meet.involves(me) else { throw BackendError.notParticipant }
        guard meet.status == .active else { throw BackendError.invalidState }
        // A fix older than the stored one is ignored (I-19).
        if let stored = progress[meetID]?[me], fixAt <= stored.fixAt { return }
        var row = MeetProgress(
            meetID: meetID, userID: me, etaS: etaS, etaSdS: etaSdS, remainingM: remainingM,
            state: state, fixAt: fixAt, updatedAt: now
        )
        progress[meetID, default: [:]][me] = row
        row.updatedAt = nil
        emit(to: meet.partner(of: me), .meetProgress(row))
        // Both skiers there: the meet is over, with nobody to tap anything. As
        // on the server (0028), the other skier's arrival counts only while
        // their fix is at most two minutes old.
        let current = progress[meetID]?.values.filter {
            $0.state == .arrived && ($0.userID == me || $0.fixAt >= now.addingTimeInterval(-120))
        }
        if completesMeetsOnArrival, current?.count == 2 {
            endMeet(meetID, status: .completed, reason: .arrived, by: me)
        }
    }

    func meetEnd(_ caller: UUID?, meetID: UUID, reason: MeetEndRequest) throws -> Meet {
        let me = try uid(caller)
        guard let meet = meets[meetID], meet.involves(me) else { throw BackendError.notParticipant }
        // Terminal states never change; ending twice returns the same row.
        if meet.status.isTerminal { return meet }

        let status: MeetStatus
        if meet.status == .proposed {
            // Only the proposer withdraws a proposal; the invitee declines instead.
            guard meet.proposerID == me, reason == .userCancelled else {
                throw BackendError.invalidState
            }
            status = .cancelled
        } else {
            status = switch reason {
            case .arrived: .completed
            case .userCancelled: .cancelled
            case .statusBlocksRoute, .partnerLeft: .invalidated
            }
        }
        let endReason: MeetEndReason = switch reason {
        case .arrived: .arrived
        case .userCancelled: .userCancelled
        case .statusBlocksRoute: .statusBlocksRoute
        case .partnerLeft: .partnerLeft
        }
        endMeet(meetID, status: status, reason: endReason, by: me)
        return meets[meetID] ?? meet
    }

    func meetCurrent(_ caller: UUID?) throws -> Meet? {
        let me = try uid(caller)
        return meets.values.filter { !$0.status.isTerminal && $0.involves(me) }
            .max { $0.createdAt < $1.createdAt }
    }

    func meetHistory(_ caller: UUID?, limit: Int) throws -> [Meet] {
        let me = try uid(caller)
        return Array(meets.values.filter { $0.involves(me) }
            .sorted { $0.createdAt > $1.createdAt }
            .prefix(min(max(limit, 1), 200)))
    }

    // MARK: Descent RPCs

    func descentUpsert(_ caller: UUID?, upload: DescentUpload) throws -> DescentUpsertResult {
        let me = try uid(caller)
        let hash = upload.contentHash.utf8
        guard hash.count == 64, hash.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              upload.endedAt > upload.startedAt, (1...2_097_152).contains(upload.track.count)
        else { throw BackendError.invalid }
        if let match = upload.match, BundleID(match.bundleID).flatMap({ bundles[$0] }) == nil {
            throw BackendError.invalid
        }
        // One physical descent is one row (I-20): same bytes, or more than 80 % of
        // the longer recording's time shared with one already stored.
        let mine = descents.filter { $0.owner == me }
        let same = mine.first { $0.upload.contentHash == upload.contentHash }
            ?? mine.sorted { $0.upload.startedAt < $1.upload.startedAt }.first {
                let start = max($0.upload.startedAt, upload.startedAt)
                let end = min($0.upload.endedAt, upload.endedAt)
                let longer = max(
                    $0.upload.endedAt.timeIntervalSince($0.upload.startedAt),
                    upload.endedAt.timeIntervalSince(upload.startedAt)
                )
                return end.timeIntervalSince(start) > 0.8 * longer
            }
        if let same {
            // A re-import of the same bytes refreshes what the phone derived.
            if same.upload.contentHash == upload.contentHash, let stats = upload.stats,
               let index = descents.firstIndex(where: { $0.id == same.id }) {
                descents[index].upload.stats = stats
            }
            // The server upserts the match whichever recording it came with.
            if let match = upload.match, let index = descents.firstIndex(where: { $0.id == same.id }) {
                descents[index].upload.match = match
            }
            return DescentUpsertResult(descentID: same.id, created: false)
        }
        let id = UUID()
        descents.append(Descent(id: id, owner: me, upload: upload))
        return DescentUpsertResult(descentID: id, created: true)
    }

    func descentDelete(_ caller: UUID?, descentID: UUID) throws {
        let me = try uid(caller)
        descents.removeAll { $0.id == descentID && $0.owner == me }
    }
}
