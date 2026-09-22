//
//  MeetRequestService.swift
//  PowderMeet
//
//  Manages real-time meet requests between friends via Supabase.
//  Table: meet_requests (sender_id, receiver_id, resort_id, meeting_node_id,
//         meeting_node_elevation, status, created_at, expires_at)
//
//  Concurrency contract:
//   - `insertTask`, `updateTask`, `receiverUpdateTask`, `pollTask` are
//     stored Task handles owned by the service. Each runs an unbounded
//     `for await` loop over a Supabase realtime async stream; the only
//     way they exit is `task.cancel()` from `stop()` (which is also
//     fired implicitly when the service is torn down via realtime
//     teardown). They capture `self` strongly because the loop's
//     lifetime IS the service's listener lifetime — `[weak self]`
//     would break the contract that "subscribed = receiving".
//   - Cancellation hygiene: every Task is reassigned (cancelling the
//     prior one) before the next subscribe call. See `subscribe()`.
//   - Polling backoff: `pollTask` is the fallback for when the realtime
//     channel goes idle; cancel-and-restart on each `startPolling()`
//     call so we never leak two polling loops.
//

import Foundation
import Observation
import Supabase

// MARK: - Meet Request Model

nonisolated struct MeetRequest: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    let senderId: UUID
    let receiverId: UUID
    let resortId: String
    let meetingNodeId: String
    let meetingNodeElevation: Double
    let meetingNodeDisplayName: String?
    let senderPositionNodeId: String?
    let receiverPositionNodeId: String?
    let senderEtaSeconds: Double?
    let receiverEtaSeconds: Double?
    /// Ordered edge IDs of the sender's path to the meeting node, as computed
    /// by the sender's solver at request time. Lets the receiver render the
    /// sender's route and lets the sender skip re-solving on accept.
    let senderPathEdgeIds: [String]?
    /// Ordered edge IDs of the receiver's path to the meeting node. Same
    /// rationale — the receiver uses these instead of re-solving (which
    /// often failed when their live GPS/broadcast wasn't ready).
    let receiverPathEdgeIds: [String]?
    let status: MeetRequestStatus
    let createdAt: Date?
    let expiresAt: Date?
    /// Date of the server-side graph snapshot the sender used.
    /// Receiver compares to their local snapshot — if different, re-downloads to ensure identical graphs.
    let graphSnapshotDate: String?
    /// Canonical manifest version of the sender's graph. When non-nil,
    /// the receiver force-fetches this exact version via get-resort-graph
    /// before solving so both devices route on byte-identical graphs.
    /// Null = legacy meet (sender on pre-canonical pipeline); the
    /// existing `graphSnapshotDate` drift fallback applies.
    let manifestVersion: Int?
    /// Full immutable dataset identity: manifest + graph schema + content SHA.
    /// Activation requires an exact match, not merely the same manifest row.
    let datasetVersion: String?

    enum CodingKeys: String, CodingKey {
        case id
        case senderId = "sender_id"
        case receiverId = "receiver_id"
        case resortId = "resort_id"
        case meetingNodeId = "meeting_node_id"
        case meetingNodeElevation = "meeting_node_elevation"
        case meetingNodeDisplayName = "meeting_node_display_name"
        case senderPositionNodeId = "sender_position_node_id"
        case receiverPositionNodeId = "receiver_position_node_id"
        case senderEtaSeconds = "sender_eta_seconds"
        case receiverEtaSeconds = "receiver_eta_seconds"
        case senderPathEdgeIds = "sender_path_edge_ids"
        case receiverPathEdgeIds = "receiver_path_edge_ids"
        case status
        case createdAt = "created_at"
        case expiresAt = "expires_at"
        case graphSnapshotDate = "graph_snapshot_date"
        case manifestVersion = "manifest_version"
        case datasetVersion = "dataset_version"
    }
}

