//
//  RouteChoreographer.swift
//  PowderMeet
//
//  Arrival celebration (pin bloom + chime + double haptic) fired when the
//  user reaches the meeting point. The prior `playShowRoutes` timeline was
//  removed — route reveal is owned end-to-end by MountainMapView's
//  CADisplayLink trim animation + `frameRoutesForMeetupOverview()`.
//

import Foundation

@MainActor
final class RouteChoreographer {
    struct Collaborators {
        let haptics: HapticService
        let audio: AudioService
        let meetingBloom: @MainActor () -> Void
    }

    private let collaborators: Collaborators
    private var currentTask: Task<Void, Never>?

    init(_ collaborators: Collaborators) {
        self.collaborators = collaborators
    }

    /// Play the arrival celebration (pin bloom + double haptic + chime).
    func playArrival() {
        cancel()
        let timeline = AnimationTimeline(name: "arrival", beats: arrivalBeats())
        currentTask = Task { @MainActor [timeline] in
            await timeline.run(on: ContinuousClock())
        }
    }

    func cancel() {
        currentTask?.cancel()
        currentTask = nil
    }

    private func arrivalBeats() -> [Beat] {
        let c = collaborators
        return [
            .at(.zero, "pin.bloomStart") { c.meetingBloom() },
            .at(.zero, "chime")          { c.audio.play(.arrivalBell) },
            .at(.zero, "haptic.double")  { c.haptics.play(.arrivalDouble) }
        ]
    }
}
