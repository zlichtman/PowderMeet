import AppCore
import Foundation
import MapScene
import MapboxAdapter
import MeetSolver
import MountainCore
import Observation
import PowderMeetAPI
import UIKit

/// "Place on the map" for developer testing: while it is armed, a tap anywhere
/// on the map is a place, not a selection (`MapCommand.captureTaps`).
/// `ResortModel` asks it first about every map event; nothing else on the map
/// knows it exists.
final class MapTapOverride {
    private var onTap: ((Coordinate) -> Void)?

    var isArmed: Bool { onTap != nil }

    func arm(_ handler: @escaping (Coordinate) -> Void) { onTap = handler }

    func disarm() { onTap = nil }

    /// True when it took the event. A map made while it is armed (a new
    /// bundle, a style reload) is told to capture taps again.
    func consume(_ event: MapEvent, scene: MapSceneCoordinator) -> Bool {
        guard let onTap else { return false }
        switch event {
        case .tappedMap(let point):
            onTap(point)
            return true
        case .tappedGroup, .tappedRendezvous, .tappedFriend:
            // From a map that had not been told to capture yet.
            return true
        case .styleLoaded:
            scene.send(.captureTaps(true))
            return false
        default:
            return false
        }
    }
}

/// Developer testing (`specs/07-CLIENT.md` section 8), for Debug and TestFlight
/// builds, on the live backend: any published mountain, a place set by hand
/// for this phone ("teleport"), three dev people who exist on this phone only,
/// placed at seeded spots and movable by hand, each at a level of their own, a
/// pretend time of day and pretend weather for the solver, a test meet-up with
/// any dev person, and the connection's diagnostics.
/// The composition root makes one only when `DeveloperAccess` allows it.
@Observable
final class DeveloperModel {
    enum Placement: Hashable {
        case me
        /// A dev person, by id.
        case dev(UUID)
    }

    /// What the solver's clock reads.
    enum PretendTime: Hashable {
        /// The real time.
        case real
        /// A time of day at the mountain, minutes after local midnight.
        case at(Int)
    }

    /// Where a test meet-up with a dev person stands, from the meet on screen.
    enum Rehearsal: Hashable {
        case idle, solving, waitingForAnswer, travelling, arrived
        case ended(String)
        case failed(String)
    }

    static let pretendTimeStepMinutes = 30
    static let diagnosticsRefreshS = 2.0
    /// How long the test meet-up waits for each step before giving up.
    static let rehearsalStepTimeoutS = 30.0

    private(set) var channel: DeveloperChannel
    var isAvailable: Bool { channel.allowsDeveloperTesting }

    /// What the next tap on the map places, while one is awaited.
    private(set) var placing: Placement?
    /// The outcome of the last action, in a sentence.
    private(set) var note: String?
    /// Live mode: this phone stands where it was put, not where GPS says.
    private(set) var isTeleported = false
    /// Live mode: real friends see the teleported position too (two test
    /// accounts at home). Off by default.
    private(set) var sharesTeleport = false
    /// The dev people on the mountain on screen.
    private(set) var placedPeople: Set<UUID> = []
    /// "Show dev people" is on: the three are put on each mountain opened.
    private(set) var wantsDevPeople = false
    /// How many times the dev people's spots were re-rolled on this mountain.
    private(set) var shuffles = 0
    private(set) var pretendWeather = PretendWeather.real
    /// When the diagnostics were last read, which their ages count from.
    private(set) var diagnosticsAt = Date()
    private(set) var levels: [UUID: Ability] = [:]
    private(set) var pretendTime = PretendTime.real
    /// The dev person the last test meet-up was with.
    private(set) var rehearsalPartner: UUID?
    private(set) var rehearsalFailure: String?
    private(set) var isRunningRehearsal = false
    private(set) var realtime = RealtimeDiagnostics()

    let app: AppModel
    let tapOverride = MapTapOverride()
    let serverHost: String?

