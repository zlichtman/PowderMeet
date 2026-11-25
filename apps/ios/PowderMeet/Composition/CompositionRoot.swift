import AppCore
import Foundation
import Synchronization
import MapboxAdapter
import PowderMeetAPI
import SupabaseBackend
import UIKit

/// Builds `Dependencies` on the live backend, the one `AppSession` and the
/// projection the views read (`specs/07-CLIENT.md` section 7). Owned by the
/// app delegate; nothing in the app is a singleton.
///
/// Debug and TestFlight builds (`DeveloperAccess`) also get developer testing
/// (`specs/07-CLIENT.md` section 8): the backend behind `SandboxedBackend`, the
/// location behind `PlaceableLocationProvider`, an `AdjustableClock` as the
/// solve clock, and `DeveloperModel`. There is no demo mode:
/// the app is always checked on real infrastructure, with test accounts.
final class CompositionRoot {
    let model: AppModel
    let push: PushService?
    /// Developer testing; nil when the build may not have it.
    let developer: DeveloperModel?

    private let session: AppSession
    private var running: Task<Void, Never>?
    private var foreground: Task<Void, Never>?
    private var background: Task<Void, Never>?
    private var termination: (any NSObjectProtocol)?
    /// `PreviewStage`: what the private fake server needs before the session starts.
    private var previewSeed: (@Sendable () async -> Void)?

    init(arguments: [String] = ProcessInfo.processInfo.arguments) {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "0"
        let build = info["CFBundleVersion"] as? String ?? "0"
        var cache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PowderMeet", isDirectory: true)
        #if DEBUG
        let outboxBesideMaps = PreviewStage.resortID == nil
        // The preview stage starts clean every launch (the fake server does),
        // so no profile, resort or activity cached by an earlier run shows
        // through. Downloaded maps are kept: they are the same live bundles.
        if PreviewStage.resortID != nil {
            cache = PreviewStage.freshCache(beside: cache)
        }
        #else
        let outboxBesideMaps = true
        #endif

        let toolsAllowed = DeveloperAccess.isAllowed
        // The demo switch earlier builds stored; there is no demo any more.
        UserDefaults.standard.removeObject(forKey: "debug.demoMode")

        let reachability = PathReachability()
        guard let live = Self.liveConfiguration(info, build: build) else {
            fatalError("SUPABASE_URL and SUPABASE_PUBLISHABLE_KEY are missing from Secrets.xcconfig")
        }
        var placeable: PlaceableLocationProvider?
        var adjustable: AdjustableClock?
        let core = CoreLocationProvider()
        let service = PushService()
        var location: any LocationProvider = core
        var solveClock: any AppCore.Clock = SystemClock()
        if toolsAllowed {
            let wrapped = PlaceableLocationProvider(base: core)
            let clock = AdjustableClock()
            location = wrapped
            solveClock = clock
            placeable = wrapped
            adjustable = clock
        }
        var dependencies = Dependencies(
            backend: SupabaseBackend(configuration: live),
            location: location, clock: SystemClock(), reachability: reachability,
            push: service.registrar, cacheDirectory: cache,
            keptMapsDirectory: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("PowderMeet/maps", isDirectory: true),
            outboxBesideMaps: outboxBesideMaps, appBuild: build, solveClock: solveClock,
            background: BackgroundTaskGrace()
        )
        #if DEBUG
        if let resortID = PreviewStage.resortID {
            let stage = PreviewStage.make(live: dependencies.backend, resortID: resortID)
            dependencies.backend = stage.client
            previewSeed = stage.seed
        }
        #endif
        let access = core.access
        push = service

        // The dev people's sandbox sits in front of whichever backend this is.
        var sandboxed: SandboxedBackend?
        if toolsAllowed, let placeable, let adjustable {
            let backend = SandboxedBackend(
                base: dependencies.backend,
                // Stills hold their positions; motion captures use the rehearsal at real time.
                sandbox: DeveloperSandbox(
                    location: placeable, solveClock: adjustable, log: dependencies.log,
                    timing: .init(speedup: DebugLaunch.demoCapture ? (DebugLaunch.demoMotion ? 1 : 0) : 6))
            )
            dependencies.backend = backend
            sandboxed = backend
        }

        // The map draws real terrain, so it always needs the token.
        if let token = info["MBXAccessToken"] as? String, !token.isEmpty {
            MapboxMapController.configure(accessToken: token)
        } else {
            dependencies.log.error(.map, "MAPBOX_ACCESS_TOKEN is missing from Secrets.xcconfig")
        }

        session = AppSession(dependencies: dependencies)
        model = AppModel(
            session: session, dependencies: dependencies, locationAccess: access, push: push,
            offlineMaps: MapOfflineRegions(log: dependencies.log),
            appVersion: version, launchedAt: Self.processStart(),
            connections: { reachability.connections() }
        )
        if let sandboxed, let placeable, let adjustable {
            developer = DeveloperModel(
                app: model, channel: DeveloperAccess.launchChannel, location: placeable, backend: sandboxed,
                clock: adjustable, serverHost: live.url.host()
            )
        } else {
            developer = nil
        }
        // Opening the resort the phone is in stays out of the way of the
        // Debug preview stage, scripted launches and developer testing that
        // moves this phone or places a dev person, so it never breaks a
        // staged test.
        var scripted = false
        #if DEBUG
        scripted = ["-openResort", "-meetState", "-mapCard"].contains(where: arguments.contains)
        #endif
        let tools = self.developer
        model.arrivalSuppressed = { [scripted] in
            DebugLaunch.previewData || scripted
                || tools?.isTeleported == true || tools?.placedPeople.isEmpty == false
        }
    }

