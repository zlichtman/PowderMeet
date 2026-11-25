#if DEBUG
import AppCore
import Foundation
import MeetSolver
import MountainCore
import PowderMeetAPI

/// Opens the signed-in app straight into one state of the context sheet, on
/// the live backend through developer testing, for looking at a screen
/// without tapping there. Debug builds only; it calls only the intents a tap
/// would.
///
/// - `-openResort <id>`: the mountain to open.
/// - `-mapCard run | lift | place | goto`: a run, lift or place tapped, or a
///   solo route to a run (teleporting this phone onto the mountain first).
/// - `-meetState options | sent | active | ended | friend`: this phone teleported to a
///   lift base, Dev 1 placed at a lodge, then the meeting options
///   for them, the request sent, the meet under way (Dev 1
///   accepts by itself), or ended (both reach the meeting point and the meet
///   completes by itself); `friend` only puts the friend on the
///   mountain, with the camera on the place `-lookAt <name>` names.
/// - `-stage green | blue | steps | tucked | ghosts | panel | nexttrail | run:<name>` after that, a few
///   seconds later: the skill level dropped to green (or to blue: advanced
///   pace, nothing harder than blue) while the options show (they re-solve),
///   the step list opened, the directions put away, the timeline scrubbed
///   ahead to halfway to the meeting, the profile panel opened, or the card
///   of the next run on the route opened (or of the run named, with the
///   camera pulled back to the route).
/// - `-placeMe coordinate:<lat>,<lon>`: an exact start for a repeatable capture.
/// - `-placeMe <name>`, `-placeFriend <name>`: the places (by name, any part
///   of it) this phone and Dev 1 stand at, instead of the first
///   lift base and the first lodge.
/// - `-meetAt <name>`: the option whose meeting point holds `name` is the
///   one shown (options) or sent (sent, active), instead of the best.
enum DebugScript {
    private enum Goal: String {
        case options, sent, active, ended, friend
    }

    private enum Card: String {
        case run, lift, place, goto
    }

    static func run(on model: AppModel, developer: DeveloperModel?, arguments: [String] = ProcessInfo.processInfo.arguments) {
        let resortID = value(after: "-openResort", in: arguments)
        let goal = value(after: "-meetState", in: arguments).flatMap(Goal.init(rawValue:))
        let card = value(after: "-mapCard", in: arguments).flatMap(Card.init(rawValue:))
        guard resortID != nil || goal != nil || card != nil else { return }
        Task {
            guard await wait(seconds: 30, until: { model.profile != nil }) else { return }
            // A start on the cached profile may have missed the network; ask
            // again, as coming back to the foreground does.
            model.sceneBecameActive()
            if let resortID, model.resort?.resortID != resortID {
                model.session.send(.resortSelected(resortID))
            }
            guard await wait(seconds: 60, until: { model.resort?.bundle != nil }),
                  let resort = model.resort, let bundle = resort.bundle else { return }
            if goal != nil || card == .goto, let developer {
                teleport(developer, in: bundle, to: value(after: "-placeMe", in: arguments))
            }
            if let goal, let developer {
                await drive(
                    model, developer: developer, resort: resort, bundle: bundle, to: goal,
                    friendAt: value(after: "-placeFriend", in: arguments), meAt: value(after: "-placeMe", in: arguments),
                    meetAt: value(after: "-meetAt", in: arguments))
            }
            if let card { await open(card, model: model, resort: resort, bundle: bundle) }
            if let step = value(after: "-stage", in: arguments) { await stage(step, model: model, resort: resort) }
        }
    }

    private static func value(after flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else {
            return nil
        }
        return arguments[index + 1]
    }

