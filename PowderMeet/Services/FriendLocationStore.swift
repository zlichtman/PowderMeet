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
    var latitude: Double
    var longitude: Double
    var capturedAt: Date
    var nearestNodeId: String?
    var accuracyMeters: Double?

    init(userId: String,
         displayName: String,
         latitude: Double,
         longitude: Double,
         capturedAt: Date,
         nearestNodeId: String?,
         accuracyMeters: Double?) {
        self.userId = userId
        self.displayName = displayName
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

    init() throws {
        let schema = Schema([StoredFriendLocation.self])
        let onDiskConfig = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
        // On-disk first. If SwiftData can't open the store (schema migration
        // failure, disk full, file-protected during background launch), fall
        // back to an in-memory container so at least the current session
        // still gets cold-start hydration rather than a permanently nil store.
        do {
            self.container = try ModelContainer(for: schema, configurations: [onDiskConfig])
        } catch {
            print("[FriendLocationStore] on-disk init failed: \(error) — retrying in-memory")
            let memoryConfig = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
            self.container = try ModelContainer(for: schema, configurations: [memoryConfig])
        }
        self.context = ModelContext(container)
    }

    /// Read all stored friend rows. Synchronous + on-disk read should complete
    /// well under the 200ms cold-launch budget for typical friend counts (<100).
    func loadAll() -> [RealtimeLocationService.FriendLocation] {
        let descriptor = FetchDescriptor<StoredFriendLocation>()
        guard let rows = try? context.fetch(descriptor) else { return [] }
        return rows.compactMap { row in
            guard let uuid = UUID(uuidString: row.userId) else { return nil }
            return RealtimeLocationService.FriendLocation(
                userId: uuid,
                displayName: row.displayName,
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
            existing.latitude = loc.latitude
            existing.longitude = loc.longitude
            existing.capturedAt = loc.capturedAt
            existing.nearestNodeId = loc.nearestNodeId
            existing.accuracyMeters = loc.accuracyMeters
        } else {
            context.insert(StoredFriendLocation(
                userId: userIdString,
                displayName: loc.displayName,
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
