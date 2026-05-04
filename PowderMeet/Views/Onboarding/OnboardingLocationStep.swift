//
//  OnboardingLocationStep.swift
//  PowderMeet
//
//  Step 4: Location permission request.
//

import SwiftUI
import CoreLocation

struct OnboardingLocationStep: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var coordinator = LocationAuthCoordinator()

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "location.circle.fill")
                .font(.system(size: 56))
                .foregroundStyle(
                    statusGranted ? HUDTheme.accentGreen : HUDTheme.accent,
                    statusGranted ? HUDTheme.accentGreen.opacity(0.3) : HUDTheme.accent.opacity(0.3)
                )

            Text("LOCATION ACCESS")
                .font(.system(size: 15, weight: .bold, design: .monospaced))
                .foregroundColor(HUDTheme.primaryText)
                .tracking(2)

            Text("POWDERMEET USES YOUR LOCATION TO SHOW WHERE YOU ARE ON THE MOUNTAIN AND HELP FRIENDS FIND YOU")
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundColor(HUDTheme.secondaryText)
                .multilineTextAlignment(.center)
                .tracking(0.5)
                .lineSpacing(4)
                .padding(.horizontal, 28)

            if statusGranted {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundColor(HUDTheme.accentGreen)
                    Text("LOCATION ENABLED")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundColor(HUDTheme.accentGreen)
                        .tracking(1)
                }
                .padding(.top, 8)
            } else if coordinator.status == .denied || coordinator.status == .restricted {
                Text("LOCATION DENIED — OPEN SETTINGS TO ENABLE")
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundColor(HUDTheme.accentAmber)
                    .tracking(0.5)
            }

            Spacer()
            Spacer()
        }
        .onAppear {
            coordinator.start()
        }
        .onChange(of: scenePhase) { _, phase in
            // Still needed — covers the Settings-round-trip case where the
            // system alert wasn't the grant mechanism.
            if phase == .active {
                coordinator.refresh()
            }
        }
    }

    private var statusGranted: Bool {
        coordinator.status == .authorizedWhenInUse || coordinator.status == .authorizedAlways
    }
}

/// Bridges the async `CLLocationManagerDelegate` callback into SwiftUI state.
/// Without a delegate, permission changes triggered by the in-app system
/// alert were invisible to the view — it only picked them up when scenePhase
/// flipped, which doesn't happen when the alert is dismissed. This class
/// owns the manager + mirrors `authorizationStatus` into an `@Observable`
/// field that the SwiftUI view tracks.
@MainActor @Observable
final class LocationAuthCoordinator: NSObject, CLLocationManagerDelegate {
    var status: CLAuthorizationStatus = .notDetermined
    private let manager = CLLocationManager()

    override init() {
        super.init()
        manager.delegate = self
        status = manager.authorizationStatus
    }

    /// Request on first appearance. Idempotent — subsequent calls no-op if
    /// the OS has already recorded an answer.
    func start() {
        status = manager.authorizationStatus
        if status == .notDetermined {
            manager.requestWhenInUseAuthorization()
        }
    }

    /// Called from the scenePhase refresh path (Settings round-trip).
    func refresh() {
        status = manager.authorizationStatus
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let newStatus = manager.authorizationStatus
        Task { @MainActor in
            self.status = newStatus
        }
    }
}
