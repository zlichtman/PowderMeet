import AppCore
import MeetSolver
import MountainCore
import SwiftUI

/// Navigation during an active meet, pinned at the top of the map
/// (`specs/13-APP-MAP.md` section 2.1; Apple Maps' turn-by-turn the
/// reference): one instruction (what to do on which run or lift, which way,
/// how far) over both arrival times. A tap or a pull down opens every step
/// under it; a push up closes the list, and pushed up again puts the
/// directions away to a small pill, while the meet carries on.
struct MeetNavigationBanner: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let resort: ResortModel
    let bundle: ResortBundle
    /// The most the banner may take with its steps open.
    let maxHeight: CGFloat
    @State private var headerHeight: CGFloat = 0

    /// Under one row of room the list is left out rather than squeezed in.
    private var stepListFits: Bool {
        maxHeight - headerHeight - 2 * GlassLayout.cardPadding - 21 >= 44
    }

    var body: some View {
        if let meet = resort.meet, case .active(let active) = meet.state {
            let name = model.name(of: meet.partnerID)
            Group {
                if resort.isNavigationTucked {
                    pill(active, name: name)
                        .transition(MapChrome.transition(.scale(scale: 0.8, anchor: .top).combined(with: .opacity), reduce: reduceMotion))
                } else {
                    banner(active, name: name)
                        .transition(MapChrome.transition(.move(edge: .top).combined(with: .opacity), reduce: reduceMotion))
                }
            }
            .animation(motion, value: resort.isNavigationTucked)
        }
    }

    // MARK: Banner

    private func banner(_ active: MeetSession.Active, name: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 10) {
                instruction(active, name: name)
                let figures = stepFigures(active)
                if let figures { StepFiguresRow(figures: figures) }
                // The arrival times tick on their own: the partner's fix ages.
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    HStack(alignment: .top, spacing: 8) {
                        // Side by side when both names fit, one over the other when not.
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: 14) { arrivals(active, name: name, now: context.date) }
                            VStack(alignment: .leading, spacing: 6) { arrivals(active, name: name, now: context.date) }
                        }
                        Spacer(minLength: 0)
                        // No chevron when there is no list to open (no room
                        // for it at this text size, or no route yet).
                        if canShowSteps(active) {
                            Image(systemName: "chevron.down")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(HUDTheme.secondaryText)
                                .rotationEffect(.degrees(resort.isNavigationStepsOpen ? 180 : 0))
                                .animation(reduceMotion ? nil : motion, value: resort.isNavigationStepsOpen)
                                .accessibilityHidden(true)
                        }
                    }
                }
            }
            // Measured, not assumed: the lines above grow with the text size,
            // a two-line step and stacked arrival times.
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { headerHeight = $0 }
            if resort.isNavigationStepsOpen, let navigation = active.navigation, stepListFits {
                GlassDivider(inset: 0)
                ScrollView {
                    RouteSteps(
                        route: navigation.route, bundle: bundle, color: HUDTheme.routeSkierA,
                        current: navigation.maneuverIndex)
                        .padding(.leading, 10)
                }
                .scrollIndicators(.hidden)
                .scrollBounceBehavior(.basedOnSize)
                // The room left under the measured lines, the divider and the padding.
                .frame(maxHeight: max(0, maxHeight - headerHeight - 2 * GlassLayout.cardPadding - 21))
                .fixedSize(horizontal: false, vertical: true)
                .transition(MapChrome.transition(.opacity.combined(with: .move(edge: .top)), reduce: reduceMotion))
            }
        }
        .padding(GlassLayout.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .environment(\.isOnGlass, true)
        .glassEffect(HUDGlass.surface, in: RoundedRectangle(cornerRadius: GlassLayout.cardRadius, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: GlassLayout.cardRadius, style: .continuous))
        .onTapGesture { toggleSteps(active) }
        .gesture(DragGesture(minimumDistance: 16).onEnded { value in
            let dy = value.translation.height
            guard abs(dy) > abs(value.translation.width), abs(dy) > 30 else { return }
            withAnimation(motion) {
                if dy > 0 {
                    if canShowSteps(active) { resort.setNavigationStepsOpen(true) }
                } else if resort.isNavigationStepsOpen {
                    resort.setNavigationStepsOpen(false)
                } else {
                    resort.setNavigationTucked(true)
                }
            }
        })
        .animation(motion, value: resort.isNavigationStepsOpen)
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: resort.isNavigationStepsOpen ? "Hide steps" : "Show every step") { toggleSteps(active) }
        .accessibilityAction(named: "Put directions away") {
            withAnimation(motion) { resort.setNavigationTucked(true) }
        }
    }

    /// The panel spring, or a 0.2 s fade under Reduce Motion.
    private var motion: Animation { MapChrome.motion(reduce: reduceMotion) }

    /// Whether the step list would show anything if opened.
    private func canShowSteps(_ active: MeetSession.Active) -> Bool {
        stepListFits && active.navigation != nil
    }

    /// Closing always works; opening only when there is a list to show.
    private func toggleSteps(_ active: MeetSession.Active) {
        guard resort.isNavigationStepsOpen || canShowSteps(active) else { return }
        withAnimation(motion) { resort.setNavigationStepsOpen(!resort.isNavigationStepsOpen) }
    }

    /// The next step, large; or what is happening instead (off route, there).
    @ViewBuilder
    private func instruction(_ active: MeetSession.Active, name: String) -> some View {
        if let status = guidance(active, name: name) {
            HStack(spacing: 12) {
                cue(status.icon, tint: status.tint)
                Text(status.text)
                    .textRole(.bodyEmph)
                    .foregroundStyle(HUDTheme.primaryText)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .combine)
        } else if let navigation = active.navigation, navigation.maneuvers.indices.contains(navigation.maneuverIndex) {
            let step = navigation.maneuvers[navigation.maneuverIndex]
            let nextIndex = navigation.maneuverIndex + 1
            let next = navigation.maneuvers.indices.contains(nextIndex) ? navigation.maneuvers[nextIndex] : nil
            let tint = step.difficulty.map { HUDTheme.color(for: $0) } ?? HUDTheme.accent
            HStack(spacing: 12) {
                cue(Self.icon(step, next: next), tint: tint)
                VStack(alignment: .leading, spacing: 1) {
                    Text(UnitFormatter.distance(navigation.currentStepRemainingM ?? step.lengthM))
                        .textRole(.display)
                        .monospacedDigit()
                        .foregroundStyle(HUDTheme.primaryText)
                        .contentTransition(reduceMotion ? ContentTransition.identity : ContentTransition.numericText())
                    Text("\(Self.verb(step)) \(MeetPresentation.stepName(step))")
                        .textRole(.bodyEmph)
                        .foregroundStyle(HUDTheme.primaryText)
                        .lineLimit(2)
                    if let next {
                        Text("Then \(MeetPresentation.stepName(next, withLength: false))")
                            .textRole(.label)
                            .foregroundStyle(HUDTheme.secondaryText)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .combine)
        } else {
            HStack(spacing: 12) {
                cue("location.fill", tint: HUDTheme.secondaryText)
                Text(active.lost ? "Off the map · directions paused" : "Finding where you are")
                    .textRole(.bodyEmph)
                    .foregroundStyle(HUDTheme.primaryText)
                Spacer(minLength: 0)
            }
        }
    }

    /// The run or lift of the step being skied, while a step is what the card
    /// shows (not off route, not there).
    private func stepFigures(_ active: MeetSession.Active) -> GroupFigures? {
        guard guidance(active, name: "") == nil, let navigation = active.navigation,
              navigation.maneuvers.indices.contains(navigation.maneuverIndex),
              let id = navigation.maneuvers[navigation.maneuverIndex].group,
              let group = bundle.groups.first(where: { $0.id == id }) else { return nil }
        let step = navigation.maneuvers[navigation.maneuverIndex]
        return GroupFigures(resort: resort, group: group, bundle: bundle, stepEdges: step.edgeIDs, stepLengthM: step.lengthM)
    }

    private func cue(_ icon: String, tint: Color) -> some View {
        Image(systemName: icon)
            .font(.title2.weight(.semibold))
            .foregroundStyle(tint)
            .frame(width: 48, height: 48)
            .background(HUDGlass.well, in: RoundedRectangle(cornerRadius: GlassLayout.innerRadius, style: .continuous))
            .contentTransition(reduceMotion ? ContentTransition.identity : ContentTransition.symbolEffect(.replace))
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private func arrivals(_ active: MeetSession.Active, name: String, now: Date) -> some View {
        if let me = model.profile {
            arrival(me.id, "You", ownETA(active), tint: HUDTheme.routeSkierA, avatarName: me.displayName)
        }
        if let partnerID = resort.meet?.partnerID {
            partnerArrival(active, partnerID: partnerID, name: name, now: now)
        }
    }

    /// One skier's arrival: their photo ringed in their
    /// route's colour (the initials disc without one), their full name, which
    /// gives way before the time does, and the time.
    /// With `onTap` the row is a button: the partner's name flies the map to them.
    /// `avatarName` gives the initials disc its letters where the row's own
    /// words are "You".
    @ViewBuilder
    private func arrival(
        _ userID: UUID, _ name: String, _ value: String, tint: Color, avatarName: String? = nil,
        onTap: (() -> Void)? = nil
    ) -> some View {
        if let onTap {
            Button(action: onTap) { arrivalRow(userID, name, value, tint: tint, avatarName: avatarName) }
                .buttonStyle(.plain)
                .accessibilityLabel("Show \(name) on the map")
                .accessibilityValue(value)
        } else {
            arrivalRow(userID, name, value, tint: tint, avatarName: avatarName)
        }
    }

    private func arrivalRow(
        _ userID: UUID, _ name: String, _ value: String, tint: Color, avatarName: String?
    ) -> some View {
        HStack(spacing: 6) {
            AvatarView(userID: userID, path: model.person(userID)?.avatarURL, name: avatarName ?? name, size: 20)
                .overlay(Circle().stroke(tint, lineWidth: 2))
                .accessibilityHidden(true)
            Text(name)
                .foregroundStyle(HUDTheme.secondaryText)
                .truncationMode(.tail)
                .fixedSize(horizontal: false, vertical: true)
            Text(value)
                .fontWeight(.semibold)
                .monospacedDigit()
                .foregroundStyle(HUDTheme.primaryText)
                .layoutPriority(1)
        }
        .textRole(.label)
        .lineLimit(1)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func partnerArrival(_ active: MeetSession.Active, partnerID: UUID, name: String, now: Date) -> some View {
        if let partner = active.partner {
            let value = switch partner.state {
            case .arrived: "Arrived"
            case .lost: "No signal"
            case .rerouting: "Rerouting"
            case .navigating: Wording.eta(seconds: partner.etaS, sd: partner.etaSdS)
            }
            let stale = now.timeIntervalSince(partner.fixAt) >= 60
            arrival(partnerID, name, stale ? "\(value) · \(Wording.age(since: partner.fixAt, now: now))" : value,
                    tint: HUDTheme.routeSkierB) { resort.centre(onFriend: partnerID) }
        } else {
            // Nothing from the partner yet: the ETA agreed when the meet started.
            let row = active.meet
            let agreed = row.proposerID == resort.meet?.partnerID
                ? Wording.eta(seconds: row.proposerEtaS, sd: row.proposerEtaSdS)
                : Wording.eta(seconds: row.inviteeEtaS, sd: row.inviteeEtaSdS)
            arrival(partnerID, name, agreed, tint: HUDTheme.routeSkierB) { resort.centre(onFriend: partnerID) }
        }
    }

    // MARK: Pill

    /// Put away: one short line at the top; a tap brings the directions back.
    private func pill(_ active: MeetSession.Active, name: String) -> some View {
        Button {
            withAnimation(motion) { resort.setNavigationTucked(false) }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "figure.skiing.downhill")
                    .foregroundStyle(HUDTheme.routeSkierA)
                Text("Meeting \(name)")
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(HUDTheme.primaryText)
                Text("· you \(ownETA(active))")
                    .monospacedDigit()
                    .foregroundStyle(HUDTheme.secondaryText)
                Image(systemName: "chevron.down")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(HUDTheme.secondaryText)
            }
            .textRole(.label)
            .lineLimit(1)
            .glassChip(interactive: true)
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
        .accessibilityLabel("Meeting \(name)")
        .accessibilityValue("You \(ownETA(active))")
        .accessibilityHint("Shows directions")
    }

    // MARK: Wording

    /// At the meeting point by the phone's own rule (30 m for 10 s); a route
    /// used up is only nearly there.
    private func isComplete(_ active: MeetSession.Active) -> Bool { active.arrived }

    private func isNearlyThere(_ active: MeetSession.Active) -> Bool {
        !active.arrived && active.navigation?.progress.state == .arrived
    }

    /// Off route, or this skier is there: said instead of the next step. The
    /// partner arriving first changes nothing here: this skier still needs
    /// their directions, and the partner's own row says "Arrived".
    private func guidance(_ active: MeetSession.Active, name: String) -> (icon: String, text: String, tint: Color)? {
        let complete = isComplete(active)
        let partnerThere = active.partner?.state == .arrived
        if (active.lost || active.navigation?.progress.state == .offRoute) && !complete {
            return ("exclamationmark.triangle.fill", "Off route · directions paused", HUDTheme.accentAmber)
        }
        if complete && partnerThere { return ("checkmark.circle.fill", "You met up", HUDTheme.accentGreen) }
        if complete { return ("checkmark.circle.fill", "You're at the meeting point", HUDTheme.accentGreen) }
        return nil
    }

    private func ownETA(_ active: MeetSession.Active) -> String {
        if isComplete(active) { return "Arrived" }
        if isNearlyThere(active) { return "Nearly there" }
        if let navigation = active.navigation { return Wording.eta(navigation.eta) }
        return active.lost ? "Off the map" : "Locating"
    }

    static func verb(_ step: Maneuver) -> String {
        switch step.action {
        case .ski: "Ski"
        case .ride: "Ride"
        case .connect: "Take"
        }
    }

    /// The cue is for the end of this step, which is the next one's entry turn.
    static func icon(_ step: Maneuver, next: Maneuver?) -> String {
        switch step.action {
        case .ride: return "arrow.up.right.circle.fill"
        case .connect: return "figure.skiing.crosscountry"
        case .ski:
            guard let next else { return "flag.checkered" }
            switch next.action {
            case .ride: return "arrow.up.right.circle"
            case .connect: return "figure.skiing.crosscountry"
            case .ski:
                switch next.turn {
                case .left: return "arrow.turn.down.left"
                case .straight: return "arrow.down"
                case .right: return "arrow.turn.down.right"
                }
            }
        }
    }
}
