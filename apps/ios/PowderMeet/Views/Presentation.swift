import AppCore
import MapScene
import MeetSolver
import MountainCore
import PowderMeetAPI
import SwiftUI

// Wording and small formatting the screens share. Pure functions of projection
// values: nothing here reads a session or holds state.

nonisolated extension Difficulty {
    var displayName: String {
        switch self {
        case .green: "Green"
        case .blue: "Blue"
        case .black: "Black"
        case .doubleBlack: "Double Black"
        case .park: "Terrain Park"
        case .unknown: "Unrated"
        }
    }

    /// The trail-map glyph.
    var icon: String {
        switch self {
        case .green: "circle.fill"
        case .blue: "square.fill"
        case .black, .doubleBlack: "diamond.fill"
        case .park: "star.fill"
        case .unknown: "questionmark"
        }
    }
}

nonisolated extension Ability {
    /// The skill tier a profile's `ability` string names.
    init(profileValue: String) {
        self = Ability(rawValue: profileValue) ?? .intermediate
    }

    var label: String { rawValue.capitalized }
}

nonisolated enum Wording {
    /// "Roundhouse Lodge", or the id made readable when the bundle lacks it.
    static func rendezvousName(_ id: RendezvousID, in bundle: ResortBundle?) -> String {
        (bundle?.rendezvous(id)?.name
            ?? id.rawValue.replacingOccurrences(of: "-", with: " ").capitalized)
    }

    /// A place's name as a card title, above `MeetPresentation.placeLine`: "Garbanzo
    /// Express", since the line under it already says "Lift base". Sentences keep the
    /// whole name from `rendezvousName`.
    static func placeTitle(_ id: RendezvousID, in bundle: ResortBundle?) -> String {
        let name = rendezvousName(id, in: bundle)
        let suffixes: [String]
        switch bundle?.rendezvous(id)?.kind {
        case .liftBase: suffixes = [" base", " bottom"]
        case .liftTop: suffixes = [" top", " summit"]
        default: return name
        }
        for suffix in suffixes where name.lowercased().hasSuffix(suffix) && name.count > suffix.count + 2 {
            return String(name.dropLast(suffix.count))
        }
        return name
    }

    /// "12 ± 3 min", "1 h 5 min ± 4": an ETA always shows its uncertainty (I-10).
    static func eta(_ eta: ETA) -> String {
        let mean = max(1, Int((eta.meanS / 60).rounded()))
        let sd = max(1, Int((max(eta.sdS, 60) / 60).rounded()))
        return mean >= 60 ? "\(minutes(eta.meanS)) ± \(sd)" : "\(mean) ± \(sd) min"
    }

    static func eta(seconds: Int?, sd: Int?) -> String {
        guard let seconds else { return "—" }
        return eta(ETA(meanS: Double(seconds), sdS: Double(sd ?? 0)))
    }

    /// "12 min", "1 h 5 min".
    static func minutes(_ seconds: Double) -> String {
        let minutes = max(1, Int((seconds / 60).rounded()))
        return minutes >= 60 ? "\(minutes / 60) h \(minutes % 60) min" : "\(minutes) min"
    }

    /// Where a run came from (`descents.source`), in words: "Apple Health".
    static func runSource(_ source: String) -> String {
        switch source {
        case "live": "Recorded live"
        case "healthkit": "Apple Health"
        case "slopes": "Slopes"
        case "gpx": "GPX file"
        case "tcx": "TCX file"
        case "fit": "FIT file"
        default: "Imported"
        }
    }

    /// A friend's line on the Friends page: the run or lift, else the resort,
    /// while their position there is live; otherwise their level, or nothing
    /// when they never set one.
    static func friendDetail(live: Bool, place: String?, resortName: String?, ability: String?) -> String? {
        if live { return place ?? "At \(resortName ?? "the mountain") now" }
        return ability.flatMap(Ability.init(rawValue:))?.label
    }

    /// How fresh a friend's position is: "Live", "4 min ago", "Lost signal".
    static func signal(_ signal: FriendSignal) -> String {
        func ago(_ minutes: Int) -> String {
            let m = max(0, minutes)
            if m < 1 { return "Just now" }
            if m < 60 { return "\(m) min ago" }
            return "\(m / 60) h ago"
        }
        return switch signal {
        case .live: "Live"
        case .stale(let minutes): ago(minutes)
        case .cold(let minutes): minutes >= 10 ? "Lost signal" : ago(minutes)
        }
    }

    /// Open, Partly open · 3 of 5, Closed: the map's own answer for a run or lift.
    static func availability(_ availability: TerrainAvailability) -> String {
        switch availability {
        case .open: "Open"
        case .partiallyOpen(let open, let total): "Partly open · \(open) of \(total)"
        case .closed: "Closed"
        }
    }

    /// "Now", "4 min ago", "2 h ago".
    static func age(since date: Date, now: Date = Date()) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        if seconds < 60 { return "Now" }
        if seconds < 3_600 { return "\(Int(seconds / 60)) min ago" }
        return "\(Int(seconds / 3_600)) h ago"
    }

    /// The message for badges just earned: "New badge · Silver Explorer",
    /// "New badges · Logbook and Century", or the first two and how many more.
    static func newBadges(_ earned: [Badges.Earned]) -> String {
        let names = earned.map { standing in
            standing.tier.map { "\(String(describing: $0).capitalized) \(standing.badge.title)" }
                ?? standing.badge.title
        }
        let list = switch names.count {
        case 0, 1: names.first ?? ""
        case 2, 3: names.dropLast().joined(separator: ", ") + " and " + (names.last ?? "")
        default: names.prefix(2).joined(separator: ", ") + " and \(names.count - 2) more"
        }
        return "\(names.count == 1 ? "New badge" : "New badges") · \(list)"
    }

    /// The weather that steered a route, as a skier would put it.
    static func weatherFavour(_ favour: WeatherFavour) -> String {
        switch favour {
        case .sunnySide: "Sunny side"
        case .shadySide: "Out of the slush"
        case .outOfTheWind: "Out of the wind"
        case .clearerView: "Better visibility"
        }
    }

    /// One solver reason in plain words, for an option card.
    /// `me` is the viewer's skier id, for reasons that are about one skier.
    static func reason(_ reason: Reason, partnerName: String, me: UUID? = nil) -> String {
        let partner = partnerName
        // Mid-sentence only, so the viewer is "you".
        func who(_ skier: UUID) -> String { skier == me ? "you" : partner }
        return switch reason {
        case .skiOnTogether(let run):
            // A run without a name is said without one.
            if let run = run?.trimmingCharacters(in: .whitespaces), !run.isEmpty {
                "Ski on together down \(run)"
            } else {
                "Ski on together from here"
            }
        case .alreadyThere(let skier):
            skier == me ? "You are already there" : "\(partner) is already there"
        case .lodgeAlternative: "Lodge option · Meet inside and take a break"
        case .noOnwardRouteFor(let skier):
            skier == me ? "You have no way on from here" : "\(partner) has no way on from here"
        case .lapWhileWaitingFor(let skier):
            skier == me ? "Time for a lap while you wait" : "\(partner) has time for a lap"
        case .longWaitUnavoidable(let skier):
            skier == me
                ? "Uneven, but the best stop there is · You get there well before \(partner)"
                : "Uneven, but the best stop there is · \(partner) gets there well before you"
        case .noLiftsRunning: "No lifts running · Downhill only"
        case .closerForYou: "Closer for you"
        case .lessWaitFor(let skier): "Less waiting for \(who(skier))"
        case .indoor: "Indoors"
        case .avoidsBlackFor(let skier): "No black runs for \(who(skier))"
        case .onlyOptionUnderClosures: "The only option with today's closures"
        case .statusUnknown: "Status unknown · Using scheduled hours"
        case .easiestWayDownFor(let skier):
            "Easiest way down for \(who(skier))"
        case .windHoldLikelyFor(let skier):
            skier == me
                ? "Strong gusts · A lift on your way may be on wind hold"
                : "Strong gusts · A lift on \(partner)'s way may be on wind hold"
        }
    }

    /// What sets a run's own weather apart from the resort reading, or nil
    /// when nothing does: "On this run: in cloud · thawed and refrozen".
    static func runConditions(_ local: LocalConditions) -> String? {
        var parts: [String] = []
        if local.inCloud {
            parts.append("in cloud")
        } else if local.sunExposure >= 0.35 {
            parts.append("in the sun")
        }
        if local.refrozen { parts.append("thawed and refrozen") }
        return parts.isEmpty ? nil : "On this run: " + parts.joined(separator: " · ")
    }

    /// What an easiest way down has above the skier's level, as a sentence:
    /// "One blue run is above your level."
    static func easiestWayDownSummary(_ easiest: EasiestWayDown, isYou: Bool) -> String {
        let order: [Difficulty] = [.doubleBlack, .black, .park, .blue, .green, .unknown]
        let parts = order.compactMap { difficulty -> String? in
            guard let count = easiest.runsAboveLevel[difficulty], count > 0 else { return nil }
            let name = switch difficulty {
            case .doubleBlack: "double black"
            case .black: "black"
            case .park: "park"
            case .blue: "blue"
            case .green: "green"
            case .unknown: "unrated"
            }
            return "\(countWord(count)) \(name) \(count == 1 ? "run" : "runs")"
        }
        let whose = isYou ? "your" : "their"
        guard !parts.isEmpty else { return "Part of the way is above \(whose) level." }
        let list = parts.count == 1 ? parts[0]
            : parts.dropLast().joined(separator: ", ") + " and " + parts[parts.count - 1]
        let verb = easiest.runCount == 1 ? "is" : "are"
        let sentence = "\(list) \(verb) above \(whose) level."
        return sentence.prefix(1).uppercased() + sentence.dropFirst()
    }

    private static func countWord(_ count: Int) -> String {
        let words = ["zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine"]
        return words.indices.contains(count) ? words[count] : "\(count)"
    }

    /// Why a meet ended, in words. Only the invitee declines, or has no route
    /// under the closures, so `viewerIsInvitee` turns those two into "You ...".
    /// When the server says who ended the meet, `endedByViewer` words a cancel,
    /// a decline or a leave from the viewer's side; nil keeps the guess above.
    static func ended(
        _ reason: MeetEndReason?, partnerName: String, viewerIsInvitee: Bool = false, endedByViewer: Bool? = nil
    ) -> String {
        let partner = partnerName
        if let endedByViewer {
            let who = endedByViewer ? "You" : partner
            switch reason {
            case .declinedByUser: return "\(who) declined"
            case .declinedCannotRoute:
                return endedByViewer
                    ? "You have no route under current closures" : "\(partner) has no route under current closures"
            case .userCancelled: return "\(who) cancelled the meet"
            case .partnerLeft: return "\(who) left the meet"
            default: break
            }
        }
        return switch reason {
        case .arrived: "You met up"
        case .declinedByUser: viewerIsInvitee ? "You declined" : "\(partner) declined"
        case .declinedCannotRoute:
            viewerIsInvitee ? "You have no route under current closures" : "\(partner) has no route under current closures"
        case .userCancelled: "Meet cancelled"
        case .timeout: "The request expired"
        case .rendezvousRemoved: "That meeting point is no longer on the map"
        case .statusBlocksRoute: "A closure blocks the route"
        case .partnerLeft: "\(partner) left the meet"
        case .superseded: "Replaced by a newer request"
        case nil: "Meet ended"
        }
    }

    static func initials(_ name: String) -> String {
        let parts = name.split(separator: " ").prefix(2)
        let letters = parts.compactMap(\.first).map(String.init).joined()
        return letters.isEmpty ? "?" : letters.uppercased()
    }
}

/// A circle with a person's initials, for people without a photo.
struct InitialsAvatar: View {
    let name: String
    var size: CGFloat = 36

    var body: some View {
        Circle()
            .fill(HUDTheme.accent.opacity(0.28))
            .frame(width: size, height: size)
            .overlay(
                Text(Wording.initials(name))
                    .font(.system(size: size * 0.38, weight: .semibold))
                    .foregroundStyle(HUDTheme.primaryText)
            )
            .accessibilityHidden(true)
    }
}