nonisolated struct NewMeetRequest: Encodable, Sendable {
    let senderId: UUID
    let receiverId: UUID
    let resortId: String
    let meetingNodeId: String
    let meetingNodeElevation: Double
    let meetingNodeDisplayName: String?
    let senderPositionNodeId: String?
    let receiverPositionNodeId: String?
    let senderEtaSeconds: Double?
    let receiverEtaSeconds: Double?
    let senderPathEdgeIds: [String]?
    let receiverPathEdgeIds: [String]?
    let status: MeetRequestStatus
    let expiresAt: String     // ISO8601
    let graphSnapshotDate: String?
    let manifestVersion: Int?
    let datasetVersion: String?

    enum CodingKeys: String, CodingKey {
        case senderId = "sender_id"
        case receiverId = "receiver_id"
        case resortId = "resort_id"
        case meetingNodeId = "meeting_node_id"
        case meetingNodeElevation = "meeting_node_elevation"
        case meetingNodeDisplayName = "meeting_node_display_name"
        case senderPositionNodeId = "sender_position_node_id"
        case receiverPositionNodeId = "receiver_position_node_id"
        case senderEtaSeconds = "sender_eta_seconds"
        case receiverEtaSeconds = "receiver_eta_seconds"
        case senderPathEdgeIds = "sender_path_edge_ids"
        case receiverPathEdgeIds = "receiver_path_edge_ids"
        case status
        case expiresAt = "expires_at"
        case graphSnapshotDate = "graph_snapshot_date"
        case manifestVersion = "manifest_version"
        case datasetVersion = "dataset_version"
    }
}

nonisolated enum MeetRequestServiceEvent: Equatable, Sendable {
    case received(MeetRequest)
    case accepted(MeetRequest)
    case etaUpdated(MeetRequest)
    case declined(MeetRequest)
    case expired(MeetRequest)
}

/// Cold-launch recovery policy for a meetup that was already accepted before
/// the app process disappeared. Recovery is deliberately bounded and requires
/// the immutable dataset identity; old or legacy rows must never silently
/// recreate navigation against whatever mountain happens to be loaded now.
nonisolated enum ActiveMeetRecoveryPolicy {
    static let maximumAge: TimeInterval = 4 * 60 * 60
    static let allowableFutureClockSkew: TimeInterval = 5 * 60

    static func isRecoverable(
        _ request: MeetRequest,
        currentUserID: UUID,
        now: Date = .now
    ) -> Bool {
        guard request.status == .accepted,
              request.senderId != request.receiverId,
              request.senderId == currentUserID || request.receiverId == currentUserID,
              !request.resortId.isEmpty,
              !request.meetingNodeId.isEmpty,
              request.datasetVersion?.isEmpty == false,
              let createdAt = request.createdAt else { return false }
        let age = now.timeIntervalSince(createdAt)
        return age >= -allowableFutureClockSkew && age <= maximumAge
    }

    static func newestRecoverable(
        from requests: [MeetRequest],
        currentUserID: UUID,
        now: Date = .now,
        excludingRequestIDs: Set<UUID> = []
    ) -> MeetRequest? {
        requests
            .filter {
                !excludingRequestIDs.contains($0.id)
                    && isRecoverable($0, currentUserID: currentUserID, now: now)
            }
            .sorted {
                let lhs = $0.createdAt ?? .distantPast
                let rhs = $1.createdAt ?? .distantPast
                if lhs != rhs { return lhs > rhs }
                return $0.id.uuidString < $1.id.uuidString
            }
            .first
    }
}

nonisolated enum PendingMeetTerminationPolicy {
    static let retention: TimeInterval = 7 * 24 * 60 * 60
    static let allowableFutureClockSkew: TimeInterval = 5 * 60

    static func retained(
        _ records: [UUID: Date],
        now: Date = .now
    ) -> [UUID: Date] {
        records.filter { _, markedAt in
            let age = now.timeIntervalSince(markedAt)
            return age >= -allowableFutureClockSkew && age <= retention
        }
    }
}

/// User-scoped durable intent. A weak-signal "End Meetup" must not be undone
/// by cold-launch recovery merely because the server update could not leave the
/// lift shed. Records are tiny and expire defensively after seven days.
@MainActor private struct PendingMeetTerminationStore {
    private let defaults: UserDefaults
    private let keyPrefix = "powdermeet.pending-meet-terminations.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func pendingIDs(for userID: UUID, now: Date = .now) -> Set<UUID> {
        let records = load(for: userID)
        let retained = PendingMeetTerminationPolicy.retained(records, now: now)
        if retained.count != records.count { save(retained, for: userID) }
        return Set(retained.keys)
    }

    func mark(_ requestID: UUID, for userID: UUID, now: Date = .now) {
        var records = PendingMeetTerminationPolicy.retained(load(for: userID), now: now)
        records[requestID] = now
        save(records, for: userID)
    }

    func remove(_ requestID: UUID, for userID: UUID) {
        var records = load(for: userID)
        records.removeValue(forKey: requestID)
        save(records, for: userID)
    }

    private func key(for userID: UUID) -> String {
        "\(keyPrefix).\(userID.uuidString.lowercased())"
    }

    private func load(for userID: UUID) -> [UUID: Date] {
        guard let data = defaults.data(forKey: key(for: userID)),
              let wire = try? JSONDecoder().decode([String: TimeInterval].self, from: data)
        else { return [:] }
        return wire.reduce(into: [:]) { result, item in
            guard let id = UUID(uuidString: item.key), item.value.isFinite else { return }
            result[id] = Date(timeIntervalSince1970: item.value)
        }
    }

    private func save(_ records: [UUID: Date], for userID: UUID) {
        let key = key(for: userID)
        guard !records.isEmpty else {
            defaults.removeObject(forKey: key)
            return
        }
        let wire = Dictionary(uniqueKeysWithValues: records.map {
            ($0.key.uuidString.lowercased(), $0.value.timeIntervalSince1970)
        })
        if let data = try? JSONEncoder().encode(wire) {
            defaults.set(data, forKey: key)
        }
    }
}

