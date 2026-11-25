import AppCore
import Foundation
import MeetSolver
import MountainCore
import Observation
import PMLogging

extension AppModel {
    /// What wants fixes, from the projections: an active meet, live recording
    /// and whether the phone is at a resort (`LocationDemand`). Whether a
    /// resort is open reaches the driver through `ResortSession`'s start/stop.
    var locationDemand: LocationDemand {
        var meetActive = false
        if case .active = resort?.meet?.state { meetActive = true }
        // Without a catalog (offline, still loading) where the phone is is
        // unknown, which keeps presence routing-grade rather than browsing.
        let atResort: Bool? = activity.recordingAtResort ?? (catalog.resorts.isEmpty ? nil : lastFix.map { fix in
            ResortVicinity.resort(at: fix.coordinate, in: catalog.resorts, current: nil) != nil
        })
        return LocationDemand(
            recordingOn: activity.isRecordingOn, meetActive: meetActive, atResort: atResort,
            inBackground: isInBackground, locating: arrivalPending && profile != nil
        )
    }

    /// Hands the demand to the location driver now and whenever what it is
    /// made of changes. Called once from `start()`.
    func trackLocationDemand() {
        let demand = withObservationTracking { locationDemand } onChange: { [weak self] in
            Task { @MainActor in self?.trackLocationDemand() }
        }
        updateLocationDemand(demand)
    }

    /// Applies the demand, and asks for "Always" at the moment it is needed:
    /// a meet becoming active or recording being turned on, never at first
    /// launch (`specs/07-CLIENT.md` section 4). iOS shows that upgrade once.
    private func updateLocationDemand(_ demand: LocationDemand) {
        locationAccess.setDemand(demand)
        let mode = demand.mode
        guard mode != appliedLocationMode else { return }
        let previous = appliedLocationMode
        appliedLocationMode = mode
        deps.log.info(.location, "location mode \(previous?.rawValue ?? "none") → \(mode.rawValue)")
        if mode.wantsAlways, previous?.wantsAlways != true, !locationAlways,
           locationPermission != .denied {
            locationAccess.requestAlways()
        }
    }

    // MARK: Arrival

    /// How long the app looks for a fix to open the resort it is in.
    static let arrivalWindowS = 30.0

    /// Starts (or restarts) the window in which a fix may open the resort the
    /// phone is in (`ResortArrival`).
    func armArrival() {
        guard arrivalPending else { return }
        considerArrival()
        run("arrival-window") { [weak self] in
            do { try await Task.sleep(for: .seconds(Self.arrivalWindowS)) } catch { return }
            self?.arrivalPending = false
        }
    }

    /// Decides with the latest fix, once it is usable and the catalog and the
    /// profile are there; afterwards nothing happens until the next arming.
    func considerArrival() {
        guard arrivalPending, !isInBackground, profile != nil, !catalog.resorts.isEmpty, let fix = lastFix,
              ResortArrival.isUsable(fix, now: Date()) else { return }
        arrivalPending = false
        work["arrival-window"]?.cancel()
        var meetUnderWay = false
        if let state = resort?.meet?.state {
            if case .ended = state {} else { meetUnderWay = true }
        }
        let decision = ResortArrival.decide(
            fix: fix, resorts: catalog.resorts, current: resort?.resortID,
            userPicked: pickedResortThisSession, meetUnderWay: meetUnderWay, suppressed: arrivalSuppressed()
        )
        switch decision {
        case .open(let id):
            // Logs are public: which resort the skier reached stays out of them.
            deps.log.info(.location, "arrived at a resort: opening it")
            // The list that opened because no mountain was picked is answered.
            if floatingPicker == .resortPicker { closeFloating() }
            session.send(.resortSelected(id))
        case .ask(let ids):
            deps.log.info(.location, "inside \(ids.count) resorts' boxes: asking")
            arrivalChoices = ids
            openFloating(.resortPicker)
        case .stay:
            break
        }
    }
}
