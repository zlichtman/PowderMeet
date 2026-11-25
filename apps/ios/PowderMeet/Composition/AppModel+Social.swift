import AppCore
import CoreGraphics
import Foundation
import MapScene
import MapboxAdapter
import MeetSolver
import MountainCore
import Observation
import PMLogging
import PowderMeetAPI
import UIKit

/// Contact discovery: people whose email address is in this phone's contacts.
/// The matches and the time of the last lookup are kept per account so the
/// suggestions survive a relaunch; the contacts themselves are never stored.
nonisolated struct DiscoveryState: Sendable, Hashable {
    /// The account these matches belong to.
    var owner: UUID?
    var matches: [UserMatch] = []
    var lastRun: Date?
    var isSearching = false
    /// The address book was too large to check in one go; part of it was skipped.
    var wasCutShort = false
    var access = ContactHashes.Access.notDetermined
    var failure: PowderMeetError?

    var hasSearched: Bool { lastRun != nil }
}

/// What is kept between launches: server matches only, never contacts.
private nonisolated struct StoredContactMatches: Codable {
    var lastRun: Date
    var matches: [UserMatch]
    var wasCutShort: Bool
}

/// The profile photo while it is prepared and uploaded.
nonisolated struct PhotoState: Sendable, Hashable {
    var isSaving = false
}

/// Friends → search by name: the query as typed, and the people the last
/// answered query found. Results are for `answered`, which may lag `query`
/// while the user types.
nonisolated struct PeopleSearchState: Sendable, Hashable {
    var query = ""
    var answered: String?
    var results: [UserSearchResult] = []
    var isSearching = false
    var failure: PowderMeetError?

    /// The query is long enough for the server to look it up.
    var isActive: Bool { UserSearch.query(query) != nil }
}

/// Who is being reported, from where, and how far the report has got.
nonisolated struct ReportTarget: Sendable, Hashable, Identifiable {
    var userID: UUID
    var displayName: String
    var avatarURL: String?
    var context: ReportContext

    var id: UUID { userID }
}

nonisolated struct ReportState: Sendable, Hashable {
    var isSending = false
    var sent = false
    var failure: PowderMeetError?
}

extension AppModel {
    func person(_ user: UUID) -> SocialSnapshot.Person? {
        social.friends.first { $0.userID == user }
            ?? social.pendingIn.first { $0.userID == user }
            ?? social.pendingOut.first { $0.userID == user }
    }

    func name(of user: UUID) -> String {
        // Developer testing's dev people are in no snapshot (`DeveloperSandbox`).
        if let dev = Self.devPersonName(user) { return dev }
        return person(user)?.displayName ?? "Friend"
    }

    func shareNames() {
        var names: [UUID: String] = [:]
        for friend in social.friends { names[friend.userID] = friend.displayName }
        resort?.names = names
    }

    // MARK: Friend intents

    func requestFriend(_ user: UUID) { session.send(.friend(.request(user))) }

    /// Profile → Friends, from anywhere: the one place friends are managed.
    func openFriends() {
        openProfilePage(.friends)
    }

    func respondToFriendRequest(_ friendshipID: UUID, accept: Bool) {
        session.send(.friend(.respond(friendshipID: friendshipID, accept: accept)))
    }

    func removeFriend(_ user: UUID) { session.send(.friend(.remove(user))) }
    func block(_ user: UUID) { session.send(.friend(.block(user))) }
    func unblock(_ user: UUID) { session.send(.friend(.unblock(user))) }

    /// Re-reads friends, requests and blocks (a friend card opened).
    func refreshFriends() { session.send(.socialRefreshRequested) }

    func isBlocked(_ user: UUID) -> Bool { social.blocks.contains { $0.userID == user } }

    // MARK: Profile photo

    /// Whose photo the photo button changes: the profile once onboarding is
    /// done, and during it the profile saved so far.
    var photoOwner: Profile? {
        profile ?? (state == .needsOnboarding ? account.onboardingProfile : nil)
    }

    /// Crops, resizes to 512 px and re-encodes the photo off the main actor
    /// (dropping every bit of its metadata), then uploads it. Failures arrive
    /// as a toast; the photo on screen stays the old one until the new one is saved.
    func saveProfilePhoto(from data: Data, crop: CGRect) {
        guard !photo.isSaving else { return }
        photo.isSaving = true
        run("profile-photo") { [weak self, session] in
            let jpeg = await Task.detached(priority: .userInitiated) {
                AvatarImageProcessor.avatarJPEG(from: data, crop: crop)
            }.value
            guard let jpeg else {
                self?.photo.isSaving = false
                self?.photoFailed(.social(.photoUnreadable))
                return
            }
            do {
                let path = try await session.setAvatar(jpeg: jpeg)
                if let image = UIImage(data: jpeg) { self?.avatarImages.keep(image, for: path) }
                self?.refreshOnboardingProfile()
            } catch {
                self?.photoFailed(PowderMeetError(error))
            }
            self?.photo.isSaving = false
        }
    }

