import Foundation
import MountainCore

extension FakeBackend {
    // MARK: Social RPCs

    func friendRequest(_ caller: UUID?, user: UUID) throws -> Friendship {
        let me = try uid(caller)
        guard user != me, profiles[user] != nil else { throw BackendError.invalid }
        // 0025: the blocker cannot ask the person they blocked; a request to
        // someone who blocked you is hidden from them, never refused.
        if blocks.contains(where: { $0.blocker == me && $0.blocked == user }) { throw BackendError.invalid }
        let hidden = blocks.contains { $0.blocker == user && $0.blocked == me }

        if var row = friendshipBetween(me, user) {
            // The other person already asked: accept. Otherwise this is a repeat.
            // Under a hidden block there is nothing of theirs to accept.
            if !hidden, row.status == .pending, row.addresseeID == me {
                row.status = .accepted
                row.respondedAt = now
                friendships[row.id] = row
                emit(to: row.requesterID, .friendAccepted(brief(me, friendshipID: row.id)))
            }
            return row
        }

        try rateLimit(me, "friend_request", max: 30, window: 3_600)
        let row = Friendship(
            id: UUID(), requesterID: me, addresseeID: user, status: .pending, createdAt: now
        )
        friendships[row.id] = row
        // Kept and pending to the sender; the blocker is not told.
        if !hidden { emit(to: user, .friendRequested(brief(me, friendshipID: row.id))) }
        return row
    }

    func friendRespond(_ caller: UUID?, friendshipID: UUID, accept: Bool) throws -> Friendship {
        let me = try uid(caller)
        guard var row = friendships[friendshipID], row.requesterID == me || row.addresseeID == me
        else { throw BackendError.notFound }
        // Only the person who was asked may answer.
        guard row.addresseeID == me else { throw BackendError.invalidState }
        if row.status == .accepted {
            if accept { return row }
            throw BackendError.invalidState
        }
        if accept {
            row.status = .accepted
            row.respondedAt = now
            friendships[row.id] = row
            emit(to: row.requesterID, .friendAccepted(brief(me, friendshipID: row.id)))
        } else {
            deleteFriendship(row, actor: me)
        }
        return row
    }

    func friendRemove(_ caller: UUID?, user: UUID) throws {
        let me = try uid(caller)
        guard user != me else { throw BackendError.invalid }
        if let row = friendshipBetween(me, user) { deleteFriendship(row, actor: me) }
        endMeetsBetween(me, user, reason: .partnerLeft, by: me)
    }

    func blockUser(_ caller: UUID?, user: UUID) throws {
        let me = try uid(caller)
        guard user != me, profiles[user] != nil else { throw BackendError.invalid }
        if !blocks.contains(where: { $0.blocker == me && $0.blocked == user }) {
            blocks.append((me, user, now))
        }
        if let row = friendshipBetween(me, user) { deleteFriendship(row, actor: me) }
        endMeetsBetween(me, user, reason: .partnerLeft, by: me)
    }

    func unblockUser(_ caller: UUID?, user: UUID) throws {
        let me = try uid(caller)
        // A request that waited unseen behind the block goes first, so it does
        // not surface stale; to its sender that reads as a decline.
        if blocks.contains(where: { $0.blocker == me && $0.blocked == user }),
           let row = friendshipBetween(me, user), row.status == .pending, row.addresseeID == me {
            deleteFriendship(row, actor: me)
        }
        blocks.removeAll { $0.blocker == me && $0.blocked == user }
    }

    func findUsers(_ caller: UUID?, emailHashes: [String], phoneHashes: [String]) throws -> [UserMatch] {
        let me = try uid(caller)
        guard emailHashes.count <= 50, phoneHashes.count <= 50 else { throw BackendError.invalid }
        try rateLimit(me, "find_users", max: 20, window: 60)
        return profiles.values.filter { profile in
            guard profile.id != me, !isBlockedBetween(me, profile.id),
                  let hashes = contactHashes[profile.id] else { return false }
            return hashes.email.map(emailHashes.contains) ?? false
                || hashes.phone.map(phoneHashes.contains) ?? false
        }
        .sorted { $0.id.uuidString < $1.id.uuidString }
        .map { UserMatch(id: $0.id, displayName: $0.displayName, avatarURL: $0.avatarURL) }
    }

