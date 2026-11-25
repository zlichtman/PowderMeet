import Foundation
import MountainCore

extension FakeBackend {
    // MARK: Reads (row level security)

    func readMeet(_ caller: UUID?, id: UUID) -> Meet? {
        guard let caller, let meet = meets[id], meet.involves(caller) else { return nil }
        return meet
    }

    func readMeetProgress(_ caller: UUID?, meetID: UUID) -> [MeetProgress] {
        guard let caller, let meet = meets[meetID], meet.involves(caller) else { return [] }
        return (progress[meetID] ?? [:]).values.sorted { $0.userID.uuidString < $1.userID.uuidString }
    }

    func readProfile(_ caller: UUID?, id: UUID) -> Profile? {
        guard let caller, caller == id || isAcceptedFriend(caller, id) else { return nil }
        guard var profile = profiles[id] else { return nil }
        // Height and weight are the owner's alone.
        if caller != id {
            profile.heightCM = nil
            profile.weightKG = nil
        }
        return profile
    }

    func readPaceModel(_ caller: UUID?, owner: UUID) -> PaceModelRow? {
        guard let caller, caller == owner || isAcceptedFriend(caller, owner) else { return nil }
        return paceModels[owner]
    }

    func readDescents(_ caller: UUID?, limit: Int) -> [DescentSummary] {
        descents.filter { $0.owner == caller }
            .sorted { $0.upload.startedAt > $1.upload.startedAt }
            .prefix(max(limit, 0))
            .map {
                DescentSummary(
                    descentID: $0.id, source: $0.upload.source, startedAt: $0.upload.startedAt,
                    endedAt: $0.upload.endedAt, contentHash: $0.upload.contentHash,
                    resortID: $0.upload.resortID, device: $0.upload.device, stats: $0.upload.stats
                )
            }
    }

    func readDescentDetail(_ caller: UUID?, descentID: UUID) -> DescentDetail? {
        guard let descent = descents.first(where: { $0.id == descentID && $0.owner == caller }) else { return nil }
        return DescentDetail(descentID: descent.id, track: descent.upload.track, match: descent.upload.match)
    }

    func readDescentRecords(_ caller: UUID?, offset: Int, limit: Int) -> [DescentRecord] {
        descents.filter { $0.owner == caller }
            .sorted { ($0.upload.startedAt, $0.id.uuidString) > ($1.upload.startedAt, $1.id.uuidString) }
            .dropFirst(max(offset, 0))
            .prefix(max(limit, 0))
            .map {
                DescentRecord(
                    summary: DescentSummary(
                        descentID: $0.id, source: $0.upload.source, startedAt: $0.upload.startedAt,
                        endedAt: $0.upload.endedAt, contentHash: $0.upload.contentHash,
                        resortID: $0.upload.resortID, device: $0.upload.device, stats: $0.upload.stats
                    ),
                    track: $0.upload.track
                )
            }
    }

    func readPublishedResorts() -> [PublishedResort] {
        resorts.values.filter(\.published).map(\.info).sorted { $0.id < $1.id }
    }

    /// `resort_catalog`: every resort; an unpublished one shows no bundle.
    func readResortCatalog() -> [PublishedResort] {
        resorts.values.map { resort in
            var info = resort.info
            if !resort.published {
                info.bundleID = nil
                info.publishedAt = nil
                info.builtAt = nil
            }
            return info
        }.sorted { $0.id < $1.id }
    }

    func readStatus(resortID: String) -> ResortStatus? {
        resorts[resortID]?.published == true ? statuses[resortID] : nil
    }

    func readConditions(resortID: String) -> Conditions? {
        resorts[resortID]?.published == true ? conditions[resortID] : nil
    }

    func readBundle(_ id: BundleID) throws -> Data {
        guard let data = bundles[id] else { throw BackendError.notFound }
        return data
    }

    /// The bundle, fetched from `resortSource` the first time when this fake
    /// lists the resort without holding its bytes.
    func serveBundle(resortID: String, _ id: BundleID) async throws -> Data {
        if let data = bundles[id] { return data }
        guard let source = resortSource, resorts[resortID]?.info.bundleID == id else {
            throw BackendError.notFound
        }
        let fetched = try await source.bundle(resortID, id)
        bundles[id] = fetched.data
        resorts[resortID]?.rendezvousIDs = fetched.rendezvousIDs
        return fetched.data
    }

    func serveStatus(resortID: String) async throws -> ResortStatus? {
        if let status = readStatus(resortID: resortID) { return status }
        guard resorts[resortID]?.published == true, let source = resortSource else { return nil }
        return try await source.status(resortID)
    }

    func serveConditions(resortID: String) async throws -> Conditions? {
        if let value = readConditions(resortID: resortID) { return value }
        guard resorts[resortID]?.published == true, let source = resortSource else { return nil }
        return try await source.conditions(resortID)
    }

    func readConfig() -> [String: JSONValue] { config }
}