    private let location: PlaceableLocationProvider
    private let backend: SandboxedBackend
    private let clock: AdjustableClock
    @ObservationIgnored private var work: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private weak var attached: ResortModel?
    /// The bundle the pretend time was last set for.
    @ObservationIgnored private var clockBundle: BundleID?
    /// The bundle the dev people were last put on.
    @ObservationIgnored private var devBundle: BundleID?
    /// The last real forecast on screen per mountain, for going back to Real.
    @ObservationIgnored private var realConditions: [String: Conditions] = [:]

    init(
        app: AppModel, channel: DeveloperChannel, location: PlaceableLocationProvider,
        backend: SandboxedBackend, clock: AdjustableClock, serverHost: String?
    ) {
        self.app = app
        self.channel = channel
        self.location = location
        self.backend = backend
        self.clock = clock
        self.serverHost = serverHost
    }

    /// Called once by the composition root.
    func start() {
        guard isAvailable else { return }
        resortChanged()
        watchResort()
        // StoreKit has the last word: production closes everything.
        run("channel") { [weak self] in
            guard let confirmed = await DeveloperAccess.confirm() else { return }
            self?.channel = confirmed
            if !confirmed.allowsDeveloperTesting { self?.shutDown() }
        }
    }

    // MARK: Mountain

    /// Every mountain with a published map.
    var mountains: [PublishedResort] { app.catalog.resorts.filter(\.hasMap) }

    func loadMountains() {
        if app.catalog.resorts.isEmpty, !app.catalog.isLoading { app.loadCatalog() }
    }

    /// Opens a mountain for testing.
    func openMountain(_ resortID: String) {
        app.selectResort(resortID)
    }

    var resortName: String? {
        guard let resort = app.resort else { return nil }
        return app.selectedResort?.name ?? resort.bundle?.name ?? resort.resortID
    }

    // MARK: Placing

    /// Arms the map: the next tap places this phone or a dev person.
    /// The caller dismisses its sheet so the map is on screen.
    func beginPlacing(_ what: Placement) {
        guard let resort = app.resort, resort.ready != nil else {
            note = "Open a mountain first."
            return
        }
        placing = what
        note = nil
        tapOverride.arm { [weak self] point in self?.placed(at: point) }
        resort.scene.send(.captureTaps(true))
        app.showMap()
    }

    func cancelPlacing() {
        placing = nil
        tapOverride.disarm()
        app.resort?.scene.send(.captureTaps(false))
    }

    /// A tap during placement, put on the nearest run or lift.
    private func placed(at point: Coordinate) {
        guard let what = placing, let bundle = app.resort?.bundle else {
            cancelPlacing()
            return
        }
        guard let spot = DeveloperPlacement.snap(point, in: bundle) else {
            // Still armed: the next tap tries again.
            note = "Too far from any run or lift. Tap on the mountain."
            return
        }
        cancelPlacing()
        switch what {
        case .me:
            // The map's banner says it is teleported; nothing to add here.
            teleport(to: spot)
        case .dev(let id):
            put(id, at: spot)
        }
    }

    private func teleport(to spot: Coordinate) {
        // Withheld before the first placed fix goes out, so no presence
        // publish in between can carry it to real friends.
        isTeleported = true
        updatePresencePolicy()
        location.place(at: spot)
        note = nil
    }

    /// `auto`: put there by Show Dev People, so a switch turned off while it
    /// was on its way takes them off again.
    private func put(_ id: UUID, at spot: Coordinate, auto: Bool = false) {
        let name = Self.name(of: id)
        run("place-\(id)") { [weak self, backend] in
            do {
                try await backend.sandbox.place(id, at: spot)
                self?.placedPeople.insert(id)
                if auto, self?.wantsDevPeople == false { self?.removeDevPerson(id) }
            } catch {
                self?.note = "\(name) couldn't be placed: \(PowderMeetError(error).userMessage)"
            }
        }
    }

