import MeetSolver
import MountainCore
import PowderMeetAPI
import SwiftUI

/// One skier's route on an option card: whose, its ETA and the route's
/// profile; tapped open, the first steps with their times and difficulty, and
/// how many more. Closed to start, so two routes and the option's reasons fit
/// one screen.
struct MeetRouteSection: View {
    let label: String
    let route: Route
    let color: Color
    let bundle: ResortBundle?
    var maxSteps = 4
    /// Held by the card, which keeps one row open at a time.
    let isOpen: Bool
    let onToggle: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(AppModel.self) private var model
    @Environment(\.isOnGlass) private var isOnGlass
    @State private var maneuvers = ManeuverMemo()

    /// Whose route it is, as their photo ringed in the route's colour: the
    /// same face and the same colour as their line on the map.
    private var face: some View {
        let own = model.profile.flatMap { $0.id == route.skierID ? $0 : nil }
        let person = model.person(route.skierID)
        return AvatarView(
            userID: route.skierID, path: own?.avatarURL ?? person?.avatarURL,
            name: own?.displayName ?? model.name(of: route.skierID), size: 30)
            .overlay(Circle().strokeBorder(color, lineWidth: 2))
            .frame(width: MeetOptionCard.iconColumn)
            .accessibilityHidden(true)
    }

    var body: some View {
        // Maneuvers group a route's edges into whole runs and lifts.
        let steps = bundle.map { maneuvers.steps(for: route, in: $0) } ?? []
        let facts = MeetPresentation.facts(route, maneuvers: steps)
        VStack(alignment: .leading, spacing: 8) {
            // The photo and the chevron sit level with the middle of the
            // two lines between them.
            HStack(spacing: 10) {
                face
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text(label)
                            .textRole(.label)
                            .fontWeight(.semibold)
                            .foregroundStyle(color)
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        Text(Wording.eta(route.eta))
                            .textRole(.label)
                            .monospacedDigit()
                            .foregroundStyle(HUDTheme.primaryText)
                            .fixedSize()
                    }
                    if let facts {
                        Text(facts)
                            .textRole(.caption)
                            .foregroundStyle(HUDTheme.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Image(systemName: "chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(HUDTheme.secondaryText)
                    .rotationEffect(.degrees(isOpen ? 180 : 0))
                    .accessibilityHidden(true)
            }
            .frame(minHeight: 36)
            .contentShape(Rectangle())
            // A tap, not a button: a sideways swipe that starts on the row
            // still turns to the next option.
            .onTapGesture {
                withAnimation(MapChrome.motion(reduce: reduceMotion)) { onToggle() }
            }
            .accessibilityAddTraits(.isButton)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel([label, Wording.eta(route.eta), facts].compactMap { $0 }.joined(separator: ", "))
            .accessibilityValue(isOpen ? "Steps shown" : "Steps hidden")
            .accessibilityHint(isOpen ? "Hides the steps" : "Shows the steps")

            if !isOpen {
                EmptyView()
            } else if route.legs.isEmpty {
                Text("Already at the meeting point")
                    .textRole(.caption)
                    .foregroundStyle(HUDTheme.secondaryText)
                    .padding(.leading, MeetOptionCard.iconColumn + 10)
            } else {
                ForEach(Array(steps.prefix(maxSteps).enumerated()), id: \.offset) { _, step in
                    HStack(spacing: 10) {
                        Image(systemName: MeetPresentation.stepIcon(step.action))
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(Self.iconColor(step))
                            .frame(width: MeetOptionCard.iconColumn)
                        Text(MeetPresentation.stepName(step))
                            .textRole(.label)
                            .foregroundStyle(HUDTheme.primaryText)
                            .fixedSize(horizontal: false, vertical: true)
                        if let difficulty = step.difficulty {
                            Image(systemName: difficulty.icon)
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(HUDTheme.color(for: difficulty))
                                .accessibilityLabel(difficulty.displayName)
                        }
                        Spacer(minLength: 4)
                        Text(UnitFormatter.formatTime(max(0, step.exitS - step.enterS)))
                            .textRole(.caption)
                            .monospacedDigit()
                            .foregroundStyle(HUDTheme.secondaryText)
                    }
                }
                if steps.count > maxSteps {
                    Text("+\(steps.count - maxSteps) more on the map")
                        .textRole(.caption)
                        .foregroundStyle(HUDTheme.secondaryText)
                        .padding(.leading, MeetOptionCard.iconColumn + 10)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .hudCard(cornerRadius: isOnGlass ? GlassLayout.innerRadius : GlassLayout.cardRadius)
    }

    static func iconColor(_ step: Maneuver) -> Color {
        switch step.action {
        case .ride: HUDTheme.liftColor
        case .ski: step.difficulty.map { HUDTheme.color(for: $0) } ?? HUDTheme.secondaryText
        case .connect: HUDTheme.secondaryText
        }
    }
}

/// The steps of the route last asked for. A card re-renders on every swipe of
/// the pager and every solve or clock tick, so it groups a route's edges once
/// per route and map, not once per render.
@MainActor
final class ManeuverMemo {
    private var key: (route: Route, bundle: BundleID)?
    private var steps: [Maneuver] = []

    func steps(for route: Route, in bundle: ResortBundle) -> [Maneuver] {
        if let key, key.route == route, key.bundle == bundle.id { return steps }
        steps = Maneuvers.build(for: route, in: bundle)
        key = (route, bundle.id)
        return steps
    }
}
