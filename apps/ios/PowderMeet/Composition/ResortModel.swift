import AppCore
import Foundation
import MapScene
import MapboxAdapter
import MeetSolver
import MountainCore
import Observation
import PMLogging
import PowderMeetAPI

// MARK: Resort

/// What a tap on the map opened a card for: a place (meeting point or
/// amenity). A friend tapped opens the meeting options, or their card while
/// another meet is under way (`ResortModel.onFriendCard`).
nonisolated enum MapCard: Sendable, Hashable {
    case rendezvous(RendezvousID)
}

/// Where a solo "Go to" route leads: a run's top, a lift's bottom station, or
/// a place.
nonisolated enum GoToDestination: Sendable, Hashable {
    case group(GroupID)
    case place(RendezvousID)
}

/// A solo "Go to" route from a run, lift or place card (`GoToPlanner`).
nonisolated enum GoToState: Sendable, Hashable {
    case solving(GoToDestination)
    case ready(GoToPlanner.Plan)
    case failed(GoToDestination, GoToPlanner.Failure)

    var destination: GoToDestination {
        switch self {
        case .solving(let destination), .failed(let destination, _): destination
        case .ready(let plan): plan.target.group.map(GoToDestination.group) ?? .place(plan.target.rendezvous)
        }
    }
}

/// What the context sheet over the map shows: one thing at a time, the first
/// that applies (`specs/13-APP-MAP.md` section 2).
nonisolated enum ContextCard: Sendable, Hashable {
    /// The meet under way, or the one that has just ended.
    case meet
    case incoming
    case sent
    case options
    case group(GroupID)
    case place(RendezvousID)
    case goTo

    /// The states that are one card through a meet's life share an identity,
    /// so the sheet morphs between them instead of swapping.
    var family: String {
        switch self {
        case .meet, .incoming, .sent, .options: "meet"
        case .group(let id): "group:\(id.rawValue)"
        case .place(let id): "place:\(id.rawValue)"
        case .goTo: "goTo"
        }
    }
}

/// The selected resort. `state`, `friends` and `meet` mirror `ResortSession`.
@Observable
final class ResortModel {
    let resortID: String
    private(set) var state: ResortSession.State = .loadingBundle
    /// Friends' latest positions at this resort.
    private(set) var friends: [UUID: Presence] = [:]
    /// "On Pika's Traverse", "Riding Peak Express" for each person the map can
    /// place, the user included (`ResortSession.places`).
    private(set) var places: [UUID: String] = [:]
    private(set) var meet: MeetModel?

    /// Map chrome state. The map sets the selection on a tap; the timeline
    /// scrubber moves `selectedTime` (sun and forecast only, never status).
    var selectedGroupID: GroupID? {
        didSet { refreshScene() }
    }
    /// The scrubbed instant; meaningful only while `isScrubbed`. Left alone,
    /// the timeline stays Live however long the resort is open.
    private(set) var selectedTime = Date() {
        didSet {
            refreshScene()
            refreshWeather()
        }
    }

    /// What the forecast at the timeline's hour does to the map: snow, wind,
    /// cloud and haze in tenths. Stored, and set only when a tenth changes,
    /// so a scrub redraws the map's weather only when it would show.
    private(set) var weatherAtDisplayTime = WeatherEffect.clear

    private func refreshWeather() {
        let weather = conditions.map { MapWeather.effect($0.sample(at: displayTime)) } ?? .clear
        if weather != weatherAtDisplayTime { weatherAtDisplayTime = weather }
    }
    /// The user has moved the timeline off Live (a drag or an adjust); Live
    /// and the weather tap put it back.
    private(set) var isScrubbed = false

    /// When the timeline last left Live; nil while Live. The capture clock
    /// (`PreviewStage.presentationDate`) reads a scrubbed instant against it,
    /// not against the moment of drawing, so an hour ahead stays "10:41"
    /// however long a still is held. A drag keeps the first instant.
    private(set) var scrubbedSince: Date?

    /// The timeline's instant: the scrubbed one, or now.
    var displayTime: Date { isScrubbed ? selectedTime : Date() }

    /// Past, Live or Forecast, as the timeline labels it and the map draws it.
    var timelineMode: TimelineMode {
        isScrubbed ? TimelineMode(display: selectedTime, now: Date()) : .live
    }