// MARK: - Service

@MainActor @Observable
final class MeetRequestService {
    private let supabase: SupabaseManager
    private let registry: ChannelRegistry
    private let terminationStore = PendingMeetTerminationStore()
    /// Per-user channel name `meets:{userId}`. NOT shared with `FriendService`
    /// — Supabase requires all `postgresChange()` filters to register BEFORE
    /// the first `subscribeWithError()`, and splitting the two services onto
    /// separate channels avoids a race on that ordering.
    private(set) var subscriptionState: RealtimeSubscriptionState = .stopped
    /// Invalidates suspended connect attempts when stop/reconnect wins a race.
    private var subscriptionGeneration: UInt64 = 0
    private var pollTask: Task<Void, Never>?
    private var insertTask: Task<Void, Never>?
    private var updateTask: Task<Void, Never>?
    private var receiverUpdateTask: Task<Void, Never>?
    /// Accepted request currently driving navigation. Polling keeps watching
    /// it even after it leaves the pending collections, so a dropped Realtime
    /// socket cannot hide partner cancellation or freeze the partner ETA.
    private var trackedActiveRequestId: UUID?
    var incomingRequests: [MeetRequest] = []
    var sentRequests: [MeetRequest] = []

    /// Single typed event stream for request lifecycle changes. The service
    /// owns transport/de-duplication; the coordinator owns UI/session effects.
    var onEvent: ((MeetRequestServiceEvent) -> Void)?

    init(supabase: SupabaseManager? = nil, registry: ChannelRegistry? = nil) {
        self.supabase = supabase ?? .shared
        self.registry = registry ?? ChannelRegistry.shared
    }

    func trackActiveRequest(_ requestId: UUID?) {
        trackedActiveRequestId = requestId
    }

    // MARK: - Send Meet Request

    func sendRequest(
        to receiverId: UUID,
        resortId: String,
        meetingNodeId: String,
        meetingNodeElevation: Double,
        meetingNodeDisplayName: String? = nil,
        senderPositionNodeId: String? = nil,
        receiverPositionNodeId: String? = nil,
        senderEtaSeconds: Double? = nil,
        receiverEtaSeconds: Double? = nil,
        senderPathEdgeIds: [String]? = nil,
        receiverPathEdgeIds: [String]? = nil,
        graphSnapshotDate: String? = nil,
        manifestVersion: Int? = nil,
        datasetVersion: String? = nil
    ) async throws -> SendResult {
        guard let senderId = supabase.currentSession?.user.id else {
            // Previously this silently `return`ed and the caller thought the
            // request was sent. Throw so the UI can surface "not signed in."
            throw NSError(
                domain: "MeetRequestService",
                code: 401,
                userInfo: [NSLocalizedDescriptionKey: "Not signed in — cannot send meet request."]
            )
        }

        // ── Conflict resolution: if the other user already sent ME a pending request,
        // auto-accept theirs instead of creating a duplicate ──
        if let existingFromThem = incomingRequests.first(where: {
            $0.senderId == receiverId && $0.status == .pending
        }) {
            print("[MeetRequestService] Conflict: \(receiverId) already sent a pending request — auto-accepting theirs")
            try await acceptRequest(existingFromThem.id)
            // Return the request we auto-accepted so the caller can activate
            // the active-meetup session on OUR side. Previously this was a
            // bare `return`, so the sender (the original pending-request
            // sender) got the typed `.accepted` event via realtime, but WE — the
            // user who just tapped POWDERMEET and auto-accepted — stayed in
            // the "just sent a request" state and never entered the active
            // meetup view.
            return .autoAcceptedIncoming(existingFromThem)
        }

        // ── Also cancel any of MY previous pending requests to this user ──
        for existing in sentRequests where existing.receiverId == receiverId && existing.status == .pending {
            try? await cancelRequest(existing.id)
        }

        // Expires in 30 minutes
        let expiry = Date.now.addingTimeInterval(30 * 60)

        let payload = NewMeetRequest(
            senderId: senderId,
            receiverId: receiverId,
            resortId: resortId,
            meetingNodeId: meetingNodeId,
            meetingNodeElevation: meetingNodeElevation,
            meetingNodeDisplayName: meetingNodeDisplayName,
            senderPositionNodeId: senderPositionNodeId,
            receiverPositionNodeId: receiverPositionNodeId,
            senderEtaSeconds: senderEtaSeconds,
            receiverEtaSeconds: receiverEtaSeconds,
            senderPathEdgeIds: senderPathEdgeIds,
            receiverPathEdgeIds: receiverPathEdgeIds,
            status: .pending,
            expiresAt: ISO8601Parser.string(from: expiry),
            graphSnapshotDate: graphSnapshotDate,
            manifestVersion: manifestVersion,
            datasetVersion: datasetVersion
        )

        // Hard 8s ceiling on the insert. The Supabase SDK's default
        // network timeout is ~30s; on a chairlift with marginal LTE that
        // means the user taps SEND, the button disables, and they sit
        // staring at it for half a minute with no signal. Throwing here
        // lets the UI surface "couldn't send — retry" within an
        // actionable window. On success this overhead is invisible.
        let request: MeetRequest = try await withTimeout(seconds: 8, operation: {
            try await self.supabase.client.from("meet_requests")
                .insert(payload)
                .select()
                .single()
                .execute()
                .value
        })

        sentRequests.append(request)
        print("[MeetRequestService] Sent meet request \(request.id) to \(receiverId)")
        // Reset to fast polling for immediate response detection
        startPolling()
        return .sent(request)
    }

