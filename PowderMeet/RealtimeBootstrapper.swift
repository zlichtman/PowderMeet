//
//  RealtimeBootstrapper.swift
//  PowderMeet
//
//  Owns the lazy construction + teardown of `RealtimeLocationService`
//  and `PresenceCoordinator`. Lifted out of `ContentCoordinator` so the
//  realtime-bootstrap lifecycle is a single object with a small, clear
//  surface (ensureLocation / ensurePresence / teardown) instead of being
//  woven through the coordinator's bind / scenePhase / activateRoute /
//  teardown paths.
//
//  The instance is held by ContentCoordinator and its `location` /
//  `presence` properties stay reachable through pass-through computed
//  properties on the coordinator (`coordinator.realtimeLocation`,
//  `coordinator.presenceCoordinator`) so existing ContentView call sites
//  don't have to learn the new path.
//
//  Threading: `@MainActor` to match every collaborator. `@Observable` so
//  the pass-through properties on ContentCoordinator continue to drive
//  SwiftUI invalidation when `location` or `presence` flip from nil →
//  set on the first `ensureLocation()` after cold launch.
//

import Foundation
import Observation

@MainActor
@Observable
final class RealtimeBootstrapper {

    /// Lazily built shared `RealtimeLocationService`. nil until the first
    /// `ensureLocation()` — kept stable from there on; resort switches
    /// reseat presence on the same instance instead of rebuilding it.
    private(set) var location: RealtimeLocationService?

    /// Lazily built shared `PresenceCoordinator`. Same one-instance-per-
    /// session contract as `location`.
    private(set) var presence: PresenceCoordinator?

    @ObservationIgnored private let friendService: FriendService
    @ObservationIgnored private let locationManager: LocationManager
    @ObservationIgnored private let locationHistory: LocationHistoryStore

    /// Returns the current resort graph for inbound-broadcast node
    /// resolution. Set by `ContentCoordinator.bind(resortManager:)` once
    /// the resort manager has landed; defaults to `{ nil }` so a stray
    /// `ensureLocation()` before bind doesn't crash. The closure form
    /// (vs a stored `MountainGraph?`) keeps the bootstrapper from
    /// holding stale graph references across resort switches.
    @ObservationIgnored var resortGraphProvider: () -> MountainGraph? = { nil }

    init(friendService: FriendService,
         locationManager: LocationManager,
         locationHistory: LocationHistoryStore) {
        self.friendService = friendService
        self.locationManager = locationManager
        self.locationHistory = locationHistory
    }

    /// Lazily build the shared `RealtimeLocationService` and (re)install
    /// the callback closures that resolve node ids, friend ids
    /// (snapshot-gated), and friend display names. Safe to call
    /// repeatedly — returns the same instance on subsequent calls so
    /// callers can use the result of `ensureLocation()` interchangeably
    /// with the stored `location` reference.
    @discardableResult
    func ensureLocation() -> RealtimeLocationService {
        let persistentStore = try? FriendLocationStore()
        let rtl = location ?? RealtimeLocationService(
            locationManager: locationManager,
            persistentStore: persistentStore
        )
        rtl.locationHistory = locationHistory

        let lm = locationManager
        let provider = resortGraphProvider
        rtl.nodeResolver = { coord in
            if let g = provider(),
               let sticky = lm.gpsStickyGraphNodeId,
               g.nodes[sticky] != nil {
                return sticky
            }
            return provider()?.nearestNode(to: coord)?.id
        }

        // Friend-only broadcast filter. See `CLAUDE.md` (social snapshot
        // gate): `socialGeneration > 0` is the gate that tells
        // `RealtimeLocationService.handleIncomingBroadcast` the atomic
        // social snapshot has applied at least once. Returning `nil`
        // causes the service to REJECT the inbound payload.
        let fs = friendService
        rtl.friendIdsProvider = {
            guard fs.socialGeneration > 0 else { return nil }
            return Set(fs.friends.map(\.id))
        }
        rtl.friendNameProvider = { id in
            fs.friends.first(where: { $0.id == id })?.displayName
        }

        if location == nil {
            location = rtl
        }
        return rtl
    }

    /// Lazily build the `PresenceCoordinator`. One instance for the
    /// lifetime of the bootstrapper — resort switches re-enter through
    /// the same coordinator's generation counter; callers just call
    /// `enter(resortId:)` after this returns.
    @discardableResult
    func ensurePresence(using rtl: RealtimeLocationService) -> PresenceCoordinator {
        if let existing = presence {
            rtl.presenceGateCoordinator = existing
            return existing
        }
        let coord = PresenceCoordinator(friendService: friendService, realtimeLocation: rtl)
        presence = coord
        rtl.presenceGateCoordinator = coord
        return coord
    }

    /// Teardown sequence — mirrors the realtime portions of
    /// `ContentCoordinator.teardown`: stop the presence ticker, cut the
    /// gate-coordinator back-link, then drop both instances. Caller is
    /// responsible for the rest of the teardown (friendQualityStore,
    /// channel reset on FriendService / MeetRequestService).
    func teardown() {
        presence?.stop()
        location?.presenceGateCoordinator = nil
        presence = nil
        location = nil
    }
}
