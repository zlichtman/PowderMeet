//
//  FriendLocationStore.swift
//  PowderMeet
//
//  On-disk last-known position cache for friends. Hydrates RealtimeLocationService
//  on cold launch within ~milliseconds so the map is never empty when there's
//  prior knowledge — Find My's "Updated 4 minutes ago" pattern. Live updates
//  overwrite when fresher data arrives.
//
//  One row per friend (latest only). Breadcrumb history stays in-memory in
//  LocationHistoryStore — this store is for "where did I last see them"
//  cold-launch resilience, not replay.
//

import Foundation
import SwiftData
import CoreLocation

@Model
final class StoredFriendLocation {
    @Attribute(.unique) var userId: String
    var displayName: String
    /// Optional for lightweight migration from pre-resort cache rows. Legacy
    /// nil rows are ignored because their coordinates cannot be placed safely.
    var resortId: String?
    var latitude: Double
    var longitude: Double
    var capturedAt: Date
    var nearestNodeId: String?
    var accuracyMeters: Double?

    init(userId: String,
         displayName: String,
         resortId: String,
         latitude: Double,
         longitude: Double,
         capturedAt: Date,
         nearestNodeId: String?,
         accuracyMeters: Double?) {
        self.userId = userId
        self.displayName = displayName
        self.resortId = resortId
        self.latitude = latitude
        self.longitude = longitude
        self.capturedAt = capturedAt
        self.nearestNodeId = nearestNodeId
        self.accuracyMeters = accuracyMeters
    }
}

@MainActor
final class FriendLocationStore {
    private let container: ModelContainer
    private let context: ModelContext

    /// Building a `ModelContainer` is a well-known tens-to-hundreds-of-ms
    /// cold cost, and opening a second container over the same on-disk store
    /// is both wasteful and racy. `ensureRealtimeLocationService` (bootstrap)
    /// and the sign-out path each construct a fresh `FriendLocationStore`, so
    /// we build the container ONCE and reuse it. @MainActor-isolated, so this
    /// static cache needs no extra synchronization.
    private static var cachedContainer: ModelContainer?

    private static func makeOrReuseContainer() throws -> ModelContainer {
        if let cachedContainer { return cachedContainer }
        let schema = Schema([StoredFriendLocation.self])
        let onDiskConfig = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
        let built: ModelContainer
        // On-disk first. If SwiftData can't open the store (schema migration
        // failure, disk full, file-protected during background launch), fall
        // back to an in-memory container so at least the current session
        // still gets cold-start hydration rather than a permanently nil store.
        do {
            built = try ModelContainer(for: schema, configurations: [onDiskConfig])
        } catch {
            print("[FriendLocationStore] on-disk init failed: \(error) — retrying in-memory")
            let memoryConfig = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
            built = try ModelContainer(for: schema, configurations: [memoryConfig])
        }
        cachedContainer = built
        return built
    }

    init() throws {
        let container = try Self.makeOrReuseContainer()
        self.container = container
        self.context = ModelContext(container)
    }

    /// Read all stored friend rows. Synchronous + on-disk read should complete
    /// well under the 200ms cold-launch budget for typical friend counts (<100).
    func loadAll(resortId: String) -> [RealtimeLocationService.FriendLocation] {
        let descriptor = FetchDescriptor<StoredFriendLocation>()
        guard let rows = try? context.fetch(descriptor) else { return [] }
        let now = Date.now
        return rows.compactMap { row in
            guard row.resortId == resortId,
                  let uuid = UUID(uuidString: row.userId),
                  FriendSignalClassifier.isAcceptableLocationPayload(
                    latitude: row.latitude,
                    longitude: row.longitude,
                    capturedAt: row.capturedAt,
                    now: now
                  ) else { return nil }
            return RealtimeLocationService.FriendLocation(
                userId: uuid,
                displayName: row.displayName,
                resortId: resortId,
                latitude: row.latitude,
                longitude: row.longitude,
                capturedAt: row.capturedAt,
                nearestNodeId: row.nearestNodeId,
                accuracyMeters: row.accuracyMeters
            )
        }
    }

    /// Upsert the latest fix for a friend. Caller should monotonic-guard
    /// before calling — store overwrites unconditionally.
    func upsert(_ loc: RealtimeLocationService.FriendLocation) {
        let userIdString = loc.userId.uuidString
        let descriptor = FetchDescriptor<StoredFriendLocation>(
            predicate: #Predicate { $0.userId == userIdString }
        )
        if let existing = try? context.fetch(descriptor).first {
            existing.displayName = loc.displayName
            existing.resortId = loc.resortId
            existing.latitude = loc.latitude
            existing.longitude = loc.longitude
            existing.capturedAt = loc.capturedAt
            existing.nearestNodeId = loc.nearestNodeId
            existing.accuracyMeters = loc.accuracyMeters
        } else {
            context.insert(StoredFriendLocation(
                userId: userIdString,
                displayName: loc.displayName,
                resortId: loc.resortId,
                latitude: loc.latitude,
                longitude: loc.longitude,
                capturedAt: loc.capturedAt,
                nearestNodeId: loc.nearestNodeId,
                accuracyMeters: loc.accuracyMeters
            ))
        }
        saveContext()
    }

    /// Remove a friend's stored row — call on unfriend.
    func remove(userId: UUID) {
        let userIdString = userId.uuidString
        let descriptor = FetchDescriptor<StoredFriendLocation>(
            predicate: #Predicate { $0.userId == userIdString }
        )
        if let rows = try? context.fetch(descriptor) {
            for row in rows { context.delete(row) }
            saveContext()
        }
    }

    /// Central save that surfaces SwiftData failures. Previously the
    /// callers used `try? context.save()` and silently lost disk-full /
    /// schema-migration errors, which then presented as "cold launch is
    /// empty even though the friend was live yesterday" with no breadcrumb.
    private func saveContext() {
        do {
            try context.save()
        } catch {
            print("[FriendLocationStore] save failed: \(error)")
        }
    }

    func clear() {
        let descriptor = FetchDescriptor<StoredFriendLocation>()
        if let rows = try? context.fetch(descriptor) {
            for row in rows { context.delete(row) }
            saveContext()
        }
    }
}