    func scrub(to instant: Date) {
        if !isScrubbed { scrubbedSince = Date() }
        isScrubbed = true
        selectedTime = instant
    }

    func returnToLive() {
        isScrubbed = false
        scrubbedSince = nil
        selectedTime = Date()
    }
    /// The friend or meeting point whose card is open over the map.
    private(set) var mapCard: MapCard?

    // MARK: Navigation during a meet (`specs/13-APP-MAP.md` section 2.1)

    /// The step list is open under the instruction pinned at the top.
    private(set) var isNavigationStepsOpen = false
    /// Everything about the meet is put away but a small pill at the top; the
    /// meet carries on.
    private(set) var isNavigationTucked = false

    func setNavigationStepsOpen(_ open: Bool) {
        isNavigationStepsOpen = open
        if open { isNavigationTucked = false }
    }

    func setNavigationTucked(_ tucked: Bool) {
        isNavigationTucked = tucked
        if tucked { isNavigationStepsOpen = false }
    }

    /// Whether the meet under way is active (not just ended).
    var isMeetActive: Bool {
        if case .active = meet?.state { true } else { false }
    }
    /// The solo route on the map, if any. A meet's own route replaces it.
    private(set) var goTo: GoToState?
    @ObservationIgnored private var goToTask: Task<Void, Never>?
    /// Where everyone has been, for scrubbing back (`ResortSession.breadcrumbUpdates`).
    @ObservationIgnored private var breadcrumbs = Breadcrumbs()
    /// Where both skiers of the active meet will be, for scrubbing forward.
    @ObservationIgnored private var ghostPlan: GhostPlan?
    @ObservationIgnored private var ghostPump: Task<Void, Never>?
    /// The partner's projected route in the active meet, for its card's
    /// easiest-way-down note. Nil until their ghost is routed.
    private(set) var partnerGhostRoute: Route?
    /// The map's first view has drawn (or could not): the stack under it may
    /// arrive. A slow map does not hold the friends row back past a few
    /// seconds.
    private(set) var hasSettledFirstView = false
    @ObservationIgnored private var settleFallback: Task<Void, Never>?

    private func settleFirstView() {
        settleFallback?.cancel()
        settleFallback = nil
        if !hasSettledFirstView { hasSettledFirstView = true }
    }

    /// Whether the map is keeping the camera on this phone, as the map reports it.
    private(set) var isFollowing = false
    /// Following as last asked for, kept for a map that does not exist yet.
    @ObservationIgnored private var wantsFollow = false

    /// What the map draws. Rebuilt whenever anything below changes.
    let scene: MapSceneCoordinator

    private let session: ResortSession
    private var pumps: [Task<Void, Never>] = []
    private var meetPump: Task<Void, Never>?
    /// This phone's position and friends' names, supplied by `AppModel`.
    @ObservationIgnored var userFix: Fix? {
        didSet {
            refreshScene()
            retryGoToReplan()
        }
    }
    /// How often this skier has skied each run here (`AppModel.syncSkiedRuns`).
    @ObservationIgnored var skiedRuns: [String: Int] = [:] {
        didSet { if skiedRuns != oldValue { refreshScene() } }
    }
    @ObservationIgnored var names: [UUID: String] = [:] {
        didSet { if names != oldValue { refreshScene() } }
    }
    /// Called when a map has finished its first load and is at rest.
    @ObservationIgnored var onMapFirstLoad: ((MapLoadTiming) -> Void)?
    /// Developer testing's "place on the map": asked first about every map
    /// event, and takes the taps while it is armed. Nil outside Debug and
    /// TestFlight builds.
    @ObservationIgnored var tapOverride: MapTapOverride?
    /// A meet request has just arrived.
    @ObservationIgnored var onMeetIncoming: (() -> Void)?
    /// A friend was tapped while another meet is under way: their card opens.
    @ObservationIgnored var onFriendCard: ((UUID) -> Void)?
    /// A meet that was sent or accepted has ended, once per meet.
    @ObservationIgnored var onMeetEnded: (() -> Void)?

    /// How often the map is drawn again for time alone: well inside the
    /// shortest age step a friend's marker shows (75 s to stale).
    static let ageingRedrawS = 30.0

    /// The instant routes are priced at, the meets' own (developer testing can move it).
    private let solveClock: any AppCore.Clock

