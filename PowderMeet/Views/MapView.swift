//
//  MapView.swift
//  PowderMeet
//
//  Main map tab — hosts the Mapbox 3D terrain view with route overlays and meeting point markers.


import SwiftUI
import CoreLocation

struct ResortMapScreen: View {
    @Environment(ResortDataManager.self) private var resortManager
    @Binding var selectedTrailEdgeId: String?
    // Map-area resort-load gate. Covers the map (and overlays the
    // bottom edge cards) but NOT the tab bar, resort bar, or page
    // header — those stay tappable so the user can navigate away
    // while a slow first-time mountain build is in progress.
    @State private var showLoadingOverlay = true
    @State private var loadingOverlayTask: Task<Void, Never>?
    @State private var loadingForResortId: String?
    @State private var earliestDismissAt: Date = .distantPast
    var meetingResult: MeetingResult?
    var userLocation: CLLocationCoordinate2D?
    var friendLocations: [UUID: RealtimeLocationService.FriendLocation] = [:]
    var replayPositions: [UUID: CLLocationCoordinate2D] = [:]
    var replayTrails: [UUID: [CLLocationCoordinate2D]] = [:]
    var routeAnimationTrigger: Int = 0
    var isActiveMeetup: Bool = false
    /// Other participant in an active meet — narrows `friendLocations` for camera fit.
    var meetupPartnerId: UUID? = nil
    var ghostPositions: [UUID: [(coordinate: CLLocationCoordinate2D, label: String)]] = [:]
    var selectedTime: Date = .now
    /// True while the user drags the timeline thumb. MountainMapView uses
    /// this to coarsen the per-minute sun exposure bucket and to skip
    /// fog/sky recomputes on every tick — full fidelity snaps in on release.
    var isScrubbingTimeline: Bool = false
    var resortLatitude: Double?
    var resortLongitude: Double?
    var temperatureC: Double = -2
    var cloudCoverPercent: Int = 0
    var snowfallCmPerHour: Double = 0
    var windSpeedKph: Double = 0
    var windDirectionDeg: Int = 0
    var visibilityKm: Double = 10
    var mapBridge: MapBridge?
    /// False when the user has switched away from the Map tab. Pauses all
    /// CADisplayLink animations inside MountainMapView until the tab is
    /// foregrounded again — meaningful battery + frame-rate win on lower
    /// devices where the gondola tick was bleeding 10Hz of GPU work.
    var isMapVisible: Bool = true
    var mapFriendLayerClock: Int = 0
    var friendSignalQualities: [UUID: FriendSignalQuality] = [:]

