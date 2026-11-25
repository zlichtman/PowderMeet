import Foundation
import PMLogging
import PowderMeetAPI

/// Everything a session is given. Built once by the composition root; there are no
/// singletons.
public struct Dependencies: Sendable {
    public var backend: any BackendClient
    public var location: any LocationProvider
    public var clock: any Clock
    /// The instant the solver prices the mountain at. The real clock, except in
    /// the demo, which solves at midday mountain time (`ShiftedClock`).
    public var solveClock: any Clock
    public var reachability: any Reachability
    public var push: any PushRegistrar
    public var bundles: BundleStore
    public var launch: LaunchCache
    public var outbox: OutboxQueue
    /// Profile photos on disk, by object path.
    public var avatars: AvatarStore
    public var toasts: Toasts
    public var recorder: FlightRecorder
    public var log: PMLog
    public var census: TaskCensus
    public var appBuild: String
    /// Time to finish a save the system would otherwise cut short (M4).
    public var background: any BackgroundGrace

    public init(
        backend: any BackendClient, location: any LocationProvider, clock: any Clock,
        reachability: any Reachability, push: any PushRegistrar, bundles: BundleStore,
        launch: LaunchCache, outbox: OutboxQueue, avatars: AvatarStore, toasts: Toasts,
        recorder: FlightRecorder, log: PMLog, census: TaskCensus = TaskCensus(), appBuild: String,
        solveClock: (any Clock)? = nil, background: any BackgroundGrace = NoBackgroundGrace()
    ) {
        self.background = background
        self.backend = backend
        self.location = location
        self.clock = clock
        self.solveClock = solveClock ?? clock
        self.reachability = reachability
        self.push = push
        self.bundles = bundles
        self.launch = launch
        self.outbox = outbox
        self.avatars = avatars
        self.toasts = toasts
        self.recorder = recorder
        self.log = log
        self.census = census
        self.appBuild = appBuild
    }

    /// Wires the shared pieces (log into the flight recorder, caches under one
    /// directory) around the services that differ between live and fake.
    /// `keptMapsDirectory` holds the maps the user downloaded, out of the cache
    /// (`BundleStore.keep`). The outbox sits beside it: its queued runs may be
    /// the only copy, so it must not live where iOS purges.
    public init(
        backend: any BackendClient, location: any LocationProvider, clock: any Clock,
        reachability: any Reachability, push: any PushRegistrar, cacheDirectory: URL,
        keptMapsDirectory: URL? = nil, outboxBesideMaps: Bool = true, appBuild: String,
        solveClock: (any Clock)? = nil, background: any BackgroundGrace = NoBackgroundGrace()
    ) {
        let recorder = FlightRecorder()
        let log = PMLog(sink: recorder)
        let cachedOutbox = cacheDirectory.appendingPathComponent("outbox", isDirectory: true)
        // A staged preview keeps its uploads in its throwaway cache.
        let keptOutbox = (outboxBesideMaps ? keptMapsDirectory : nil).map {
            $0.deletingLastPathComponent().appendingPathComponent("outbox", isDirectory: true)
        }
        self.init(
            backend: backend, location: location, clock: clock, reachability: reachability,
            push: push,
            bundles: BundleStore(
                directory: cacheDirectory.appendingPathComponent("bundles", isDirectory: true),
                keptDirectory: keptMapsDirectory, log: log
            ),
            launch: LaunchCache(
                directory: cacheDirectory.appendingPathComponent("launch", isDirectory: true), log: log
            ),
            outbox: OutboxQueue(
                directory: keptOutbox ?? cachedOutbox,
                movingFrom: keptOutbox == nil ? nil : cachedOutbox, log: log
            ),
            avatars: AvatarStore(
                directory: cacheDirectory.appendingPathComponent("avatars", isDirectory: true), log: log
            ),
            toasts: Toasts(), recorder: recorder, log: log, appBuild: appBuild,
            solveClock: solveClock, background: background
        )
    }
}
