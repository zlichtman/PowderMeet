import AppCore
import CoreLocation
import Foundation
import MountainCore
import Network
import PowderMeetAPI
import Synchronization
import UIKit
import UserNotifications

// The live device services `AppCore` asks the app to supply
// (`packages/AppCore/Sources/AppCore/Providers.swift`).

// MARK: Location

/// What the user has allowed, as the screens need it.
nonisolated enum LocationPermission: Sendable, Hashable {
    case notDetermined, denied, allowed
}

/// What the screens need from a location source besides fixes: the permission
/// state, a way to ask for it, and what wants fixes besides an open resort.
/// The demo source reports `.allowed` and keeps the defaults.
nonisolated struct LocationAccess: Sendable {
    var permissions: @Sendable () -> AsyncStream<LocationPermission>
    var requestWhenInUse: @MainActor @Sendable () -> Void
    /// True while the user allows "Always", then every change.
    var alwaysAllowed: @Sendable () -> AsyncStream<Bool> = {
        AsyncStream { continuation in
            continuation.yield(true)
            continuation.finish()
        }
    }
    /// The upgrade to "Always". Asked only when a meet or recording needs it
    /// (`AppModel.updateLocationDemand`), never at first launch.
    var requestAlways: @MainActor @Sendable () -> Void = {}
    /// Recording, meet and vicinity, for the driver's mode (`LocationDemand`).
    /// Whether a resort is open comes from `start()` and `stop()`.
    var setDemand: @MainActor @Sendable (LocationDemand) -> Void = { _ in }
}

/// CoreLocation behind `LocationProvider`: one stream of fixes fanned out to
/// presence, navigation and recording.
nonisolated struct CoreLocationProvider: LocationProvider {
    private let driver: LocationDriver

    @MainActor init() {
        driver = LocationDriver()
    }

    func fixes() -> AsyncStream<Fix> { driver.fixCast.stream() }

    /// A resort session wants fixes. Without permission this delivers
    /// nothing; the screens ask.
    func start() async { await driver.setResortOpen(true) }

    /// The resort session ended. Updates continue if recording or a meet
    /// still needs them.
    func stop() async { await driver.setResortOpen(false) }

    var access: LocationAccess {
        let driver = driver
        return LocationAccess(
            permissions: { driver.permissions() },
            requestWhenInUse: { driver.requestWhenInUse() },
            alwaysAllowed: { driver.alwaysAllowed() },
            requestAlways: { driver.requestAlways() },
            setDemand: { driver.setDemand($0) }
        )
    }
}