    func removeProfilePhoto() {
        guard !photo.isSaving else { return }
        photo.isSaving = true
        run("profile-photo") { [weak self, session] in
            do {
                try await session.removeAvatar()
                self?.refreshOnboardingProfile()
            } catch {
                self?.photoFailed(PowderMeetError(error))
            }
            self?.photo.isSaving = false
        }
    }

    func photoFailed(_ error: PowderMeetError) {
        let toasts = deps.toasts
        Task { await toasts.post(error) }
    }

    // MARK: Search by name

    /// The search field changed. Waits for typing to pause, then asks the
    /// server (rate-limited to 60 a minute there); a newer query cancels an
    /// older one still waiting or in flight.
    func searchPeople(_ query: String) {
        peopleSearch.query = query
        peopleSearch.failure = nil
        guard UserSearch.query(query) != nil else {
            work["people-search"]?.cancel()
            peopleSearch = PeopleSearchState(query: query)
            return
        }
        peopleSearch.isSearching = true
        run("people-search") { [weak self, session] in
            do {
                try await Task.sleep(for: .milliseconds(350))
            } catch {
                return
            }
            do {
                let results = try await session.searchUsers(query)
                guard !Task.isCancelled else { return }
                self?.peopleSearch.results = results
                self?.peopleSearch.answered = query
            } catch {
                guard !Task.isCancelled else { return }
                self?.peopleSearch.failure = PowderMeetError(error)
            }
            self?.peopleSearch.isSearching = false
        }
    }

    /// Search results as they stand now: someone blocked since drops out, and
    /// a request sent or accepted since shows as such, without asking again.
    var peopleFound: [UserSearchResult] {
        let blocked = Set(social.blocks.map(\.userID))
        let friends = Set(social.friends.map(\.userID))
        let sent = Set(social.pendingOut.map(\.userID))
        let received = Set(social.pendingIn.map(\.userID))
        return peopleSearch.results.compactMap { result in
            guard !blocked.contains(result.userID) else { return nil }
            var result = result
            if friends.contains(result.userID) {
                result.relation = .friend
            } else if sent.contains(result.userID) {
                result.relation = .requestSent
            } else if received.contains(result.userID) {
                result.relation = .requestReceived
            } else if result.relation != .none {
                // Withdrawn, declined or removed since the search.
                result.relation = .none
            }
            return result
        }
    }

    /// The friendship id of a request this user received from `user`.
    func receivedRequest(from user: UUID) -> UUID? {
        social.pendingIn.first { $0.userID == user }?.friendshipID
    }

    // MARK: Reports

    /// Files the report. The sheet then offers to block.
    func sendReport(_ target: ReportTarget, reason: ReportReason, note: String) {
        guard !report.isSending else { return }
        report = ReportState(isSending: true)
        run("report") { [weak self, session] in
            do {
                try await session.reportUser(target.userID, reason: reason, note: note, context: target.context)
                self?.report = ReportState(sent: true)
            } catch {
                self?.report = ReportState(failure: PowderMeetError(error))
            }
        }
    }

    func resetReport() {
        work["report"]?.cancel()
        report = ReportState()
    }
}

extension AppModel {
    // MARK: Contacts

    private static let contactMatchesPrefix = "contacts.emailMatches."

    private func contactMatchesKey(_ user: UUID) -> String {
        Self.contactMatchesPrefix + user.uuidString.lowercased()
    }

    /// Other people's names and photo paths do not outlive the session that
    /// was allowed to see them; the next sign-in looks them up again. Every
    /// account's entry goes, including one an earlier build left behind.
    func forgetContactMatches() {
        work["discovery"]?.cancel()
        discovery = DiscoveryState()
        let defaults = UserDefaults.standard
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(Self.contactMatchesPrefix) {
            defaults.removeObject(forKey: key)
        }
    }

    /// Loads the last lookup's matches for this account, once per sign-in.
    func restoreContactMatches(for user: UUID) {
        guard discovery.owner != user else { return }
        var restored = DiscoveryState(owner: user, access: ContactHashes.access)
        if let data = UserDefaults.standard.data(forKey: contactMatchesKey(user)) {
            do {
                let stored = try JSONDecoder().decode(StoredContactMatches.self, from: data)
                restored.matches = stored.matches
                restored.lastRun = stored.lastRun
                restored.wasCutShort = stored.wasCutShort
            } catch {
                // Written by another build: the next lookup writes it again.
                deps.log.notice(.session, "stored contact matches unreadable: \(error)")
            }
        }
        discovery = restored
    }