    init(session: ResortSession, log: PMLog, solveClock: any AppCore.Clock) {
        self.session = session
        self.solveClock = solveClock
        resortID = session.resortID
        scene = MapSceneCoordinator(log: log)
    }

    var ready: ResortSession.Ready? {
        if case .ready(let ready) = state { ready } else { nil }
    }

    var bundle: ResortBundle? { ready?.bundle }
    var status: ResortStatus? { ready?.status }
    var conditions: Conditions? { ready?.conditions }

    var failure: DataFailure? {
        if case .failed(let failure) = state { failure } else { nil }
    }

    /// The context sheet's subject, first match wins: the meet under way (or
    /// just ended), an incoming request, the request sent, the meeting options,
    /// the run or lift tapped, the place tapped, the solo route.
    var contextCard: ContextCard? {
        guard bundle != nil else { return nil }
        switch meet?.state {
        case .active:
            // The instruction stays pinned at the top; a run, lift or place
            // tapped on the map takes the sheet until it is closed (storyboard
            // beat 6), and a meet put away leaves the sheet empty.
            if let selectedGroupID { return .group(selectedGroupID) }
            if case .rendezvous(let id) = mapCard { return .place(id) }
            return isNavigationTucked ? nil : .meet
        case .ended(let ended):
            // Backing out of options before sending leaves nothing to say.
            if ended.meet != nil { return .meet }
        case .incoming: return .incoming
        case .proposed: return .sent
        case .proposing:
            // A place tapped while picking where to meet shows its card, with
            // "Meet here"; closed, the options are back.
            if case .rendezvous(let id) = mapCard { return .place(id) }
            return .options
        case nil: break
        }
        if let selectedGroupID { return .group(selectedGroupID) }
        if case .rendezvous(let id) = mapCard { return .place(id) }
        if goTo != nil { return .goTo }
        return nil
    }

    /// The context sheet's close (× or a swipe down) for what can be put away
    /// without a decision; a request or a meet has its own buttons.
    func closeContextCard() {
        switch contextCard {
        case .options: closeMeetTray()
        case .group: selectedGroupID = nil
        case .place: mapCard = nil
        case .goTo: cancelGoTo()
        case .meet:
            switch meet?.state {
            case .ended: dismissMeet()
            case .active: setNavigationTucked(true)
            default: break
            }
        case .incoming, .sent, nil: break
        }
    }

    // Intents.
    func propose(to friend: UUID) { session.send(.proposeRequested(friend: friend)) }
    /// Developer testing switched the pretend weather: solve and draw on this
    /// row now, not at the next read.
    func showConditions(_ conditions: Conditions) { session.send(.conditionsUpdated(conditions)) }
    func retry() { session.send(.retry) }
    /// Clears a finished meet from view.
    func dismissMeet() { session.send(.meetDismissed) }

    /// What the user did on the map. A tap anywhere but on a friend or a place
    /// puts away an unsent proposal: the tray is the proposal, and nothing was sent.
    func handleMap(_ event: MapEvent) {
        if tapOverride?.consume(event, scene: scene) == true { return }
        switch event {
        case .tappedGroup(let group):
            closeMeetTray()
            mapCard = nil
            selectedGroupID = group
        case .tappedMap:
            closeMeetTray()
            mapCard = nil
            selectedGroupID = nil
        case .tappedFriend(let friend): tapFriend(friend)
        case .tappedRendezvous(let id):
            guard bundle?.rendezvous(id) != nil else { return }
            // An unsent proposal stays: the place may be where to meet.
            if case .proposing = meet?.state {} else { closeMeetTray() }
            selectedGroupID = nil
            mapCard = .rendezvous(id)
        case .styleLoaded:
            scene.styleLoaded()
            // A map made after the meet began (a relaunch mid-meet) still follows.
            if wantsFollow, !isFollowing { scene.send(.follow(true)) }
        case .styleFailed:
            scene.styleDidFail()
            settleFirstView()
        case .followingChanged(let on):
            isFollowing = on
            wantsFollow = on
        case .firstLoad(let timing):
            onMapFirstLoad?(timing)
            settleFirstView()
        case .userMovedCamera, .cameraIdle:
            break
        }
    }