    /// Outcome of `sendRequest`. The caller needs to know whether the normal
    /// "we sent it, wait for the other user" path was taken, or whether we
    /// short-circuited by auto-accepting an incoming request — in the latter
    /// case the caller should activate its own active-meetup session right
    /// now rather than waiting on a realtime ack.
    enum SendResult {
        case sent(MeetRequest)
        case autoAcceptedIncoming(MeetRequest)
    }

    // MARK: - Respond to Request

    func acceptRequest(_ requestId: UUID) async throws {
        try await respondToIncomingRequest(requestId, transition: .accept)
    }

    func declineRequest(_ requestId: UUID) async throws {
        try await respondToIncomingRequest(requestId, transition: .decline)
    }

    private func respondToIncomingRequest(_ requestId: UUID,
                                          transition: MeetRequestTransition) async throws {
        guard let userID = supabase.currentSession?.user.id,
              let current = incomingRequests.first(where: { $0.id == requestId }),
              current.receiverId == userID,
              let next = MeetRequestStateMachine.next(from: current.status, on: transition),
              current.expiresAt.map({ $0 > Date.now }) != false else {
            throw SocialRequestWriteError.unavailable
        }
        let generation = supabase.sessionGeneration
        incomingRequests.removeAll { $0.id == requestId }
        do {
            try await SocialRequestWriter(client: supabase.client).respondToMeet(
                id: requestId, receiverID: userID, status: next)
            guard supabase.sessionGeneration == generation else {
                throw SocialRequestWriteError.sessionChanged
            }
        } catch {
            // Restore only this card; do not erase requests that arrived while
            // the write was suspended, or write into a different user's session.
            if supabase.sessionGeneration == generation,
               !incomingRequests.contains(where: { $0.id == requestId }) {
                incomingRequests.append(current)
            }
            throw error
        }
    }

    /// Cancel an active meetup (sets status to "expired" — matches the `AGENTS.md` schema:
    /// pending / accepted / declined / expired; avoids a non-schema "cancelled" value).
    /// Works for both sender and receiver — the other user picks it up
    /// via realtime subscription or polling.
    func cancelRequest(_ requestId: UUID) async throws {
        let current = sentRequests.first(where: { $0.id == requestId })?.status ?? .accepted
        guard let next = MeetRequestStateMachine.next(from: current, on: .expire) else {
            return
        }
        try await supabase.client.from("meet_requests")
            .update(["status": next.rawValue])
            .eq("id", value: requestId.uuidString)
            .execute()

        if let idx = sentRequests.firstIndex(where: { $0.id == requestId }) {
            sentRequests.remove(at: idx)
        }
        if let userID = supabase.currentSession?.user.id {
            terminationStore.remove(requestId, for: userID)
        }
    }