    var body: some View {
        ZStack(alignment: .bottom) {
            HUDTheme.mapBackground
                .ignoresSafeArea()

            MountainMapView(
                resortEntry: resortManager.currentEntry,
                graph: resortManager.currentGraph,
                routeA: meetingResult?.pathA,
                routeB: meetingResult?.pathB,
                meetingNode: meetingResult?.meetingNode,
                userLocation: userLocation,
                friendLocations: friendLocations,
                replayPositions: replayPositions,
                replayTrails: replayTrails,
                selectedEdgeId: selectedTrailEdgeId,
                onTrailTapped: { edgeId in
                    // Ignore trail taps while an active meetup is running —
                    // the active-meetup nav card occupies the same slot as
                    // the edge info card, and accepting a tap here would
                    // silently update hidden state that reappeared the
                    // moment the meetup ended.
                    guard !isActiveMeetup else { return }
                    selectedTrailEdgeId = edgeId
                },
                routeAnimationTrigger: routeAnimationTrigger,
                isActiveMeetup: isActiveMeetup,
                meetupPartnerId: meetupPartnerId,
                ghostPositions: ghostPositions,
                selectedTime: selectedTime,
                isScrubbingTimeline: isScrubbingTimeline,
                resortLatitude: resortLatitude,
                resortLongitude: resortLongitude,
                temperatureC: temperatureC,
                cloudCoverPercent: cloudCoverPercent,
                snowfallCmPerHour: snowfallCmPerHour,
                windSpeedKph: windSpeedKph,
                windDirectionDeg: windDirectionDeg,
                visibilityKm: visibilityKm,
                mapBridge: mapBridge,
                isMapVisible: isMapVisible,
                mapFriendLayerClock: mapFriendLayerClock,
                friendSignalQualities: friendSignalQualities
            )

            if showLoadingOverlay {
                ResortLoadingView(resortName: resortManager.currentEntry?.name)
                    .transition(.opacity)
                    .zIndex(10)
            }

            if let error = resortManager.error {
                errorOverlay(error)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 120)
            }
        }
        .onAppear {
            if resortManager.currentGraph == nil {
                raiseOverlay(for: resortManager.currentEntry?.id)
            } else {
                showLoadingOverlay = false
            }
        }
        .onChange(of: resortManager.currentEntry?.id) { _, newId in
            raiseOverlay(for: newId)
        }
        .onChange(of: resortManager.currentGraph?.fingerprint) { _, _ in
            tryDismissOverlay()
        }
    }

    /// Raise the map-area gate for a resort id; stamp the min-hold
    /// deadline so a quick resort swap can't dismiss before the new
    /// graph commits.
    private func raiseOverlay(for resortId: String?) {
        loadingOverlayTask?.cancel()
        loadingForResortId = resortId
        earliestDismissAt = Date().addingTimeInterval(0.45)
        if !showLoadingOverlay {
            showLoadingOverlay = true
        }
        if resortManager.currentGraph != nil {
            tryDismissOverlay()
        }
    }

    private func tryDismissOverlay() {
        guard showLoadingOverlay,
              resortManager.currentGraph != nil,
              loadingForResortId == resortManager.currentEntry?.id else { return }
        loadingOverlayTask?.cancel()
        let delay = max(0, earliestDismissAt.timeIntervalSinceNow)
        loadingOverlayTask = Task { @MainActor in
            if delay > 0 {
                try? await Task.sleep(for: .seconds(delay))
            }
            guard !Task.isCancelled,
                  resortManager.currentGraph != nil,
                  loadingForResortId == resortManager.currentEntry?.id else { return }
            withAnimation(.easeOut(duration: 0.25)) {
                showLoadingOverlay = false
            }
        }
    }

    private func errorOverlay(_ message: String) -> some View {
        VStack(spacing: 12) {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("MAP LOAD ERROR")
                        .font(HUDTheme.hud(12, .bold))
                        .foregroundColor(HUDTheme.accent)
                        .tracking(1)

                    Text(message)
                        .font(HUDTheme.hud(11))
                        .foregroundColor(HUDTheme.secondaryText)
                        .multilineTextAlignment(.leading)
                        .lineLimit(4)
                }

                Spacer(minLength: 0)

                // Close (×) — dismiss without retrying. Without this the
                // user was stuck with the error banner until the next
                // successful load, even for transient failures they'd
                // already seen.
                Button {
                    resortManager.clearError()
                } label: {
                    Image(systemName: "xmark")
                        .font(HUDTheme.hud(11, .bold, monospaced: false))
                        .foregroundColor(HUDTheme.secondaryText)
                        .padding(6)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss error")
            }

            // Retry: re-run loadResort for the current entry. On success,
            // `loadResort` clears `errorMessage` itself (see the reset at
            // the top of the cold path and the new cache-hit clears).
            if let entry = resortManager.currentEntry {
                Button {
                    resortManager.clearError()
                    Task { await resortManager.loadResort(entry) }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.clockwise")
                            .font(HUDTheme.hud(11, .bold, monospaced: false))
                        Text("RETRY")
                            .font(HUDTheme.hud(11, .bold))
                            .tracking(1.5)
                    }
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(HUDTheme.accent)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(HUDTheme.cardBackground.opacity(0.94))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(HUDTheme.cardBorder, lineWidth: 0.8)
                )
        )
    }
}

/// Opaque resort-load gate. The bottom resort bar already shows the
/// spinner + amber state-dot for "is loading," so the main screen
/// doesn't repeat it — just resort name in red mono with a cycling
/// status caption underneath. Cleaner read; no duplicated affordance.
struct ResortLoadingView: View {
    var resortName: String?

    @State private var statusPhase: Int = 0

    /// Caption text, cycled every 900ms while the gate is up. Honest
    /// descriptions of what the cold-load pipeline goes through; not
    /// wired to actual phase timing but reads as live.
    private static let statusFrames = [
        "FETCHING TERRAIN",
        "BUILDING GRAPH",
        "LOADING TRAIL DATA",
        "ENRICHING CONDITIONS",
    ]

    var body: some View {
        ZStack {
            HUDTheme.mapBackground.ignoresSafeArea()

            VStack(spacing: 14) {
                if let resortName, !resortName.isEmpty {
                    Text(resortName.uppercased())
                        .font(HUDTheme.hud(18, .bold))
                        .foregroundColor(HUDTheme.accent)
                        .tracking(2.5)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .minimumScaleFactor(0.7)
                        .padding(.horizontal, 32)
                }

                Text(Self.statusFrames[statusPhase])
                    .font(HUDTheme.hud(10, .semibold))
                    .foregroundColor(HUDTheme.secondaryText)
                    .tracking(2)
                    .id(statusPhase) // forces fade transition on swap
                    .transition(.opacity)
            }
        }
        .onAppear {
            Task { @MainActor in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(900))
                    withAnimation(.easeInOut(duration: 0.3)) {
                        statusPhase = (statusPhase + 1) % Self.statusFrames.count
                    }
                }
            }
        }
    }
}

#Preview {
    ResortMapScreen(selectedTrailEdgeId: .constant(nil), meetingResult: nil)
        .environment(ResortDataManager())
}
