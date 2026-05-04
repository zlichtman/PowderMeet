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

struct MeetRequest: Codable, Identifiable {
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
    let status: String        // "pending", "accepted", "declined", "expired"
    let createdAt: Date?
    let expiresAt: Date?
    /// Date of the server-side graph snapshot the sender used.
    /// Receiver compares to their local snapshot — if different, re-downloads to ensure identical graphs.
    let graphSnapshotDate: String?

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
    }
}

struct NewMeetRequest: Encodable {
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
    let status: String
    let expiresAt: String     // ISO8601
    let graphSnapshotDate: String?

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
    }
}

// MARK: - Service

@MainActor @Observable
final class MeetRequestService {
    private let supabase: SupabaseManager
    private let registry: ChannelRegistry
    /// Per-user channel name `meets:{userId}`. NOT shared with `FriendService`
    /// — Supabase requires all `postgresChange()` filters to register BEFORE
    /// the first `subscribeWithError()`, and splitting the two services onto
    /// separate channels avoids a race on that ordering.
    private var sharedChannelName: String?
    private var pollTask: Task<Void, Never>?
    private var insertTask: Task<Void, Never>?
    private var updateTask: Task<Void, Never>?
    private var receiverUpdateTask: Task<Void, Never>?
    /// Guard against concurrent startListening() calls.
    private var isConnecting = false

    var incomingRequests: [MeetRequest] = []
    var sentRequests: [MeetRequest] = []

    /// Called when a sent request is accepted by the receiver.
    var onRequestAccepted: ((MeetRequest) -> Void)?
    /// Called when the other user cancels the meetup.
    var onMeetupCancelled: ((UUID) -> Void)?