    /// This phone onto the mountain: the named place, or the bottom of the
    /// first named lift.
    private static func teleport(_ developer: DeveloperModel, in bundle: ResortBundle, to name: String?) {
        if let name, name.hasPrefix("coordinate:") {
            let values = name.dropFirst(11).split(separator: ",").compactMap { Double($0) }
            if values.count == 2 {
                developer.place(.me, at: Coordinate(lon: values[1], lat: values[0]))
            }
            return
        }
        if let name, name.hasPrefix("run:"), let start = runStart(String(name.dropFirst(4)), in: bundle) {
            developer.place(.me, at: start)
            return
        }
        guard let base = place(named: name, in: bundle) ?? bundle.rendezvous.first(where: { $0.kind == .liftBase }),
              let node = bundle.graph.nodes[base.nodeID] else { return }
        developer.place(.me, at: node.coordinate)
    }

    /// `run:<name>`: the end of the run's first stretch, so the skier stands
    /// on that run rather than at a junction it shares with others.
    private static func runStart(_ name: String, in bundle: ResortBundle) -> Coordinate? {
        guard let group = bundle.groups.first(where: { $0.kind == .trail && $0.name.localizedCaseInsensitiveContains(name) }),
              let first = group.edgeIDs.first,
              let edge = bundle.graph.edges.first(where: { $0.id == first }) else { return nil }
        return bundle.graph.nodes[edge.to]?.coordinate
    }

    /// The first place whose name holds `name`, ignoring case.
    private static func place(named name: String?, in bundle: ResortBundle) -> Rendezvous? {
        guard let name, !name.isEmpty else { return nil }
        return bundle.rendezvous.first { $0.name.localizedCaseInsensitiveContains(name) }
    }

    private static func drive(
        _ model: AppModel, developer: DeveloperModel, resort: ResortModel, bundle: ResortBundle, to goal: Goal,
        friendAt name: String?, meAt myPlace: String?, meetAt meeting: String?
    ) async {
        guard let lodge = place(named: name, in: bundle) ?? lodge(in: bundle),
              let node = bundle.graph.nodes[lodge.nodeID] else { return }
        // Midday at the mountain, so lifts run whatever the hour here.
        developer.setPretendTime(minuteOfDay: 12 * 60)
        // The sandbox follows the mountain a moment after it opens.
        let friend = DeveloperSandbox.pretendFriendID
        for _ in 0..<10 where !developer.isPlaced(friend) {
            developer.place(.dev(friend), at: node.coordinate)
            _ = await wait(seconds: 1.5, until: { developer.isPlaced(friend) })
        }
        // Once the sandbox is on the mountain, this phone again where it was
        // asked to stand: a place made before then may not have held.
        teleport(developer, in: bundle, to: myPlace)
        guard await wait(seconds: 30, until: { resort.friends[friend] != nil && model.lastFix != nil }) else { return }
        model.showMap()
        // After the opening camera move, so the options' framing is not lost
        // under it.
        _ = await wait(seconds: 20, until: { resort.hasSettledFirstView })
        do { try await Task.sleep(for: .seconds(2)) } catch { return }
        if goal == .friend {
            // Only the friend on the mountain; the camera on a place if asked.
            if let look = place(named: value(after: "-lookAt", in: ProcessInfo.processInfo.arguments), in: bundle),
               let node = bundle.graph.nodes[look.nodeID] {
                resort.scene.send(.focus(node.coordinate))
            }
            return
        }
        if let meeting {
            // The options for the friend, turned to the one meeting where asked.
            resort.tapFriend(friend)
            guard await wait(seconds: 30, until: {
                if case .proposing(let proposing) = resort.meet?.state { proposing.options != nil } else { false }
            }), case .proposing(let proposing) = resort.meet?.state, let meet = resort.meet,
                let options = proposing.options?.options else { return }
            print("debug script: meeting options", options.map { option in
                bundle.rendezvous.first { $0.id == option.rendezvous }?.name ?? option.rendezvous.rawValue
            })
            let index = options.firstIndex { option in
                bundle.rendezvous.first { $0.id == option.rendezvous }?.name
                    .localizedCaseInsensitiveContains(meeting) == true
            } ?? 0
            meet.pick(option: index)
            if goal == .options {
                // The option framed once the card has risen.
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
                resort.showRouteOnMap()
                return
            }
            do { try await Task.sleep(for: .seconds(1)) } catch { return }
            meet.sendProposal()
        } else if goal == .options {
            resort.tapFriend(friend)
            do { try await Task.sleep(for: .seconds(4)) } catch { return }
            resort.showRouteOnMap()
            return
        } else {
            developer.runTestMeet(with: friend)
        }
    }

