import AppCore
import MapScene
import MeetSolver
import MountainCore
import SwiftUI

/// The one context sheet over the map (`specs/13-APP-MAP.md` section 2): a
/// glass card above the friends row that shows whatever the moment is about,
/// one thing at a time (`ResortModel.contextCard`). Short by default; swiping
/// up (or tapping the grabber) shows everything, scrolling inside the room
/// the map leaves. × or a swipe down closes what can be put away; a request or
/// a meet has its own buttons.
struct ContextSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let resort: ResortModel
    let card: ContextCard
    @Binding var isExpanded: Bool
    /// The most the sheet may take, swiped up.
    let maxHeight: CGFloat

    /// The states with more to show than their short form.
    private var canExpand: Bool {
        switch card {
        case .incoming, .options, .group, .goTo: true
        // A meet under way shows all it has: nothing to swipe open.
        case .meet, .sent, .place: false
        }
    }

    private var canClose: Bool {
        switch card {
        case .options, .group, .place, .goTo: true
        // A swipe down puts the directions away; the meet carries on.
        case .meet: resort.isMeetActive
        case .incoming, .sent: false
        }
    }

    /// The open options card has no sheet of its own.
    private var isBare: Bool { isExpanded && card == .options }

    var body: some View {
        VStack(spacing: 0) {
            if canExpand, !isBare {
                grabber
            }
            if isBare {
                // Swiped up, meeting options are separate pieces of glass over
                // the map (the option, its rows, the page indicator), not one
                // sheet with boxes on it. A swipe down folds them back to the
                // short card.
                content(expanded: true)
                    .simultaneousGesture(swipe)
            } else if isExpanded, canExpand {
                ScrollView {
                    content(expanded: true)
                        .padding(.horizontal, GlassLayout.cardPadding)
                        .padding(.bottom, GlassLayout.cardPadding)
                }
                .scrollBounceBehavior(.basedOnSize)
                .scrollIndicators(.hidden)
                .frame(maxHeight: maxHeight - 20)
                .fixedSize(horizontal: false, vertical: true)
            } else {
                content(expanded: false)
                    .padding(.horizontal, GlassLayout.cardPadding)
                    .padding(.top, canExpand ? 0 : GlassLayout.cardPadding)
                    .padding(.bottom, GlassLayout.cardPadding)
            }
        }
        .frame(maxWidth: .infinity)
        .environment(\.isOnGlass, !isBare)
        .modifier(StandaloneGlass(
            shape: RoundedRectangle(cornerRadius: GlassLayout.cardRadius, style: .continuous), applies: !isBare))
        .contentShape(RoundedRectangle(cornerRadius: GlassLayout.cardRadius, style: .continuous))
        .gesture(isExpanded ? nil : swipe)
        .animation(MapChrome.motion(reduce: reduceMotion), value: isExpanded)
    }

    /// A short bar at the top: drag or tap to show more or less.
    private var grabber: some View {
        Capsule()
            .fill(HUDTheme.secondaryText.opacity(0.6))
            .frame(width: 36, height: 5)
            .frame(maxWidth: .infinity, minHeight: 20)
            .contentShape(Rectangle())
            .onTapGesture { isExpanded.toggle() }
            .gesture(swipe)
            .accessibilityElement()
            .accessibilityLabel(isExpanded ? "Show less" : "Show more")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { isExpanded.toggle() }
    }

    /// Up shows more; down shows less, then closes what can be put away.
    private var swipe: some Gesture {
        DragGesture(minimumDistance: 16).onEnded { value in
            let dy = value.translation.height
            guard abs(dy) > abs(value.translation.width), abs(dy) > 40 else { return }
            if dy < 0 {
                if canExpand { isExpanded = true }
            } else if isExpanded {
                isExpanded = false
            } else if canClose {
                close()
            }
        }
    }

    private func close() {
        withAnimation(MapChrome.motion(reduce: reduceMotion)) { resort.closeContextCard() }
    }

    /// The state inside one card crossfades while the glass around it
    /// morphs to the new size.
    private func content(expanded: Bool) -> some View {
        states(expanded: expanded)
            .id(card)
            .transition(MapChrome.transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .bottom)), reduce: reduceMotion))
    }

    @ViewBuilder
    private func states(expanded: Bool) -> some View {
        if let bundle = resort.bundle {
            switch card {
            case .meet:
                MeetUnderWayCard(resort: resort, bundle: bundle)
            case .incoming:
                MeetIncomingCard(resort: resort, bundle: bundle, expanded: expanded)
            case .sent:
                MeetSentCard(resort: resort, bundle: bundle)
            case .options:
                MeetOptionsCard(
                    resort: resort, bundle: bundle, expanded: expanded, maxHeight: maxHeight, onClose: close)
            case .group(let id):
                if let group = bundle.group(id) {
                    GroupCard(resort: resort, group: group, bundle: bundle, expanded: expanded, onClose: close)
                }
            case .place(let id):
                if let place = bundle.rendezvous(id) {
                    PlaceCard(resort: resort, place: place, onClose: close)
                }
            case .goTo:
                if let goTo = resort.goTo {
                    GoToCard(resort: resort, state: goTo, bundle: bundle, expanded: expanded, onClose: close)
                }
            }
        }
    }
}

