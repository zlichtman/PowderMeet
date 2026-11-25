import MeetSolver
import MountainCore
import SwiftUI

/// One meeting option in full: one block for the option itself (where and
/// when, the expected wait, anything to be careful of, why the solver offers
/// it, each reason said outright, and the optional lap), then each
/// skier's route as a row that opens, one open at a time. Closed, the whole option fits one
/// screen. The card on screen is the option that will be sent.
struct MeetOptionCard: View {
    let index: Int
    let option: MeetOption
    /// The solve ran on operating hours instead of fresh status.
    let degraded: Bool
    let bundle: ResortBundle?
    let partnerName: String

    /// The icon column every row shares: the place glyph's width.
    static let iconColumn: CGFloat = 40

    @Environment(\.isOnGlass) private var isOnGlass
    /// A box on a sheet is a well in its glass; on the map it is a piece of
    /// glass itself, with the sheet's own corners.
    private var boxRadius: CGFloat { isOnGlass ? GlassLayout.innerRadius : GlassLayout.cardRadius }

    /// The rows that open. One at a time: opening one closes the others, so
    /// the card stays on the screen.
    private enum Row { case mine, theirs }
    @State private var openRow: Row?

    private func toggle(_ row: Row) { openRow = openRow == row ? nil : row }

    private var headline: String { MeetPresentation.headline(option.tradeoff, index: index) }
    private var meetingName: String { Wording.rendezvousName(option.rendezvous, in: bundle) }

    var body: some View {
        let why = MeetPresentation.why(option, partnerName: partnerName)
        let lap = MeetPresentation.lap(option, partnerName: partnerName, bundle: bundle)

        // Every block is a box on the same grid: 12 pt in, one icon column as
        // wide as the place glyph, then the words, so icons sit under icons
        // and every line of text starts at the same edge down the card.
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Image(systemName: MeetPresentation.headlineIcon(option.tradeoff, index: index))
                        .font(.footnote.weight(.semibold))
                        .frame(width: Self.iconColumn)
                        .accessibilityHidden(true)
                    Text(headline)
                        .textRole(.label)
                        .fontWeight(.semibold)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Spacer(minLength: 8)
                    // The time is the fact; the headline gives way to it.
                    Text("Together in \(MeetPresentation.together(option))")
                        .textRole(.label)
                        .monospacedDigit()
                        .foregroundStyle(HUDTheme.routeMeeting)
                        .lineLimit(1)
                        .fixedSize()
                        .layoutPriority(1)
                }
                .foregroundStyle(index == 0 ? HUDTheme.accentAmber : HUDTheme.accentCyan)

                HStack(spacing: 10) {
                    ContextGlyph(
                        systemImage: MeetPresentation.kindIcon(bundle?.rendezvous(option.rendezvous)?.kind),
                        tint: HUDTheme.routeMeeting)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(Wording.placeTitle(option.rendezvous, in: bundle))
                            .textRole(.bodyEmph)
                            .foregroundStyle(HUDTheme.primaryText)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(MeetPresentation.placeLine(option.rendezvous, in: bundle))
                            .textRole(.label)
                            .foregroundStyle(HUDTheme.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }

                whyRow(MeetPresentation.WhyLine(
                    icon: "person.2.fill", text: MeetPresentation.balance(option, partnerName: partnerName),
                    detail: MeetPresentation.arrivalDetail(option), tone: .neutral))

                // A caution is never folded away.
                ForEach(why.filter { $0.tone == .caution }, id: \.self) { whyRow($0) }
                // Under hours only a route never uses a known closure, but
                // status is unknown, and every card says so.
                if degraded {
                    whyRow(MeetPresentation.WhyLine(
                        icon: "exclamationmark.triangle.fill",
                        text: Wording.reason(.statusUnknown, partnerName: partnerName),
                        detail: nil, tone: .caution))
                }
                whySection(why.filter { $0.tone != .caution }, lap: lap)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            // What is inside sits on this box's glass.
            .environment(\.isOnGlass, true)
            .hudCard(cornerRadius: boxRadius)

            MeetRouteSection(
                label: "Your route", route: option.routes.0, color: HUDTheme.routeSkierA, bundle: bundle,
                isOpen: openRow == .mine) { toggle(.mine) }
            MeetRouteSection(
                label: "\(partnerName)'s route", route: option.routes.1, color: HUDTheme.routeSkierB, bundle: bundle,
                isOpen: openRow == .theirs) { toggle(.theirs) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(headline). Meet at \(meetingName). Together in \(MeetPresentation.together(option)).")
    }

    /// The reasons that are not cautions, said outright, then the lap.
    @ViewBuilder
    private func whySection(_ reasons: [MeetPresentation.WhyLine], lap: MeetPresentation.LapSummary?) -> some View {
        ForEach(reasons, id: \.self) { whyRow($0) }
        if let lap { MeetLapBox(summary: lap) }
    }

    private func whyRow(_ line: MeetPresentation.WhyLine) -> some View {
        let color: Color = switch line.tone {
        case .good: HUDTheme.accentGreen
        case .neutral: HUDTheme.primaryText
        case .caution: HUDTheme.accentAmber
        }
        return HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: line.icon)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(color)
                .frame(width: Self.iconColumn)
            VStack(alignment: .leading, spacing: 2) {
                Text(line.text)
                    .textRole(.label)
                    .foregroundStyle(color)
                    .fixedSize(horizontal: false, vertical: true)
                if let detail = line.detail {
                    Text(detail)
                        .textRole(.caption)
                        .foregroundStyle(HUDTheme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}

/// The optional lap for the skier who would otherwise stand waiting: which lift
/// and run, how long, and how much time is left over. On an option card it is
/// information; the meet under way adds a control under it.
struct MeetLapBox<Footer: View>: View {
    let summary: MeetPresentation.LapSummary
    @ViewBuilder var footer: Footer

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(summary.title, systemImage: "arrow.triangle.2.circlepath")
                .textRole(.label)
                .fontWeight(.semibold)
                .foregroundStyle(HUDTheme.accentCyan)
            Text(summary.path)
                .textRole(.label)
                .foregroundStyle(HUDTheme.primaryText)
                .fixedSize(horizontal: false, vertical: true)
            Text(summary.detail)
                .textRole(.caption)
                .foregroundStyle(HUDTheme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            footer
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .hudCard()
        .accessibilityElement(children: .contain)
    }
}

extension MeetLapBox where Footer == EmptyView {
    init(summary: MeetPresentation.LapSummary) {
        self.init(summary: summary) { EmptyView() }
    }
}