    #if DEBUG
    /// Debug launch scripts (`DebugScript`): what a placing tap would do, at a
    /// point on the open mountain.
    func place(_ what: Placement, at point: Coordinate) {
        placing = what
        placed(at: point)
    }

    /// Debug launch scripts: the solver at this time of day at the mountain.
    func setPretendTime(minuteOfDay: Int) {
        pretendTime = .at(minuteOfDay)
        applyPretendTime()
    }
    #endif

    /// The Teleport switch: on puts this phone at the mountain's first seeded
    /// spot at once (Move Me then puts it anywhere by hand); off is back to GPS.
    func setTeleported(_ on: Bool) {
        guard on else {
            if placing == .me { cancelPlacing() }
            if isTeleported { returnToGPS() }
            return
        }
        guard let bundle = app.resort?.bundle,
              let spot = DeveloperSpots.pick(
                  devPeople.count + 1, in: bundle, seed: DeveloperSpots.seed(for: bundle.resortID)).first
        else {
            note = "Open a mountain first."
            return
        }
        teleport(to: spot)
    }

    /// Live mode: back to the phone's own fixes.
    func returnToGPS() {
        location.release()
        isTeleported = false
        updatePresencePolicy()
        note = "Back on GPS."
    }

    func setSharesTeleport(_ on: Bool) {
        sharesTeleport = on
        updatePresencePolicy()
    }

    /// A teleported phone in live mode keeps its pretend position to itself
    /// unless sharing is on.
    private func updatePresencePolicy() {
        backend.sandbox.setWithholdsPresence(isTeleported && !sharesTeleport)
    }

    // MARK: Dev people

    var devPeople: [DeveloperSandbox.DevPerson] { DeveloperSandbox.devPeople }

    static func name(of id: UUID) -> String { AppModel.devPersonName(id) ?? "Dev person" }

    func isPlaced(_ id: UUID) -> Bool { placedPeople.contains(id) }

    /// The "Show dev people" switch reads on while any dev person is out.
    var showsDevPeople: Bool { wantsDevPeople || !placedPeople.isEmpty }

    /// On puts the three on the mountain at seeded spots, spread apart; off
    /// takes every one of them off.
    func setShowsDevPeople(_ on: Bool) {
        wantsDevPeople = on
        if on {
            guard app.resort?.ready != nil else {
                note = "Open a mountain first."
                return
            }
            for person in devPeople where !isPlaced(person.id) { putBack(person.id) }
        } else {
            for id in placedPeople { removeDevPerson(id) }
        }
    }

    /// New spots for every dev person on the mountain.
    func shuffleDevPeople() {
        shuffles += 1
        for id in placedPeople { putBack(id) }
    }

    /// A dev person to their seeded spot on the open mountain.
    func putBack(_ id: UUID) {
        guard let spot = spot(for: id) else {
            note = "Open a mountain first."
            return
        }
        put(id, at: spot, auto: true)
    }

    /// Spot 0 is this phone's teleport; the dev people take the next three.
    private func spot(for id: UUID) -> Coordinate? {
        guard let bundle = app.resort?.bundle,
              let index = devPeople.firstIndex(where: { $0.id == id }) else { return nil }
        let spots = DeveloperSpots.pick(
            devPeople.count + 1, in: bundle, seed: DeveloperSpots.seed(for: bundle.resortID, shuffle: shuffles))
        guard !spots.isEmpty else { return nil }
        return spots[min(index + 1, spots.count - 1)]
    }

    /// A dev person's row on the Dev page, in a line.
    func summary(of id: UUID) -> String {
        guard isPlaced(id) else { return "Not on the map" }
        let tier = level(of: id).label
        switch rehearsal(with: id) {
        case .idle: return tier
        case .solving, .waitingForAnswer: return "\(tier) · Meet-up starting"
        case .travelling, .arrived: return "\(tier) · Meeting you"
        case .ended, .failed: return "\(tier) · Meet-up over"
        }
    }