    /// `search_users` (0019).
    func searchUsers(_ caller: UUID?, query: String) throws -> [UserSearchResult] {
        let me = try uid(caller)
        guard let query = UserSearch.query(query) else { return [] }
        try rateLimit(me, "search_users", max: 60, window: 60)
        let matches = profiles.values.compactMap { profile -> (prefix: Bool, name: String, row: UserSearchResult)? in
            let name = DisplayName.normalize(profile.displayName).lowercased()
            guard profile.id != me, !DisplayName.isPlaceholder(profile.displayName),
                  name.contains(query), !isBlockedBetween(me, profile.id) else { return nil }
            let relation: SearchRelation
            if let row = friendshipBetween(me, profile.id) {
                relation = row.status == .accepted ? .friend : row.requesterID == me ? .requestSent : .requestReceived
            } else {
                relation = .none
            }
            return (name.hasPrefix(query), profile.displayName.lowercased(), UserSearchResult(
                userID: profile.id, displayName: profile.displayName, avatarURL: profile.avatarURL,
                relation: relation
            ))
        }
        return matches
            .sorted {
                if $0.prefix != $1.prefix { return $0.prefix }
                if $0.name != $1.name { return $0.name < $1.name }
                return $0.row.userID.uuidString < $1.row.userID.uuidString
            }
            .prefix(UserSearch.limit)
            .map(\.row)
    }

    func socialSnapshot(_ caller: UUID?) throws -> SocialSnapshot {
        let me = try uid(caller)
        func person(_ user: UUID, friendship: UUID?, at: Date?) -> SocialSnapshot.Person? {
            profiles[user].map {
                SocialSnapshot.Person(
                    friendshipID: friendship, userID: user, displayName: $0.displayName,
                    avatarURL: $0.avatarURL, at: at
                )
            }
        }
        /// 0016: a friend's entry carries the card fields; nobody else's does.
        func friend(_ user: UUID, friendship: UUID, at: Date?) -> SocialSnapshot.Person? {
            guard var entry = person(user, friendship: friendship, at: at), let profile = profiles[user]
            else { return nil }
            entry.ability = profile.ability
            entry.equipment = profile.equipment
            entry.stats = LifetimeStats(readDescents(user, limit: .max))
            entry.lastSeen = presence[user].flatMap { fix in
                (fix.receivedAt ?? .distantPast) > now.addingTimeInterval(-15 * 60)
                    ? LastSeen(resortID: fix.resortID, at: fix.capturedAt) : nil
            }
            return entry
        }
        let mine = friendships.values.filter { $0.requesterID == me || $0.addresseeID == me }
        let newestFirst = { (a: SocialSnapshot.Person, b: SocialSnapshot.Person) in
            (a.at ?? .distantPast) > (b.at ?? .distantPast)
        }
        return SocialSnapshot(
            friends: mine.filter { $0.status == .accepted }.compactMap { row -> SocialSnapshot.Person? in
                let other = row.requesterID == me ? row.addresseeID : row.requesterID
                guard !isBlockedBetween(me, other) else { return nil }
                return friend(other, friendship: row.id, at: row.respondedAt)
            }.sorted { ($0.displayName, $0.userID.uuidString) < ($1.displayName, $1.userID.uuidString) },
            // A request from someone this user blocked waits unseen.
            pendingIn: mine.filter { row in
                row.status == .pending && row.addresseeID == me
                    && !blocks.contains { $0.blocker == me && $0.blocked == row.requesterID }
            }
                .compactMap { person($0.requesterID, friendship: $0.id, at: $0.createdAt) }
                .sorted(by: newestFirst),
            pendingOut: mine.filter { $0.status == .pending && $0.requesterID == me }
                .compactMap { person($0.addresseeID, friendship: $0.id, at: $0.createdAt) }
                .sorted(by: newestFirst),
            blocks: blocks.filter { $0.blocker == me }
                .compactMap { person($0.blocked, friendship: nil, at: $0.at) }
                .sorted(by: newestFirst)
        )
    }