    init(supabase: SupabaseManager? = nil, registry: ChannelRegistry? = nil) {
        self.supabase = supabase ?? .shared
        self.registry = registry ?? ChannelRegistry.shared
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
        graphSnapshotDate: String? = nil
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
            $0.senderId == receiverId && $0.status == "pending"
        }) {
            print("[MeetRequestService] Conflict: \(receiverId) already sent a pending request — auto-accepting theirs")
            try await acceptRequest(existingFromThem.id)
            // Return the request we auto-accepted so the caller can activate
            // the active-meetup session on OUR side. Previously this was a
            // bare `return`, so the sender (the original pending-request
            // sender) got `onRequestAccepted` via realtime, but WE — the
            // user who just tapped POWDERMEET and auto-accepted — stayed in
            // the "just sent a request" state and never entered the active
            // meetup view.
            return .autoAcceptedIncoming(existingFromThem)
        }

        // ── Also cancel any of MY previous pending requests to this user ──
        for existing in sentRequests where existing.receiverId == receiverId && existing.status == "pending" {
            try? await cancelRequest(existing.id)
        }

        // Expires in 30 minutes
        let expiry = Date.now.addingTimeInterval(30 * 60)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

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
            status: "pending",
            expiresAt: formatter.string(from: expiry),
            graphSnapshotDate: graphSnapshotDate
        )

        let request: MeetRequest = try await supabase.client.from("meet_requests")
            .insert(payload)
            .select()
            .single()
            .execute()
            .value

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
        // ── Optimistic UI: remove card IMMEDIATELY so user sees instant feedback ──
        let previous = incomingRequests
        incomingRequests.removeAll(where: { $0.id == requestId })

        // ── DB update (runs after UI already updated) ──
        do {
            try await supabase.client.from("meet_requests")
                .update(["status": "accepted"])
                .eq("id", value: requestId.uuidString)
                .execute()
        } catch {
            // Revert optimistic UI on failure so the card doesn't silently vanish.
            incomingRequests = previous
            throw error
        }
    }

    func declineRequest(_ requestId: UUID) async throws {
        let previous = incomingRequests
        incomingRequests.removeAll(where: { $0.id == requestId })

        do {
            try await supabase.client.from("meet_requests")
                .update(["status": "declined"])
                .eq("id", value: requestId.uuidString)
                .execute()
        } catch {
            incomingRequests = previous
            throw error
        }
    }

    /// Cancel an active meetup (sets status to "expired" — matches `CLAUDE.md` schema:
    /// pending / accepted / declined / expired; avoids a non-schema "cancelled" value).
    /// Works for both sender and receiver — the other user picks it up
    /// via realtime subscription or polling.
    func cancelRequest(_ requestId: UUID) async throws {
        try await supabase.client.from("meet_requests")
            .update(["status": "expired"])
            .eq("id", value: requestId.uuidString)
            .execute()

        if let idx = sentRequests.firstIndex(where: { $0.id == requestId }) {
            sentRequests.remove(at: idx)
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
                .eq("status", value: "pending")
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
                .eq("status", value: "pending")
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

    // MARK: - Realtime Subscription

    func startListening(forceReconnect: Bool = false) async {
        // Skip if already subscribed — prevents duplicate channels on tab switches.
        if !forceReconnect, sharedChannelName != nil {
            print("[MeetRequestService] already subscribed, skipping")
            return
        }

        // Guard against concurrent calls (e.g., rapid tab switches).
        if isConnecting {
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
            while isConnecting, guardTicks < 40 {
                try? await Task.sleep(for: .milliseconds(100))
                guardTicks += 1
            }
        }
        isConnecting = true
        defer { isConnecting = false }

        // Tear down stale listener tasks + release the shared channel ref
        // before re-acquiring (forceReconnect path).
        insertTask?.cancel(); insertTask = nil
        updateTask?.cancel(); updateTask = nil
        receiverUpdateTask?.cancel(); receiverUpdateTask = nil
        if let old = sharedChannelName {
            await registry.release(name: old)
            sharedChannelName = nil
        }
        guard let userId = supabase.currentSession?.user.id else { return }

        // Own per-user channel for meet_requests. Cannot share with FriendService
        // because Supabase requires postgresChange() filters before first
        // subscribeWithError() — splitting eliminates that race.
        let name = "meets:\(userId.uuidString)"
        sharedChannelName = name
        let channel = await registry.prepare(name: name)

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
            sharedChannelName = nil
            return
        }

        // Start listener tasks AFTER successful subscribe.
        insertTask = Task {
            for await insert in insertions {
                do {
                    let request = try insert.decodeRecord(as: MeetRequest.self, decoder: .supabaseDecoder)
                    let expired = request.expiresAt.map { $0 <= Date.now } ?? false
                    if request.status == "pending" && !expired {
                        await MainActor.run {
                            guard !self.incomingRequests.contains(where: { $0.id == request.id }) else { return }
                            self.incomingRequests.append(request)
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
                        if request.status == "accepted" && wasTracked {
                            self.onRequestAccepted?(request)
                            // Sender-side "PowderMeet started" notification
                            // is delivered via `notify_meet_accepted`
                            // trigger → APNs.
                        }
                        if request.status == "expired" {
                            self.onMeetupCancelled?(request.id)
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
                        if request.status == "expired" {
                            // Also drop any matching row from `incomingRequests`
                            // so the card disappears immediately — otherwise
                            // the card lingers until the next REST refresh.
                            self.incomingRequests.removeAll { $0.id == request.id }
                            self.onMeetupCancelled?(request.id)
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
                        guard req.status == "pending" else { return false }
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

                let stillPending = self.sentRequests.filter { req in
                    guard req.status == "pending" else { return false }
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
                        if request.status == "accepted" {
                            if let idx = self.sentRequests.firstIndex(where: { $0.id == request.id }) {
                                self.sentRequests.remove(at: idx)
                                print("[MeetRequestService] poll: request \(request.id) accepted!")
                                self.onRequestAccepted?(request)
                            }
                        } else if request.status == "declined" {
                            if let idx = self.sentRequests.firstIndex(where: { $0.id == request.id }) {
                                self.sentRequests.remove(at: idx)
                                print("[MeetRequestService] poll: request \(request.id) declined")
                            }
                        } else if request.status == "expired" {
                            if let idx = self.sentRequests.firstIndex(where: { $0.id == request.id }) {
                                self.sentRequests.remove(at: idx)
                                print("[MeetRequestService] poll: request \(request.id) expired (TTL or cancelled)")
                            }
                        }
                    }
                } catch {
                    print("[MeetRequestService] poll error: \(error)")
                }
            }
        }
    }

    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    func stopListening() async {
        pollTask?.cancel(); pollTask = nil
        insertTask?.cancel(); insertTask = nil
        updateTask?.cancel(); updateTask = nil
        receiverUpdateTask?.cancel(); receiverUpdateTask = nil
        if let name = sharedChannelName {
            await registry.release(name: name)
            sharedChannelName = nil
        }
    }

    /// Clear all in-memory state. Call on sign-out so the next user doesn't
    /// inherit stale requests in memory.
    func reset() async {
        await stopListening()
        incomingRequests.removeAll()
        sentRequests.removeAll()
    }

    /// Best-effort sender name lookup for notification copy. Tries the
    /// `profiles` table directly; returns a generic fallback on miss.
    private static func resolveSenderName(for userId: UUID, supabase: SupabaseManager) async -> String {
        struct NameRow: Decodable { let display_name: String }
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