    /// Draws the suggested lap on the map in place of the route to the meeting
    /// point, or goes back to that route.
    func followLap(_ follow: Bool) {
        guard let meet, meet.lapSuggestion != nil || !follow else { return }
        meet.isFollowingLap = follow
        refreshScene()
    }

    /// The explicit "show route on map": frames the routes and replays the reveal.
    func showRouteOnMap() { scene.send(.showRoute) }

    // Map controls. The map reports what following actually is through
    // `followingChanged`; nothing here assumes a command took effect.
    func toggleFollow() { scene.send(.follow(!isFollowing)) }
    func recenter() { scene.send(.recenter) }
    func resetNorth() { scene.send(.resetNorth) }
    func showWholeMountain() { scene.send(.showResort) }
    func dismissMapCard() { mapCard = nil }

    // MARK: Friends and the meeting-options tray

    /// No meet is under way that a new one would replace: nothing yet, an unsent
    /// proposal, or one that has ended (as `AppModel.canStartMeet`).
    var canStartMeet: Bool {
        guard ready != nil else { return false }
        switch meet?.state {
        case nil, .ended: return true
        case .proposing(let proposing): return !proposing.sending
        case .proposed, .incoming, .active: return false
        }
    }

    /// The friend whose meeting options are on the map.
    var proposingFriend: UUID? {
        guard let meet, case .proposing = meet.state else { return nil }
        return meet.partnerID
    }

    /// A friend's chip or marker: centres on them and opens the meeting-options
    /// tray straight away. Nothing is sent until an option is chosen and sent.
    /// While another meet is under way it opens their card instead, and that
    /// meet is left alone.
    /// A friend's chip: picks them, or puts them back when they are the one
    /// picked, so nobody need stay selected.
    func toggleFriend(_ friend: UUID) {
        if proposingFriend == friend {
            closeMeetTray()
        } else {
            tapFriend(friend)
        }
    }

    func tapFriend(_ friend: UUID) {
        guard let presence = friends[friend] else { return }
        selectedGroupID = nil
        cancelGoTo()
        scene.send(.focus(presence.coordinate))
        guard canStartMeet else {
            onFriendCard?(friend)
            return
        }
        mapCard = nil
        // The same order as `AppModel.startMeet`, without leaving the map: an
        // unsent proposal to someone else (or a finished meet) is cleared first.
        if let meet {
            if case .proposing(let proposing) = meet.state {
                if proposing.friend == friend { return }
                meet.end()
            }
            dismissMeet()
        }
        propose(to: friend)
    }

    /// An off-screen chip: centres on the friend and nothing else.
    func centre(onFriend friend: UUID) {
        guard let presence = friends[friend] else { return }
        scene.send(.focus(presence.coordinate))
    }

    /// The tray's close button, or a tap elsewhere on the map: backs out of an
    /// unsent proposal. A proposal being sent, or any later state, is untouched.
    func closeMeetTray() {
        guard let meet, case .proposing(let proposing) = meet.state, !proposing.sending else { return }
        meet.end()
        dismissMeet()
    }

    // MARK: Go to

    /// A solo route from this phone to a run's top, a lift's bottom station or
    /// a place. Only one at a time; a meet's route takes its place.
    func startGoTo(_ destination: GoToDestination, profile: SkierProfile?) {
        guard ready != nil else { return }
        closeMeetTray()
        selectedGroupID = nil
        mapCard = nil
        goTo = .solving(destination)
        planGoTo(destination, profile: profile, isReplan: false)
    }

    /// What the solo route was last planned on. A closure, new conditions, a
    /// new map or a profile edit plans it again (`replanGoToIfNeeded`).
    private struct GoToInputs: Equatable {
        var destination: GoToDestination
        var profile: SkierProfile?
        var bundleID: BundleID
        var status: ResortStatus?
        var conditions: Conditions?
    }
    @ObservationIgnored private var goToInputs: GoToInputs?
    /// A re-plan could not place the skier (no fresh fix), so the route on
    /// screen has not been checked against the mountain as it is now: the
    /// next fix good enough to route from plans it again.
    @ObservationIgnored private var goToNeedsReplan = false

