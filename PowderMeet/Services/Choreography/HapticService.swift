//
//  HapticService.swift
//  PowderMeet
//
//  Central haptic coordinator backed by CoreHaptics. Built on CHHapticEngine
//  so we can express multi-beat patterns (the arrival celebration fires
//  `.rigid + .success` 400ms apart in one continuous pattern — impossible
//  with UIImpactFeedbackGenerator since its actuator can't overlap with
//  UINotificationFeedbackGenerator on the same call-site).
//

import Foundation
import CoreHaptics
import UIKit

@MainActor
final class HapticService {
    static let shared = HapticService()

    private var engine: CHHapticEngine?
    private var engineStarted = false

    enum Signal {
        case soft            // button tap
        case rigid           // route arrival
        case success         // meeting reached
        case warning         // off-route
        case arrivalDouble   // .rigid then .success 400ms later
    }

    private init() {
        guard CHHapticEngine.capabilitiesForHardware().supportsHaptics else {
            print("[HapticService] haptics not supported on this device")
            return
        }
        do {
            engine = try CHHapticEngine()
            engine?.stoppedHandler = { [weak self] _ in
                Task { @MainActor in self?.engineStarted = false }
            }
            engine?.resetHandler = { [weak self] in
                Task { @MainActor in await self?.start() }
            }
        } catch {
            print("[HapticService] engine init failed: \(error)")
        }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleResignActive),
            name: UIApplication.willResignActiveNotification,
            object: nil
        )
    }

    @objc private func handleResignActive() {
        engine?.stop()
        engineStarted = false
    }

    deinit {
        // Defensive — singleton lives for app lifetime today, but if this
        // ever gets refactored away from `shared`, observer accumulation
        // across instances would silently double-fire on app lifecycle events.
        NotificationCenter.default.removeObserver(self)
    }

    private func start() async {
        guard let engine, !engineStarted else { return }
        do {
            try await engine.start()
            engineStarted = true
        } catch {
            print("[HapticService] engine start failed: \(error)")
        }
    }

    /// Plays the given signal. Safe to call without pre-starting the engine.
    func play(_ signal: Signal) {
        Task { @MainActor in
            await start()
            do {
                let pattern = try pattern(for: signal)
                let player = try engine?.makePlayer(with: pattern)
                try player?.start(atTime: 0)
            } catch {
                // Fall back to UIKit feedback — worse, but better than silence.
                uikitFallback(signal)
            }
        }
    }

    // MARK: - Patterns

    private func pattern(for signal: Signal) throws -> CHHapticPattern {
        let events: [CHHapticEvent]
        switch signal {
        case .soft:
            events = [transient(intensity: 0.4, sharpness: 0.3, at: 0)]
        case .rigid:
            events = [transient(intensity: 1.0, sharpness: 0.9, at: 0)]
        case .success:
            events = [
                transient(intensity: 0.6, sharpness: 0.5, at: 0),
                transient(intensity: 1.0, sharpness: 0.9, at: 0.12)
            ]
        case .warning:
            events = [
                transient(intensity: 0.8, sharpness: 0.7, at: 0),
                transient(intensity: 0.8, sharpness: 0.7, at: 0.18)
            ]
        case .arrivalDouble:
            events = [
                transient(intensity: 1.0, sharpness: 0.9, at: 0),                 // rigid
                transient(intensity: 0.6, sharpness: 0.5, at: 0.4),                // success 1
                transient(intensity: 1.0, sharpness: 0.9, at: 0.52)                // success 2
            ]
        }
        return try CHHapticPattern(events: events, parameters: [])
    }

    private func transient(intensity: Float, sharpness: Float, at time: TimeInterval) -> CHHapticEvent {
        CHHapticEvent(
            eventType: .hapticTransient,
            parameters: [
                CHHapticEventParameter(parameterID: .hapticIntensity, value: intensity),
                CHHapticEventParameter(parameterID: .hapticSharpness, value: sharpness)
            ],
            relativeTime: time
        )
    }

    // MARK: - UIKit Fallback

    private func uikitFallback(_ signal: Signal) {
        switch signal {
        case .soft:
            UIImpactFeedbackGenerator(style: .soft).impactOccurred()
        case .rigid:
            UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
        case .success:
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        case .warning:
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
        case .arrivalDouble:
            UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            }
        }
    }
}
