import AppCore
import MapScene
import MountainCore
import SwiftUI

/// The bottom of the screen: the resort bar across the width, then the round
/// profile button at the right (there is no inbox: meet requests take the context sheet, friend requests live in Friends).
struct MapBottomRow: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: GlassLayout.gap) {
            ResortBar()
                .frame(maxWidth: .infinity)
            // The one search of the map: with a friend picked, places to meet
            // them; with nobody, somewhere to go. Not during a meet, whose
            // route either would replace.
            if let resort = model.resort, resort.bundle != nil, resort.canStartMeet {
                if case .proposing(let proposing) = resort.meet?.state {
                    IconButton(systemImage: "magnifyingglass", label: "Search meeting places") {
                        model.openFloating(.meetPlacePicker)
                    }
                    .disabled(proposing.sending)
                } else {
                    IconButton(systemImage: "magnifyingglass", label: "Search places to go to") {
                        model.openFloating(.goToPicker)
                    }
                }
            }
            ProfileButton()
        }
        .frame(height: GlassLayout.barHeight)
    }
}

/// The resort and its weather on one glass bar: the status dot (green live,
/// amber stale or hours only), the name and a chevron open the resort picker;
/// the temperature and new snow at the scrubbed hour take the timeline back to
/// now.
struct ResortBar: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var resort: ResortModel? { model.resort }

    private var name: String {
        model.selectedResort?.name ?? resort?.bundle?.name ?? "Choose a resort"
    }

    private var isLoading: Bool {
        if case .loadingBundle = resort?.state { return true }
        return false
    }

    /// `now` comes from the bar's own clock, so the dot turns amber when the
    /// status ages past fresh, not only when a new one arrives.
    private func statusColor(at now: Date) -> Color {
        guard let resort else { return HUDTheme.secondaryText }
        guard let status = resort.status else {
            return resort.ready == nil ? HUDTheme.secondaryText : HUDTheme.accentAmber
        }
        return status.freshness(at: now) == .fresh ? HUDTheme.accentGreen : HUDTheme.accentAmber
    }

    private func statusWords(at now: Date) -> String {
        guard let resort, resort.ready != nil else { return "" }
        guard let status = resort.status else { return "hours only" }
        return status.freshness(at: now) == .fresh ? "live lift status" : "lift status is stale"
    }

    private var weather: ConditionsSample? {
        resort.flatMap { $0.conditions?.sample(at: $0.displayTime) }
    }

    var body: some View {
        HStack(spacing: 10) {
            TimelineView(.periodic(from: .now, by: 30)) { context in
                resortButton(now: context.date)
            }

            if let weather, let resort {
                Rectangle().fill(HUDGlass.hairline).frame(width: 0.5, height: 24)
                Button {
                    withAnimation(reduceMotion ? MapChrome.reducedFade : .interactiveSpring(response: 0.22, dampingFraction: 0.86)) {
                        resort.returnToLive()
                    }
                } label: {
                    quickWeather(weather)
                        .frame(maxHeight: .infinity)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(weatherWords(weather))
                .accessibilityHint("Takes the timeline back to now")
            }
        }
        .glassBar()
    }

    /// The status dot, the name and the chevron: opens the resort picker.
    private func resortButton(now: Date) -> some View {
        let words = statusWords(at: now)
        return Button { model.openFloating(.resortPicker) } label: {
            HStack(spacing: 8) {
                if isLoading {
                    ProgressView().controlSize(.mini)
                } else {
                    Circle().fill(statusColor(at: now)).frame(width: 8, height: 8)
                }
                Text(name)
                    .textRole(.section)
                    .foregroundStyle(HUDTheme.primaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                    .allowsTightening(true)
                    .layoutPriority(1)
                Image(systemName: "chevron.down")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(HUDTheme.secondaryText)
                Spacer(minLength: 0)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Resort: \(name)\(words.isEmpty ? "" : ", \(words)")")
        .accessibilityHint("Change resort")
    }

    /// The sky at the scrubbed hour as a symbol, beside the temperature over
    /// the new snow. The bar has room to spare, so the symbol
    /// is full size and the name still keeps the width. At accessibility
    /// sizes the snow line gives its room to the name (VoiceOver still reads
    /// it).
    private func quickWeather(_ sample: ConditionsSample) -> some View {
        HStack(spacing: 8) {
            Image(systemName: MapWeather.symbol(sample.weatherCode))
                .font(.title3.weight(.semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(ResortTimelineView.iconTint(for: sample))
                .frame(width: 28)
                .contentTransition(reduceMotion ? ContentTransition.identity : ContentTransition.symbolEffect(.replace))
            VStack(alignment: .leading, spacing: 0) {
                Text(UnitFormatter.temperature(sample.tempC))
                    .textRole(.bodyEmph)
                    .monospacedDigit()
                    .foregroundStyle(HUDTheme.primaryText)
                if !dynamicTypeSize.isAccessibilitySize, let snow = UnitFormatter.snowfall(sample.snow24hCM) {
                    HStack(spacing: 2) {
                        Image(systemName: "snowflake")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(HUDTheme.accentCyan)
                        Text(snow)
                            .textRole(.caption).fontWeight(.semibold)
                            .monospacedDigit()
                            .foregroundStyle(HUDTheme.primaryText)
                    }
                }
            }
        }
        .lineLimit(1)
        .fixedSize()
        .padding(.trailing, 4)
    }

    private func weatherWords(_ sample: ConditionsSample) -> String {
        var parts = ["\(MapWeather.description(sample.weatherCode)), \(UnitFormatter.temperature(sample.tempC))"]
        if let snow = UnitFormatter.snowfall(sample.snow24hCM) { parts.append("\(snow) new snow") }
        return parts.joined(separator: ", ")
    }
}

/// The round profile button: your photo or initials, ringed in the accent
/// while the profile panel is open, with a count of friend requests waiting.
/// Tapping it opens or folds the panel.
struct ProfileButton: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Button {
            model.toggleProfilePanel()
        } label: {
            ZStack {
                if let profile = model.profile {
                    AvatarView(
                        userID: profile.id, path: profile.avatarURL, name: profile.displayName,
                        size: GlassLayout.barHeight - 8
                    )
                } else {
                    Image(systemName: "person.fill")
                        .font(.title3)
                        .foregroundStyle(HUDTheme.primaryText)
                }
            }
            .frame(width: GlassLayout.barHeight, height: GlassLayout.barHeight)
            .glassEffect(
                model.isProfilePanelOpen ? HUDGlass.selectedSurface.interactive() : HUDGlass.control, in: Circle())
            .overlay {
                if model.isProfilePanelOpen {
                    Circle().strokeBorder(HUDTheme.accent, lineWidth: 2)
                }
            }
            .overlay(alignment: .topTrailing) {
                CountBadge(count: model.friendRequestCount)
                    .offset(x: 4, y: -4)
            }
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Profile")
        .accessibilityValue(Self.requestsValue(model.friendRequestCount))
        .accessibilityHint(model.isProfilePanelOpen ? "Folds your profile away" : "Shows your profile")
    }

    static func requestsValue(_ count: Int) -> String {
        switch count {
        case 0: ""
        case 1: "1 friend request"
        default: "\(count) friend requests"
        }
    }
}

/// One chip per friend at this resort, closest first (by name without a fix
/// of our own), scrolling sideways; the last chip adds a friend. Tapping a
/// friend opens the meeting options for them; their chip shows as selected.
/// Ages follow `FriendSignal`, as the map markers do.
struct MapFriendsRow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let resort: ResortModel
    let isVisible: Bool

    private struct Item: Identifiable {
        let id: UUID
        let name: String
        let distanceM: Double?
        let capturedAt: Date
        let avatarPath: String?
        let place: String?
    }

    private var items: [Item] {
        let here = model.lastFix?.coordinate
        let now = Date()
        return resort.friends.compactMap { id, presence -> Item? in
            guard FriendSignal.isVisibleOnMap(lastSeen: presence.capturedAt, now: now) else { return nil }
            return Item(
                id: id, name: model.name(of: id),
                distanceM: here.map { Geo.haversineM($0, presence.coordinate) },
                capturedAt: presence.capturedAt, avatarPath: model.person(id)?.avatarURL,
                place: resort.places[id]
            )
        }
        .sorted {
            switch ($0.distanceM, $1.distanceM) {
            case let (a?, b?): a < b
            default: $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
        }
    }

    /// The friend whose meeting options are open.
    private var selected: UUID? { resort.proposingFriend }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: GlassLayout.gap) {
                ForEach(items) { item in
                    Button {
                        withAnimation(MapChrome.motion(reduce: reduceMotion)) { resort.toggleFriend(item.id) }
                    } label: {
                        chip(item)
                    }
                    .buttonStyle(.plain)
                }
                Button { model.openAddFriend() } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "plus")
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(HUDTheme.accent)
                        Text("Add friend")
                            .textRole(.section)
                            .foregroundStyle(HUDTheme.primaryText)
                    }
                    .glassChip(interactive: true)
                }
                .buttonStyle(.plain)
                .accessibilityHint("Search for friends by name")
            }
        }
        // The chips' glass reaches past their bounds when pressed.
        .scrollClipDisabled()
        .frame(height: GlassLayout.chipHeight)
    }

    private func chip(_ item: Item) -> some View {
        let isSelected = item.id == selected
        return HStack(spacing: 8) {
            AvatarView(userID: item.id, path: item.avatarPath, name: item.name, size: 32)
                .overlay(Circle().strokeBorder(HUDTheme.routeSkierB, lineWidth: 2))
                .padding(.leading, -8)
            VStack(alignment: .leading, spacing: 0) {
                Text(item.name)
                    .textRole(.section)
                    .foregroundStyle(HUDTheme.primaryText)
                    .lineLimit(1)
                FriendChipDetail(
                    distanceM: item.distanceM, place: item.place, capturedAt: item.capturedAt, isVisible: isVisible)
            }
            // A long name or run name is cut short, so the row shows as many
            // friends as it can; the card that opens has both in full.
            .frame(maxWidth: 112, alignment: .leading)
        }
        .glassChip(interactive: true, selected: isSelected)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Shows the places you could meet")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

/// "420 m · live" under a friend's name: the distance and how fresh the fix
/// is, ticking on its own clock while the map shows. While the fix is live
/// and the map can place them, the run or lift takes the distance's place
/// ("On Pika's Traverse · live").
struct FriendChipDetail: View {
    let distanceM: Double?
    var place: String?
    let capturedAt: Date
    let isVisible: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 15, paused: !isVisible)) { context in
            let signal = FriendSignal.classify(lastSeen: capturedAt, now: context.date)
            HStack(spacing: 4) {
                if signal == .live, let place {
                    Text(place)
                        .foregroundStyle(HUDTheme.secondaryText)
                        .truncationMode(.tail)
                    Text("·").foregroundStyle(HUDTheme.secondaryText)
                } else if let distanceM {
                    Text(UnitFormatter.distance(distanceM))
                        .foregroundStyle(HUDTheme.secondaryText)
                    Text("·").foregroundStyle(HUDTheme.secondaryText)
                }
                // How fresh the fix is stays whole; the place before it gives way.
                Text(Wording.signal(signal))
                    .foregroundStyle(signal == .live ? HUDTheme.accentGreen : HUDTheme.accentAmber)
                    .fixedSize()
                    .layoutPriority(1)
            }
            .textRole(.caption)
            .monospacedDigit()
            .lineLimit(1)
        }
    }
}