// MARK: Shared pieces

/// The head of every context-sheet state: a glyph or a photo, the title, one
/// line under it, and what sits at the trailing edge (a status, ×).
struct ContextHeader<Leading: View, Trailing: View>: View {
    let title: String
    var subtitle: String?
    var subtitleTint: Color = HUDTheme.secondaryText
    /// Makes the title a button (a friend's name flies the map to them).
    var onTitleTap: (() -> Void)?
    /// The title button's VoiceOver label, "Show Alex on the map".
    var titleTapLabel: String?
    @ViewBuilder var leading: Leading
    @ViewBuilder var trailing: Trailing
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        HStack(spacing: 12) {
            leading
            VStack(alignment: .leading, spacing: 2) {
                if let onTitleTap {
                    Button(action: onTitleTap) { titleText }
                        .buttonStyle(.plain)
                        .accessibilityLabel(titleTapLabel ?? title)
                } else {
                    titleText
                }
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .textRole(.label)
                        .foregroundStyle(subtitleTint)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            trailing
        }
        .frame(minHeight: GlassLayout.iconButton)
        .accessibilityElement(children: .contain)
    }

    // One line, shrunk a little if needed, so a long lift name doesn't break beside the
    // buttons; accessibility sizes wrap instead, so nothing is cut off.
    private var titleText: some View {
        Text(title)
            .textRole(.bodyEmph)
            .foregroundStyle(HUDTheme.primaryText)
            .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
            .minimumScaleFactor(dynamicTypeSize.isAccessibilitySize ? 1 : 0.75)
    }
}

/// A round glyph at the head of a card, in a well of its colour.
struct ContextGlyph: View {
    let systemImage: String
    var tint: Color = HUDTheme.accent

    var body: some View {
        Image(systemName: systemImage)
            .font(.body.weight(.semibold))
            .foregroundStyle(tint)
            .frame(width: 40, height: 40)
            .background(tint.opacity(0.18), in: Circle())
            .accessibilityHidden(true)
    }
}

/// A labelled figure in a row of figures: "Length" over "1.2 km".
struct ContextStat: View {
    let label: String
    let value: String
    var tint: Color = HUDTheme.primaryText

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .textRole(.caption)
                .foregroundStyle(HUDTheme.secondaryText)
            Text(value)
                .textRole(.section)
                .monospacedDigit()
                .foregroundStyle(tint)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .accessibilityElement(children: .combine)
    }
}

