import AppCore
import Foundation
import MapScene
import MapboxAdapter
import MeetSolver
import MountainCore
import Observation
import PMLogging
import PowderMeetAPI

// MARK: Meet

/// An optional lap for the skier who would otherwise wait at the meeting point.
nonisolated struct LapSuggestion: Sendable, Hashable {
    /// The loop from the meeting point back to it.
    var route: Route
    /// From leaving the meeting point to being back.
    var durationS: Double
    /// Time to spare before the partner arrives, as the solver planned it.
    var plannedMarginS: Double
}

/// One meet on this phone. `state` mirrors `MeetSession.state`.
@Observable
final class MeetModel {
    let partnerID: UUID
    var state: MeetSession.State

    private let session: MeetSession
    /// Haptics, the spoken prompt and the arrival bell while the meet is active.
    private let feedback: NavigationFeedback

    /// The lap the solver suggested for this phone's skier in the option that
    /// was sent. The meet row does not carry it, so only the proposer's phone
    /// has one, and it is gone if the app restarts mid-meet.
    private(set) var lapSuggestion: LapSuggestion?
    /// The user chose to follow the lap: the map draws it in place of the
    /// route to the meeting point. Set through `ResortModel.followLap`.
    var isFollowingLap = false
    /// This skier has reached the meeting point at some time in this meet, so
    /// a lap starts and ends there and their own time to it no longer counts.
    private var hasReachedMeetingPoint = false

    init(
        session: MeetSession, state: MeetSession.State,
        feedback: NavigationFeedback = NavigationFeedback()
    ) {
        self.session = session
        self.state = state
        self.feedback = feedback
        partnerID = session.partnerID
        noteLap(in: state)
    }

    /// `ResortModel` calls this with every state. It remembers the picked
    /// option's lap while proposing, keeps it through the sent and active meet
    /// while it stands (`reviewLap`, `dropLap`), drops it with the meet, and
    /// plays the navigation cues.
    func noteLap(in state: MeetSession.State) {
        feedback.observe(state)
        switch state {
        case .proposing(let proposing):
            lapSuggestion = nil
            if let options = proposing.options?.options, let picked = proposing.picked,
               options.indices.contains(picked) {
                let option = options[picked]
                if let lap = option.lapWhileWaiting, lap.skierID == option.routes.0.skierID {
                    lapSuggestion = LapSuggestion(
                        route: lap,
                        durationS: max(0, lap.eta.meanS - (lap.legs.first?.enterS ?? option.routes.0.eta.meanS)),
                        plannedMarginS: option.routes.1.eta.meanS - lap.eta.meanS
                    )
                }
            }
        case .proposed:
            break
        case .active(let active):
            if active.arrived { hasReachedMeetingPoint = true }
            // A lap that no longer fits goes back to the meeting route by
            // itself: its box, and the button that would undo it, are gone.
            if isFollowingLap, lapMarginS(in: active) == nil { isFollowingLap = false }
        case .incoming, .ended:
            dropLap()
        }
    }

    /// The lap is never re-costed (06-SOLVER section 3), so it is offered only
    /// while it still stands: a closure on any of its runs or lifts drops it.
    func reviewLap(status: ResortStatus?, in bundle: ResortBundle) {
        guard let lap = lapSuggestion, let status else { return }
        let closed = lap.route.legs.contains { leg in
            bundle.graph.edge(leg.edgeID)?.group.map { status.groups[$0] == .closed } ?? false
        }
        if closed { dropLap() }
    }

    /// The lap was found under limits the skier has since changed.
    func dropLap() {
        lapSuggestion = nil
        isFollowingLap = false
        hasReachedMeetingPoint = false
    }

    /// The time the lap leaves to spare before the partner arrives, on the
    /// live estimates (the planned margin until the partner reports one), or
    /// nil once it no longer fits: no lap, the partner has arrived, or under
    /// a minute would be left.
    func lapMarginS(in active: MeetSession.Active) -> Double? {
        guard let lap = lapSuggestion else { return nil }
        if case .arrived = active.partner?.state { return nil }
        let myRemainingS = hasReachedMeetingPoint ? 0 : (active.navigation?.eta.meanS ?? 0)
        let marginS = active.partner?.etaS.map { Double($0) - myRemainingS - lap.durationS } ?? lap.plannedMarginS
        return marginS >= 60 ? marginS : nil
    }

    // Intents.
    func pick(option index: Int) { session.send(.optionPicked(index)) }
    /// Ask for a meeting place by name (nil takes it back): it joins the options.
    func request(place: RendezvousID?) { session.send(.placeRequested(place)) }
    func sendProposal() { session.send(.sent) }
    /// Re-solve to replace the sent proposal; sending the new pick supersedes it.
    func changeProposal() { session.send(.changeProposal) }
    func accept() { session.send(.accepted) }
    func decline() { session.send(.declined(.declinedByUser)) }
    /// Backs out of proposing (back to the sent proposal when replacing one),
    /// cancels an outgoing proposal, declines an incoming one or ends an active
    /// meet, whichever applies.
    func end() { session.send(.userEnded) }
    func retrySolve() { session.send(.retry) }
}
