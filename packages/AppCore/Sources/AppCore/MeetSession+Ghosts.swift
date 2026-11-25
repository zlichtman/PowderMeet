import Foundation
import MeetSolver
import MountainCore
import PMLogging
import PowderMeetAPI

extension MeetSession {
    // MARK: Ghosts

    /// Rebuilds the ghost plan from the active state: the user's route from the
    /// last progress along it, the partner's from their last routed presence.
    /// Asks for a newer partner route when one is due.
    func updateGhosts() {
        var plan: GhostPlan?
        if case .active(let active) = state {
            var tracks: [GhostPlan.Track] = []
            // A route used up (nearly there) leaves nothing ahead to show.
            if let navigation = active.navigation, !active.arrived, navigation.progress.state != .arrived {
                if ownProjection?.route != navigation.route {
                    ownProjection = RouteProjection(route: navigation.route, graph: bundle.graph)
                }
                if let projection = ownProjection {
                    tracks.append(GhostPlan.Track(
                        userID: me, isSelf: true, projection: projection,
                        anchor: navigation.progress.lastFixAt ?? lastFix?.capturedAt ?? deps.clock.now,
                        anchorRouteTimeS: projection.routeTime(
                            legIndex: navigation.progress.legIndex, fraction: navigation.progress.fractionAlongLeg
                        )
                    ))
                }
            }
            if let partnerTrack, active.partner?.state != .arrived { tracks.append(partnerTrack) }
            plan = tracks.isEmpty ? nil : GhostPlan(tracks: tracks)
            requestPartnerGhost(to: active.meet.rendezvousID)
        } else {
            ownProjection = nil
            partnerTrack = nil
            partnerGhostFrom = nil
        }
        guard plan != ghostPlan else { return }
        ghostPlan = plan
        ghostChanges.send(plan)
    }

    /// Solves the partner's route from their last presence fix, as the meet
    /// options do, off the actor. Their profile and pace are read again once
    /// the copy is older than `partnerRefreshS`.
    func requestPartnerGhost(to rendezvous: RendezvousID) {
        guard let presence = partnerPresence,
              partnerGhostFrom.map({ presence.capturedAt.timeIntervalSince($0) >= Self.partnerGhostRefreshS }) ?? true,
              let origin = OriginResolver.origin(for: presence.fix, in: bundle) else { return }
        partnerGhostFrom = presence.capturedAt
        refreshPartnerIfStale()
        let backend = deps.backend, log = deps.log, inbox = inbox, inputs = solveInputs
        let partnerID = partnerID, known = partner, anchor = presence.capturedAt
        bag.start("ghost-partner") {
            var people = known
            if people == nil {
                do {
                    guard let row = try await backend.profile(id: partnerID) else { return }
                    people = (SkierProfile(row), try await backend.paceModel(owner: partnerID).flatMap(PaceModel.init))
                } catch {
                    if !Task.isCancelled { log.info(.meet, "partner unavailable for the ghost: \(error)") }
                    return
                }
            }
            guard let people else { return }
            let skier = SkierInput(id: partnerID, profile: people.profile, pace: people.pace, origin: origin)
            guard case .success(let route) = await Solving.route(skier, to: rendezvous, inputs),
                  !Task.isCancelled else { return }
            inbox.yield(.partnerRouted(route, anchor: anchor, profile: people.profile, pace: people.pace))
        }
    }
}