    /// When the kernel started this process, so launch timing includes everything
    /// before `main`. Falls back to now.
    private static func processStart() -> Date {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var name = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&name, UInt32(name.count), &info, &size, nil, 0) == 0 else { return Date() }
        let start = info.kp_proc.p_starttime
        return Date(timeIntervalSince1970: Double(start.tv_sec) + Double(start.tv_usec) / 1_000_000)
    }

    /// Starts the session's run loop, which lasts as long as the app.
    func start() {
        guard running == nil else { return }
        model.start()
        developer?.start()
        #if DEBUG
        DebugScript.run(on: model, developer: developer)
        #endif
        let session = session
        let seed = previewSeed
        running = Task {
            await seed?()
            await session.run()
        }
        // Coming back to the foreground is an event for the session, not
        // something a view decides.
        let model = model
        // Relaunched by iOS in the background (a wake region, significant
        // change or push): no didEnterBackground arrives for that.
        if UIApplication.shared.applicationState == .background { model.sceneEnteredBackground() }
        foreground = Task {
            let activations = NotificationCenter.default
                .notifications(named: UIApplication.didBecomeActiveNotification)
                .map { _ in () }
            for await _ in activations {
                model.sceneBecameActive()
            }
        }
        background = Task {
            let departures = NotificationCenter.default
                .notifications(named: UIApplication.didEnterBackgroundNotification)
                .map { _ in () }
            for await _ in departures {
                model.sceneEnteredBackground()
            }
        }
        // Best effort: friends stop seeing a phone whose app was ended. iOS
        // gives a terminating app a few seconds; the clear gets up to two,
        // with the run loop turning so the network call can finish.
        termination = NotificationCenter.default.addObserver(
            forName: UIApplication.willTerminateNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                let task = BackgroundTask("presence-clear")
                let done = Flag()
                // Detached: the main thread is held below, so nothing this
                // needs may wait for it.
                Task.detached {
                    await session.prepareForTermination()
                    done.set()
                }
                let deadline = Date().addingTimeInterval(2)
                while !done.isSet, Date() < deadline {
                    RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
                }
                task.end()
            }
        }
    }

    /// `Secrets.xcconfig` reaches the app through Info.plist. A live build
    /// without it cannot talk to anything, so it stops at launch with the
    /// reason.
    private static func liveConfiguration(
        _ info: [String: Any], build: String
    ) -> SupabaseBackend.Configuration? {
        guard let text = info["SupabaseURL"] as? String, let url = URL(string: text),
              url.host() != nil,
              let key = info["SupabasePublishableKey"] as? String, !key.isEmpty else { return nil }
        return SupabaseBackend.Configuration(url: url, publishableKey: key, appBuild: build)
    }
}

/// Set once from any thread, read on the main thread.
nonisolated private final class Flag: Sendable {
    private let value = Mutex(false)
    var isSet: Bool { value.withLock { $0 } }
    func set() { value.withLock { $0 = true } }
}