    func profileUpdate(_ caller: UUID?, patch: ProfilePatch) throws -> Profile {
        let me = try uid(caller)
        guard var profile = profiles[me] else { throw BackendError.notFound }
        var hashes = contactHashes[me] ?? (nil, nil)

        func string(_ value: JSONValue, nullable: Bool) throws -> String? {
            switch value {
            case .string(let text): return text
            case .null where nullable: return nil
            default: throw BackendError.invalid
            }
        }
        /// A whole number in `range`, or nil for JSON null.
        func integer(_ value: JSONValue, in range: ClosedRange<Int>) throws -> Int? {
            switch value {
            case .null: return nil
            case .number(let number):
                guard let whole = Int(exactly: number), range.contains(whole) else {
                    throw BackendError.invalid
                }
                return whole
            default: throw BackendError.invalid
            }
        }
        /// The `equipment` check constraint.
        func equipment(_ value: JSONValue) throws -> ProfileEquipment {
            guard case .object(let object) = value,
                  Set(object.keys).isSubset(of: ["discipline", "type", "length_cm", "waist_mm", "ski", "skin"]),
                  case .string(let discipline)? = object["discipline"],
                  case .string(let type)? = object["type"]
            else { throw BackendError.invalid }
            func optional(_ key: String) throws -> Int? {
                guard let field = object[key] else { return nil }
                guard case .number(let number) = field, let whole = Int(exactly: number) else {
                    throw BackendError.invalid
                }
                return whole
            }
            func text(_ key: String) throws -> String? {
                guard let field = object[key] else { return nil }
                guard case .string(let text) = field else { throw BackendError.invalid }
                return text
            }
            let gear = ProfileEquipment(
                discipline: discipline, type: type, lengthCM: try optional("length_cm"),
                waistMM: try optional("waist_mm"), ski: try text("ski"), skin: try text("skin")
            )
            guard gear.isValid else { throw BackendError.invalid }
            return gear
        }
        func isHash(_ text: String) -> Bool {
            text.utf8.count == 64
                && text.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
        }

        for (key, value) in patch.values.sorted(by: { $0.key < $1.key }) {
            switch key {
            case "display_name":
                guard case .success(let name) = DisplayName.validate(try string(value, nullable: false) ?? "")
                else { throw BackendError.invalid }
                guard !isTaken(name, by: me) else { throw BackendError.nameTaken }
                profile.displayName = name
            case "avatar_url":
                let path = try string(value, nullable: true)
                if let path {
                    let prefix = me.uuidString.lowercased() + "/"
                    let file = path.dropFirst(prefix.count)
                    let allowed = file.utf8.allSatisfy {
                        (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
                            || $0 == 46 || $0 == 95 || $0 == 45
                    }
                    guard path.hasPrefix(prefix), (1...80).contains(file.count), allowed
                    else { throw BackendError.invalid }
                }
                profile.avatarURL = path
            case "ability":
                guard let ability = try string(value, nullable: false),
                      ["beginner", "intermediate", "advanced", "expert"].contains(ability)
                else { throw BackendError.invalid }
                profile.ability = ability
            case "max_difficulty":
                guard let difficulty = try string(value, nullable: false),
                      ["green", "blue", "black", "double_black"].contains(difficulty)
                else { throw BackendError.invalid }
                profile.maxDifficulty = difficulty
            case "baseline_speeds":
                guard case .object(let speeds) = value else { throw BackendError.invalid }
                profile.baselineSpeeds = try speeds.mapValues {
                    guard case .number(let speed) = $0 else { throw BackendError.invalid }
                    return speed
                }
            case "equipment":
                if case .null = value {
                    profile.equipment = nil
                } else {
                    profile.equipment = try equipment(value)
                }
            case "avoid":
                guard case .array(let items) = value else { throw BackendError.invalid }
                let choices = try items.map { item -> String in
                    guard case .string(let choice) = item, Profile.avoidChoices.contains(choice)
                    else { throw BackendError.invalid }
                    return choice
                }
                profile.avoid = Set(choices).sorted()
            case "max_pitch_deg":
                profile.maxPitchDeg = try integer(value, in: Profile.maxPitchRangeDeg)
            case "height_cm":
                profile.heightCM = try integer(value, in: Profile.heightRangeCM)
            case "weight_kg":
                profile.weightKG = try integer(value, in: Profile.weightRangeKG)
            case "email_hash":
                // The server keeps this one from the auth email (0022) and drops
                // it from the patch, so a client can never claim an address.
                break
            case "phone_hash":
                let hash = try string(value, nullable: true)
                if let hash {
                    let taken = contactHashes.contains { $0.key != me && $0.value.phone == hash }
                    guard isHash(hash), !taken else { throw BackendError.invalid }
                }
                hashes.phone = hash
            case "current_resort_id":
                let resortID = try string(value, nullable: true)
                if let resortID, resorts[resortID]?.published != true {
                    throw BackendError.resortNotPublished
                }
                profile.currentResortID = resortID
            default:
                throw BackendError.invalid
            }
        }
        profile.updatedAt = now
        profiles[me] = profile
        contactHashes[me] = hashes
        return profile
    }

    func accountDelete(_ caller: UUID?) throws {
        let me = try uid(caller)
        for meet in meets.values where !meet.status.isTerminal && meet.involves(me) {
            endMeet(meet.meetID, status: .invalidated, reason: .partnerLeft, by: me)
        }
        for row in friendships.values where row.requesterID == me || row.addresseeID == me {
            deleteFriendship(row, actor: me)
        }
        blocks.removeAll { $0.blocker == me || $0.blocked == me }
        emailAccounts = emailAccounts.filter { $0.value.id != me }
        presence[me] = nil
        descents.removeAll { $0.owner == me }
        paceModels[me] = nil
        deviceTokens[me] = nil
        mutedPushKinds[me] = nil
        contactHashes[me] = nil
        // 0017: reports stay without its id.
        reports = reports.map { report in
            var report = report
            if report.reporterID == me { report.reporterID = nil }
            if report.reportedID == me { report.reportedID = nil }
            return report
        }
        let folder = AvatarPath.folder(of: me) + "/"
        avatarObjects = avatarObjects.filter { !$0.key.hasPrefix(folder) }
        // The rest cascades from the profile.
        for meet in meets.values where meet.involves(me) {
            meets[meet.meetID] = nil
            progress[meet.meetID] = nil
        }
        profiles[me] = nil
        appleTokens = appleTokens.filter { $0.value != me }
    }

    // MARK: Reports and avatars (0016, 0017)

    /// Service role: stores avatar bytes at a path, as an upload would.
    public func storeAvatar(_ data: Data, at path: String) {
        avatarObjects[path] = data
    }

    public func avatarPaths(of user: UUID) -> [String] {
        let folder = AvatarPath.folder(of: user) + "/"
        return avatarObjects.keys.filter { $0.hasPrefix(folder) }.sorted()
    }

    func reportUser(
        _ caller: UUID?, user: UUID, reason: ReportReason, note: String?, context: ReportContext?
    ) throws {
        let me = try uid(caller)
        guard user != me, let profile = profiles[user] else { throw BackendError.invalid }
        let note = note?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (note?.count ?? 0) <= reportNoteLimit else { throw BackendError.invalid }
        try rateLimit(me, "report_user", max: 10, window: 3_600)
        reports.append(FakeReport(
            reporterID: me, reportedID: user, reportedName: profile.displayName,
            reportedAvatarURL: profile.avatarURL, reason: reason,
            note: note?.isEmpty == false ? note : nil, context: context, at: now
        ))
    }

    func avatarUpload(_ caller: UUID?, jpeg: Data) throws -> String {
        let me = try uid(caller)
        // The bucket's limit and types (0003).
        guard (1...2_097_152).contains(jpeg.count) else { throw BackendError.invalid }
        let path = AvatarPath.new(for: me)
        avatarObjects[path] = jpeg
        return path
    }

    func avatarRemove(_ caller: UUID?, keeping: String?) throws {
        let me = try uid(caller)
        let folder = AvatarPath.folder(of: me) + "/"
        avatarObjects = avatarObjects.filter { !$0.key.hasPrefix(folder) || $0.key == keeping }
    }

    func avatarData(path: String) throws -> Data {
        guard let data = avatarObjects[path] else { throw BackendError.notFound }
        return data
    }
}
