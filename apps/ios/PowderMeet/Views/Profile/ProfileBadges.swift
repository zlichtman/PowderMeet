import AppCore
import SwiftUI

/// The profile's top row (`specs/13-APP-MAP.md` section 3): the badges earned
/// so far as pins in a line, and how many of them there are. A tap opens all
/// of them.
struct ProfileBadgeRow: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let earned = model.earnedBadges
        Button { model.openFloating(.badgePicker) } label: {
            HStack(spacing: 10) {
                if earned.isEmpty {
                    Text("No badges yet")
                        .textRole(.label)
                        .foregroundStyle(HUDTheme.secondaryText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    // Every pin when they fit side by side; otherwise stacked
                    // over one another like a fanned hand, closer the more
                    // there are, so all of them still show.
                    ViewThatFits(in: .horizontal) {
                        pins(earned, overlap: 0)
                        pins(earned, overlap: 8)
                        pins(earned, overlap: 14)
                        // Never closer than this: under half of each pin
                        // covered, so every picture still reads. Past that
                        // the row shows the first ones and the count the rest.
                        pins(Array(earned.prefix(14)), overlap: 14)
                        pins(Array(earned.prefix(10)), overlap: 14)
                        pins(Array(earned.prefix(7)), overlap: 14)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                Text("\(earned.count) of \(Badges.all.count)")
                    .textRole(.label)
                    .fontWeight(.semibold)
                    .foregroundStyle(HUDTheme.primaryText)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(HUDTheme.secondaryText)
            }
            .frame(minHeight: 36)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .glassCardControl(padding: 10)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Badges, \(earned.count) of \(Badges.all.count) earned")
        .accessibilityHint("Shows every badge")
        .accessibilityAddTraits(.isButton)
    }

    private func pins(_ earned: [Badges.Earned], overlap: CGFloat) -> some View {
        HStack(spacing: overlap == 0 ? 6 : -overlap) {
            ForEach(Array(earned.enumerated()), id: \.element.id) { index, earned in
                Image(earned.badge.image(earned.tier))
                    .resizable()
                    .scaledToFit()
                    .frame(width: 36, height: 36)
                    // The first pin on top, each next one tucked under it.
                    .zIndex(Double(-index))
            }
        }
    }
}

/// Every badge in a floating list like the other lists: search at the foot,
/// a sort button, and one row a badge. A row is two lines and never wraps, so
/// the rows line up: the name over how it is earned, and on the right where
/// the skier stands, with a tiered badge's three levels as dots and the count
/// still to reach.
struct BadgesFloatingPicker: View {
    @Environment(AppModel.self) private var model
    let onClose: () -> Void
    @State private var query = ""
    /// The order picked last time.
    @AppStorage("powdermeet.badges.sort") private var sortChoice = Sort.kind.rawValue

    enum Sort: String {
        case kind, earned, level, name
    }

    private var sort: Sort { Sort(rawValue: sortChoice) ?? .kind }

    var body: some View {
        let all = model.badgeStandings
        let units = model.badgeUnits
        let shown = all.filter { query.isEmpty || $0.badge.title.localizedStandardContains(query)
            || $0.badge.rule(in: units).localizedStandardContains(query) }
        let earned = all.filter(\.isEarned)
        FloatingPicker(
            title: "Badges", subtitle: "\(earned.count) of \(all.count) earned",
            leading: earned.first.map { AnyView(BadgePin(standing: $0, size: 36)) },
            query: $query, prompt: "Search badges",
            sort: AnyView(FloatingSortButton(
                selection: Binding { sort } set: { sortChoice = $0.rawValue },
                options: [
                    (.kind, "Kind", "square.grid.2x2"),
                    (.earned, "Earned", "checkmark.seal"),
                    (.level, "Level", "medal"),
                    (.name, "Name", "textformat"),
                ])),
            onClose: onClose
        ) {
            ForEach(groups(shown), id: \.title) { group in
                if !group.rows.isEmpty {
                    FloatingLabel("\(group.title) · \(group.rows.count)").padding(.top, 10)
                    ForEach(group.rows) { BadgeRow(standing: $0, units: units) }
                }
            }
            if shown.isEmpty {
                EmptyStateView(icon: "magnifyingglass", title: "No badge matches", detail: "Try a name, like Explorer.")
            }
        }
    }

    /// Nothing more to reach on it: a single badge earned, or a tiered one at gold.
    private func isComplete(_ standing: Badges.Earned) -> Bool {
        standing.isEarned && (!standing.badge.isTiered || standing.tier == .gold)
    }

    private func groups(_ rows: [Badges.Earned]) -> [(title: String, rows: [Badges.Earned])] {
        func byName(_ rows: [Badges.Earned]) -> [Badges.Earned] {
            rows.sorted { $0.badge.title.localizedStandardCompare($1.badge.title) == .orderedAscending }
        }
        switch sort {
        case .kind:
            return Badge.Section.allCases.map { section in (section.rawValue, rows.filter { $0.badge.section == section }) }
        case .earned:
            // Finished first (a single badge, or gold); then the ones with a
            // level still to reach, the higher level first.
            let partly = rows.filter { $0.isEarned && !isComplete($0) }
                .enumerated()
                .sorted { ($1.element.tier ?? .bronze, $0.offset) < ($0.element.tier ?? .bronze, $1.offset) }
                .map(\.element)
            return [
                ("Earned", rows.filter { $0.isEarned && isComplete($0) }),
                ("Levels to go", partly),
                ("To earn", rows.filter { !$0.isEarned && $0.badge.isLive }),
                ("Soon", rows.filter { !$0.isEarned && !$0.badge.isLive }),
            ]
        case .level:
            return [
                ("Gold", rows.filter { $0.tier == .gold }),
                ("Silver", rows.filter { $0.tier == .silver }),
                ("Bronze", rows.filter { $0.tier == .bronze }),
                ("Earned", rows.filter { $0.isEarned && $0.tier == nil }),
                ("Not yet", rows.filter { !$0.isEarned }),
            ]
        case .name:
            return [("A to Z", byName(rows))]
        }
    }
}

/// A badge's picture: in colour at the tier reached, or grey and faint.
private struct BadgePin: View {
    let standing: Badges.Earned
    let size: CGFloat

    var body: some View {
        Image(standing.badge.image(standing.tier))
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
            .saturation(standing.isEarned ? 1 : 0)
            .opacity(standing.isEarned ? 1 : 0.35)
            .accessibilityHidden(true)
    }
}

private struct BadgeRow: View {
    let standing: Badges.Earned
    let units: Badge.Units

    private var badge: Badge { standing.badge }
    private var rule: String { badge.rule(in: units) }

    var body: some View {
        HStack(spacing: 12) {
            BadgePin(standing: standing, size: 48)
            VStack(alignment: .leading, spacing: 2) {
                Text(badge.title)
                    .textRole(.bodyEmph)
                    .foregroundStyle(standing.isEarned ? HUDTheme.primaryText : HUDTheme.secondaryText)
                Text(rule)
                    .textRole(.caption)
                    .foregroundStyle(HUDTheme.secondaryText)
            }
            // One line each, shrinking before it cuts off: every row the same height.
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .frame(maxWidth: .infinity, alignment: .leading)
            standingMark
        }
        .frame(height: 52)
        .glassCard(padding: 12)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(badge.title). \(rule)")
        .accessibilityValue(spoken)
    }

    @ViewBuilder private var standingMark: some View {
        if badge.isTiered, badge.isLive {
            VStack(alignment: .trailing, spacing: 4) {
                HStack(spacing: 5) {
                    ForEach(Badge.Tier.allCases, id: \.self) { tier in
                        let reached = (standing.tier ?? .bronze) >= tier && standing.tier != nil
                        Circle()
                            .fill(reached ? Self.color(tier) : .clear)
                            .strokeBorder(Self.color(tier).opacity(reached ? 1 : 0.6), lineWidth: 1.5)
                            .frame(width: 12, height: 12)
                    }
                }
                Text(progress)
                    .textRole(.caption)
                    .fontWeight(.semibold)
                    .monospacedDigit()
                    .foregroundStyle(standing.nextTarget == nil ? Self.color(.gold) : HUDTheme.secondaryText)
                    .lineLimit(1)
            }
        } else if standing.isEarned {
            Image(systemName: "checkmark.seal.fill")
                .font(.title3)
                .foregroundStyle(HUDTheme.accent)
        } else if !badge.isLive {
            StatusChip(text: "Soon")
        }
    }

    /// "4 / 10" toward the next level, or the level's name once gold.
    private var progress: String {
        guard standing.value != nil else { return "" }
        guard let progress = standing.progress(in: units) else { return "Gold" }
        return "\(Self.count(progress.value)) / \(Self.count(progress.next))"
    }

    private var spoken: String {
        if badge.isTiered, badge.isLive, standing.value != nil {
            let level = standing.tier.map { "\($0)" } ?? "no level yet"
            let next = standing.progress(in: units)
                .map { ", \(Self.count($0.value)) of \(Self.count($0.next)) to the next" } ?? ""
            return level + next
        }
        if standing.isEarned { return "Earned" }
        return badge.isLive ? "Not earned" : "Coming soon"
    }

    /// Whole numbers, shortened past ten thousand ("29k", "1M") so the
    /// figures never widen the row.
    private static func count(_ value: Double) -> String {
        if value >= 1_000_000 { return String(format: "%.1fM", value / 1_000_000).replacingOccurrences(of: ".0", with: "") }
        if value >= 10_000 { return "\(Int(value / 1000))k" }
        return Int(value).formatted()
    }

    private static func color(_ tier: Badge.Tier) -> Color {
        switch tier {
        case .bronze: Color(red: 0.80, green: 0.52, blue: 0.30)
        case .silver: Color(red: 0.78, green: 0.80, blue: 0.84)
        case .gold: Color(red: 0.96, green: 0.78, blue: 0.28)
        }
    }
}