    func level(of id: UUID) -> Ability { levels[id] ?? DeveloperSandbox.defaultLevel }

    /// Applies from the next solve; a meet with them ends.
    func setLevel(_ level: Ability, for id: UUID) {
        guard level != self.level(of: id) else { return }
        levels[id] = level
        let name = Self.name(of: id)
        run("level-\(id)") { [weak self, backend] in
            do {
                try await backend.sandbox.setLevel(level, for: id)
            } catch {
                self?.note = "\(name)'s level couldn't be changed: \(PowderMeetError(error).userMessage)"
            }
        }
    }

    func removeDevPerson(_ id: UUID) {
        let name = Self.name(of: id)
        run("remove-\(id)") { [weak self, backend] in
            do {
                try await backend.sandbox.remove(id)
            } catch {
                self?.note = "\(name) stopped reporting but stays on the map: \(PowderMeetError(error).userMessage)"
            }
            self?.placedPeople.remove(id)
            if self?.placedPeople.isEmpty == true { self?.wantsDevPeople = false }
        }
    }

    // MARK: Pretend time

    var mountainTimeZone: TimeZone {
        app.resort?.bundle.flatMap { TimeZone(identifier: $0.timezone) } ?? .current
    }

    /// The solver's time of day at the mountain, as minutes after midnight.
    var solveMinuteOfDay: Int { AdjustableClock.minuteOfDay(clock.now, in: mountainTimeZone) }

    /// The solver prices the mountain later than now: lift status and weather
    /// past their expiry read as stale or degraded.
    var pretendTimeIsAhead: Bool {
        _ = pretendTime
        return clock.offset > 60
    }

    /// Half an hour earlier or later, from the time the solver reads now.
    func stepPretendTime(_ step: Int) {
        let minute = solveMinuteOfDay
        let stepped = (minute / Self.pretendTimeStepMinutes + (step > 0 ? 1 : (minute % Self.pretendTimeStepMinutes == 0 ? -1 : 0)))
            * Self.pretendTimeStepMinutes
        pretendTime = .at(min(max(stepped, 0), 24 * 60 - Self.pretendTimeStepMinutes))
        applyPretendTime()
    }

    /// Back to the real time.
    func resetPretendTime() {
        pretendTime = .real
        applyPretendTime()
    }

    func jump(to preset: SolverTimePreset) {
        pretendTime = .at(preset.minuteOfDay(on: liftDay))
        applyPretendTime()
    }

    /// The preset the solver's time sits on, if any.
    var currentPreset: SolverTimePreset? {
        guard case .at(let minute) = pretendTime else { return nil }
        return SolverTimePreset.allCases.first { $0.minuteOfDay(on: liftDay) == minute }
    }

    private var solveWeekday: Int { LiftDay.weekday(clock.now, in: mountainTimeZone) }

    /// When the open mountain's lifts run on the solver's day.
    var liftDay: LiftDay? {
        _ = pretendTime
        guard let bundle = app.resort?.bundle else { return nil }
        return LiftDay.of(bundle, weekday: solveWeekday)
    }

    /// The solver's time of day at the mountain, "10:30".
    var solveTimeText: String { Self.clockText(solveMinuteOfDay) }

    /// Whether lifts load at the solver's time, in a line.
    var liftLine: String {
        _ = pretendTime
        guard let bundle = app.resort?.bundle else { return "No mountain open" }
        guard let day = liftDay else { return "No lifts run today" }
        let hours = "\(Self.clockText(day.openMinute))–\(Self.clockText(day.closeMinute))"
        return LiftDay.anyLiftRuns(bundle, weekday: solveWeekday, minute: solveMinuteOfDay)
            ? "Open, \(hours)" : "Closed at this time (\(hours))"
    }

