import AppCore
import MapScene
import MeetSolver
import MountainCore
import PowderMeetAPI
import SwiftUI

/// The profile panel: it grows out of the profile button,
/// over the map. Just above the bottom row the four sections as equal glass
/// tiles (Friends, Activity, Gear, Settings), each continuing in the same
/// floating space; above them the profile card. The button again, the map, or
/// a swipe down folds it.
struct ProfilePanel: View {
    @Environment(AppModel.self) private var model
    let onClose: () -> Void

    private let columns = [
        GridItem(.flexible(), spacing: GlassLayout.gap), GridItem(.flexible(), spacing: GlassLayout.gap),
    ]

    var body: some View {
        VStack(spacing: GlassLayout.gap) {
            Group {
                if let profile = model.profile {
                    ProfileCard(profile: profile)
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity, minHeight: 200)
                        .glassCard()
                }
            }

            LazyVGrid(columns: columns, spacing: GlassLayout.gap) {
                ForEach(ProfilePage.allCases, id: \.self) { page in
                    tile(page)
                }
            }
        }
        .gesture(
            DragGesture(minimumDistance: 24).onEnded { value in
                if value.translation.height > 60, abs(value.translation.width) < value.translation.height {
                    onClose()
                }
            }
        )
    }

    private func tile(_ page: ProfilePage) -> some View {
        // One structure for all four: the icon and title on one line, one
        // short summary under them.
        PanelTile(
            icon: page.icon, title: page.title, value: summary(page),
            badge: page == .friends ? model.friendRequestCount : 0
        ) {
            model.pushPanel(.section(page))
        }
    }

    // MARK: Summaries

    private func summary(_ page: ProfilePage) -> String {
        switch page {
        case .friends: friendsSummary
        case .activity: activitySummary
        case .gear: model.profile.map(gearSummary) ?? ""
        case .settings: settingsSummary
        }
    }

    /// "3 friends".
    private var friendsSummary: String {
        let friends = model.social.friends.count
        return friends == 0 ? "No friends yet" : "\(friends) \(friends == 1 ? "friend" : "friends")"
    }

    /// "14 days".
    private var activitySummary: String {
        let days = model.activity.history.totals.days
        return days == 0 ? "No runs yet" : "\(days) \(days == 1 ? "day" : "days")"
    }

    /// "Atomic Bent 110 · 184 cm", "Skis · 184 cm": the one gear label.
    private func gearSummary(_ profile: Profile) -> String {
        GearDraft(profile).label ?? "Not set yet"
    }

    /// "Classic": the theme.
    private var settingsSummary: String { ThemeManager.shared.displayName }
}

// MARK: Card

/// The profile in separate glass pieces over the map, none on a shared card
/// (owner, 22 Nov): the picture; the name with the resort and where the skier
/// stands; the two levels (picked over what the runs show); the ski pair,
/// large, on glass of its own; with a map open, how much of it is skied; then ten boxes of one size, five lifetime figures over the
/// learned pace and the runs it rests on. A tap on the picture changes it; a
/// tap on the name opens Settings → Account, where the name and its font change.
private struct ProfileCard: View {
    @Environment(AppModel.self) private var model
    @State private var manager = ThemeManager.shared
    let profile: Profile

    var body: some View {
        VStack(spacing: GlassLayout.gap) {
            ProfileBadgeRow()
            HStack(spacing: GlassLayout.gap) {
                VStack(spacing: 0) {
                    Text(profile.displayName)
                        .font(manager.nameFont.font)
                        .foregroundStyle(HUDTheme.primaryText)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                    if let resort = model.selectedResort {
                        Text(resort.name)
                            .textRole(.label)
                            .fontWeight(.semibold)
                            .foregroundStyle(HUDTheme.accent)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    if let place = ownPlace {
                        Text(place)
                            .textRole(.label)
                            .foregroundStyle(HUDTheme.secondaryText)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                }
                // Centred in its piece, as the levels are in theirs.
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .glassCardControl(padding: 12)
                // A tap goes to where the name and its font change.
                .onTapGesture { model.openPanel([.section(.settings), .settings(.account)]) }
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isButton)
                .accessibilityHint("Opens Account to change your name")
                // The photo in the middle, the name to its left and the
                // levels to its right, the two sides the same width.
                // Still a button: a tap changes the photo, as in Account.
                ProfilePhotoButton(size: 64, showsBadge: false)
                    .padding(4)
                    .glassEffect(HUDGlass.surface, in: Circle())
                ProfileLevels()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .glassCard(padding: 12)
            }
            // The two side pieces take the taller one's height.
            .fixedSize(horizontal: false, vertical: true)
            // Its own view so a GPS fix redraws only the strip. On glass of
            // its own, so the map's labels do not show between the skis.
            ProfileSkiStrip()
                .glassCard(padding: 10)
            // Above the figures, so Days stays over the pace row's Runs.
            MountainCompletionRow()
            stats
            pace
        }
        .frame(maxWidth: .infinity)
    }

    /// "On Pika's Traverse" while this phone's fix is live and the map can
    /// place it; nothing otherwise (the skis already carry the resort).
    private var ownPlace: String? {
        guard let fix = model.lastFix,
              FriendSignal.classify(lastSeen: fix.capturedAt, now: Date()) == .live else { return nil }
        return model.resort?.places[profile.id]
    }

    /// Lifetime figures from the run history, in the chosen units; a dash
    /// until there is a run.
    private var stats: some View {
        let totals = model.activity.history.totals
        func shown(_ value: Double?, _ format: (Double) -> String) -> String {
            value.flatMap { $0 > 0 ? format($0) : nil } ?? "—"
        }
        return StatBoxRow(columns: 5) {
            StatBox(label: "Distance", value: shown(totals.distanceM, UnitFormatter.distance))
            StatBox(label: "Vertical", value: shown(totals.verticalM, UnitFormatter.verticalDrop))
            StatBox(label: "Avg", value: shown(totals.avgSpeedMS, UnitFormatter.speed))
            StatBox(label: "Top", value: shown(totals.topSpeedMS, UnitFormatter.speed))
            // Last, over the pace row's Runs: the two counts share a column.
            StatBox(label: "Days", value: totals.days > 0 ? totals.days.formatted() : "—")
        }
    }
}

private extension ProfileCard {
    struct LearnedPace: Hashable {
        let level: Difficulty
        let speed: String
    }