    /// A re-plan keeps the route on screen until its answer arrives and never
    /// moves the camera; the first plan frames the route.
    private func planGoTo(_ destination: GoToDestination, profile: SkierProfile?, isReplan: Bool) {
        guard let ready else { return }
        goToTask?.cancel()
        goToNeedsReplan = false
        goToInputs = GoToInputs(
            destination: destination, profile: profile, bundleID: ready.bundle.id,
            status: ready.status, conditions: ready.conditions
        )
        // I-14: an old or rough fix is where the skier was; the planner then
        // says it cannot place them (`notOnMap`).
        let fix = userFix.flatMap { FixQuality.isRoutingGrade($0, now: Date()) ? $0 : nil }
        let bundle = ready.bundle, status = ready.status, conditions = ready.conditions
        let at = solveClock.now
        goToTask = Task { [weak self] in
            // Placing the fix scans the whole graph: off the main actor with the plan.
            let result = await Task.detached(priority: .userInitiated) {
                () -> Result<GoToPlanner.Plan, GoToPlanner.Failure> in
                let skier = fix.flatMap { fix in
                    profile.flatMap { profile in
                        OriginResolver.origin(for: fix, in: bundle).map {
                            SkierInput(id: profile.userID, profile: profile, origin: $0)
                        }
                    }
                }
                return switch destination {
                case .group(let group):
                    GoToPlanner.plan(
                        to: group, skier: skier, bundle: bundle, status: status,
                        conditions: conditions, at: at)
                case .place(let place):
                    GoToPlanner.plan(
                        toPlace: place, skier: skier, bundle: bundle, status: status,
                        conditions: conditions, at: at)
                }
            }.value
            guard let self, !Task.isCancelled else { return }
            switch result {
            case .success(let plan):
                self.goTo = .ready(plan)
                self.refreshScene()
                // Framed once the scene carrying the route is on the map.
                if !isReplan { self.scene.sendAfterNextScene(.showRoute) }
            case .failure(.notOnMap) where isReplan:
                // No fresh fix to place the skier: the route stands for now,
                // and the next usable fix plans it again. Unless something
                // on it has closed: a line through a closed lift, with an
                // arrival time, is worse than no route.
                if case .ready(let plan) = self.goTo, Self.crossesClosure(plan.route, in: bundle, status: status) {
                    self.goTo = .failed(destination, .routeClosed)
                    self.refreshScene()
                }
                self.goToNeedsReplan = true
            case .failure(let failure):
                self.goTo = .failed(destination, failure)
                self.refreshScene()
            }
        }
    }

    /// Whether a lift or run the route uses is reported closed.
    private static func crossesClosure(_ route: Route, in bundle: ResortBundle, status: ResortStatus?) -> Bool {
        guard let status else { return false }
        return route.legs.contains { leg in
            guard let group = bundle.graph.edge(leg.edgeID)?.group else { return false }
            return status.groups[group] == .closed
        }
    }

    /// The solo route answers the mountain as it is now: a lift that closes
    /// under it, or a limit lowered in Gear, plans it again.
    private func replanGoToIfNeeded(profile newProfile: SkierProfile? = nil) {
        guard var inputs = goToInputs, goTo != nil, let ready else { return }
        if let newProfile { inputs.profile = newProfile }
        inputs.bundleID = ready.bundle.id
        inputs.status = ready.status
        inputs.conditions = ready.conditions
        guard inputs != goToInputs else { return }
        // A first plan still solving has yet to frame its route.
        var isFirstPlan = false
        if case .solving = goTo { isFirstPlan = true }
        planGoTo(inputs.destination, profile: inputs.profile, isReplan: !isFirstPlan)
    }

    private func retryGoToReplan() {
        guard goToNeedsReplan, goTo != nil, let inputs = goToInputs,
              let fix = userFix, FixQuality.isRoutingGrade(fix, now: Date()) else { return }
        planGoTo(inputs.destination, profile: inputs.profile, isReplan: true)
    }

    /// The user saved their profile.
    func profileChanged(_ profile: SkierProfile) {
        replanGoToIfNeeded(profile: profile)
        // Called with every signed-in state: only a change to what routing
        // reads drops a lap found under the old limits.
        if let known = routingProfile, known != profile, meet?.lapSuggestion != nil {
            meet?.dropLap()
            refreshScene()
        }
        routingProfile = profile
    }
    @ObservationIgnored private var routingProfile: SkierProfile?