    static func clockText(_ minuteOfDay: Int) -> String {
        String(format: "%02d:%02d", minuteOfDay / 60, minuteOfDay % 60)
    }

    /// The Time row's value on the Dev page.
    var timeValue: String {
        switch pretendTime {
        case .real: "Real"
        case .at: solveTimeText
        }
    }

    // MARK: Pretend weather

    /// From now on this phone's solver and weather card read `weather`; the
    /// mountain on screen switches at once, from the last real row.
    func setPretendWeather(_ weather: PretendWeather) {
        pretendWeather = weather
        backend.sandbox.setPretendWeather(weather)
        guard let resort = app.resort else { return }
        // A forecast replayed from the cache never passed through the sandbox.
        if let current = resort.conditions, current.source != PretendWeather.source {
            realConditions[resort.resortID] = current
        }
        let real = weather == .real ? realConditions[resort.resortID] : nil
        if let shown = backend.sandbox.conditions(resortID: resort.resortID) ?? real {
            resort.showConditions(shown)
        } else {
            note = "This mountain has no forecast. The pretend weather stays until the next read."
        }
    }

    private func applyPretendTime() {
        let now = Date()
        switch pretendTime {
        case .real:
            clock.setOffset(0)
        case .at(let minute):
            clock.setOffset(AdjustableClock.offset(toMinuteOfDay: minute, in: mountainTimeZone, now: now))
        }
    }

    // MARK: Test meet-up

    /// Where a test meet-up stands, in a line.
    func rehearsalLine(with id: UUID) -> String {
        let name = Self.name(of: id)
        return switch rehearsal(with: id) {
        case .idle: "Ready."
        case .solving: "Solving the meeting options…"
        case .waitingForAnswer: "Proposed. Waiting for \(name) to accept…"
        case .travelling: "Accepted. Both of you are on the way."
        case .arrived: "Arrived. The meet finishes when you are both there."
        case .ended(let reason): "Ended: \(reason)."
        case .failed(let message): message
        }
    }

    /// Proposes to a dev person from the map, as a tap would, and sends the
    /// first option. They accept after a few seconds and both travel; the
    /// meet's own screens show the rest.
    func runTestMeet(with friend: UUID) {
        guard let resort = app.resort, resort.ready != nil, isPlaced(friend) else { return }
        rehearsalPartner = friend
        rehearsalFailure = nil
        isRunningRehearsal = true
        app.showMap()
        run("rehearsal") { [weak self] in
            await self?.propose(to: friend, on: resort)
            self?.isRunningRehearsal = false
        }
    }

    private func propose(to friend: UUID, on resort: ResortModel) async {
        guard await Self.wait(until: { resort.friends[friend] != nil }) else {
            rehearsalFailure = "\(Self.name(of: friend)) isn't on the map yet."
            return
        }
        // An ended meet does not count: the tap clears it first.
        guard resort.canStartMeet else {
            rehearsalFailure = "Another meet is under way. End it first."
            return
        }
        resort.tapFriend(friend)
        guard await Self.wait(until: { Self.solved(for: friend, on: resort) }),
              case .proposing(let proposing) = resort.meet?.state, let meet = resort.meet else {
            rehearsalFailure = "No meeting options came back."
            return
        }
        guard let options = proposing.options?.options, !options.isEmpty else {
            rehearsalFailure = proposing.failure?.userMessage ?? "No meeting point can be reached from here."
            return
        }
        meet.pick(option: 0)
        guard await Self.wait(until: {
            if case .proposing(let proposing) = resort.meet?.state { return proposing.picked == 0 }
            return false
        }) else { return }
        meet.sendProposal()
    }

    /// The tray is open for this dev person and its solve has come back.
    private static func solved(for friend: UUID, on resort: ResortModel) -> Bool {
        guard resort.proposingFriend == friend,
              case .proposing(let proposing) = resort.meet?.state else { return false }
        return proposing.options != nil || proposing.failure != nil
    }

