import Foundation
import Supabase

nonisolated enum SocialRequestWriteError: LocalizedError {
    case unavailable
    case sessionChanged

    var errorDescription: String? {
        switch self {
        case .unavailable: return "This request is no longer available. Refresh and try again."
        case .sessionChanged: return "Your account changed. Please try again."
        }
    }
}

/// A successful HTTP update can affect zero rows. Require the server's exact
/// updated identity before letting either phone present acceptance as success.
nonisolated struct SocialRequestWriter {
    let client: SupabaseClient
    private struct Receipt: Decodable {
        let id: UUID
        let status: String
    }

    func acceptFriendship(id: UUID, receiverID: UUID) async throws {
        let rows: [Receipt] = try await client.from("friendships")
            .update(["status": FriendshipStatus.accepted.rawValue])
            .eq("id", value: id.uuidString)
            .eq("addressee_id", value: receiverID.uuidString)
            .eq("status", value: FriendshipStatus.pending.rawValue)
            .select("id,status").execute().value
        try confirm(rows, id: id, status: FriendshipStatus.accepted.rawValue)
    }

    func respondToMeet(id: UUID, receiverID: UUID, status: MeetRequestStatus,
                       now: Date = .now) async throws {
        guard status == .accepted || status == .declined else {
            throw SocialRequestWriteError.unavailable
        }
        let rows: [Receipt] = try await client.from("meet_requests")
            .update(["status": status.rawValue])
            .eq("id", value: id.uuidString)
            .eq("receiver_id", value: receiverID.uuidString)
            .eq("status", value: MeetRequestStatus.pending.rawValue)
            .gt("expires_at", value: ISO8601Parser.string(from: now))
            .select("id,status").execute().value
        try confirm(rows, id: id, status: status.rawValue)
    }

    private func confirm(_ rows: [Receipt], id: UUID, status: String) throws {
        guard rows.count == 1, rows[0].id == id, rows[0].status == status else {
            throw SocialRequestWriteError.unavailable
        }
    }
}
