import AppCore
import MountainCore
import PowderMeetAPI
import SwiftUI

/// Picks the resort: a floating list over the map with a search field, then
/// the whole catalog (last used, nearest, then by country; which goes where is
/// `ResortDirectory`'s). Every row is one glass card of one height and one
/// layout, map or no map: the name and where it is on the
/// left; on the right a block of one fixed width with the passes and map
/// status, and a pill saying how fresh the map is ("Today", "This week",
/// "22 Nov"). A resort without a published map is dimmed and cannot be
/// opened; the selected one has the accent ring. Last, a row to ask for a
/// resort that is not listed.
struct ResortPickerSheet: View {
    let onClose: () -> Void
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    @State private var searchText = ""
    /// The order picked last time, kept between openings.
    @AppStorage("powdermeet.resorts.sort") private var sortChoice = ResortDirectory.Sort.country.rawValue
    /// The resort tapped while a meet is on: opening it leaves the meet, so
    /// the skier is asked first, as End asks.
    @State private var resortAwaitingLeave: PublishedResort?

    /// The right-hand block's width; it grows with Dynamic Type.
    @ScaledMetric(relativeTo: .caption) private var statusBlockWidth: CGFloat = 132

    init(onClose: @escaping () -> Void = {}) {
        self.onClose = onClose
    }

    private var catalog: CatalogState { model.catalog }

    private var isSearching: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var sort: ResortDirectory.Sort { ResortDirectory.Sort(rawValue: sortChoice) ?? .country }

    private var sections: [ResortDirectory.Section] { model.resortSections(matching: searchText, sort: sort) }

    private var sortButton: some View {
        FloatingSortButton(
            selection: Binding { sort } set: { sortChoice = $0.rawValue },
            options: [
                (.country, "Country", "globe.americas"),
                (.nearest, "Nearest", "location"),
                (.name, "Name", "textformat"),
                (.pass, "Pass", "ticket"),
            ])
    }

    private var availableCount: Int { catalog.resorts.count { $0.hasMap } }

    private static func mapDateFormatter(_ template: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate(template)
        return formatter
    }

    private static let shortDate = mapDateFormatter("d MMM")
    private static let shortDateWithYear = mapDateFormatter("d MMM yyyy")
    private static let spokenDate = mapDateFormatter("d MMMM")
    private static let spokenDateWithYear = mapDateFormatter("d MMMM yyyy")

    var body: some View {
        FloatingPicker(
            title: model.selectedResort?.name ?? "Choose a resort", subtitle: isSearching ? countLine : nil,
            query: $searchText, prompt: "Search resorts", sort: AnyView(sortButton), onClose: onClose
        ) {
                if let failure = catalog.failure {
                    failureCard(failure)
                }
                let sections = sections
                // How many mountains there are, at the top, on its own.
                if !isSearching, availableCount > 0 {
                    FloatingLabel("\(availableCount) mountains")
                }
                ForEach(sections) { section in
                    FloatingLabel(
                        section.kind == .country || section.kind == .pass
                            ? "\(section.title) · \(section.resorts.count)" : section.title)
                        .padding(.top, 10)
                    // A resort can sit in two sections (recent, nearest, its
                    // country); one LazyVStack needs a unique id per row, or rows
                    // blank out while scrolling.
                    ForEach(section.resorts, id: \.id) { resort in
                        resortRow(resort)
                            .id("\(section.id)/\(resort.id)")
                    }
                }

                if catalog.isLoading, catalog.resorts.isEmpty {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(24)
                        .accessibilityLabel("Loading resorts")
                } else if sections.isEmpty, catalog.failure == nil {
                    EmptyStateView(
                        icon: "mountain.2", title: "No mountains found",
                        detail: isSearching ? "Try a mountain name, pass, state or country." : "The resort list is empty.")
                    .glassCard()
                }
                if !catalog.isLoading || !catalog.resorts.isEmpty {
                    requestRow.padding(.top, 10)
                }
        }
        .task {
            if catalog.resorts.isEmpty, !catalog.isLoading {
                model.loadCatalog()
            }
        }
        .confirmCard(
            item: $resortAwaitingLeave, title: { _ in "Leave your meet-up?" },
            message: { "Opening \($0.name) ends it for you and \(leavesMeetWith ?? "your friend")." },
            confirm: "Leave", cancel: "Stay"
        ) { model.selectResort($0.id) }
    }

    /// The friend a meet under way, or a request sent or received, is with:
    /// opening another mountain would end it for both.
    private var leavesMeetWith: String? {
        guard let meet = model.resort?.meet else { return nil }
        switch meet.state {
        case .proposed, .incoming, .active: return model.name(of: meet.partnerID)
        // Changing the spot of a request already sent: that request is still
        // live until its replacement goes out.
        case .proposing(let proposing): return proposing.replacing == nil ? nil : model.name(of: meet.partnerID)
        case .ended: return nil
        }
    }

    private var countLine: String { "\(sections.reduce(0) { $0 + $1.resorts.count }) matches" }

    private func failureCard(_ failure: PowderMeetError) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Resorts didn't load")
                .textRole(.bodyEmph)
                .foregroundStyle(HUDTheme.primaryText)
            Text(failure.userMessage)
                .textRole(.label)
                .foregroundStyle(HUDTheme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            SecondaryButton(title: "Retry", isLoading: catalog.isLoading) { model.loadCatalog() }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
    }

    // MARK: Row

