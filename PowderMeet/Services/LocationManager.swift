//
//  LocationManager.swift
//  PowderMeet
//
//  CoreLocation wrapper. Background updates are gated on an explicit "ski
//  session" — when the user is at a resort and sharing live presence. Outside
//  a session we only run while the app is foreground (When-In-Use).
//

import Foundation
import CoreLocation
import Observation

@Observable
final class LocationManager: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()

    var currentLocation: CLLocationCoordinate2D?
    var currentAccuracy: CLLocationAccuracy = -1
    /// Instantaneous ground speed in m/s from the most recent fix, or `-1` if
    /// unknown (iOS sometimes reports `-1` for low-quality fixes). Exposed so
    /// `RealtimeLocationService` can shorten the broadcast cadence when moving
    /// fast — crisp friend-dot updates on a run, battery-friendly ticks at rest.
    var currentSpeed: CLLocationSpeed = -1
    /// Most recent altitude in meters, or nil if unavailable. Needed by
    /// `LiveRunRecorder` to do run/lift segmentation (lift = sustained
    /// elevation gain). Surface here rather than re-deriving from a
    /// CLLocation — the recorder already lives on the main actor and the
    /// CLLocation object isn't piped past this delegate.
    var currentAltitude: Double?
    /// Monotonically increases with every accepted fix. SwiftUI `onChange`
    /// on a `CLLocationCoordinate2D?` (or even on `.latitude` alone) misses
    /// pure-longitude moves and quantised fixes that land on the same
    /// `Double` bit-pattern twice. Keying `onChange` off this counter
    /// guarantees every fix triggers downstream handlers.
    var fixGeneration: UInt64 = 0

    /// Sticky graph node for GPS (`MountainGraph.nearestNodeSticky`). Cleared when
    /// the user picks a manual test node or changes resort. Keeps meet/profile/map
    /// labels aligned instead of flipping between adjacent trails on every fix.
    var gpsStickyGraphNodeId: String?
    var authorizationStatus: CLAuthorizationStatus = .notDetermined
    var isAuthorized: Bool {
        authorizationStatus == .authorizedWhenInUse || authorizationStatus == .authorizedAlways
    }
    var hasAlwaysPermission: Bool {
        authorizationStatus == .authorizedAlways
    }

    /// Fires exactly once per `startUpdating()` call, on the first valid GPS fix.
    /// Used by RealtimeLocationService to trigger an immediate broadcast instead
    /// of waiting for the periodic 5s tick — first-friend visibility goes from
    /// up-to-5s to milliseconds.
    var onFirstFix: (() -> Void)?
    private var firstFixDelivered = false

    /// True while a "ski session" is active — the user is at a resort and
    /// sharing live presence. Background location is enabled only during a
    /// session so we don't drain battery when the app is closed at home.
    private(set) var sessionActive = false

    private let distanceFilterDefault: CLLocationDistance = 10
    private let distanceFilterLiveSession: CLLocationDistance = 5

    /// Battery throttle. Read by RealtimeLocationService to stretch the
    /// broadcast / table-upsert cadence when the phone is low or hot.
    /// `.normal` is the default. `.lowPower` corresponds to either iOS
    /// Low Power Mode being enabled OR thermal state >= .serious; both
    /// are treated equivalently for cadence purposes since both indicate
    /// the OS would prefer fewer wakeups. `.critical` is thermal == .critical.
    enum PowerProfile: Equatable {
        case normal
        case lowPower
        case critical
    }
    private(set) var powerProfile: PowerProfile = .normal

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = distanceFilterDefault
        // Don't pause during a ski session — Apple's auto-pause heuristics
        // think a stationary user on a long chairlift is "stopped" and pause
        // updates, which kills friends' visibility.
        manager.pausesLocationUpdatesAutomatically = false
        authorizationStatus = manager.authorizationStatus

        // Observe power-state and thermal-state changes so a phone going
        // into Low Power Mode mid-session (or getting too hot in the cold-
        // sun pocket) re-applies the right accuracy + filter without
        // forcing the user to restart the session.
        let nc = NotificationCenter.default
        nc.addObserver(
            self, selector: #selector(powerStateChanged),
            name: .NSProcessInfoPowerStateDidChange, object: nil
        )
        nc.addObserver(
            self, selector: #selector(powerStateChanged),
            name: ProcessInfo.thermalStateDidChangeNotification, object: nil
        )
        // Compute initial profile so getters report correctly even before
        // the first session start.
        recomputePowerProfile()
    }

    /// Resolve the active `PowerProfile` from current OS conditions and,
    /// if a session is active, immediately adjust the live CLLocationManager
    /// accuracy / distanceFilter to match. Idempotent — safe to call from
    /// any thread (CLLocationManager mutations hop to main).
    private func recomputePowerProfile() {
        let info = ProcessInfo.processInfo
        let thermal = info.thermalState
        let lowPower = info.isLowPowerModeEnabled
        let next: PowerProfile
        if thermal == .critical {
            next = .critical
        } else if lowPower || thermal == .serious {
            next = .lowPower
        } else {
            next = .normal
        }
        guard next != powerProfile else { return }
        powerProfile = next
        // Only adjust live CLLocationManager if a session is in flight.
        // Outside a session we don't bother — session start re-applies
        // the right accuracy via `applyPowerProfileToManager()`.
        if sessionActive {
            applyPowerProfileToManager()
        }
    }

    @objc private func powerStateChanged() {
        // Notifications can fire on a background thread; bounce to main
        // since CLLocationManager mutations require it.
        Task { @MainActor in self.recomputePowerProfile() }
    }

    /// Push the current `powerProfile`'s tuning into CLLocationManager.
    /// Called from `startSession` and from `recomputePowerProfile` when
    /// the profile transitions while a session is live.
    private func applyPowerProfileToManager() {
        switch powerProfile {
        case .normal:
            manager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
            manager.distanceFilter = distanceFilterLiveSession
        case .lowPower:
            // Drop from navigation-grade to best-civilian, widen the
            // movement filter so fewer fixes wake the chip. Friend dots
            // still update every ~15 m of movement, which on a ski run
            // is sub-second.
            manager.desiredAccuracy = kCLLocationAccuracyBest
            manager.distanceFilter = 15
        case .critical:
            // Phone is overheating — back off hard. Friend visibility
            // becomes coarse (rare in practice; thermal .critical is
            // sustained-high-load territory) but the alternative is the
            // OS killing the app.
            manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
            manager.distanceFilter = 30
        }
    }

    func requestPermission() {
        manager.requestWhenInUseAuthorization()
    }

    /// Escalate to Always after the user has granted When-In-Use. Apple requires
    /// the two-step flow — Always cannot be requested cold.
    func requestAlwaysPermission() {
        guard authorizationStatus == .authorizedWhenInUse else { return }
        manager.requestAlwaysAuthorization()
    }

    /// Begin a foreground-only update session.
    func startUpdating() {
        guard isAuthorized else { return }
        firstFixDelivered = false
        manager.startUpdatingLocation()
    }

    /// Begin a background-eligible ski session. Requires Always permission to
    /// actually keep delivering updates with the screen locked. Without Always,
    /// this still starts foreground updates but background delivery is silently
    /// no-op'd by the OS.
    func startSession() {
        guard isAuthorized else { return }
        sessionActive = true
        firstFixDelivered = false
        // Tighter filter + accuracy while sharing live presence — main
        // product is real-time friend positions. The exact tuning depends
        // on the active power profile (Low Power Mode / thermal state) so
        // we route through `applyPowerProfileToManager`. On a normal
        // phone this resolves to the same nav-grade + 5 m it always was.
        recomputePowerProfile()
        applyPowerProfileToManager()
        if hasAlwaysPermission {
            manager.allowsBackgroundLocationUpdates = true
            #if os(iOS)
            manager.showsBackgroundLocationIndicator = true
            #endif
        }
        manager.startUpdatingLocation()
    }

    func endSession() {
        sessionActive = false
        manager.distanceFilter = distanceFilterDefault
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.allowsBackgroundLocationUpdates = false
        #if os(iOS)
        manager.showsBackgroundLocationIndicator = false
        #endif
        manager.stopUpdatingLocation()
    }

    func stopUpdating() {
        if sessionActive {
            // Don't kill background updates if a session is intentionally live.
            return
        }
        manager.stopUpdatingLocation()
    }

    // MARK: - CLLocationManagerDelegate

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        // Accept all valid fixes — the 100m gate dropped legitimate post-wake
        // fixes that sharpen within seconds. Consumers should weight by
        // accuracy rather than gate, so route snapping can still ignore the
        // worst readings while map dots remain visible with an accuracy halo.
        guard location.horizontalAccuracy >= 0 else { return }
        currentLocation = location.coordinate
        currentAccuracy = location.horizontalAccuracy
        currentSpeed = location.speed
        // Altitude: CL reports `verticalAccuracy < 0` when invalid; in
        // that case we keep the previous value rather than poison the
        // recorder buffer with -∞ junk fixes.
        if location.verticalAccuracy >= 0 {
            currentAltitude = location.altitude
        }
        fixGeneration &+= 1
        if !firstFixDelivered {
            firstFixDelivered = true
            onFirstFix?()
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        authorizationStatus = manager.authorizationStatus
        if isAuthorized {
            manager.startUpdatingLocation()
            if sessionActive, hasAlwaysPermission {
                manager.allowsBackgroundLocationUpdates = true
                #if os(iOS)
                manager.showsBackgroundLocationIndicator = true
                #endif
            }
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        print("[LocationManager] error: \(error.localizedDescription)")
    }
}