/// Owns the `CLLocationManager` on the main actor and applies `LocationMode`:
/// accuracy, distance filter, background updates (with the blue indicator)
/// and the significant-change service, all from one place.
private final class LocationDriver: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    nonisolated let fixCast = Multicast<Fix>()
    private nonisolated let permissionCast = Multicast<LocationPermission>()
    private nonisolated let alwaysCast = Multicast<Bool>()
    private nonisolated let permission = Mutex(LocationPermission.notDetermined)
    private nonisolated let always = Mutex(false)
    private var resortOpen = false
    private var demand = LocationDemand()
    private var applied: LocationMode?
    /// Updates are paused while the phone is still (`pausesWhenStill`); leaving
    /// this region around the last fix starts them again.
    private nonisolated static let wakeRegionID = "powdermeet.wake"
    private static let wakeRadiusM = 50.0
    private var lastLocation: CLLocation?
    /// When a fix last went out, real or repeated.
    private var lastSentAt = Date.distantPast
    private var standing: Task<Void, Never>?
    /// A phone that stays inside the distance filter gets no update, so its
    /// last fix would age past routing grade (I-14) while the skier stands in
    /// a lift line. While updates run, silence from CoreLocation means "has
    /// not moved further than the filter", so the last position is said again
    /// with the time it is known for and the filter added to its accuracy.
    private static let standingRepeatS = 45.0

    override init() {
        super.init()
        manager.delegate = self
        manager.activityType = .fitness
        manager.showsBackgroundLocationIndicator = true
        let status = manager.authorizationStatus
        permission.withLock { $0 = Self.permission(status) }
        always.withLock { $0 = status == .authorizedAlways }
    }

    nonisolated func permissions() -> AsyncStream<LocationPermission> {
        permissionCast.stream(initial: permission.withLock { $0 })
    }

    nonisolated func alwaysAllowed() -> AsyncStream<Bool> {
        alwaysCast.stream(initial: always.withLock { $0 })
    }

    func setResortOpen(_ open: Bool) {
        resortOpen = open
        apply()
    }

    func setDemand(_ new: LocationDemand) {
        demand = new
        apply()
    }

    func requestWhenInUse() {
        manager.requestWhenInUseAuthorization()
    }

    /// iOS shows the upgrade once; after that this does nothing, and the
    /// screens point to Settings.
    func requestAlways() {
        guard manager.authorizationStatus == .authorizedWhenInUse
            || manager.authorizationStatus == .notDetermined else { return }
        manager.requestAlwaysAuthorization()
    }

    private func apply() {
        var wanted = demand
        wanted.resortOpen = resortOpen
        let mode = wanted.mode
        let status = manager.authorizationStatus
        let authorized = status == .authorizedAlways || status == .authorizedWhenInUse
        guard let settings = mode.settings, authorized else {
            if applied != .off {
                manager.stopUpdatingLocation()
                manager.stopMonitoringSignificantLocationChanges()
                manager.allowsBackgroundLocationUpdates = false
                stopWakeRegion()
                applied = .off
                standing?.cancel()
                standing = nil
            }
            return
        }
        guard mode != applied else { return }
        applied = mode
        stopWakeRegion()
        manager.desiredAccuracy = switch settings.accuracyM {
        case ..<1: kCLLocationAccuracyBest
        case ..<50: kCLLocationAccuracyNearestTenMeters
        case ..<500: kCLLocationAccuracyHundredMeters
        default: kCLLocationAccuracyKilometer
        }
        manager.distanceFilter = settings.distanceFilterM
        // Needs the `location` background mode (project.yml). With "While
        // Using" it keeps updates started in the foreground going; "Always"
        // also lets the significant-change service relaunch the app.
        manager.allowsBackgroundLocationUpdates = settings.background
        // A pause in the background ends only by leaving the wake region,
        // which needs "Always"; without it a background mode never pauses.
        manager.pausesLocationUpdatesAutomatically = settings.pausesWhenStill
            && (!settings.background || status == .authorizedAlways)
        manager.startUpdatingLocation()
        startStandingRepeats()
        if settings.significantChanges, status == .authorizedAlways {
            manager.startMonitoringSignificantLocationChanges()
        } else {
            manager.stopMonitoringSignificantLocationChanges()
        }
    }

    private func startStandingRepeats() {
        guard standing == nil else { return }
        standing = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.standingRepeatS / 3))
                self?.repeatIfStanding()
            }
        }
    }

    private func repeatIfStanding() {
        // A paused manager (the wake region is up) is not watching: say nothing.
        guard let settings = applied?.settings, let last = lastLocation,
              !manager.monitoredRegions.contains(where: { $0.identifier == Self.wakeRegionID }),
              Date().timeIntervalSince(lastSentAt) >= Self.standingRepeatS else { return }
        lastSentAt = Date()
        fixCast.send(Fix(
            coordinate: Coordinate(lon: last.coordinate.longitude, lat: last.coordinate.latitude),
            accuracyM: max(last.horizontalAccuracy, settings.distanceFilterM), capturedAt: lastSentAt,
            altitudeM: last.verticalAccuracy >= 0 ? last.altitude : nil, speedMS: 0
        ))
    }

    private nonisolated static func permission(_ status: CLAuthorizationStatus) -> LocationPermission {
        switch status {
        case .notDetermined: .notDetermined
        case .authorizedAlways, .authorizedWhenInUse: .allowed
        case .denied, .restricted: .denied
        @unknown default: .denied
        }
    }

    /// iOS paused updates because the phone has been still (the meet's
    /// background mode): watch a small region around the last fix, so the
    /// first steps away start them again.
    nonisolated func locationManagerDidPauseLocationUpdates(_ manager: CLLocationManager) {
        Task { @MainActor in self.startWakeRegion() }
    }

    nonisolated func locationManagerDidResumeLocationUpdates(_ manager: CLLocationManager) {
        Task { @MainActor in self.stopWakeRegion() }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didExitRegion region: CLRegion) {
        guard region.identifier == Self.wakeRegionID else { return }
        Task { @MainActor in
            self.stopWakeRegion()
            guard self.applied?.settings != nil else { return }
            self.manager.startUpdatingLocation()
        }
    }

    /// Only for the meet's background mode: the foreground modes that pause
    /// (browsing, watching, locating) must not gain a way to wake the app.
    private func startWakeRegion() {
        guard applied == .navigationBackground, manager.authorizationStatus == .authorizedAlways,
              let center = lastLocation?.coordinate,
              CLLocationManager.isMonitoringAvailable(for: CLCircularRegion.self) else { return }
        let region = CLCircularRegion(center: center, radius: Self.wakeRadiusM, identifier: Self.wakeRegionID)
        region.notifyOnEntry = false
        region.notifyOnExit = true
        manager.startMonitoring(for: region)
    }

    private func stopWakeRegion() {
        for region in manager.monitoredRegions where region.identifier == Self.wakeRegionID {
            manager.stopMonitoring(for: region)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        if let last = locations.last(where: { $0.horizontalAccuracy >= 0 }) {
            Task { @MainActor in
                self.lastLocation = last
                self.lastSentAt = Date()
            }
        }
        for location in locations where location.horizontalAccuracy >= 0 {
            fixCast.send(Fix(
                coordinate: Coordinate(
                    lon: location.coordinate.longitude, lat: location.coordinate.latitude
                ),
                accuracyM: location.horizontalAccuracy, capturedAt: location.timestamp,
                altitudeM: location.verticalAccuracy >= 0 ? location.altitude : nil,
                speedMS: location.speed >= 0 ? location.speed : nil
            ))
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: any Error) {
        // CoreLocation keeps trying after a transient failure; a denial arrives as
        // an authorization change below.
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        let value = Self.permission(status)
        permission.withLock { $0 = value }
        always.withLock { $0 = status == .authorizedAlways }
        permissionCast.send(value)
        alwaysCast.send(status == .authorizedAlways)
        Task { @MainActor in
            // A grant or a downgrade changes what may run.
            self.applied = nil
            self.apply()
        }
    }
}

// MARK: Reachability

/// `NWPathMonitor` behind `Reachability`. Sends changes only; a consumer that
/// starts while the phone is offline is told so first, because the session
/// assumes it starts online.
nonisolated final class PathReachability: Reachability {
    private let cast = Multicast<Bool>()
    private let connectionCast = Multicast<Connection>()
    private let connection = Mutex(Connection.unmetered)
    private let watcher = Mutex<Task<Void, Never>?>(nil)

    init() {
        let task = Task.detached { [weak self] in
            for await path in NWPathMonitor() {
                guard let self else { return }
                let value: Connection = path.status != .satisfied ? .offline
                    : (path.isExpensive || path.isConstrained) ? .metered : .unmetered
                let old = self.connection.withLock { current -> Connection? in
                    guard current != value else { return nil }
                    defer { current = value }
                    return current
                }
                guard let old else { continue }
                self.connectionCast.send(value)
                if (old == .offline) != (value == .offline) { self.cast.send(value != .offline) }
            }
        }
        watcher.withLock { $0 = task }
    }

    deinit {
        watcher.withLock { $0?.cancel() }
    }

    func changes() -> AsyncStream<Bool> {
        cast.stream(initial: connection.withLock { $0 } == .offline ? false : nil)
    }

    /// The kind of connection now, then every change. Large downloads read this.
    func connections() -> AsyncStream<Connection> {
        connectionCast.stream(initial: connection.withLock { $0 })
    }
}

// MARK: Push

/// What a foreground notification says, shown as an in-app banner instead of a
/// system alert (`specs/11-SETUP-RELEASE.md` section 5).
nonisolated struct InAppBanner: Identifiable, Hashable, Sendable {
    var id = UUID()
    var title: String
    var body: String
}

nonisolated enum NotificationPermission: Sendable, Hashable {
    case notDetermined, denied, allowed
}

/// APNs registration and notification presentation. The app delegate forwards
/// the token callbacks here; `registrar` is what `Dependencies.push` holds.
final class PushService: NSObject, UNUserNotificationCenterDelegate {
    /// How long a session waits for APNs before starting without a token.
    static let tokenTimeoutS = 5.0

    private nonisolated let bannerCast = Multicast<InAppBanner>()
    private nonisolated let tapCast = Multicast<String?>()
    private nonisolated let tokenCast = Multicast<DeviceToken>()
    /// Read off the main actor by `tokenChanges`, so a new listener starts
    /// from the token already known (`Multicast` does not replay).
    private nonisolated let latestToken = Mutex<DeviceToken?>(nil)
    private var token: DeviceToken?
    private var waiters: [CheckedContinuation<DeviceToken?, Never>] = []

    override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
    }

    nonisolated var registrar: any PushRegistrar { Registrar(service: self) }

    private nonisolated struct Registrar: PushRegistrar {
        let service: PushService

        func deviceToken() async -> DeviceToken? { await service.currentToken() }

        func tokenChanges() -> AsyncStream<DeviceToken> {
            service.tokenCast.stream(initial: service.latestToken.withLock { $0 })
        }
    }

    /// Foreground notifications, as banners.
    nonisolated func banners() -> AsyncStream<InAppBanner> { bannerCast.stream() }

    /// The user tapped a notification; the value is its `kind` (`meet.proposed`,
    /// `friend.requested`, …) as `push-drain` wrote it.
    nonisolated func taps() -> AsyncStream<String?> { tapCast.stream() }

    func permission() async -> NotificationPermission {
        switch await UNUserNotificationCenter.current().notificationSettings().authorizationStatus {
        case .notDetermined: .notDetermined
        case .authorized, .provisional, .ephemeral: .allowed
        case .denied: .denied
        @unknown default: .denied
        }
    }

    /// Asks once; the system remembers the answer.
    func requestPermission() async throws -> NotificationPermission {
        let granted = try await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound, .badge])
        if granted { UIApplication.shared.registerForRemoteNotifications() }
        return granted ? .allowed : .denied
    }

    /// The APNs token, or nil when notifications are off or APNs does not answer
    /// in time. Sign-in never waits on push for longer than the timeout.
    private func currentToken() async -> DeviceToken? {
        guard await permission() == .allowed else { return nil }
        if let token { return token }
        UIApplication.shared.registerForRemoteNotifications()
        return await withCheckedContinuation { continuation in
            waiters.append(continuation)
            Task {
                do {
                    try await Task.sleep(for: .seconds(Self.tokenTimeoutS))
                } catch {
                    return
                }
                self.resolve(nil)
            }
        }
    }

    /// Which APNs a token belongs to follows the signing, not the build
    /// configuration: a build installed from Xcode carries a development
    /// provisioning profile (sandbox tokens) even in Release, and App Store
    /// and TestFlight builds carry none (production tokens).
    static let pushEnvironment: PushEnvironment = {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = FileManager.default.contents(atPath: url.path),
              // The profile is a signed plist; its entitlements are plain text inside.
              let text = String(data: data, encoding: .isoLatin1),
              let key = text.range(of: "<key>aps-environment</key>")
        else { return .production }
        return text[key.upperBound...].prefix(80).contains("development") ? .development : .production
    }()

    private func resolve(_ value: DeviceToken?) {
        let waiting = waiters
        waiters = []
        for waiter in waiting { waiter.resume(returning: value) }
    }

    func didRegister(tokenData: Data) {
        let environment = Self.pushEnvironment
        let value = DeviceToken(
            token: tokenData.map { String(format: "%02x", $0) }.joined(), environment: environment
        )
        let changed = value != token
        token = value
        latestToken.withLock { $0 = value }
        resolve(value)
        // iOS calls this on every registration, mostly with the same token.
        if changed { tokenCast.send(value) }
    }

    func didFailToRegister() {
        resolve(nil)
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        let content = notification.request.content
        bannerCast.send(InAppBanner(title: content.title, body: content.body))
        return []
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse
    ) async {
        tapCast.send(response.notification.request.content.userInfo["kind"] as? String)
    }
}