    /// Two lines on each side in every row, placeholders holding the space,
    /// so every row is the same height without a fixed frame.
    private func resortRow(_ resort: PublishedResort) -> some View {
        let isSelected = resort.id == model.resort?.resortID
        let passes = resort.passProducts.sorted()

        return Button {
            if !isSelected, leavesMeetWith != nil {
                resortAwaitingLeave = resort
            } else {
                model.selectResort(resort.id)
            }
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(resort.name)
                        .textRole(.bodyEmph)
                        .foregroundStyle(HUDTheme.primaryText)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                    placeTags(resort)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(alignment: .trailing, spacing: 4) {
                    HStack(spacing: 4) {
                        ForEach(passes, id: \.self) { pass in
                            StatusChip(
                                text: pass.capitalized,
                                tint: pass.lowercased() == "epic" ? HUDTheme.accentCyan : HUDTheme.accentAmber)
                        }
                        StatusChip(text: "", tint: HUDTheme.accentGreen, systemImage: "map.fill")
                    }
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    StatusChip(
                        text: updatedText(resort, isSelected: isSelected),
                        tint: resort.hasMap ? HUDTheme.accent : HUDTheme.secondaryText,
                        systemImage: "arrow.triangle.2.circlepath")
                        .monospacedDigit()
                        .minimumScaleFactor(0.8)
                }
                .frame(width: statusBlockWidth, alignment: .trailing)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassCardControl(padding: 14, selected: isSelected)
            .opacity(resort.hasMap ? 1 : 0.55)
        }
        .buttonStyle(.plain)
        .disabled(!resort.hasMap)
        .accessibilityLabel(accessibilityLabel(resort, passes: passes))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    /// How fresh the map is: "Today", "Yesterday", "This week", then its
    /// date ("12 Nov", "12 Nov 2025"); "—" for a resort with no map yet.
    private func updatedText(_ resort: PublishedResort, isSelected: Bool) -> String {
        guard resort.hasMap, let built = mapBuiltAt(resort, isSelected: isSelected) else { return "—" }
        switch ResortDirectory.freshness(builtAt: built, now: Date()) {
        case .today: return "Today"
        case .yesterday: return "Yesterday"
        case .thisWeek: return "This week"
        case .on(let date, let showsYear): return (showsYear ? Self.shortDateWithYear : Self.shortDate).string(from: date)
        }
    }

    /// The same, as VoiceOver says it: "map updated this week".
    private func spokenUpdate(_ built: Date) -> String {
        switch ResortDirectory.freshness(builtAt: built, now: Date()) {
        case .today: return "map updated today"
        case .yesterday: return "map updated yesterday"
        case .thisWeek: return "map updated this week"
        case .on(let date, let showsYear):
            return "map updated \((showsYear ? Self.spokenDateWithYear : Self.spokenDate).string(from: date))"
        }
    }

    /// A resort that is not listed is asked for where support is: the
    /// project's public issues page (Settings → About → Support).
    private var requestRow: some View {
        Button {
            if let url = SupportLinks.support { openURL(url) }
        } label: {
            FloatingRow(title: "Request a resort", detail: "Not listed? Ask for it on the support page.") {
                ContextGlyph(systemImage: "plus", tint: HUDTheme.accent)
            }
        }
        .buttonStyle(.plain)
        .accessibilityHint("Opens the support page")
    }

    /// Under the name, the same tags in the same order on every row: the
    /// country's flag, the state or province, how far away it is, and how its
    /// lift status is known (an hourglass for scheduled hours, a signal for live).
    private func placeTags(_ resort: PublishedResort) -> some View {
        // Outside the USA and Canada the region is just the country's code.
        let region = resort.region.flatMap { region in
            region.count > 2 || resort.country == "USA" || resort.country == "Canada" ? region : nil
        }
        return HStack(spacing: 4) {
            if let country = resort.country {
                StatusChip(text: CountryFlag.emoji(for: country) ?? country)
                    .accessibilityLabel(country)
            }
            if let region { StatusChip(text: region) }
            if let distance = model.distanceM(to: resort) {
                StatusChip(text: UnitFormatter.distance(distance), systemImage: "location.fill")
                    .accessibilityLabel("\(UnitFormatter.distance(distance)) away")
            }
            if resort.hasMap {
                if resort.statusMode == .live {
                    StatusChip(text: "", tint: HUDTheme.accentGreen, systemImage: "dot.radiowaves.left.and.right")
                        .accessibilityLabel("Live lift status")
                } else {
                    StatusChip(text: "", tint: HUDTheme.accentAmber, systemImage: "hourglass")
                        .accessibilityLabel("Scheduled hours")
                }
            }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.7)
    }

    /// When the resort's map last changed for skiers: the day it was published,
    /// not the day it was built, which can be days earlier. Catalogs from before
    /// the publish date was sent fall back to the build date.
    private func mapBuiltAt(_ resort: PublishedResort, isSelected: Bool) -> Date? {
        resort.publishedAt ?? (isSelected ? model.resort?.bundle?.builtAt : nil) ?? resort.builtAt
    }

    private func accessibilityLabel(_ resort: PublishedResort, passes: [String]) -> String {
        var parts = [resort.name]
        if let country = resort.country { parts.append(country) }
        if !resort.hasMap {
            parts.append("no map yet")
        } else {
            if !passes.isEmpty { parts.append(passes.map { $0.capitalized }.joined(separator: ", ")) }
            if let built = mapBuiltAt(resort, isSelected: resort.id == model.resort?.resortID) {
                parts.append(spokenUpdate(built))
            }
        }
        return parts.joined(separator: ", ")
    }
}