    /// The meet with this dev person, read from the meet on screen.
    func rehearsal(with friend: UUID) -> Rehearsal {
        let isLast = rehearsalPartner == friend
        if isLast, let rehearsalFailure { return .failed(rehearsalFailure) }
        guard let meet = app.resort?.meet, meet.partnerID == friend else {
            return isLast && isRunningRehearsal ? .solving : .idle
        }
        switch meet.state {
        case .proposing: return .solving
        case .proposed: return .waitingForAnswer
        case .incoming: return .waitingForAnswer
        case .active(let active): return active.arrived ? .arrived : .travelling
        case .ended(let ended):
            return .ended(ended.reason.map { "\($0.rawValue)" } ?? "backed out")
        }
    }

    /// Polls a condition every 200 ms. False when it never held.
    private static func wait(until condition: () -> Bool) async -> Bool {
        let tries = Int(rehearsalStepTimeoutS / 0.2)
        for _ in 0..<tries {
            if condition() { return true }
            do {
                try await Task.sleep(for: .milliseconds(200))
            } catch {
                return false
            }
        }
        return condition()
    }

    // MARK: Diagnostics

    /// Re-reads the diagnostics every two seconds while the page that asks is open.
    func keepDiagnosticsFresh() async {
        while !Task.isCancelled {
            refreshDiagnostics()
            do {
                try await Task.sleep(for: .seconds(Self.diagnosticsRefreshS))
            } catch {
                return
            }
        }
    }

    func refreshDiagnostics() {
        realtime = backend.diagnostics
        diagnosticsAt = Date()
    }

    /// The diagnostics as plain text on the clipboard, for a bug report.
    func copyDiagnostics() {
        refreshDiagnostics()
        UIPasteboard.general.string = diagnosticsText
        note = "Diagnostics copied."
        UIAccessibility.post(notification: .announcement, argument: "Diagnostics copied")
    }

    // MARK: Following the mountain on screen

    /// Re-registers on every change: the resort replaced, or its state moved.
    private func watchResort() {
        withObservationTracking {
            _ = app.resort
            _ = app.resort?.state
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.resortChanged()
                self?.watchResort()
            }
        }
    }

    private func resortChanged() {
        guard let resort = app.resort else {
            attached = nil
            return
        }
        if attached !== resort {
            attached = resort
            resort.tapOverride = tapOverride
            placedPeople = []
            rehearsalFailure = nil
        }
        guard let ready = resort.ready else { return }
        // The sandbox follows the mountain on screen and its status.
        let stage = RehearsalPartner.Stage(bundle: ready.bundle, status: ready.status, conditions: ready.conditions)
        let isNewMountain = devBundle != ready.bundle.id
        devBundle = ready.bundle.id
        if isNewMountain { shuffles = 0 }
        run("sandbox-stage") { [weak self, backend] in
            await backend.sandbox.stage(stage)
            guard let self else { return }
            placedPeople = backend.sandbox.placedPeople
            // "Show dev people" follows the tester to each mountain they open.
            if isNewMountain, wantsDevPeople {
                for person in devPeople where !isPlaced(person.id) { putBack(person.id) }
            }
        }
        if clockBundle != ready.bundle.id {
            clockBundle = ready.bundle.id
            applyPretendTime()
        }
    }

    /// StoreKit said App Store: everything goes back to normal at once.
    private func shutDown() {
        cancelPlacing()
        if isTeleported { returnToGPS() }
        wantsDevPeople = false
        for id in placedPeople { removeDevPerson(id) }
        backend.sandbox.setWithholdsPresence(false)
        if pretendWeather != .real { setPretendWeather(.real) }
        clock.setOffset(0)
        note = nil
    }

    /// One named piece of work at a time; starting it again replaces the last.
    private func run(_ name: String, _ operation: @escaping @MainActor () async -> Void) {
        work[name]?.cancel()
        work[name] = Task { await operation() }
    }
}
