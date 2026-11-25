import MapScene
import MeetSolver
import MountainCore
import SwiftUI

/// Search for a meeting place by name (`specs/13-APP-MAP.md` section 2,
/// meet-up options): a floating list over the map like the resort picker,
/// with every meeting point in the resort (lodges, lifts, runs, landmarks),
/// filtered as you type. Choosing one asks the solver for it; it comes back
/// as one more option with both routes and who waits how long, to send like
/// any other.
struct MeetPlaceFloatingPicker: View {
    @Environment(AppModel.self) private var model
    let onClose: () -> Void
    @State private var query = ""
    /// The order picked last time, shared by the two place lists.
    @AppStorage(PlaceSearch.sortKey) private var sortChoice = PlaceSearch.Sort.kind.rawValue
    private var sort: PlaceSearch.Sort { PlaceSearch.Sort(rawValue: sortChoice) ?? .kind }

    var body: some View {
        if let resort = model.resort, let bundle = resort.bundle, let meet = resort.meet,
           case .proposing(let proposing) = meet.state {
            let places = PlaceSearch.places(in: bundle, matching: query)
            let requested = proposing.requested
            FloatingPicker(
                title: requested.map { Wording.placeTitle($0, in: bundle) } ?? "Meeting places",
                subtitle: requested == nil ? "Pick where to meet \(model.name(of: meet.partnerID))" : "Your pick",
                leading: AnyView(PlaceSearch.icon(requested.flatMap { bundle.rendezvous($0)?.kind })),
                query: $query, prompt: "Search lodges, lifts and runs",
                sort: AnyView(PlaceSearch.sortButton($sortChoice)), onClose: onClose
            ) {
                if requested != nil {
                    Button {
                        meet.request(place: nil)
                        onClose()
                    } label: {
                        FloatingRow(title: "Suggested places only", detail: "Takes your pick back") {
                            PlaceSearch.icon(nil, systemImage: "arrow.uturn.backward")
                        }
                    }
                    .buttonStyle(.plain)
                }
                ForEach(PlaceSearch.groups(places, sort: sort, here: model.lastFix?.coordinate), id: \.title) { group in
                    if !group.rows.isEmpty {
                        FloatingLabel(group.title).padding(.top, 10)
                        ForEach(group.rows) { place in
                            Button {
                                meet.request(place: place.id)
                                onClose()
                            } label: {
                                FloatingRow(title: place.title, detail: place.detail, selected: place.id == requested) {
                                    PlaceSearch.icon(place.kind)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                if places.isEmpty {
                    EmptyStateView(
                        icon: "magnifyingglass", title: "No meeting place matches",
                        detail: "Try a lodge, a lift or a run by name.")
                }
            }
        } else {
            // The request was answered or ended while the list was open: the
            // list has nothing to pick for, and an open list hides the map's
            // controls, so it closes itself.
            Color.clear.onAppear(perform: onClose)
        }
    }

}

/// Every place in the resort as rows to search, shared by the two lists that
/// pick one: where to meet, and where to go.
@MainActor
enum PlaceSearch {
    struct Place: Identifiable {
        let id: RendezvousID
        let kind: RendezvousKind
        let title: String
        let detail: String
        let searchable: String
        let coordinate: Coordinate?
    }

    /// How the list is ordered: in its groups, as one list by name, or by how
    /// far each place is from this phone.
    enum Sort: String {
        case kind, name, nearest
    }

    static let sortKey = "powdermeet.places.sort"

    static func sortButton(_ choice: Binding<String>) -> some View {
        FloatingSortButton(
            selection: Binding { Sort(rawValue: choice.wrappedValue) ?? .kind } set: { choice.wrappedValue = $0.rawValue },
            options: [
                (.kind, "Kind", "square.grid.2x2"),
                (.name, "Name", "textformat"),
                (.nearest, "Nearest", "location"),
            ])
    }

    /// `places` (already in name order) as the list's groups. Nearest without
    /// a position is the list by name.
    static func groups(_ places: [Place], sort: Sort, here: Coordinate?) -> [(title: String, rows: [Place])] {
        switch sort {
        case .kind:
            return sections.map { section in (section.title, places.filter { section.kinds.contains($0.kind) }) }
        case .nearest:
            guard let here else { return [("A to Z", places)] }
            let away = places.map { ($0, $0.coordinate.map { Geo.haversineM(here, $0) } ?? .infinity) }
            return [("Nearest first", away.sorted { $0.1 < $1.1 }.map(\.0))]
        case .name:
            return [("A to Z", places)]
        }
    }

    /// The groups in the order a skier thinks of them.
    static let sections: [(title: String, kinds: [RendezvousKind])] = [
        ("Lodges", [.lodge]),
        ("Runs", [.junction]),
        ("Lifts", [.liftBase, .liftTop]),
        ("Landmarks", [.landmark]),
    ]

    static func fold(_ text: String) -> String {
        text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }

    static func places(in bundle: ResortBundle, matching query: String) -> [Place] {
        let terms = fold(query).split(whereSeparator: \.isWhitespace).map(String.init)
        return bundle.rendezvous
            .map { point in
                let title = Wording.placeTitle(point.id, in: bundle)
                let detail = MeetPresentation.placeLine(point.id, in: bundle)
                return Place(
                    id: point.id, kind: point.kind, title: title, detail: detail,
                    searchable: fold("\(title) \(detail)"),
                    coordinate: bundle.graph.nodes[point.nodeID]?.coordinate)
            }
            .filter { place in terms.allSatisfy { place.searchable.contains($0) } }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    static func icon(_ kind: RendezvousKind?, systemImage: String? = nil) -> some View {
        Image(systemName: systemImage ?? MeetPresentation.kindIcon(kind))
            .font(.body.weight(.semibold))
            .foregroundStyle(HUDTheme.routeMeeting)
            .frame(width: 36, height: 36)
            .background(HUDGlass.well, in: Circle())
            .accessibilityHidden(true)
    }
}

/// The rows of the Go-to list: lodges and landmarks from the meeting points,
/// runs and lifts from the mountain's own named runs and lifts, so every one
/// of them can be found and each routes as its card's "Go to" does (a run to
/// its top, a lift to its bottom station), not to a meeting point at a run's
/// foot.
@MainActor
enum GoToSearch {
    struct Row: Identifiable {
        let id: String
        let destination: GoToDestination
        let section: String
        let kind: RendezvousKind
        let title: String
        let detail: String
        let searchable: String
        let coordinate: Coordinate?
    }

    static let sections = ["Lodges", "Runs", "Lifts", "Landmarks"]

    static func rows(in bundle: ResortBundle, matching query: String) -> [Row] {
        var rows: [Row] = []
        for point in bundle.rendezvous where point.kind == .lodge || point.kind == .landmark {
            let title = Wording.placeTitle(point.id, in: bundle)
            let detail = MeetPresentation.placeLine(point.id, in: bundle)
            rows.append(Row(
                id: "place:\(point.id.rawValue)", destination: .place(point.id),
                section: point.kind == .lodge ? "Lodges" : "Landmarks", kind: point.kind,
                title: title, detail: detail, searchable: PlaceSearch.fold("\(title) \(detail)"),
                coordinate: bundle.graph.nodes[point.nodeID]?.coordinate))
        }
        // One row a name: a run mapped in several pieces is one run to a skier.
        var named: Set<String> = []
        for group in bundle.groups {
            let name = group.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let isLift = group.kind == .lift
            guard !name.isEmpty, named.insert("\(isLift)|\(PlaceSearch.fold(name))").inserted else { continue }
            let detail = isLift ? "Lift" : (group.difficulty ?? .unknown).displayName
            rows.append(Row(
                id: "group:\(group.id.rawValue)", destination: .group(group.id),
                section: isLift ? "Lifts" : "Runs", kind: isLift ? .liftBase : .junction,
                title: name, detail: detail, searchable: PlaceSearch.fold("\(name) \(detail)"),
                coordinate: GoToPlanner.entryNode(of: group, in: bundle)?.coordinate))
        }
        let terms = PlaceSearch.fold(query).split(whereSeparator: \.isWhitespace).map(String.init)
        return rows
            .filter { row in terms.allSatisfy { row.searchable.contains($0) } }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    /// `rows` (in name order) as the list's groups, like `PlaceSearch.groups`.
    static func groups(_ rows: [Row], sort: PlaceSearch.Sort, here: Coordinate?) -> [(title: String, rows: [Row])] {
        switch sort {
        case .kind:
            return sections.map { section in (section, rows.filter { $0.section == section }) }
        case .nearest:
            guard let here else { return [("A to Z", rows)] }
            let away = rows.map { ($0, $0.coordinate.map { Geo.haversineM(here, $0) } ?? .infinity) }
            return [("Nearest first", away.sorted { $0.1 < $1.1 }.map(\.0))]
        case .name:
            return [("A to Z", rows)]
        }
    }
}

/// Search the open mountain for somewhere to go (the search button in the
/// bottom row): the same list of lodges, runs, lifts and landmarks; choosing
/// one plans the solo route there, as "Go to" on its card does.
struct GoToFloatingPicker: View {
    @Environment(AppModel.self) private var model
    let onClose: () -> Void
    @State private var query = ""
    /// The order picked last time, shared by the two place lists.
    @AppStorage(PlaceSearch.sortKey) private var sortChoice = PlaceSearch.Sort.kind.rawValue
    private var sort: PlaceSearch.Sort { PlaceSearch.Sort(rawValue: sortChoice) ?? .kind }

    var body: some View {
        if let bundle = model.resort?.bundle {
            let places = GoToSearch.rows(in: bundle, matching: query)
            FloatingPicker(
                title: "Go to", subtitle: "Pick a place and get the route there",
                leading: AnyView(PlaceSearch.icon(nil, systemImage: "arrow.triangle.turn.up.right.diamond.fill")),
                query: $query, prompt: "Search lodges, lifts and runs",
                sort: AnyView(PlaceSearch.sortButton($sortChoice)), onClose: onClose
            ) {
                ForEach(GoToSearch.groups(places, sort: sort, here: model.lastFix?.coordinate), id: \.title) { group in
                    if !group.rows.isEmpty {
                        FloatingLabel(group.title).padding(.top, 10)
                        ForEach(group.rows) { place in
                            Button {
                                model.goTo(place.destination)
                                onClose()
                            } label: {
                                FloatingRow(title: place.title, detail: place.detail) {
                                    PlaceSearch.icon(place.kind)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                if places.isEmpty {
                    EmptyStateView(
                        icon: "magnifyingglass", title: "No place matches",
                        detail: "Try a lodge, a lift or a run by name.")
                }
            }
        } else {
            Color.clear.onAppear(perform: onClose)
        }
    }
}