    func cancelGoTo() {
        goToTask?.cancel()
        goToTask = nil
        goToInputs = nil
        guard goTo != nil else { return }
        goTo = nil
        refreshScene()
    }

    /// When the active meet's slower skier is expected at the meeting point, for
    /// the timeline. Nil without an active meet.
    var meetArrival: Date? {
        guard case .active(let active) = meet?.state else { return nil }
        let now = Date()
        var times: [Date] = []
        if let navigation = active.navigation {
            times.append(now.addingTimeInterval(navigation.eta.meanS))
        }
        if let partner = active.partner, let eta = partner.etaS {
            times.append(partner.fixAt.addingTimeInterval(TimeInterval(eta)))
        }
        if times.isEmpty {
            // Nothing live yet: the ETAs agreed when the meet started.
            let start = active.meet.respondedAt ?? active.meet.createdAt
            for eta in [active.meet.proposerEtaS, active.meet.inviteeEtaS].compactMap({ $0 }) {
                times.append(start.addingTimeInterval(TimeInterval(eta)))
            }
        }
        return times.max()
    }

    func reloadMapStyle() { scene.send(.reloadStyle) }

    /// Describes everything on the map as one value and hands it to the scene
    /// coordinator, which builds off the main actor.
    private func refreshScene() {
        guard let ready else { return }
        var routes: [SceneRoute] = []
        var meeting: RendezvousID?
        switch meet?.state {
        case .proposing(let proposing):
            if let options = proposing.options?.options, let picked = proposing.picked,
               options.indices.contains(picked) {
                routes = [
                    SceneRoute(slot: .a, route: options[picked].routes.0),
                    SceneRoute(slot: .b, route: options[picked].routes.1),
                ]
                meeting = options[picked].rendezvous
            }
        case .proposed(let meet):
            meeting = meet.rendezvousID
        case .incoming(let incoming):
            meeting = incoming.meet.rendezvousID
            if let route = incoming.ownRoute { routes = [SceneRoute(slot: .a, route: route)] }
        case .active(let active):
            meeting = active.meet.rendezvousID
            if let meet, meet.isFollowingLap, let lap = meet.lapSuggestion {
                // The lap starts and ends at the meeting point; it is drawn
                // whole, since progress is tracked on the route there only.
                routes = [SceneRoute(slot: .a, route: lap.route)]
            } else if let navigation = active.navigation {
                routes = [SceneRoute(
                    slot: .a, route: navigation.route, legIndex: navigation.progress.legIndex,
                    fractionAlongLeg: navigation.progress.fractionAlongLeg
                )]
            }
        case .ended, nil:
            break
        }
        // The solo route shows only while no meet draws one of its own.
        if routes.isEmpty, case .ready(let plan) = goTo {
            routes = [SceneRoute(slot: .a, route: plan.route)]
        }
        let now = Date()
        let mode = timelineMode
        let display = displayTime
        #if DEBUG
        // `-previewSunHour`: the light of another hour for a daytime still.
        let light = PreviewStage.sunShifted(display, in: ready.bundle.timeZone ?? .current, now: scrubbedSince ?? now)
        #else
        let light = display
        #endif
        var markers: [FriendMarker]
        var trails: [BreadcrumbTrail] = []
        if mode == .past {
            (markers, trails) = replay(at: selectedTime, now: now)
        } else {
            markers = friends.values
                .sorted { $0.userID.uuidString < $1.userID.uuidString }
                .map { presence in
                    FriendMarker(
                        id: presence.userID,
                        displayName: names[presence.userID]
                            ?? AppModel.devPersonName(presence.userID) ?? "Friend",
                        coordinate: presence.coordinate, accuracyM: presence.accuracyM,
                        capturedAt: presence.capturedAt, place: places[presence.userID]
                    )
                }
        }
        let ghosts = mode == .future ? ghostMarkers(at: selectedTime, in: ready.bundle.timeZone ?? .current) : []
        scene.show(RenderInput(
            bundle: ready.bundle, status: ready.status, routes: routes, meeting: meeting,
            friends: markers, user: userFix?.coordinate, selection: selectedGroupID,
            time: SceneTime(now: now, display: light), breadcrumbs: trails, ghosts: ghosts,
            skied: skiedRuns
        ))
    }