    private static func open(_ card: Card, model: AppModel, resort: ResortModel, bundle: ResortBundle) async {
        let trails = bundle.groups.filter { $0.kind == .trail && !$0.name.isEmpty && $0.difficulty != nil }
        switch card {
        case .run:
            resort.selectedGroupID = trails.first?.id
        case .lift:
            resort.selectedGroupID = bundle.groups.first { $0.kind == .lift && !$0.name.isEmpty }?.id
        case .place:
            if let place = lodge(in: bundle) { resort.handleMap(.tappedRendezvous(place.id)) }
        case .goto:
            guard await wait(seconds: 20, until: { model.lastFix != nil }),
                  let trail = trails.dropFirst(3).first else { return }
            model.goTo(.group(trail.id))
        }
    }

    private static func stage(_ step: String, model: AppModel, resort: ResortModel) async {
        // Long enough for the map to settle and the route to draw on.
        do { try await Task.sleep(for: .seconds(step == "green" || step == "blue" ? 25 : 12)) } catch { return }
        switch step {
        case "green":
            model.session.send(.profileEdited(ProfilePatch().ability("beginner").maxDifficulty("green")))
        case "blue":
            // "I'm stuck on blues" (owner, 21 Nov): the same pace, a hard limit at blue.
            model.session.send(.profileEdited(ProfilePatch().maxDifficulty("blue")))
        case "steps":
            resort.setNavigationStepsOpen(true)
        case "tucked":
            resort.setNavigationTucked(true)
        case "ghosts":
            let arrival = resort.meetArrival ?? Date().addingTimeInterval(20 * 60)
            resort.scrub(to: Date().addingTimeInterval(max(16 * 60, arrival.timeIntervalSinceNow / 2)))
        case "panel":
            model.openPanel([])
        case "nexttrail":
            // The demo's hero: the run the instruction names, its card open.
            // The step the instruction shows now, once it is a named run.
            var group: GroupID?
            _ = await wait(seconds: 30) {
                guard let meet = resort.meet, case .active(let active) = meet.state,
                      let navigation = active.navigation,
                      navigation.maneuvers.indices.contains(navigation.maneuverIndex) else { return false }
                let step = navigation.maneuvers[navigation.maneuverIndex]
                guard step.difficulty != nil, step.name != nil else { return false }
                group = step.group
                return group != nil
            }
            if let group { resort.selectedGroupID = group }
            // Pulled back, as "View route" does: both skiers, both routes
            // and the meeting point, once the card has risen.
            do { try await Task.sleep(for: .seconds(1.5)) } catch { return }
            resort.showRouteOnMap()
        case let named where named.hasPrefix("run:"):
            // That run's card open, and the camera pulled back to the route.
            let name = String(named.dropFirst(4))
            guard let bundle = resort.bundle,
                  let group = bundle.groups.first(where: { $0.kind == .trail && $0.name.localizedCaseInsensitiveContains(name) })
            else { return }
            resort.selectedGroupID = group.id
            // Framed once the card has risen; the route draws on again.
            do { try await Task.sleep(for: .seconds(3)) } catch { return }
            resort.showRouteOnMap()
        default:
            break
        }
    }

    /// A lodge with something there, or any lodge, or any place.
    private static func lodge(in bundle: ResortBundle) -> Rendezvous? {
        bundle.rendezvous.first { $0.kind == .lodge && !$0.amenities.isEmpty }
            ?? bundle.rendezvous.first { $0.kind == .lodge }
            ?? bundle.rendezvous.first
    }

    /// Polls a condition every 200 ms. False when it never held.
    private static func wait(seconds: Double, until condition: () -> Bool) async -> Bool {
        for _ in 0..<Int(seconds * 5) {
            if condition() { return true }
            do {
                try await Task.sleep(for: .milliseconds(200))
            } catch {
                return false
            }
        }
        return condition()
    }
}
#endif