    /// Re-reads Contacts access, which can change in Settings at any time.
    func refreshContactsAccess() {
        discovery.access = ContactHashes.access
    }

    /// The user asked: asks for Contacts access if iOS has not yet, then
    /// matches. Contacts never leave the phone, only their addresses' hashes.
    func findFriendsFromContacts() {
        matchContacts(prompting: true)
    }

    /// Friends page opened: with access already granted, looks again at most
    /// once a day, quietly. Never asks for access.
    func refreshContactMatchesIfDue() {
        refreshContactsAccess()
        guard discovery.access == .granted else { return }
        if let last = discovery.lastRun, Date().timeIntervalSince(last) < 24 * 60 * 60 { return }
        matchContacts(prompting: false)
    }

    /// Hashes the address book's email addresses and asks `find_users` in
    /// batches of 50, at most 18 calls a minute (the server allows 20). A rate
    /// limit waits out the minute once, then stops with what was found.
    private func matchContacts(prompting: Bool) {
        // Onboarding runs before there is a profile: the signed-in account then.
        guard let me = profile?.id ?? account.identity?.userID, !discovery.isSearching else { return }
        if discovery.owner != me { restoreContactMatches(for: me) }
        discovery.isSearching = true
        if prompting { discovery.failure = nil }
        let key = contactMatchesKey(me)
        run("discovery") { [weak self, session] in
            let hashes: ContactHashes
            do {
                hashes = try await ContactHashes.load(prompting: prompting)
            } catch {
                self?.discovery.isSearching = false
                self?.refreshContactsAccess()
                if prompting, !(error is ContactHashes.Denied) {
                    self?.discovery.failure = PowderMeetError(error)
                }
                return
            }
            self?.refreshContactsAccess()

            var found: [UUID: UserMatch] = [:]
            var cutShort = hashes.isCutShort
            var stoppedEarly = false
            var failure: PowderMeetError?
            var callsThisMinute = 0
            var minuteStart = ContinuousClock.now
            batches: for batch in hashes.batches() {
                if callsThisMinute == ContactHashes.callsPerMinute {
                    do {
                        try await Task.sleep(until: minuteStart + .seconds(61))
                    } catch {
                        return
                    }
                    callsThisMinute = 0
                    minuteStart = .now
                }
                var retried = false
                while true {
                    if Task.isCancelled { return }
                    callsThisMinute += 1
                    do throws(PowderMeetError) {
                        for match in try await session.findUsers(emailHashes: batch, phoneHashes: []) {
                            found[match.id] = match
                        }
                        break
                    } catch .social(.tooManyTries) where !retried {
                        retried = true
                        do {
                            try await Task.sleep(for: .seconds(61))
                        } catch {
                            return
                        }
                        callsThisMinute = 0
                        minuteStart = .now
                    } catch .social(.tooManyTries) {
                        stoppedEarly = true
                        break batches
                    } catch {
                        failure = error
                        stoppedEarly = true
                        break batches
                    }
                }
            }
            guard let self, !Task.isCancelled else { return }

            // Nothing found because nothing could be asked: keep the last
            // matches, and say so only when the user asked.
            if let failure, found.isEmpty {
                discovery.isSearching = false
                if prompting { discovery.failure = failure }
                return
            }
            // A lookup that stopped part way keeps the earlier matches too,
            // since the addresses it did not reach may hold them.
            if stoppedEarly {
                for match in discovery.matches where found[match.id] == nil { found[match.id] = match }
            }
            let now = Date()
            let matches = found.values.sorted { $0.displayName < $1.displayName }
            discovery.matches = matches
            discovery.lastRun = now
            discovery.wasCutShort = cutShort || stoppedEarly
            discovery.failure = nil
            discovery.isSearching = false
            let stored = StoredContactMatches(lastRun: now, matches: matches, wasCutShort: cutShort || stoppedEarly)
            do {
                UserDefaults.standard.set(try JSONEncoder().encode(stored), forKey: key)
            } catch {
                // Shown now; the next lookup finds them again.
                deps.log.error(.session, "contact matches not saved: \(error)")
            }
        }
    }
}

extension AppModel {
    /// A dev person's name ("Dev 2"), or nil for anyone else. Dev 1 is the
    /// demo's friend when the demo names one (`-demoFriendName`, Debug).
    nonisolated static func devPersonName(_ user: UUID) -> String? {
        guard let person = DeveloperSandbox.devPerson(user) else { return nil }
        #if DEBUG
        if person.id == DeveloperSandbox.pretendFriendID, let name = DemoCast.friendName { return name }
        #endif
        return person.name
    }
}