    /// Scrubbed back: each friend where they were at `instant`, and their
    /// path from the start of the timeline up to it. Only people in the
    /// friends list now (`names`), so someone removed or blocked since is
    /// not replayed.
    private func replay(at instant: Date, now: Date) -> ([FriendMarker], [BreadcrumbTrail]) {
        let since = TimelineWindow.range(now: now, arrival: nil).lowerBound
        let positions = breadcrumbs.positions(at: instant)
        var markers: [FriendMarker] = []
        var trails: [BreadcrumbTrail] = []
        for (user, name) in names.sorted(by: { $0.key.uuidString < $1.key.uuidString }) {
            var path = breadcrumbs.trail(for: user, since: since)
                .prefix { $0.at <= instant }
                .map(\.coordinate)
            if let position = positions[user] {
                // Drawn as current: the timeline already says when this was.
                markers.append(FriendMarker(id: user, displayName: name, coordinate: position, capturedAt: now))
                path.append(position)
            }
            if path.count >= 2 { trails.append(BreadcrumbTrail(id: user, coordinates: path)) }
        }
        return (markers, trails)
    }

    /// Scrubbed forward during an active meet: each skier on their route,
    /// labelled "YOU @ 3:15 PM" or "GlacierGlider @ 3:15 PM" (the whole name: a first word alone can read as a place) in resort time.
    private func ghostMarkers(at instant: Date, in timeZone: TimeZone) -> [GhostMarker] {
        guard let ghostPlan, case .active = meet?.state else { return [] }
        let time = ResortModel.ghostTime(instant, in: timeZone, heldSince: scrubbedSince)
        return ghostPlan.ghosts(at: instant).map { ghost in
            let who = ghost.isSelf
                ? "YOU"
                : names[ghost.userID] ?? "Friend"
            return GhostMarker(
                id: ghost.userID, isSelf: ghost.isSelf, label: "\(who) @ \(time)",
                coordinate: ghost.coordinate, trail: ghost.trail)
        }
    }