    /// Record end intent before attempting the network write. This method is
    /// intentionally synchronous from the caller's perspective so UI teardown
    /// can never race ahead of durable intent persistence.
    func endRequestEventually(_ requestId: UUID) {
        guard let userID = supabase.currentSession?.user.id else {
            AppLog.meet.error("cannot persist meet termination without a signed-in user")
            return
        }
        terminationStore.mark(requestId, for: userID)
        Task { [weak self] in await self?.flushPendingTerminations() }
    }

    /// Retry every durable end intent. Successful updates remove their
    /// tombstones; failures remain queued for reconnect or the next launch.
    func flushPendingTerminations() async {
        guard let userID = supabase.currentSession?.user.id else { return }
        let ids = terminationStore.pendingIDs(for: userID)
        guard !ids.isEmpty else { return }
        for requestID in ids.sorted(by: { $0.uuidString < $1.uuidString }) {
            do {
                try await supabase.client.from("meet_requests")
                    .update(["status": MeetRequestStatus.expired.rawValue])
                    .eq("id", value: requestID.uuidString)
                    .execute()
                terminationStore.remove(requestID, for: userID)
            } catch {
                AppLog.meet.info(
                    "meet termination remains queued for \(requestID): \(error.localizedDescription)"
                )
            }
        }
    }

    // MARK: - Live ETA Updates (Phase 8.5)

    /// Broadcast an updated ETA to the partner. The blended estimator in the
    /// nav layer decides when to call this (hysteresis: >15s delta AND >5s
    /// rate limit) so we don't spam the realtime channel.
    /// Silently swallows network errors — ETA updates are best-effort.
    func updateETA(
        requestId: UUID,
        newTimeA: Double?,
        newTimeB: Double?
    ) async {
        _ = await updateETAReportingSuccess(
            requestId: requestId,
            newTimeA: newTimeA,
            newTimeB: newTimeB
        )
    }

    /// Same as `updateETA`, but returns `true` only when the server actually
    /// accepted the update. Callers (notably `ContentView`'s ETA broadcast
    /// loop) use this to decide whether to advance `BlendedETAEstimator`'s
    /// rate-limit baseline — failing the baseline advance on network error
    /// lets the next GPS fix retry immediately instead of being silenced
    /// for the 5s cooldown.
    @discardableResult
    func updateETAReportingSuccess(
        requestId: UUID,
        newTimeA: Double?,
        newTimeB: Double?
    ) async -> Bool {
        var update: [String: AnyJSON] = [:]
        if let a = newTimeA { update["sender_eta_seconds"] = .double(a) }
        if let b = newTimeB { update["receiver_eta_seconds"] = .double(b) }
        guard !update.isEmpty else { return false }
        do {
            try await supabase.client.from("meet_requests")
                .update(update)
                .eq("id", value: requestId.uuidString)
                .execute()
            return true
        } catch {
            print("[MeetRequestService] updateETA failed: \(error.localizedDescription)")
            return false
        }
    }

    // MARK: - Load Pending Requests

    func loadIncoming() async {
        guard let userId = supabase.currentSession?.user.id else { return }
        do {
            let requests: [MeetRequest] = try await supabase.client.from("meet_requests")
                .select()
                .eq("receiver_id", value: userId.uuidString)
                .eq("status", value: MeetRequestStatus.pending.rawValue)
                .order("created_at", ascending: false)
                .execute()
                .value
            // Filter expired
            incomingRequests = requests.filter { req in
                guard let exp = req.expiresAt else { return true }
                return exp > Date.now
            }
        } catch {
            print("[MeetRequestService] loadIncoming error: \(error)")
        }
    }

    func loadSent() async {
        guard let userId = supabase.currentSession?.user.id else { return }
        do {
            let requests: [MeetRequest] = try await supabase.client.from("meet_requests")
                .select()
                .eq("sender_id", value: userId.uuidString)
                .eq("status", value: MeetRequestStatus.pending.rawValue)
                .order("created_at", ascending: false)
                .execute()
                .value
            sentRequests = requests.filter { req in
                guard let exp = req.expiresAt else { return true }
                return exp > Date.now
            }
        } catch {
            print("[MeetRequestService] loadSent error: \(error)")
        }
    }

