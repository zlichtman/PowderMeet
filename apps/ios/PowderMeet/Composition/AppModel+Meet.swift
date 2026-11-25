import AppCore
import Foundation
import MapScene
import MapboxAdapter
import MeetSolver
import MountainCore
import Observation
import PMLogging
import PowderMeetAPI

extension AppModel {
    /// "Meet up" on a friend's card: back to the map, where the meeting
    /// options for them open in the context sheet, as a tap on their chip does.
    func startMeet(with friend: UUID) {
        guard let resort, canStartMeet else { return }
        showMap()
        resort.tapFriend(friend)
    }

    /// No meet is under way that a new one would replace: nothing yet, an unsent
    /// proposal, or one that has ended.
    var canStartMeet: Bool {
        resort?.canStartMeet ?? false
    }

    /// "View route": the map, framed on the route.
    func showRouteOnMap() {
        showMap()
        resort?.showRouteOnMap()
    }
}