    private static let ghostTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        return formatter
    }()

    private static func ghostTime(_ date: Date, in timeZone: TimeZone, heldSince: Date?) -> String {
        ghostTimeFormatter.timeZone = timeZone
        #if DEBUG
        let displayedDate = PreviewStage.presentationDate(date, in: timeZone, now: heldSince ?? Date())
        #else
        let displayedDate = date
        #endif
        return ghostTimeFormatter.string(from: displayedDate)
    }

    func start() {
        let session = session
        pumps.append(Task { [weak self] in
            for await state in await session.states() {
                self?.state = state
                if case .ready(let ready) = state {
                    self?.meet?.reviewLap(status: ready.status, in: ready.bundle)
                }
                self?.refreshScene()
                self?.refreshWeather()
                self?.startSettleFallback()
                self?.replanGoToIfNeeded()
            }
        })
        // A friend's marker turns stale, then lost, and closures expire, as
        // time passes; a skier standing still gets no new fix to redraw it.
        pumps.append(Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(ResortModel.ageingRedrawS)) } catch { return }
                guard let self else { return }
                if !self.friends.isEmpty || self.status != nil { self.refreshScene() }
            }
        })
        pumps.append(Task { [weak self] in
            for await friends in await session.friendUpdates() {
                self?.friends = friends
                self?.refreshScene()
            }
        })
        pumps.append(Task { [weak self] in
            for await places in await session.placeUpdates() {
                let phrases = places.mapValues(\.phrase)
                guard let self, phrases != self.places else { continue }
                self.places = phrases
                self.refreshScene()
            }
        })
        pumps.append(Task { [weak self] in
            for await crumbs in await session.breadcrumbUpdates() {
                guard let self else { return }
                self.breadcrumbs = crumbs
                // A new crumb changes the map only while the past is on screen.
                if self.timelineMode == .past { self.refreshScene() }
            }
        })
        pumps.append(Task { [weak self] in
            for await meetSession in await session.meetSessions() {
                self?.follow(meetSession)
            }
        })
    }

    private func follow(_ meetSession: MeetSession?) {
        meetPump?.cancel()
        meetPump = nil
        ghostPump?.cancel()
        ghostPump = nil
        ghostPlan = nil
        partnerGhostRoute = nil
        guard let meetSession else {
            meet = nil
            refreshScene()
            return
        }
        ghostPump = Task { [weak self] in
            for await plan in await meetSession.ghostPlans() {
                guard let self, !Task.isCancelled else { return }
                self.ghostPlan = plan
                let partnerRoute = plan?.tracks.first { !$0.isSelf }?.projection.route
                if partnerRoute != self.partnerGhostRoute { self.partnerGhostRoute = partnerRoute }
                if self.timelineMode == .future { self.refreshScene() }
            }
        }
        meetPump = Task { [weak self] in
            var model: MeetModel?
            var wasActive = false
            var wasIncoming = false
            var endedMeetID: UUID?
            /// The option the map last framed while proposing.
            var framed: PickedOption?
            for await state in await meetSession.states() {
                guard !Task.isCancelled else { return }
                // A meet that has just become active keeps the map on the skier
                // until they pan away.
                var isActive = false
                if case .active = state { isActive = true }
                if isActive, !wasActive {
                    self?.cancelGoTo()
                    self?.followForMeet()
                    self?.isNavigationStepsOpen = false
                    self?.isNavigationTucked = false
                }
                wasActive = isActive
                if case .incoming = state, !wasIncoming { self?.onMeetIncoming?() }
                if case .incoming = state { wasIncoming = true } else { wasIncoming = false }
                if case .ended(let ended) = state, let meet = ended.meet, meet.meetID != endedMeetID {
                    endedMeetID = meet.meetID
                    self?.onMeetEnded?()
                }
                if let model {
                    model.state = state
                    model.noteLap(in: state)
                } else {
                    let created = MeetModel(session: meetSession, state: state)
                    model = created
                    self?.meet = created
                }
                self?.refreshScene()
                // The tray describes the picked option, so the map shows its two
                // routes and meeting point, once per option: a swipe, or a
                // re-solve after a profile edit that moved the meeting point or
                // the routes. Behind the panel it waits for the map to show.
                let picked = ResortModel.pickedOption(in: state)
                if let picked, picked != framed,
                   !DebugLaunch.lockMeetCamera || framed == nil { self?.reframe() }
                framed = picked
            }
        }
    }

    /// The picked option as the map draws it: the meeting point and both
    /// routes' edges.
    private struct PickedOption: Equatable {
        var rendezvous: RendezvousID
        var edges: [EdgeID]
    }

    private static func pickedOption(in state: MeetSession.State) -> PickedOption? {
        guard case .proposing(let proposing) = state, let options = proposing.options?.options,
              let picked = proposing.picked, options.indices.contains(picked) else { return nil }
        let option = options[picked]
        return PickedOption(
            rendezvous: option.rendezvous,
            edges: option.routes.0.legs.map(\.edgeID) + option.routes.1.legs.map(\.edgeID))
    }

    /// Whether the map is what the user is looking at (no panel or picker
    /// over it), as the screen reports it.
    @ObservationIgnored private var isMapInView = true
    @ObservationIgnored private var reframeWhenVisible = false

    /// Frames the routes and draws them on again once the scene carrying
    /// them is on the map; if the map is covered, when it shows again.
    private func reframe() {
        if isMapInView {
            scene.sendAfterNextScene(.showRoute)
        } else {
            reframeWhenVisible = true
        }
    }

    /// The screen's report: the panel or a picker opened over the map, or
    /// went away. Coming back to options that changed meanwhile replays them.
    func mapVisibilityChanged(_ visible: Bool) {
        isMapInView = visible
        guard visible, reframeWhenVisible else { return }
        reframeWhenVisible = false
        // Under the fading panel for a moment first, so the move is seen.
        scene.send(.showRoute)
    }

    private func followForMeet() {
        mapCard = nil
        wantsFollow = true
        scene.send(.follow(true))
    }

    /// Once the bundle is in, the stack arrives within four seconds whatever
    /// the map does.
    private func startSettleFallback() {
        guard ready != nil, !hasSettledFirstView, settleFallback == nil else { return }
        settleFallback = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(4)) } catch { return }
            self?.settleFirstView()
        }
    }

    func stop() {
        settleFallback?.cancel()
        goToTask?.cancel()
        goToTask = nil
        for pump in pumps { pump.cancel() }
        pumps = []
        meetPump?.cancel()
        meetPump = nil
        ghostPump?.cancel()
        ghostPump = nil
        scene.stop()
    }
}