/// A line of caution inside a card (stale weather, a replaced request).
struct ContextNote: View {
    @Environment(\.isOnGlass) private var isOnGlass
    let icon: String
    let text: String
    var tint: Color = HUDTheme.accentAmber

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: icon)
                .font(.footnote.weight(.semibold))
                .accessibilityHidden(true)
            Text(text)
                .textRole(.label)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: GlassLayout.innerRadius, style: .continuous))
        .modifier(StandaloneGlass(
            shape: RoundedRectangle(cornerRadius: GlassLayout.innerRadius, style: .continuous),
            applies: !isOnGlass))
    }
}

// MARK: Run or lift

/// A run or lift the map selected: its kind, name and open state; length,
/// vertical and grade (or ride time); the three surface meters for a run
/// (grooming, moguls, glide: `TrailConditions`); the weather at the
/// timeline's hour; "Go to". Swiped up: a run's elevation profile and what
/// the meters mean in words, or a lift's capacity.
private struct GroupCard: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let resort: ResortModel
    let group: MountainCore.Group
    let bundle: ResortBundle
    let expanded: Bool
    let onClose: () -> Void

    private var figures: GroupFigures { GroupFigures(resort: resort, group: group, bundle: bundle) }
    private var edges: [MountainCore.Edge] { figures.edges }
    private var isLift: Bool { group.kind == .lift }
    private var name: String { TerrainName.of(group, in: bundle.graph) }
    private var difficulty: Difficulty? { group.difficulty ?? edges.lazy.compactMap(\.difficulty).first }
    private var lift: LiftInfo? { edges.lazy.compactMap(\.lift).first }
    private var state: GroupState? { resort.status?.groups[group.id] }
    private var groomed: Bool { figures.groomed }
    private var weather: ConditionsSample? { figures.weather }

    /// The weather on this run or lift itself at the timeline's hour: the
    /// forecast moved to its height and slope, as routing reads it.
    private var local: LocalConditions? {
        MeetSolver.localConditions(
            on: edges, in: bundle, conditions: resort.conditions, at: resort.displayTime)
    }

    /// Nil for an unnamed run or lift, whose title already says its rating
    /// or kind ("Unnamed blue run"), so the line under it would only repeat it.
    private var kindLine: String? {
        guard TerrainName.named(group.name) != nil else { return nil }
        if isLift { return liftType }
        guard let difficulty else { return "Run" }
        return difficulty == .park ? "Terrain park" : "\(difficulty.displayName) run"
    }

    private var liftType: String {
        switch lift?.type {
        case .chair: "Chairlift"
        case .gondola: "Gondola"
        case .tbar: "T-bar"
        case .magicCarpet: "Magic carpet"
        case .ropeTow: "Rope tow"
        case .cableCar: "Cable car"
        case nil: "Lift"
        }
    }

    private var liftIcon: String {
        switch lift?.type {
        case .gondola, .cableCar: "tram.fill"
        case .tbar: "arrow.up.to.line"
        case .magicCarpet, .ropeTow: "figure.walk"
        case .chair, nil: "cablecar.fill"
        }
    }

    /// The map's own answer when there is one, so the card and the lines
    /// agree (I-15). Before a scene exists, the group's status row.
    private var availability: (label: String, color: Color) {
        if let scene = resort.scene.model?.availability(of: group.id), state != .hold {
            let scheduled = scene == .open && (state == nil || state == .scheduled)
            let color: Color = switch scene {
            case .open: scheduled ? HUDTheme.secondaryText : HUDTheme.accentGreen
            case .partiallyOpen: HUDTheme.accentAmber
            case .closed: HUDTheme.accentRed
            }
            return (scheduled ? "Scheduled" : Wording.availability(scene), color)
        }
        return switch state {
        case .open: ("Open", HUDTheme.accentGreen)
        case .hold: ("On hold", HUDTheme.accentAmber)
        case .closed: ("Closed", HUDTheme.accentRed)
        case .scheduled, nil: ("Scheduled", HUDTheme.secondaryText)
        }
    }

    /// "Go to": with a fix of our own and no meet whose route it would replace.
    private var canGoTo: Bool { resort.canStartMeet && model.lastFix != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ContextHeader(title: name, subtitle: kindLine) {
                if isLift {
                    ContextGlyph(systemImage: liftIcon, tint: HUDTheme.liftColor)
                } else {
                    ContextGlyph(
                        systemImage: difficulty?.icon ?? "questionmark",
                        tint: difficulty.map(HUDTheme.color(for:)) ?? HUDTheme.secondaryText)
                }
            } trailing: {
                StatusChip(text: availability.label, tint: availability.color)
                CloseButton(action: onClose)
            }

            HStack(alignment: .bottom, spacing: 16) {
                if isLift {
                    if let ride = figures.rideS { ContextStat(label: "Ride", value: Wording.minutes(ride)) }
                    ContextStat(label: "Length", value: figures.length)
                    ContextStat(label: "Vertical", value: figures.vertical)
                } else {
                    ContextStat(label: "Length", value: figures.length)
                    ContextStat(label: "Vertical", value: figures.vertical)
                    ContextStat(label: "Grade", value: figures.grade)
                }
                Spacer(minLength: 0)
                if canGoTo {
                    PrimaryButton(title: "Go to", systemImage: "arrow.triangle.turn.up.right.diamond.fill",
                                  fillsWidth: false) {
                        withAnimation(MapChrome.motion(reduce: reduceMotion)) { model.goTo(.group(group.id)) }
                    }
                    .accessibilityLabel("Route to \(name)")
                }
            }

            if !isLift {
                let surface = figures.surface
                HStack(spacing: 18) {
                    SurfaceMeter(label: "Grooming", level: surface.grooming, tint: HUDTheme.accentGreen)
                    SurfaceMeter(label: "Moguls", level: surface.moguls, tint: HUDTheme.accentAmber)
                    SurfaceMeter(label: "Glide", level: surface.glide, tint: HUDTheme.accentCyan)
                    Spacer(minLength: 0)
                }
            }
            // Only while the big weather card is folded: never the same
            // numbers twice on screen.
            let local = local
            if let weather, MapChrome.isWeatherCollapsed(resort) {
                weatherRow(weather, local: local)
            }

            if expanded {
                GlassDivider(inset: 0)
                let profile = figures.elevationProfile
                if !profile.isEmpty {
                    ElevationProfileChart(
                        points: profile, drop: figures.vertical,
                        tint: difficulty.map(HUDTheme.color(for:)) ?? HUDTheme.accent)
                }
                if let words = local.flatMap(Wording.runConditions) {
                    Text(words)
                        .textRole(.label)
                        .foregroundStyle(HUDTheme.primaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if isLift {
                    if let capacity = lift?.capacityPPH {
                        ContextStat(label: "Capacity", value: "\(capacity) people an hour")
                    }
                } else {
                    Label(groomed ? "Groomed today" : "Not groomed", systemImage: groomed ? "checkmark.circle.fill" : "circle")
                        .textRole(.label)
                        .foregroundStyle(groomed ? HUDTheme.accentGreen : HUDTheme.secondaryText)
                    Text("Moguls are judged from the pitch, new snow and freeze-thaw; glide from new snow, the temperature and the sun on the slope.")
                        .textRole(.caption)
                        .foregroundStyle(HUDTheme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// The weather at the timeline's hour on one line: sky, temperature, new
    /// snow, wind. Temperature and wind are this run's own where the forecast
    /// allows, so the line earns its place beside the resort weather card.
    private func weatherRow(_ weather: ConditionsSample, local: LocalConditions?) -> some View {
        HStack(spacing: 10) {
            Image(systemName: local?.inCloud == true ? "cloud.fog.fill" : MapWeather.symbol(weather.weatherCode))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(ResortTimelineView.iconTint(for: weather))
                .accessibilityHidden(true)
            Text(UnitFormatter.temperature(local?.tempC ?? weather.tempC))
                .fontWeight(.semibold)
                .foregroundStyle(HUDTheme.primaryText)
            if let snow = UnitFormatter.snowfall(weather.snow24hCM) {
                Label(snow, systemImage: "snowflake")
                    .foregroundStyle(HUDTheme.accentCyan)
            }
            Label(UnitFormatter.windSpeed(local?.windKmh ?? MapWeather.kph(weather.windMS)), systemImage: "wind")
                .foregroundStyle(HUDTheme.secondaryText)
            Spacer(minLength: 0)
            Text(ResortTimelineView.fullTime(
                resort.displayTime, in: bundle.timeZone ?? .current, heldSince: resort.scrubbedSince))
                .foregroundStyle(HUDTheme.secondaryText)
        }
        .textRole(.label)
        .monospacedDigit()
        .lineLimit(1)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(HUDGlass.well, in: RoundedRectangle(cornerRadius: GlassLayout.innerRadius, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

// MARK: Place

/// A meeting point or amenity the map selected: name, kind, what is there,
/// and "Go to".
private struct PlaceCard: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let resort: ResortModel
    let place: Rendezvous
    let onClose: () -> Void

    private var isMeetingPoint: Bool {
        switch resort.meet?.state {
        case .proposed(let meet): meet.rendezvousID == place.id
        case .incoming(let incoming): incoming.meet.rendezvousID == place.id
        case .active(let active): active.meet.rendezvousID == place.id
        case .proposing, .ended, nil: false
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ContextHeader(
                title: place.name,
                subtitle: isMeetingPoint ? "Your meeting point · \(MeetPresentation.kindLabel(place.kind))"
                    : MeetPresentation.kindLabel(place.kind)
            ) {
                ContextGlyph(
                    systemImage: PlaceIcon.icon(kind: place.kind, amenities: place.amenities),
                    tint: HUDTheme.routeMeeting)
            } trailing: {
                CloseButton(action: onClose)
            }

            HStack(alignment: .center, spacing: 8) {
                if !place.amenities.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(PlaceIcon.ordered(place.amenities), id: \.self) { amenity in
                                Label(Self.amenity(amenity), systemImage: Self.amenityIcon(amenity) ?? "circle.fill")
                                    .textRole(.label)
                                    .foregroundStyle(HUDTheme.primaryText)
                                    .padding(.horizontal, 10)
                                    .frame(height: 30)
                                    .background(HUDGlass.well, in: Capsule())
                            }
                        }
                    }
                }
                Spacer(minLength: 0)
                if let meet = resort.meet, case .proposing = meet.state {
                    // Picking where to meet: this place joins the options.
                    PrimaryButton(title: "Meet here", systemImage: "person.2.fill", fillsWidth: false) {
                        meet.request(place: place.id)
                        onClose()
                    }
                    .accessibilityLabel("Meet \(model.name(of: meet.partnerID)) at \(place.name)")
                } else if resort.canStartMeet, model.lastFix != nil {
                    PrimaryButton(title: "Go to", systemImage: "arrow.triangle.turn.up.right.diamond.fill",
                                  fillsWidth: false) {
                        withAnimation(MapChrome.motion(reduce: reduceMotion)) { model.goTo(.place(place.id)) }
                    }
                    .accessibilityLabel("Route to \(place.name)")
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    /// Catalog amenity keys ("food", "restrooms", "first_aid") in words.
    static func amenity(_ key: String) -> String {
        switch key {
        case "first_aid": "First aid"
        case "rental": "Rentals"
        default: key.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    static func amenityIcon(_ key: String) -> String? {
        switch key {
        case "food": "fork.knife"
        case "restrooms": "toilet.fill"
        case "first_aid": "cross.case.fill"
        case "parking": "parkingsign"
        case "rental": "shippingbox.fill"
        case "indoor": "house.fill"
        default: nil
        }
    }
}

// MARK: Go to

/// The solo route from a run, lift or place card: where it ends, how long,
/// how far, lifts and vertical; "Show route"; ×. Swiped up: the runs and lifts
/// in order.
private struct GoToCard: View {
    let resort: ResortModel
    let state: GoToState
    let bundle: ResortBundle
    let expanded: Bool
    let onClose: () -> Void

    private var destinationName: String {
        switch state.destination {
        case .group(let id):
            return bundle.group(id).map { TerrainName.of($0, in: bundle.graph) } ?? "this run"
        case .place(let id):
            return bundle.rendezvous(id)?.name ?? "this place"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ContextHeader(title: "Go to \(destinationName)", subtitle: subtitle, subtitleTint: subtitleTint) {
                ContextGlyph(systemImage: "arrow.triangle.turn.up.right.diamond.fill", tint: HUDTheme.routeSkierA)
            } trailing: {
                CloseButton(label: "End route", action: onClose)
            }
            switch state {
            case .solving:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Finding your route")
                        .textRole(.label)
                        .foregroundStyle(HUDTheme.secondaryText)
                }
            case .failed:
                EmptyView()
            case .ready(let plan):
                HStack(alignment: .bottom, spacing: 16) {
                    ContextStat(label: "Time", value: Wording.eta(plan.route.eta))
                    ContextStat(label: "Distance", value: UnitFormatter.distance(plan.route.lengthM))
                    ContextStat(label: "Lifts", value: "\(plan.route.liftCount)")
                    if plan.descentM >= 5 { ContextStat(label: "Down", value: UnitFormatter.verticalDrop(plan.descentM)) }
                    Spacer(minLength: 0)
                    IconButton(systemImage: "map", label: "Show the whole route on the map", tint: HUDTheme.accent) {
                        resort.showRouteOnMap()
                    }
                }
                if let note = MeetPresentation.easiestWayDownNote(
                    plan.route, me: plan.route.skierID, partnerName: "") {
                    ContextNote(icon: "exclamationmark.triangle.fill", text: note)
                }
                if let note = MeetPresentation.statusNote(resort.status, now: Date()) {
                    ContextNote(icon: "exclamationmark.triangle.fill", text: note)
                }
                if expanded {
                    GlassDivider(inset: 0)
                    RouteSteps(route: plan.route, bundle: bundle, color: HUDTheme.routeSkierA)
                }
            }
        }
    }

    private var subtitle: String {
        switch state {
        case .solving: return ""
        case .failed(_, let failure): return Self.message(failure)
        case .ready(let plan):
            let place = bundle.rendezvous(plan.target.rendezvous)?.name ?? "the start"
            if plan.target.isExact { return "Ends at \(place)" }
            return "Ends at \(place), \(UnitFormatter.distance(plan.target.offsetM)) from the start"
        }
    }

    private var subtitleTint: Color {
        if case .failed = state { return HUDTheme.accentAmber }
        return HUDTheme.secondaryText
    }

    static func message(_ failure: GoToPlanner.Failure) -> String {
        switch failure {
        case .noTarget: "No route: there is no meeting place at or near the start of this run yet."
        case .notOnMap: "No route: your position isn't on or near a run or lift yet."
        case .routeClosed: "A lift or run on your route has closed. A new route comes when your position is back."
        case .solver(let failure): PowderMeetError.routing(failure).userMessage
        }
    }
}

/// A route step by step: each run, lift or connector with its time.
struct RouteSteps: View {
    let route: Route
    let bundle: ResortBundle
    let color: Color
    /// The step under way, highlighted; nil for a plan.
    var current: Int?
    @State private var maneuvers = ManeuverMemo()

    var body: some View {
        let steps = maneuvers.steps(for: route, in: bundle)
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                HStack(spacing: 10) {
                    Image(systemName: MeetPresentation.stepIcon(step.action))
                        .font(.caption.weight(.bold))
                        .foregroundStyle(MeetRouteSection.iconColor(step))
                        .frame(width: 22, height: 22)
                        .background(HUDGlass.well, in: Circle())
                    Text(MeetPresentation.stepName(step))
                        .textRole(index == current ? .bodyEmph : .body)
                        .foregroundStyle(index == current || current == nil ? HUDTheme.primaryText : HUDTheme.secondaryText)
                        .lineLimit(2)
                    if let difficulty = step.difficulty {
                        Image(systemName: difficulty.icon)
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(HUDTheme.color(for: difficulty))
                            .accessibilityLabel(difficulty.displayName)
                    }
                    Spacer(minLength: 8)
                    Text(UnitFormatter.formatTime(max(0, step.exitS - step.enterS)))
                        .textRole(.label)
                        .monospacedDigit()
                        .foregroundStyle(HUDTheme.secondaryText)
                }
                .padding(.vertical, 6)
                .background(alignment: .leading) {
                    if index == current {
                        Capsule().fill(color).frame(width: 3).offset(x: -10)
                    }
                }
            }
        }
    }
}

/// A run's height along its length: the line from its top (left) to its
/// bottom (right), filled under, with the two heights over its ends. Drawn
/// once and never animated, so Reduce Motion has nothing to stop.
private struct ElevationProfileChart: View {
    let points: [ElevationProfile.Point]
    /// The card's own Vertical figure, so VoiceOver says the same drop.
    let drop: String
    let tint: Color

    @ScaledMetric(relativeTo: .caption) private var height: CGFloat = 56

    var body: some View {
        let top = UnitFormatter.elevation(points.first?.eleM ?? 0)
        let bottom = UnitFormatter.elevation(points.last?.eleM ?? 0)
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(top)
                Spacer(minLength: 8)
                Text(bottom)
            }
            .textRole(.caption)
            .monospacedDigit()
            .foregroundStyle(HUDTheme.secondaryText)
            ZStack {
                ProfileShape(points: points, closed: true).fill(tint.opacity(0.18))
                ProfileShape(points: points, closed: false)
                    .stroke(tint, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            }
            .frame(height: height)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Elevation profile")
        .accessibilityValue("Top \(top), bottom \(bottom), a drop of \(drop)")
    }
}

/// The profile's line scaled to its frame: the run's length across, its
/// lowest to highest point up; closed along the foot for the fill.
nonisolated private struct ProfileShape: Shape {
    let points: [ElevationProfile.Point]
    let closed: Bool

    func path(in rect: CGRect) -> Path {
        guard let first = points.first, let last = points.last, last.distanceM > first.distanceM else { return Path() }
        let heights = points.map(\.eleM)
        let low = heights.min() ?? 0
        let span = max((heights.max() ?? 0) - low, 1)
        // Half the stroke's width inside, so the top of the line is not cut.
        let frame = rect.insetBy(dx: 1, dy: 1)
        func place(_ point: ElevationProfile.Point) -> CGPoint {
            CGPoint(
                x: frame.minX + frame.width * (point.distanceM - first.distanceM) / (last.distanceM - first.distanceM),
                y: frame.maxY - frame.height * (point.eleM - low) / span)
        }
        var path = Path()
        path.move(to: place(first))
        for point in points.dropFirst() { path.addLine(to: place(point)) }
        if closed {
            path.addLine(to: CGPoint(x: frame.maxX, y: rect.maxY))
            path.addLine(to: CGPoint(x: frame.minX, y: rect.maxY))
            path.closeSubpath()
        }
        return path
    }
}

/// The battery meter (GRM, MOG, GLD): a word over four short bars, filled to
/// the nearest quarter.
struct SurfaceMeter: View {
    let label: String
    let level: Double
    let tint: Color

    var body: some View {
        let filled = Int((max(0, min(1, level)) * 4).rounded())
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .textRole(.caption)
                .foregroundStyle(filled > 0 ? tint : HUDTheme.secondaryText)
            HStack(spacing: 2) {
                ForEach(0..<4, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(index < filled ? tint : HUDGlass.well)
                        .frame(width: 12, height: 6)
                }
            }
        }
        .accessibilityElement()
        .accessibilityLabel(label)
        .accessibilityValue("\(filled) of 4")
    }
}
