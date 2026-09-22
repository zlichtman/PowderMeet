//
//  FriendService+Contacts.swift
//  PowderMeet
//
//  Extension of FriendService — contact-based friend suggestions.
//  Split out of FriendService.swift (behavior-preserving). Methods inherit
//  @MainActor from the class; stored state stays in the core file.
//

import Foundation
import Supabase

extension FriendService {
    // MARK: - Contact Suggestions

    /// Fetches contact emails and phone numbers, then calls Supabase RPCs
    /// to find matching profiles. Filters out existing friends, pending requests,
    /// and dismissed entries.
    func loadContactSuggestions() async {
        guard !isLoadingContactSuggestions else { return }
        isLoadingContactSuggestions = true
        defer { isLoadingContactSuggestions = false }

        let (emails, phones) = await ContactsService.shared.fetchContactEmailsAndPhones()
        guard let userId = supabase.currentSession?.user.id else { return }
        guard !emails.isEmpty || !phones.isEmpty else { return }

        var allMatches: [UUID: UserProfile] = [:]

        // Match by email
        if !emails.isEmpty {
            do {
                let matches: [UserProfile] = try await supabase.client
                    .rpc("find_users_by_emails", params: ["emails": emails])
                    .execute()
                    .value
                for m in matches { allMatches[m.id] = m }
            } catch {
                print("[FriendService] email suggestions error: \(error)")
            }
        }

        // Match by phone number
        if !phones.isEmpty {
            do {
                let matches: [UserProfile] = try await supabase.client
                    .rpc("find_users_by_phones", params: ["phones": phones])
                    .execute()
                    .value
                for m in matches { allMatches[m.id] = m }
            } catch {
                print("[FriendService] phone suggestions error: \(error)")
                // Silently fail — RPC may not be set up yet
            }
        }

        let friendIds  = Set(friends.map(\.id))
        let pendingIds = Set(pendingSent.map(\.addresseeId) + pendingReceived.map(\.requesterId))

        contactSuggestions = Array(allMatches.values).filter {
            $0.id != userId
                && !friendIds.contains($0.id)
                && !pendingIds.contains($0.id)
                && !dismissedSuggestionIds.contains($0.id)
        }
    }

    /// Hides a suggestion for the rest of the session without sending a request.
    func dismissSuggestion(_ id: UUID) {
        dismissedSuggestionIds.insert(id)
        contactSuggestions.removeAll { $0.id == id }
    }

    /// Prunes `contactSuggestions` so nobody already in friends or pending
    /// appears in the SUGGESTED section. Called from every path that mutates
    /// the friendship graph — `loadContactSuggestions` runs a filter once at
    /// fetch time, but accept / decline / remove / cancel all happen later
    /// and would otherwise leave stale entries in view.
    func refilterSuggestions() {
        guard !contactSuggestions.isEmpty else { return }
        let friendIds = Set(friends.map(\.id))
        let pendingIds = Set(pendingSent.map(\.addresseeId) + pendingReceived.map(\.requesterId))
        contactSuggestions.removeAll {
            friendIds.contains($0.id) || pendingIds.contains($0.id)
        }
    }
}