    /// Returns the newest recent accepted request involving the signed-in user.
    /// Pending lists intentionally exclude accepted rows, so without this query
    /// a process restart erased an otherwise-valid active meetup from the UI.
    /// Server status remains authoritative; errors simply disable recovery.
    func loadRecoverableAccepted(now: Date = .now) async -> MeetRequest? {
        guard let userId = supabase.currentSession?.user.id else { return nil }
        do {
            let requests: [MeetRequest] = try await supabase.client
                .from("meet_requests")
                .select()
                .eq("status", value: MeetRequestStatus.accepted.rawValue)
                .or("sender_id.eq.\(userId.uuidString),receiver_id.eq.\(userId.uuidString)")
                .order("created_at", ascending: false)
                .limit(8)
                .execute()
                .value
            return ActiveMeetRecoveryPolicy.newestRecoverable(
                from: requests,
                currentUserID: userId,
                now: now,
                excludingRequestIDs: terminationStore.pendingIDs(
                    for: userId,
                    now: now
                )
            )
        } catch {
            AppLog.meet.info("accepted-meet recovery unavailable: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Realtime Subscription

    func startListening(forceReconnect: Bool = false) async {
        guard let userId = supabase.currentSession?.user.id else { return }
        let name = "meets:\(userId.uuidString)"

        // Guard against concurrent calls (e.g., rapid tab switches).
        if subscriptionState.isConnecting {
            if !forceReconnect {
                print("[MeetRequestService] already connecting, skipping")
                return
            }
            // forceReconnect is the session-recovery path — the caller is
            // explicitly asking us to rebuild the channel. Waiting here
            // for an in-flight connect, then proceeding, is strictly safer
            // than the prior silent-skip (which left meet requests going
            // to the stale socket after an auth refresh).
            print("[MeetRequestService] forceReconnect awaiting in-flight connect")
            var guardTicks = 0
            while subscriptionState.isConnecting, guardTicks < 40 {
                try? await Task.sleep(for: .milliseconds(100))
                guardTicks += 1
            }
        }
        guard subscriptionState.canBegin(
            channelName: name,
            forceReconnect: forceReconnect
        ) else {
            print("[MeetRequestService] realtime start ignored in state \(String(describing: subscriptionState))")
            return
        }

        subscriptionGeneration &+= 1
        let generation = subscriptionGeneration

        // Tear down stale listener tasks + release the shared channel ref
        // before re-acquiring (forceReconnect path).
        let old = subscriptionState.channelName
        subscriptionState = .stopping(channelName: old)
        insertTask?.cancel(); insertTask = nil
        updateTask?.cancel(); updateTask = nil
        receiverUpdateTask?.cancel(); receiverUpdateTask = nil
        if let old {
            await registry.release(name: old)
        }
        guard generation == subscriptionGeneration else { return }

        // Own per-user channel for meet_requests. Cannot share with FriendService
        // because Supabase requires postgresChange() filters before first
        // subscribeWithError() — splitting eliminates that race.
        subscriptionState = .connecting(channelName: name)
        let channel = await registry.prepare(name: name)
        guard generation == subscriptionGeneration,
              subscriptionState == .connecting(channelName: name) else {
            await registry.release(name: name)
            return
        }

        let insertions = channel.postgresChange(
            InsertAction.self,
            table: "meet_requests",
            filter: .eq("receiver_id", value: userId.uuidString)
        )
        let updates = channel.postgresChange(
            UpdateAction.self,
            table: "meet_requests",
            filter: .eq("sender_id", value: userId.uuidString)
        )
        // Listen for cancellations/updates on requests where we're the receiver
        let receiverUpdates = channel.postgresChange(
            UpdateAction.self,
            table: "meet_requests",
            filter: .eq("receiver_id", value: userId.uuidString)
        )

        do {
            try await registry.subscribe(name: name)
            print("[MeetRequestService] realtime subscribed (shared user channel)")
        } catch {
            print("[MeetRequestService] subscribe failed: \(error)")
            await registry.release(name: name)
            if generation == subscriptionGeneration {
                subscriptionState = .stopped
            }
            return
        }
        guard generation == subscriptionGeneration,
              subscriptionState == .connecting(channelName: name) else {
            await registry.release(name: name)
            return
        }
        subscriptionState = .listening(channelName: name)

        // Start listener tasks AFTER successful subscribe.
        insertTask = Task {
            for await insert in insertions {
                do {
                    let request = try insert.decodeRecord(as: MeetRequest.self, decoder: .supabaseDecoder)
                    let expired = request.expiresAt.map { $0 <= Date.now } ?? false
                    if request.status == .pending && !expired {
                        await MainActor.run {
                            guard !self.incomingRequests.contains(where: { $0.id == request.id }) else { return }
                            self.incomingRequests.append(request)
                            self.onEvent?(.received(request))
                        }
                        // Notification delivery is handled by
                        // `notify_meet_request_insert` trigger → APNs.
                    }
                } catch {
                    print("[MeetRequestService] realtime insert decode failed: \(error) — refreshing incoming from REST")
                    await self.loadIncoming()
                }
            }
        }

        updateTask = Task {
            for await update in updates {
                do {
                    let request = try update.decodeRecord(as: MeetRequest.self, decoder: .supabaseDecoder)
                    await MainActor.run {
                        let wasTracked = self.sentRequests.contains(where: { $0.id == request.id })
                        if let idx = self.sentRequests.firstIndex(where: { $0.id == request.id }) {
                            self.sentRequests.remove(at: idx)
                        }
                        if request.status == .accepted {
                            if wasTracked {
                                self.onEvent?(.accepted(request))
                                // Sender-side "PowderMeet started" notification
                                // is delivered via `notify_meet_accepted`
                                // trigger → APNs.
                            } else {
                                // Once activation removed the request from the
                                // pending collection, later accepted-row updates
                                // are live ETA broadcasts from the partner.
                                self.onEvent?(.etaUpdated(request))
                            }
                        }
                        if request.status == .declined {
                            self.onEvent?(.declined(request))
                        } else if request.status == .expired {
                            self.onEvent?(.expired(request))
                        }
                    }
                } catch {
                    print("[MeetRequestService] realtime update (sender) decode failed: \(error) — refreshing from REST")
                    async let s: () = self.loadSent()
                    async let i: () = self.loadIncoming()
                    _ = await (s, i)
                }
            }
        }

        // Listen for updates on requests where we're the receiver
        // (e.g., sender cancels the meetup after it was accepted)
        receiverUpdateTask = Task {
            for await update in receiverUpdates {
                do {
                    let request = try update.decodeRecord(as: MeetRequest.self, decoder: .supabaseDecoder)
                    await MainActor.run {
                        if request.status == .expired {
                            // Also drop any matching row from `incomingRequests`
                            // so the card disappears immediately — otherwise
                            // the card lingers until the next REST refresh.
                            self.incomingRequests.removeAll { $0.id == request.id }
                            self.onEvent?(.expired(request))
                        } else if request.status == .accepted {
                            self.onEvent?(.etaUpdated(request))
                        }
                    }
                } catch {
                    print("[MeetRequestService] realtime update (receiver) decode failed: \(error) — refreshing from REST")
                    async let i: () = self.loadIncoming()
                    async let s: () = self.loadSent()
                    _ = await (i, s)
                }
            }
        }
    }

    // MARK: - Polling Fallback

    /// Start polling for sent request status changes (fallback when realtime is unreliable).
    /// Adaptive backoff: 2s for first 30s → 5s for next 2min → 15s after.
    /// Resets to fast polling when a new request is sent.
    func startPolling() {
        pollTask?.cancel()
        pollTask = Task { @MainActor in
            var sentPollPhase = 0
            var isFirstIteration = true
            while !Task.isCancelled {
                // On first iteration, load immediately — don't sleep first.
                if isFirstIteration {
                    isFirstIteration = false
                } else {
                    // Drop locally-expired from the polling set so requests past
                    // their TTL don't keep the fast-poll window alive (server may
                    // not mark them "expired" for a while after the client deadline).
                    let pendingSent = self.sentRequests.filter { req in
                        guard req.status == .pending else { return false }
                        guard let exp = req.expiresAt else { return true }
                        return exp > Date.now
                    }

                    // Receivers need incoming refresh even with no pending sent; use a modest interval.
                    let sleepSeconds: Double
                    if pendingSent.isEmpty {
                        sleepSeconds = 10
                        sentPollPhase = 0
                    } else {
                        if sentPollPhase < 15 {
                            sleepSeconds = 2
                        } else if sentPollPhase < 39 {
                            sleepSeconds = 5
                        } else {
                            sleepSeconds = 15
                        }
                        sentPollPhase += 1
                    }

                    try? await Task.sleep(for: .seconds(sleepSeconds))
                    guard !Task.isCancelled else { break }
                }

                await self.loadIncoming()
                await self.pollActiveRequestIfNeeded()

                let stillPending = self.sentRequests.filter { req in
                    guard req.status == .pending else { return false }
                    guard let exp = req.expiresAt else { return true }
                    return exp > Date.now
                }
                guard !stillPending.isEmpty,
                      let userId = self.supabase.currentSession?.user.id else { continue }

                do {
                    let fresh: [MeetRequest] = try await self.supabase.client.from("meet_requests")
                        .select()
                        .eq("sender_id", value: userId.uuidString)
                        .in("id", values: stillPending.map { $0.id.uuidString })
                        .execute()
                        .value

                    for request in fresh {
                        if request.status == .accepted {
                            if let idx = self.sentRequests.firstIndex(where: { $0.id == request.id }) {
                                self.sentRequests.remove(at: idx)
                                print("[MeetRequestService] poll: request \(request.id) accepted!")
                                self.onEvent?(.accepted(request))
                            }
                        } else if request.status == .declined {
                            if let idx = self.sentRequests.firstIndex(where: { $0.id == request.id }) {
                                self.sentRequests.remove(at: idx)
                                print("[MeetRequestService] poll: request \(request.id) declined")
                                self.onEvent?(.declined(request))
                            }
                        } else if request.status == .expired {
                            if let idx = self.sentRequests.firstIndex(where: { $0.id == request.id }) {
                                self.sentRequests.remove(at: idx)
                                print("[MeetRequestService] poll: request \(request.id) expired (TTL or cancelled)")
                                self.onEvent?(.expired(request))
                            }
                        }
                    }
                } catch {
                    print("[MeetRequestService] poll error: \(error)")
                }
            }
        }
    }

    private func pollActiveRequestIfNeeded(now: Date = .now) async {
        guard let requestId = trackedActiveRequestId else { return }
        do {
            let request: MeetRequest = try await supabase.client.from("meet_requests")
                .select()
                .eq("id", value: requestId.uuidString)
                .single()
                .execute()
                .value
            guard trackedActiveRequestId == requestId else { return }
            switch ActiveMeetPollClassifier.action(
                status: request.status,
                expiresAt: request.expiresAt,
                now: now
            ) {
            case .updateETA:
                onEvent?(.etaUpdated(request))
            case .endMeet:
                trackedActiveRequestId = nil
                onEvent?(.expired(request))
            case .ignore:
                break
            }
        } catch {
            print("[MeetRequestService] active meet poll error: \(error)")
        }
    }

    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    func stopListening() async {
        subscriptionGeneration &+= 1
        let name = subscriptionState.channelName
        subscriptionState = .stopping(channelName: name)
        pollTask?.cancel(); pollTask = nil
        insertTask?.cancel(); insertTask = nil
        updateTask?.cancel(); updateTask = nil
        receiverUpdateTask?.cancel(); receiverUpdateTask = nil
        if let name {
            await registry.release(name: name)
        }
        subscriptionState = .stopped
    }

    /// Clear all in-memory state. Call on sign-out so the next user doesn't
    /// inherit stale requests in memory.
    func reset() async {
        await stopListening()
        trackedActiveRequestId = nil
        incomingRequests.removeAll()
        sentRequests.removeAll()
    }

    /// Best-effort sender name lookup for notification copy. Tries the
    /// `profiles` table directly; returns a generic fallback on miss.
    private static func resolveSenderName(for userId: UUID, supabase: SupabaseManager) async -> String {
        nonisolated struct NameRow: Decodable, Sendable { let display_name: String }
        do {
            let row: NameRow = try await supabase.client.from("profiles")
                .select("display_name")
                .eq("id", value: userId.uuidString)
                .single()
                .execute()
                .value
            let trimmed = row.display_name.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "A FRIEND" : trimmed
        } catch {
            return "A FRIEND"
        }
    }
}

// MARK: - Typed errors

/// Surfaces send-side outcomes the UI needs to distinguish so it can
/// render an actionable retry banner instead of a generic "something
/// failed" alert. Cast `error as? MeetRequestSendError` at the call
/// site; any other error means an unexpected SDK failure and bubbles
/// up to the generic handler.
enum MeetRequestSendError: LocalizedError {
    case timeout

    var errorDescription: String? {
        switch self {
        case .timeout:
            return "Couldn't send — your connection looks slow or unreachable. Tap retry."
        }
    }
}

// MARK: - Timeout helper

/// Race an async operation against a deadline. Throws
/// `MeetRequestSendError.timeout` when the deadline expires first;
/// otherwise returns the operation's value (or rethrows its error).
/// Cancels the loser when the winner returns.
///
/// `@MainActor` so the operation closure inherits MainActor isolation
/// — the only callers are `MeetRequestService` methods (which are
/// MainActor-isolated themselves) and Supabase Codable conformance
/// for the request payload is also MainActor-isolated. Without this
/// annotation Swift 6 strict concurrency rejects the conformance
/// being used in the `@Sendable` closure body.
@MainActor
private func withTimeout<T: Sendable>(
    seconds: TimeInterval,
    operation: @MainActor @escaping () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { @MainActor in try await operation() }
        group.addTask {
            try await Task.sleep(for: .seconds(seconds))
            throw MeetRequestSendError.timeout
        }
        let result = try await group.next()!
        group.cancelAll()
        return result
    }
}
