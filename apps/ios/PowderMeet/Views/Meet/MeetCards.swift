import AppCore
import MapScene
import MeetSolver
import MountainCore
import PowderMeetAPI
import SwiftUI

// The meet's states in the context sheet (`specs/13-APP-MAP.md` section 2):
// the meeting options after a friend is tapped, the request sent, a request
// received, and the meet under way (or just ended). They render the meet's
// projection (`MeetModel`) and call its intents; the session does the work.

// MARK: Options

/// After tapping a friend: their name, distance and live state; the option
/// cards, one per page, swiped to pick (the map draws the one on screen); and
/// "PowderMeet", which sends it. Swiped up, each card shows its reasons and
/// both routes. Nothing is sent until the button is pressed.
struct MeetOptionsCard: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// False when the card is swiped up: it is then a stack of separate glass
    /// pieces over the map, with no sheet behind them.
    @Environment(\.isOnGlass) private var isOnGlass
    let resort: ResortModel
    let bundle: ResortBundle
    let expanded: Bool
    /// The most the open option may take before it scrolls.
    let maxHeight: CGFloat
    let onClose: () -> Void

    /// The page on screen. It follows the session's pick and, when the user
    /// swipes, sets it.
    @State private var page: Int?
    @State private var pageHeights: [Int: CGFloat] = [:]

    var body: some View {
        if let meet = resort.meet, case .proposing(let proposing) = meet.state {
            let name = model.name(of: meet.partnerID)
            VStack(alignment: .leading, spacing: isOnGlass ? 12 : GlassLayout.gap) {
                if proposing.replacing != nil {
                    ContextNote(icon: "arrow.triangle.2.circlepath",
                                text: "\(name) still has your first request until you send this one.",
                                tint: HUDTheme.accent)
                }
                if let notice = MeetPresentation.weatherNotice(resort.conditions, now: Date()) {
                    ContextNote(icon: "cloud.slash.fill", text: notice)
                }
                if proposing.requestedUnreachable, let place = proposing.requested {
                    ContextNote(
                        icon: "mappin.slash",
                        text: "You can't both get to \(Wording.placeTitle(place, in: bundle)) right now.")
                }
                if let options = proposing.options?.options, !options.isEmpty {
                    if expanded {
                        // The option sits at the bottom, over the page
                        // indicator, as tall as it is: the map and the routes
                        // drawn on it stay in view above. A row that opens
                        // grows it upward, to a small gap under the status
                        // bar before it scrolls.
                        ScrollView {
                            pager(options, proposing: proposing, meet: meet, name: name)
                        }
                        .scrollBounceBehavior(.basedOnSize)
                        .scrollIndicators(.hidden)
                        .frame(maxHeight: max(160, maxHeight - 34))
                        .fixedSize(horizontal: false, vertical: true)
                    } else {
                        pager(options, proposing: proposing, meet: meet, name: name)
                    }
                    footer(count: options.count, proposing: proposing)
                    if !expanded { MeetSendButton(resort: resort) }
                    sendFailure(meet: meet, proposing: proposing)
                } else {
                    emptyState(meet: meet, proposing: proposing)
                }
            }
            .onAppear { page = proposing.picked ?? 0 }
            // A new solve can move or clamp the pick; the pager follows it.
            .onChange(of: proposing.picked) { _, picked in
                if let picked, picked != page { page = picked }
            }
            // Swiping to a card picks it, so the map draws, and the button
            // sends, the card that is on screen.
            .onChange(of: page) { _, page in
                if let page, page != proposing.picked, page < (proposing.options?.options.count ?? 0),
                   !proposing.sending {
                    meet.pick(option: page)
                }
            }
        }
    }

    private func shownPage(_ count: Int, _ proposing: MeetSession.Proposing) -> Int {
        min(max(0, page ?? proposing.picked ?? 0), max(0, count - 1))
    }

    private func pager(
        _ options: [MeetOption], proposing: MeetSession.Proposing, meet: MeetModel, name: String
    ) -> some View {
        let visible = shownPage(options.count, proposing)
        return ScrollView(.horizontal) {
            // Far enough apart that the next option is off the screen, not a
            // sliver at its edge.
            HStack(alignment: .top, spacing: expanded ? 40 : 0) {
                // Indexed by position: `MeetOption` holds a tuple.
                ForEach(Array(options.indices), id: \.self) { index in
                    Group {
                        if expanded {
                            MeetOptionCard(
                                index: index, option: options[index], degraded: proposing.options?.degraded ?? false,
                                bundle: bundle, partnerName: name)
                        } else {
                            MeetOptionSummary(
                                index: index, option: options[index], degraded: proposing.options?.degraded ?? false,
                                bundle: bundle, partnerName: name)
                        }
                    }
                    .padding(.horizontal, 2)
                    .containerRelativeFrame(.horizontal)
                    // Measured at its own height, not the pager's: a card that
                    // grows after the first measure (a note arriving, a route
                    // filling in) would otherwise stay squeezed and spill over
                    // the header.
                    .fixedSize(horizontal: false, vertical: true)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { pageHeights[index] = $0 }
                    // Every card is then held to the height of the one on
                    // screen, from the top: a taller neighbour is cut off
                    // below instead of making the row taller and pushing
                    // this one up out of its place.
                    .frame(height: pageHeights[visible], alignment: .top)
                    .clipped()
                    .id(index)
                }
            }
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.viewAligned(limitBehavior: .alwaysByOne))
        .scrollPosition(id: $page)
        .scrollIndicators(.hidden)
        .scrollDisabled(proposing.sending)
        // As tall as the card on screen, so a short one leaves no gap.
        .frame(height: pageHeights[visible], alignment: .top)
        .animation(MapChrome.motion(reduce: reduceMotion), value: pageHeights[visible])
    }

    private func footer(count: Int, proposing: MeetSession.Proposing) -> some View {
        let visible = shownPage(count, proposing)
        // A page indicator, centred: the lit dot is a short bar, so which
        // option is up reads at a glance and the row needs no words.
        return HStack(spacing: 6) {
            if count > 1 {
                ForEach(0..<count, id: \.self) { index in
                    Capsule()
                        .fill(index == visible ? HUDTheme.accent : HUDTheme.secondaryText.opacity(0.35))
                        .frame(width: index == visible ? 18 : 7, height: 7)
                }
            }
        }
        .padding(.horizontal, 14)
        .frame(minHeight: count > 1 ? 26 : 0)
        .modifier(StandaloneGlass(shape: Capsule(), applies: !isOnGlass && count > 1))
        .frame(maxWidth: .infinity)
        .animation(MapChrome.motion(reduce: reduceMotion), value: visible)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Option \(visible + 1) of \(count)")
        .accessibilityAction(named: "Next meeting option") {
            if visible + 1 < count { page = visible + 1 }
        }
        .accessibilityAction(named: "Previous meeting option") {
            if visible > 0 { page = visible - 1 }
        }
        .accessibilityAction(named: "First meeting option") { page = 0 }
        .frame(minHeight: GlassLayout.chipHeight)
        // A tap on the dots goes straight back to the first, best option,
        // however far along the skier has swiped.
        .contentShape(Rectangle())
        .onTapGesture {
            if visible > 0 { withAnimation(MapChrome.motion(reduce: reduceMotion)) { page = 0 } }
        }
    }

    @ViewBuilder
    private func sendFailure(meet: MeetModel, proposing: MeetSession.Proposing) -> some View {
        if let failure = proposing.failure, !proposing.sending {
            // Tap to send again.
            Button { meet.sendProposal() } label: {
                ContextNote(icon: "exclamationmark.circle.fill", text: MeetPresentation.failureMessage(failure), tint: HUDTheme.accentRed)
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder
    private func emptyState(meet: MeetModel, proposing: MeetSession.Proposing) -> some View {
        if proposing.options == nil, proposing.failure == nil {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Finding meeting points")
                    .textRole(.label)
                    .foregroundStyle(HUDTheme.secondaryText)
                Spacer(minLength: 0)
            }
            .frame(minHeight: GlassLayout.chipHeight)
            .padding(.horizontal, isOnGlass ? 0 : 14)
            .modifier(StandaloneGlass(shape: Capsule(), applies: !isOnGlass))
        } else {
            let message = proposing.failure.map(MeetPresentation.failureMessage) ?? PowderMeetError.routing(.lostAll).userMessage
            ContextNote(icon: "exclamationmark.triangle.fill", text: "No meeting point found. \(message)")
            SecondaryButton(title: "Try again", systemImage: "arrow.clockwise") { meet.retrySolve() }
        }
    }
}

/// Sends the option on screen: under the short options card, and in place of
/// the resort bar while the options are swiped up.
struct MeetSendButton: View {
    @Environment(AppModel.self) private var model
    let resort: ResortModel

    var body: some View {
        if let meet = resort.meet, case .proposing(let proposing) = meet.state {
            PrimaryButton(
                title: proposing.sending ? "Sending" : "PowderMeet",
                systemImage: "bolt.fill",
                mirrorsImage: true,
                titleImage: "PowderMeetWordmark",
                isLoading: proposing.sending,
                isEnabled: proposing.picked != nil
            ) {
                meet.sendProposal()
            }
            // The wordmark says nothing aloud about what the tap does.
            .accessibilityLabel(proposing.sending
                ? "Sending" : "Send meet-up request to \(model.name(of: meet.partnerID))")
        }
    }
}

/// An option in short: why it is offered, where, together in how long and who
/// waits.
private struct MeetOptionSummary: View {
    let index: Int
    let option: MeetOption
    let degraded: Bool
    let bundle: ResortBundle
    let partnerName: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Label(MeetPresentation.headline(option.tradeoff, index: index),
                      systemImage: MeetPresentation.headlineIcon(option.tradeoff, index: index))
                    .textRole(.label)
                    .fontWeight(.semibold)
                    .foregroundStyle(index == 0 ? HUDTheme.accentAmber : HUDTheme.secondaryText)
                Spacer(minLength: 8)
                Text("Together in \(MeetPresentation.together(option))")
                    .textRole(.label)
                    .monospacedDigit()
                    .foregroundStyle(HUDTheme.routeMeeting)
            }
            HStack(spacing: 10) {
                ContextGlyph(
                    systemImage: MeetPresentation.kindIcon(bundle.rendezvous(option.rendezvous)?.kind),
                    tint: HUDTheme.routeMeeting)
                VStack(alignment: .leading, spacing: 2) {
                    Text(Wording.rendezvousName(option.rendezvous, in: bundle))
                        .textRole(.bodyEmph)
                        .foregroundStyle(HUDTheme.primaryText)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Text(MeetPresentation.balance(option, partnerName: partnerName))
                        .textRole(.label)
                        .foregroundStyle(HUDTheme.secondaryText)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
            }
            // Said here too: PowderMeet sends from the collapsed card.
            ForEach(MeetPresentation.collapsedCautions(option, degraded: degraded, partnerName: partnerName), id: \.self) {
                ContextNote(icon: "exclamationmark.triangle.fill", text: $0)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

// MARK: Sent

/// The request sent, waiting for the friend: where, your ETA, the time left,
/// and Change or Cancel.
struct MeetSentCard: View {
    @Environment(AppModel.self) private var model
    let resort: ResortModel
    let bundle: ResortBundle

    var body: some View {
        if let meet = resort.meet, case .proposed(let sent) = meet.state {
            let name = model.name(of: meet.partnerID)
            VStack(alignment: .leading, spacing: 12) {
                ContextHeader(
                    title: "Waiting for \(name)",
                    subtitle: "At \(Wording.rendezvousName(sent.rendezvousID, in: bundle)) · you \(Wording.eta(seconds: sent.proposerEtaS, sd: sent.proposerEtaSdS))",
                    onTitleTap: { resort.centre(onFriend: meet.partnerID) }, titleTapLabel: "Show \(name) on the map"
                ) {
                    AvatarView(userID: meet.partnerID, path: model.person(meet.partnerID)?.avatarURL, name: name, size: 40)
                        .overlay(Circle().strokeBorder(HUDTheme.routeSkierB, lineWidth: 2))
                } trailing: {
                    MeetCountdown(expiresAt: sent.expiresAt)
                }
                HStack(spacing: GlassLayout.gap) {
                    SecondaryButton(title: "Change spot", systemImage: "arrow.triangle.2.circlepath") {
                        meet.changeProposal()
                    }
                    SecondaryButton(title: "Cancel", systemImage: "xmark", destructive: true) {
                        meet.end()
                    }
                    .accessibilityLabel("Cancel the request to \(name)")
                }
            }
        }
    }
}

// MARK: Incoming

/// A request received: who, where, how long for each of you, Accept and
/// Decline. Your own route is worked out on this phone before you decide;
/// Accept waits for it. Swiped up: that route, step by step.
struct MeetIncomingCard: View {
    @Environment(AppModel.self) private var model
    let resort: ResortModel
    let bundle: ResortBundle
    let expanded: Bool

    var body: some View {
        if let meet = resort.meet, case .incoming(let incoming) = meet.state {
            let row = incoming.meet
            let name = model.name(of: row.proposerID)
            VStack(alignment: .leading, spacing: 12) {
                ContextHeader(
                    title: "\(name) wants to meet", subtitle: "At \(place(row.rendezvousID))",
                    onTitleTap: { resort.centre(onFriend: row.proposerID) }, titleTapLabel: "Show \(name) on the map"
                ) {
                    AvatarView(userID: row.proposerID, path: model.person(row.proposerID)?.avatarURL, name: name, size: 40)
                        .overlay(Circle().strokeBorder(HUDTheme.routeSkierB, lineWidth: 2))
                } trailing: {
                    MeetCountdown(expiresAt: row.expiresAt)
                }

                HStack(alignment: .top, spacing: 20) {
                    ContextStat(
                        label: name, value: Wording.eta(seconds: row.proposerEtaS, sd: row.proposerEtaSdS),
                        tint: HUDTheme.routeSkierB)
                    ContextStat(label: "You", value: ownETA(incoming), tint: HUDTheme.routeSkierA)
                    Spacer(minLength: 0)
                }
                // Why there is no route, or why Accept failed: a lasting
                // failure gets no toast, so the card is the only place it shows.
                if let failure = incoming.failure, incoming.ownRoute == nil || !failure.isTransient {
                    ContextNote(icon: "exclamationmark.triangle.fill", text: failure.userMessage)
                }
                if let note = MeetPresentation.easiestWayDownNote(incoming.ownRoute, me: row.inviteeID, partnerName: name) {
                    ContextNote(icon: "exclamationmark.triangle.fill", text: note)
                }
                if incoming.ownRoute != nil, let note = MeetPresentation.statusNote(resort.status, now: Date()) {
                    ContextNote(icon: "exclamationmark.triangle.fill", text: note)
                }

                if expanded, let route = incoming.ownRoute {
                    GlassDivider(inset: 0)
                    SectionHeader("Your route")
                    RouteSteps(route: route, bundle: bundle, color: HUDTheme.routeSkierA)
                }

                HStack(spacing: GlassLayout.gap) {
                    PrimaryButton(title: "Accept", systemImage: "checkmark", isEnabled: incoming.ownRoute != nil) {
                        meet.accept()
                    }
                    .accessibilityHint(incoming.ownRoute == nil ? "Available once your route is ready" : "")
                    SecondaryButton(title: "Decline", destructive: true) { meet.decline() }
                }
            }
        }
    }

    private func place(_ id: RendezvousID) -> String {
        let name = Wording.rendezvousName(id, in: bundle)
        guard let elevation = MeetPresentation.elevationM(of: id, in: bundle) else { return name }
        return "\(name) · \(UnitFormatter.elevation(elevation))"
    }

    private func ownETA(_ incoming: MeetSession.Incoming) -> String {
        if let route = incoming.ownRoute { return Wording.eta(route.eta) }
        return incoming.failure == nil ? "Routing…" : "No route"
    }
}

/// "Expires 4:32", ticking each second.
struct MeetCountdown: View {
    let expiresAt: Date

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            Text(MeetPresentation.countdown(to: expiresAt, now: context.date))
                .textRole(.label)
                .monospacedDigit()
                .foregroundStyle(HUDTheme.accentAmber)
                .accessibilityLabel("Expires in \(MeetPresentation.countdown(to: expiresAt, now: context.date))")
        }
    }
}

// MARK: Under way

/// The meet under way, at the bottom, all of it at once with nothing to
/// swipe open: where, "View route" and put away, the route as a strip in its
/// runs' colours, the lap suggestion and "End". The meet completes by itself
/// once both skiers are there. The next step, both arrival times and the step list are pinned at the top
/// (`MeetNavigationBanner`), so the map between stays clear. After the meet:
/// how it ended, Done.
struct MeetUnderWayCard: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let resort: ResortModel
    let bundle: ResortBundle

    @State private var isConfirmingEnd = false

    var body: some View {
        if let meet = resort.meet {
            switch meet.state {
            case .active(let active):
                activeBody(meet: meet, active: active)
            case .ended(let ended):
                endedBody(ended: ended, name: model.name(of: meet.partnerID))
            default:
                EmptyView()
            }
        }
    }

    // MARK: Active

    private func activeBody(meet: MeetModel, active: MeetSession.Active) -> some View {
        let name = model.name(of: meet.partnerID)
        let rendezvous = active.meet.rendezvousID
        return VStack(alignment: .leading, spacing: 12) {
            ContextHeader(
                title: Wording.placeTitle(rendezvous, in: bundle),
                subtitle: active.failure?.userMessage ?? MeetPresentation.placeLine(rendezvous, in: bundle),
                subtitleTint: active.failure == nil ? HUDTheme.secondaryText : HUDTheme.accentAmber
            ) {
                ContextGlyph(
                    systemImage: MeetPresentation.kindIcon(bundle.rendezvous(rendezvous)?.kind),
                    tint: isComplete(active) ? HUDTheme.accentGreen : HUDTheme.routeMeeting)
            } trailing: {
                IconButton(systemImage: "map", label: "View route", tint: HUDTheme.accent) {
                    model.showRouteOnMap()
                }
                IconButton(systemImage: "chevron.down", label: "Put directions away") {
                    withAnimation(MapChrome.motion(reduce: reduceMotion)) { resort.setNavigationTucked(true) }
                }
            }

            ForEach(easiestWayDownNotes(meet: meet, active: active, name: name), id: \.self) { note in
                ContextNote(icon: "exclamationmark.triangle.fill", text: note)
            }
            if let note = MeetPresentation.statusNote(resort.status, now: Date()) {
                ContextNote(icon: "exclamationmark.triangle.fill", text: note)
            }
            // Both there: the meet is completing, and says so until it has.
            if active.arrived, active.partner?.state == .arrived {
                ContextNote(icon: "checkmark.circle.fill", text: "You met up", tint: HUDTheme.accentGreen)
            }
            routeStrip(active)
            if let lap = meet.lapSuggestion, let summary = lapSummary(lap, active: active, name: name) {
                MeetLapBox(summary: summary) {
                    if meet.isFollowingLap {
                        SecondaryButton(title: "Back to the meeting route", systemImage: "arrow.uturn.backward") {
                            resort.followLap(false)
                        }
                    } else {
                        SecondaryButton(title: "Follow the lap", systemImage: "arrow.triangle.2.circlepath") {
                            resort.followLap(true)
                        }
                        .accessibilityHint("Draws the lap on the map. The meeting point stays the same.")
                    }
                }
            }
            SecondaryButton(title: "End", destructive: true) {
                isConfirmingEnd = true
            }
            .accessibilityLabel("End meetup")
        }
        // Once the partner is there the lap is over: back to the route.
        .onChange(of: active.partner?.state) { _, state in
            if state == .arrived, meet.isFollowingLap { resort.followLap(false) }
        }
        .confirmCard(
            "End this meet-up?", isPresented: $isConfirmingEnd,
            message: "This ends the shared route for you and \(name).",
            confirm: "End meet-up", cancel: "Keep going"
        ) { meet.end() }
    }

    /// "Easiest way down for …" for either skier whose route is one: this
    /// phone's own route and the partner's projected one.
    private func easiestWayDownNotes(meet: MeetModel, active: MeetSession.Active, name: String) -> [String] {
        let row = active.meet
        let me = meet.partnerID == row.proposerID ? row.inviteeID : row.proposerID
        return [active.navigation?.route, resort.partnerGhostRoute].compactMap {
            MeetPresentation.easiestWayDownNote($0, me: me, partnerName: name)
        }
    }

    /// Arrived means at the meeting point by the phone's own rule; a route
    /// used up is only nearly there.
    private func isComplete(_ active: MeetSession.Active) -> Bool { active.arrived }

    /// The route as one strip: each run and lift a piece as long as its share
    /// of the way, in the run's own colour, bright where it is behind this
    /// skier and faint where it is ahead.
    private func routeStrip(_ active: MeetSession.Active) -> some View {
        let navigation = active.navigation
        let lengthM = navigation?.route.lengthM ?? 0
        let share: Double = {
            guard let navigation, lengthM > 0 else { return isComplete(active) ? 1 : 0 }
            return min(1, max(0, 1 - navigation.progress.remainingM / lengthM))
        }()
        let steps = navigation?.maneuvers.filter { $0.lengthM > 0 } ?? []
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Your route")
                Spacer(minLength: 8)
                if isComplete(active) {
                    Text("Arrived")
                } else if let navigation, lengthM > 0 {
                    Text("\(UnitFormatter.distance(navigation.progress.remainingM)) to go")
                        .monospacedDigit()
                }
            }
            .textRole(.caption)
            .foregroundStyle(HUDTheme.secondaryText)
            GeometryReader { geo in
                let pieces = HStack(spacing: 2) {
                    if steps.isEmpty || lengthM <= 0 {
                        Rectangle().fill(isComplete(active) ? HUDTheme.accentGreen : HUDTheme.accent)
                    } else {
                        ForEach(Array(steps.enumerated()), id: \.offset) { _, step in
                            Rectangle()
                                .fill(MeetRouteSection.iconColor(step))
                                .frame(width: max(2, (geo.size.width - CGFloat(steps.count - 1) * 2) * step.lengthM / lengthM))
                        }
                    }
                }
                .frame(width: geo.size.width, alignment: .leading)
                ZStack(alignment: .leading) {
                    pieces.opacity(0.4)
                    pieces.mask(alignment: .leading) {
                        Rectangle().frame(width: geo.size.width * share)
                    }
                }
                .clipShape(Capsule())
            }
            .frame(height: 8)
        }
        .accessibilityElement()
        .accessibilityLabel("Your route")
        .accessibilityValue("\(Int((share * 100).rounded())) percent done")
    }

    /// The lap in words, or nil once it no longer fits (`MeetModel.lapMarginS`).
    private func lapSummary(_ lap: LapSuggestion, active: MeetSession.Active, name: String) -> MeetPresentation.LapSummary? {
        guard let marginS = resort.meet?.lapMarginS(in: active) else { return nil }
        return MeetPresentation.LapSummary(
            title: active.arrived ? "Optional · a lap while you wait" : "Optional · a lap when you get there",
            path: MeetPresentation.lapPath(Maneuvers.build(for: lap.route, in: bundle)),
            detail: "About \(Wording.minutes(lap.durationS)) · back about \(Wording.minutes(marginS)) before \(name) arrives"
        )
    }

    // MARK: Ended

    private func endedBody(ended: MeetSession.Ended, name: String) -> some View {
        // Ended by hand while the two were together or nearly: GPS missed the
        // meet-up, so it reads as one rather than as a failure.
        let endedTogether = ended.wereTogether && (ended.reason == .userCancelled || ended.reason == .partnerLeft)
        let met = ended.reason == .arrived || endedTogether
        let viewerIsInvitee = ended.meet.map { $0.proposerID == resort.meet?.partnerID } ?? false
        return VStack(alignment: .leading, spacing: 12) {
            ContextHeader(
                title: endedTogether ? Wording.ended(.arrived, partnerName: name)
                    : Wording.ended(ended.reason, partnerName: name, viewerIsInvitee: viewerIsInvitee,
                    endedByViewer: resort.meet.flatMap { MeetPresentation.endedByViewer(ended.meet, partnerID: $0.partnerID) }),
                subtitle: ended.failure?.userMessage
            ) {
                ContextGlyph(
                    systemImage: met ? "checkmark.circle.fill" : "flag.slash.fill",
                    tint: met ? HUDTheme.accentGreen : HUDTheme.secondaryText)
            } trailing: {
                EmptyView()
            }
            PrimaryButton(title: "Done") {
                withAnimation(MapChrome.motion(reduce: reduceMotion)) { resort.dismissMeet() }
            }
        }
    }
}

/// Glass of its own for a piece that sits straight on the map; nothing for a
/// piece already on a sheet's glass.
struct StandaloneGlass<S: Shape>: ViewModifier {
    let shape: S
    let applies: Bool

    func body(content: Content) -> some View {
        if applies {
            content.glassEffect(HUDGlass.surface, in: shape)
        } else {
            content
        }
    }
}