    /// What the runs taught the pace model: one cell per learned level, its
    /// trail symbol in its colour over the speed, then a last cell with how
    /// many runs it rests on. Nothing until a run has calibrated it.
    @ViewBuilder var pace: some View {
        let runs = model.activity.history.calibrationRuns
        let learned = GearDraft.ladder.compactMap { level -> LearnedPace? in
            guard model.activity.history.evidence[level] != nil,
                  let speed = profile.baselineSpeeds[level.rawValue] else { return nil }
            return LearnedPace(level: level, speed: UnitFormatter.speed(speed))
        }
        if runs > 0, !learned.isEmpty {
            HStack(spacing: 6) {
                    ForEach(learned, id: \.self) { pace in
                        // The symbol over the speed, so a double black
                        // leaves the whole "10.7 mph" room at 375 pt.
                        VStack(spacing: 2) {
                            TrailSymbol(level: pace.level)
                            Text(pace.speed)
                                .textRole(.label)
                                .monospacedDigit()
                                .foregroundStyle(HUDTheme.primaryText)
                                .lineLimit(1)
                                .minimumScaleFactor(0.6)
                        }
                        .frame(maxWidth: .infinity, minHeight: 56)
                        .padding(.horizontal, 4)
                        .hudCard()
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("\(pace.level.displayName), \(pace.speed)")
                    }
                    VStack(spacing: 2) {
                        Text(runs.formatted())
                            .textRole(.label)
                            .fontWeight(.semibold)
                            .monospacedDigit()
                            .foregroundStyle(HUDTheme.primaryText)
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                        Text(runs == 1 ? "Run" : "Runs")
                            .textRole(.caption)
                            .foregroundStyle(HUDTheme.secondaryText)
                    }
                    .frame(maxWidth: .infinity, minHeight: 56)
                    .padding(.horizontal, 4)
                    .hudCard()
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Learned from \(runs.formatted()) \(runs == 1 ? "run" : "runs")")
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Your pace")
        }
    }
}

/// How much of the open mountain the skier has skied: "Skied", a bar
/// and "42 of 213 runs" on one line, as short as the badge row, so the card
/// still fits the smallest iPhone. Its own view, so a GPS fix redrawing the
/// card does not count the runs again. The resort is named on the name piece.
private struct MountainCompletionRow: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let count = model.mountainCompletion {
            let words = "\(count.skied.formatted()) of \(count.total.formatted()) runs"
            HStack(spacing: 10) {
                Text("Skied")
                    .foregroundStyle(HUDTheme.secondaryText)
                ProgressView(value: count.fraction)
                    .tint(HUDTheme.accent)
                    .frame(minWidth: 40)
                Text(words)
                    .fontWeight(.semibold)
                    .monospacedDigit()
                    .foregroundStyle(HUDTheme.primaryText)
            }
            .textRole(.label)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .frame(minHeight: 36)
            .glassCardControl(padding: 10)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Runs skied on this mountain")
            .accessibilityValue(words)
        }
    }
}

/// Figures side by side (four, or five on the profile); two to a row at
/// accessibility text sizes, so each value keeps a size that can be read.
struct StatBoxRow<Content: View>: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    var columns = 4
    @ViewBuilder let content: Content

    var body: some View {
        let columns = dynamicTypeSize.isAccessibilitySize ? 2 : columns
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: columns), spacing: 6) {
            content
        }
    }
}

/// One figure in a well: the value over its name, at least one row tall.
/// The profile card, a friend's card and a run's detail use it.
struct StatBox: View {
    let label: String
    let value: String

    var body: some View {
        VStack(spacing: 2) {
            RollingNumber(text: value)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
            Text(label)
                .textRole(.caption)
                .foregroundStyle(HUDTheme.secondaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, minHeight: 56)
        .padding(.horizontal, 4)
        .hudCard()
        .accessibilityElement(children: .combine)
    }
}