// MARK: Local notifications

/// Notifications the phone raises itself, for activity: "Runs imported" when
/// an import finishes while the app is in the background, and a summary of
/// the day's recording. Never asks for permission; with notifications off it
/// does nothing. A tap carries `kind` (`activity.*`), which opens Profile.
final class LocalNotifier {
    static let importedKind = "activity.imported"
    static let summaryKind = "activity.summary"
    /// The summary fires this long after the last recorded run, so it comes
    /// once the skier has stopped for the day.
    static let summaryDelayS: TimeInterval = 2 * 3_600

    private var isAllowed: Bool {
        get async {
            switch await UNUserNotificationCenter.current().notificationSettings().authorizationStatus {
            case .authorized, .provisional, .ephemeral: true
            default: false
            }
        }
    }

    /// An import finished; told only when the app is not on screen, where the
    /// toast already says it.
    func runsImported(_ count: Int) async {
        guard count > 0, UIApplication.shared.applicationState != .active, await isAllowed else { return }
        let content = UNMutableNotificationContent()
        content.title = "Runs imported"
        content.body = "\(count) \(count == 1 ? "run" : "runs") added to your history."
        content.userInfo = ["kind": Self.importedKind]
        await add(UNNotificationRequest(identifier: Self.importedKind, content: content, trigger: nil))
    }

