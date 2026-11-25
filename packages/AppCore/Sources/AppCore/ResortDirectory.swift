import Foundation
import MountainCore
import PowderMeetAPI

/// How the resort picker lays out the catalog: the resorts this phone used
/// last, the ones nearest to it, then every resort by country. A resort with no
/// published map is listed (so its absence is explained) but never offered as
/// last used.
public enum ResortDirectory {
    public struct Section: Identifiable, Hashable, Sendable {
        public enum Kind: Hashable, Sendable {
            case matches, lastUsed, nearest, country, pass, all
        }

        public var id: String
        public var kind: Kind
        /// The country for a `country` section; fixed text otherwise.
        public var title: String
        public var resorts: [PublishedResort]
    }

    /// How the whole list is ordered when nothing is typed. `country` is the
    /// picker's own layout (last used, nearest, then by country).
    public enum Sort: String, CaseIterable, Sendable {
        case country, nearest, name, pass
    }

    public static let lastUsedLimit = 3
    public static let nearestLimit = 3
    /// Beyond this a resort is not "near" in any useful sense.
    public static let nearestWithinM = 500_000.0

    /// - Parameters:
    ///   - query: what is typed in the search field; every word must match the
    ///     name, another name the resort goes by (`aliases`), a pass, the
    ///     region (its code or, in the USA and Canada, its full name) or the
    ///     country.
    ///   - here: this phone's position, when it is known.
    ///   - recent: resort ids, most recently used first.
    ///   - sort: the order with nothing typed. `nearest` without a position
    ///     falls back to names.
    public static func sections(
        _ resorts: [PublishedResort], query: String = "", here: Coordinate? = nil, recent: [String] = [],
        sort: Sort = .country
    ) -> [Section] {
        let byName = resorts.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        let terms = fold(query).split(whereSeparator: \.isWhitespace).map(String.init)
        if !terms.isEmpty {
            let matches = byName.filter { resort in
                let text = fold(searchText(resort))
                return terms.allSatisfy(text.contains)
            }
            // Nearest keeps its order while searching; the other orders are
            // by name within the matches anyway.
            var found = matches
            if sort == .nearest, let here {
                found = matches.map { ($0, $0.center.map { Geo.haversineM(here, $0) } ?? .infinity) }
                    .sorted { $0.1 < $1.1 }.map(\.0)
            }
            // Resorts that can be opened come first.
            let ordered = found.filter(\.hasMap) + found.filter { !$0.hasMap }
            return ordered.isEmpty ? [] : [Section(id: "matches", kind: .matches, title: "Matches", resorts: ordered)]
        }

        switch sort {
        case .country:
            break
        case .name:
            return byName.isEmpty ? [] : [Section(id: "all", kind: .all, title: "A to Z", resorts: byName)]
        case .nearest:
            guard let here else {
                return byName.isEmpty ? [] : [Section(id: "all", kind: .all, title: "A to Z", resorts: byName)]
            }
            func away(_ resort: PublishedResort) -> Double {
                resort.center.map { Geo.haversineM(here, $0) } ?? .infinity
            }
            // Stable, so resorts with no known place keep their name order at the end.
            let ordered = byName.map { ($0, away($0)) }.sorted { $0.1 < $1.1 }.map(\.0)
            return ordered.isEmpty ? [] : [Section(id: "all", kind: .all, title: "Nearest first", resorts: ordered)]
        case .pass:
            // A resort on two passes is listed under each.
            let other = "No pass"
            var groups: [String: [PublishedResort]] = [:]
            for resort in byName {
                for pass in resort.passProducts.isEmpty ? [other] : resort.passProducts {
                    groups[pass, default: []].append(resort)
                }
            }
            return groups.keys
                .sorted { a, b in
                    if (a == other) != (b == other) { return b == other }
                    if groups[a]!.count != groups[b]!.count { return groups[a]!.count > groups[b]!.count }
                    return a < b
                }
                .map { Section(id: "pass:\($0)", kind: .pass, title: $0, resorts: groups[$0]!) }
        }

        var sections: [Section] = []
        let known = Dictionary(byName.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let lastUsed = recent.compactMap { known[$0] }.filter(\.hasMap).prefix(lastUsedLimit)
        if !lastUsed.isEmpty {
            sections.append(Section(id: "last-used", kind: .lastUsed, title: "Last used", resorts: Array(lastUsed)))
        }

        var distance: [String: Double] = [:]
        if let here {
            for resort in byName {
                if let center = resort.center { distance[resort.id] = Geo.haversineM(here, center) }
            }
            let nearest = byName
                .filter { (distance[$0.id] ?? .infinity) <= nearestWithinM }
                .sorted { distance[$0.id]! < distance[$1.id]! }
                .prefix(nearestLimit)
            if !nearest.isEmpty {
                sections.append(Section(id: "nearest", kind: .nearest, title: "Nearest", resorts: Array(nearest)))
            }
        }

        // Countries: the closest one first when the position is known, otherwise
        // the ones with the most resorts. Resorts with no country come last.
        let other = "OTHER"
        let groups = Dictionary(grouping: byName) { $0.country ?? other }
        func closest(_ members: [PublishedResort]) -> Double {
            members.compactMap { distance[$0.id] }.min() ?? .infinity
        }
        let countries = groups.keys.sorted { a, b in
            if (a == other) != (b == other) { return b == other }
            let (ga, gb) = (groups[a]!, groups[b]!)
            if here != nil, closest(ga) != closest(gb) { return closest(ga) < closest(gb) }
            if ga.count != gb.count { return ga.count > gb.count }
            return a < b
        }
        for country in countries {
            // A catalog that names no country at all (a database from before
            // migration 0012) is simply the list of resorts.
            let title = countries.count == 1 && country == other ? "All resorts" : country
            sections.append(Section(
                id: "country:\(country)", kind: .country, title: title, resorts: groups[country]!
            ))
        }
        return sections
    }

    /// The picker opened because the phone is inside several resorts' boxes
    /// (`ResortArrival.Decision.ask`): just those, in the order given.
    public static func arrivalChoices(_ ids: [String], in resorts: [PublishedResort]) -> [Section] {
        let chosen = ids.compactMap { id in resorts.first { $0.id == id } }
        return chosen.isEmpty ? [] : [Section(id: "nearest", kind: .nearest, title: "You're at", resorts: chosen)]
    }

    /// The distance from `here` to a resort's centre, when both are known.
    public static func distanceM(to resort: PublishedResort, from here: Coordinate?) -> Double? {
        guard let here, let center = resort.center else { return nil }
        return Geo.haversineM(here, center)
    }

    /// `recent` with `resortID` moved to the front, without duplicates.
    public static func noting(_ resortID: String, in recent: [String], limit: Int = 8) -> [String] {
        Array(([resortID] + recent.filter { $0 != resortID }).prefix(limit))
    }

    /// Everything a resort can be found by, as one string.
    static func searchText(_ resort: PublishedResort) -> String {
        var words = [resort.name, resort.region ?? "", resort.country ?? ""]
        words += resort.aliases + resort.passProducts
        if let region = resort.region, let name = regionNames[region] { words.append(name) }
        if resort.country == "USA" { words.append("United States America") }
        return words.joined(separator: " ")
    }

    /// State and province names for the region codes the catalog uses in the
    /// USA and Canada (elsewhere `region` is the country code and `country`
    /// already spells it out).
    static let regionNames: [String: String] = [
        "AK": "Alaska", "CA": "California", "CO": "Colorado", "ID": "Idaho", "IN": "Indiana",
        "MA": "Massachusetts", "ME": "Maine", "MI": "Michigan", "MN": "Minnesota",
        "MO": "Missouri", "MT": "Montana", "NH": "New Hampshire", "NM": "New Mexico",
        "NV": "Nevada", "NY": "New York", "OH": "Ohio", "OR": "Oregon", "PA": "Pennsylvania",
        "UT": "Utah", "VT": "Vermont", "WA": "Washington", "WI": "Wisconsin",
        "WV": "West Virginia", "WY": "Wyoming",
        "AB": "Alberta", "BC": "British Columbia", "ON": "Ontario", "QC": "Québec",
    ]

    /// How fresh a resort's map is, in the words a row can say it in: the
    /// day it was built when that is more than a few days back, with its year
    /// once it is from an earlier one.
    public enum Freshness: Hashable, Sendable {
        case today, yesterday, thisWeek
        case on(Date, showsYear: Bool)
    }

    /// A build "in the future" (the phone's clock behind the server's) is today.
    public static func freshness(builtAt: Date, now: Date, calendar: Calendar = .current) -> Freshness {
        let built = calendar.startOfDay(for: builtAt)
        let today = calendar.startOfDay(for: now)
        let days = calendar.dateComponents([.day], from: built, to: today).day ?? 0
        switch days {
        case ...0: return .today
        case 1: return .yesterday
        case 2..<7: return .thisWeek
        default:
            return .on(builtAt, showsYear: calendar.component(.year, from: builtAt) != calendar.component(.year, from: now))
        }
    }

    private static func fold(_ text: String) -> String {
        text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }
}
