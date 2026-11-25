import Foundation
import MountainCore

// Pure layout and wording rules for what floats over the map. The adapter and
// the app's views apply them; nothing here knows about Mapbox or SwiftUI.

// MARK: Amenity icons

/// Which icon a place draws on the map, from its kind and the amenities the
/// bundle lists for it. Food beats everything (a lodge is where people eat);
/// a building with nothing but a roof is a hut; the rest keep their kind's icon.
public enum PlaceIcon {
    /// Every image a place can name. The adapter registers exactly these.
    public static let all = [
        "fork.knife", "toilet.fill", "cross.case.fill", "parkingsign", "shippingbox.fill",
        "house.fill", "cablecar.fill", "triangle.fill", "mappin.circle.fill",
    ]

    /// Amenity keys in the order a card lists them. The pipeline emits `food`,
    /// `restrooms` and `indoor` today; the others are named so a later bundle
    /// that carries them draws without an app change.
    public static let amenityOrder = ["food", "restrooms", "first_aid", "rental", "parking", "indoor"]

    public static func icon(kind: RendezvousKind, amenities: [String]) -> String {
        let set = Set(amenities)
        if set.contains("food") { return "fork.knife" }
        if set.contains("first_aid") { return "cross.case.fill" }
        if set.contains("rental") { return "shippingbox.fill" }
        if set.contains("parking") { return "parkingsign" }
        if set.contains("restrooms") { return "toilet.fill" }
        if set.contains("indoor") { return "house.fill" }
        switch kind {
        case .lodge: return "house.fill"
        case .liftBase, .liftTop: return "cablecar.fill"
        case .landmark: return "triangle.fill"
        case .junction: return "mappin.circle.fill"
        }
    }

    /// Higher draws first where icons collide: a place to eat or get help wins
    /// over a lift station or a named junction.
    public static func priority(kind: RendezvousKind, amenities: [String]) -> Double {
        let set = Set(amenities)
        if set.contains("first_aid") { return 5 }
        if set.contains("food") { return 4 }
        if set.contains("restrooms") || set.contains("rental") { return 3 }
        if set.contains("indoor") || set.contains("parking") { return 2 }
        return kind == .junction ? 0 : 1
    }

    /// The amenities a card shows, known keys first in `amenityOrder`.
    public static func ordered(_ amenities: [String]) -> [String] {
        let known = amenityOrder.filter(amenities.contains)
        return known + amenities.filter { !amenityOrder.contains($0) }.sorted()
    }
}

// MARK: Timeline

/// The weather scrubber's window: the last and next twelve hours, reaching
/// further forward when a meet's arrival lies beyond that (to arrival plus
/// five minutes).
public enum TimelineWindow {
    public static let halfSpanS: TimeInterval = 12 * 3_600
    public static let arrivalMarginS: TimeInterval = 5 * 60

    public static func range(now: Date, arrival: Date?) -> ClosedRange<Date> {
        let start = now.addingTimeInterval(-halfSpanS)
        var end = now.addingTimeInterval(halfSpanS)
        if let arrival { end = max(end, arrival.addingTimeInterval(arrivalMarginS)) }
        return start...end
    }
}