    /// The day so far, to arrive two hours after the last run. One request per
    /// day, replaced after every run, so it survives the app being ended.
    func scheduleDaySummary(runs: Int, verticalM: Double, resortName: String?, day: String?) async {
        guard runs > 0, await isAllowed else { return }
        let content = UNMutableNotificationContent()
        content.title = resortName.map { "Your day at \($0)" } ?? "Your ski day"
        content.body = "\(runs) \(runs == 1 ? "run" : "runs") · \(UnitFormatter.verticalDrop(verticalM)) recorded."
        content.userInfo = ["kind": Self.summaryKind]
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: Self.summaryDelayS, repeats: false)
        await add(UNNotificationRequest(
            identifier: "\(Self.summaryKind).\(day ?? "today")", content: content, trigger: trigger
        ))
    }

    /// A signed-out or deleted account's day summary must not arrive once it is gone.
    func forgetDaySummaries() async {
        let center = UNUserNotificationCenter.current()
        let pending = await center.pendingNotificationRequests().map(\.identifier)
        let delivered = await center.deliveredNotifications().map(\.request.identifier)
        let isSummary: (String) -> Bool = { $0.hasPrefix(Self.summaryKind) }
        center.removePendingNotificationRequests(withIdentifiers: pending.filter(isSummary))
        center.removeDeliveredNotifications(withIdentifiers: delivered.filter(isSummary))
    }

    private func add(_ request: UNNotificationRequest) async {
        do {
            try await UNUserNotificationCenter.current().add(request)
        } catch {
            // Nothing to show: the toast and the history already say it.
        }
    }
}

// MARK: Background time

/// UIKit's background task behind `BackgroundGrace` (M4): the save that starts
/// as the phone locks gets the half minute or so iOS allows to finish.
nonisolated struct BackgroundTaskGrace: BackgroundGrace {
    func hold<Value: Sendable>(_ name: String, _ work: @Sendable () async -> Value) async -> Value {
        let task = await BackgroundTask(name)
        let value = await work()
        await task.end()
        return value
    }
}

/// One `beginBackgroundTask`, ended once: by the work finishing or by iOS
/// running out of time first.
@MainActor
final class BackgroundTask {
    private var identifier = UIBackgroundTaskIdentifier.invalid

    init(_ name: String) {
        identifier = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
            MainActor.assumeIsolated { self?.end() }
        }
    }

    func end() {
        guard identifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(identifier)
        identifier = .invalid
    }
}
