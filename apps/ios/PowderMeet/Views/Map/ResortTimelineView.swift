import AppCore
import MapScene
import MountainCore
import SwiftUI

/// The resort timeline (not `TimelineView`: SwiftUI has one): a 24-hour weather scrubber,
/// last 12 h to next 12 h, always on screen above the bottom row. Scrubbing
/// moves `resort.selectedTime`, which changes the forecast shown (here and in
/// the bar's quick weather) and the sun on the map. Scrubbed back, friends'
/// markers replay where they were with their trails; scrubbed forward in a
/// meet, both skiers' ghosts move along their routes (`ResortModel`). Never
/// status. During an active meet the window reaches past the arrival and
/// marks it.
struct ResortTimelineView: View {
    @Bindable var resort: ResortModel
    /// The active meet's expected arrival (`ResortModel.meetArrival`).
    var arrival: Date?
    /// Folded to the hour and the scrubber while a meet is under way
    /// (`MapChrome.isWeatherCollapsed`): the map gets the room, and the
    /// sky and temperature stay in the resort bar (and on a run's card).
    var isCollapsed = false

    @State private var isDragging = false
    /// The window's centre. Purely visual; re-read when the app comes back.
    @State private var referenceNow = Date()
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The sky symbol and the temperature, the card's main visual, grow with
    /// Dynamic Type like the rest of the card.
    @ScaledMetric(relativeTo: .largeTitle) private var skySize: CGFloat = 30
    @ScaledMetric(relativeTo: .largeTitle) private var temperatureSize: CGFloat = 32

    private var conditions: Conditions? { resort.conditions }

    /// Mountain-local time (I-06), not the phone's zone.
    private var timeZone: TimeZone { resort.bundle?.timeZone ?? .current }

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }

    private var window: ClosedRange<Date> { TimelineWindow.range(now: referenceNow, arrival: arrival) }
    private var rangeStart: Date { window.lowerBound }
    private var rangeEnd: Date { window.upperBound }

    private var mode: TimelineMode { resort.timelineMode }


    private var selectedTimeContext: String {
        switch mode {
        case .future: "Forecast"
        case .past: "Past"
        case .live: "Live"
        }
    }

    /// The marker is the theme's accent at any hour.
    private var thumbColor: Color { HUDTheme.accent }

    var body: some View {
        VStack(spacing: 8) {
            if isCollapsed {
                HStack(spacing: 8) {
                    timeButton
                    Spacer(minLength: 8)
                    if let conditions {
                        Text(MapWeather.description(conditions.sample(at: resort.displayTime).weatherCode))
                            .textRole(.label)
                            .foregroundStyle(HUDTheme.secondaryText)
                            .lineLimit(1)
                            .contentTransition(.opacity)
                    }
                }
            } else if let conditions {
                let sample = conditions.sample(at: resort.displayTime)
                HStack(alignment: .center, spacing: 10) {
                    sky(sample)
                    Spacer(minLength: 8)
                    timeButton
                }
                figures(sample)
            } else {
                HStack {
                    timeButton
                    Spacer(minLength: 0)
                    // `Conditions.sample(at:)` always answers once there is a
                    // forecast, so this shows only before the first one.
                    Text("Live weather loading…")
                        .textRole(.label)
                        .foregroundColor(HUDTheme.secondaryText)
                        .lineLimit(1)
                }
            }
            VStack(spacing: 2) {
                track
                hourLabels
            }
        }
        .padding(.horizontal, GlassLayout.cardPadding)
        .padding(.vertical, 10)
        .glassEffect(
            HUDGlass.surface,
            in: RoundedRectangle(cornerRadius: GlassLayout.cardRadius, style: .continuous))
        .onAppear {
            referenceNow = Date()
        }
        // Keeps the window centred on today after the app sat in the background.
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                referenceNow = Date()
            }
        }
        // And while it stays open: a map left up from morning to afternoon
        // would otherwise keep "Now" where the morning left it. Never under
        // a scrub, whose hours must not move under the finger.
        .task {
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(60)) } catch { return }
                if !isDragging, !resort.isScrubbed { referenceNow = Date() }
            }
        }
        .onChange(of: resort.isScrubbed) { _, scrubbed in
            if !scrubbed { referenceNow = Date() }
        }
    }

    /// The scrubbed hour; tapping it returns to now.
    private var timeButton: some View {
        Button {
            withAnimation(reduceMotion ? MapChrome.reducedFade : .interactiveSpring(response: 0.22, dampingFraction: 0.86)) {
                resort.returnToLive()
            }
        } label: {
            // "Live · Nov 22 · 1:54 PM" on one line, always; Live keeps the clock's minute.
            TimelineView(.everyMinute) { _ in
                HStack(spacing: 4) {
                    Text(selectedTimeContext)
                        .foregroundColor(
                            selectedTimeContext == "Live" ? HUDTheme.accentGreen : HUDTheme.accentAmber)
                    Text("·").foregroundColor(HUDTheme.secondaryText)
                    Text(shortDate(resort.displayTime))
                        .foregroundColor(HUDTheme.secondaryText)
                    Text("·").foregroundColor(HUDTheme.secondaryText)
                    Text(fullTime(resort.displayTime))
                        .monospacedDigit()
                        .foregroundColor(HUDTheme.primaryText)
                }
            }
            .textRole(.label)
            .fontWeight(.semibold)
            .lineLimit(1)
            .fixedSize()
            .frame(minHeight: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
            "\(selectedTimeContext.lowercased()) weather on \(shortDate(resort.displayTime)) at \(fullTime(resort.displayTime)); tap to return to now"
        )
    }

    private var track: some View {
        GeometryReader { geo in
            let width = geo.size.width

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(HUDGlass.well)
                    .frame(height: 8)
                    .frame(maxHeight: .infinity, alignment: .center)
                // What is ahead is lit; what is behind stays dim.
                let nowX = xForDate(referenceNow, width: width)
                Capsule()
                    .fill(HUDTheme.accent.opacity(0.22))
                    .frame(width: max(0, width - nowX), height: 8)
                    .frame(maxHeight: .infinity, alignment: .center)
                    .offset(x: nowX)

                // Weather-tinted hour ticks: snow cyan, storm red, else grey.
                ForEach(tickDates, id: \.self) { tick in
                    let tint = tickTint(at: tick)
                    Rectangle()
                        .fill(tint.color.opacity(tick < referenceNow ? 0.45 : 1))
                        .frame(width: tint.width, height: tint.height)
                        .frame(maxHeight: .infinity, alignment: .center)
                        .offset(x: xForDate(tick, width: width))
                }

                Rectangle()
                    .fill(HUDTheme.primaryText.opacity(0.5))
                    .frame(width: 1.5, height: 14)
                    .frame(maxHeight: .infinity, alignment: .center)
                    .offset(x: xForDate(referenceNow, width: width) - 0.75)

                // The meet's arrival, in the meeting colour.
                if let arrival {
                    Capsule()
                        .fill(HUDTheme.routeMeeting)
                        .frame(width: 3, height: 16)
                        .frame(maxHeight: .infinity, alignment: .center)
                        .offset(x: xForDate(arrival, width: width) - 1.5)
                        .accessibilityHidden(true)
                }

                let thumbX = xForDate(resort.displayTime, width: width)
                Circle()
                    .fill(thumbColor)
                    .frame(width: 16, height: 16)
                    .overlay(Circle().stroke(thumbColor.opacity(0.4), lineWidth: 1))
                    .shadow(color: thumbColor.opacity(isDragging ? 0.5 : 0.2), radius: isDragging ? 6 : 2)
                    .frame(maxHeight: .infinity, alignment: .center)
                    .offset(x: thumbX - 8)
                    .animation(reduceMotion ? nil : .interactiveSpring(response: 0.15), value: thumbX)
            }
            // The track is drawn 22 pt tall; a glove gets 44 pt to grab it.
            .contentShape(Rectangle().inset(by: -11))
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        isDragging = true
                        guard width > 0 else { return }
                        let fraction = Double(max(0, min(width, value.location.x)) / width)
                        resort.scrub(to: rangeStart.addingTimeInterval(
                            fraction * rangeEnd.timeIntervalSince(rangeStart)
                        ))
                    }
                    .onEnded { _ in
                        isDragging = false
                    }
            )
        }
        .frame(height: 22)
        .accessibilityElement()
        .accessibilityLabel(arrival.map { "Weather timeline. Meet arrival \(fullTime($0))" } ?? "Weather timeline")
        .accessibilityValue(fullTime(resort.displayTime))
        .accessibilityAction(named: "Later weather") {
            resort.scrub(to: min(rangeEnd, resort.displayTime.addingTimeInterval(3_600)))
        }
        .accessibilityAction(named: "Earlier weather") {
            resort.scrub(to: max(rangeStart, resort.displayTime.addingTimeInterval(-3_600)))
        }
        .accessibilityAdjustableAction { direction in
            let step: TimeInterval = direction == .increment ? 3_600 : -3_600
            let next = resort.displayTime.addingTimeInterval(step)
            resort.scrub(to: min(rangeEnd, max(rangeStart, next)))
        }
    }

    /// A few hours named under the scrubber: three hours apart from now,
    /// "Now" in the middle.
    private var hourLabels: some View {
        GeometryReader { geo in
            let width = geo.size.width
            ZStack(alignment: .leading) {
                ForEach(labelOffsets, id: \.self) { hours in
                    let x = xForDate(referenceNow.addingTimeInterval(Double(hours) * 3_600), width: width)
                    Text(hours == 0 ? "Now" : hours > 0 ? "+\(hours)h" : "\(hours)h")
                        .font(.caption2.weight(hours == 0 ? .semibold : .regular))
                        .monospacedDigit()
                        .foregroundStyle(hours == 0 ? HUDTheme.primaryText : HUDTheme.secondaryText)
                        .fixedSize()
                        .frame(width: 40)
                        .offset(x: min(max(x - 20, -6), width - 34))
                }
            }
        }
        .frame(height: 13)
        .accessibilityHidden(true)
        // The labels sit inside the track's 44 pt grab area; touches pass
        // through them to the scrubber.
        .allowsHitTesting(false)
    }

    private var labelOffsets: [Int] {
        let span = rangeEnd.timeIntervalSince(referenceNow) / 3_600
        return [-9, -6, -3, 0, 3, 6, 9, 12].filter { hours in
            Double(hours) <= span - 0.5 && Double(hours) >= -TimelineWindow.halfSpanS / 3_600 + 0.5
        }
    }

    // MARK: Conditions readout

    /// The weather at the scrubbed hour as the screen's main visual: the sky as a large symbol beside the temperature, large, on
    /// one line whatever the width, and what it is doing.
    private func sky(_ sample: ConditionsSample) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: MapWeather.symbol(sample.weatherCode))
                .font(.system(size: skySize, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(Self.iconTint(for: sample))
                .contentTransition(reduceMotion ? ContentTransition.identity : ContentTransition.symbolEffect(.replace))
                .frame(width: skySize + 8)
            VStack(alignment: .leading, spacing: 0) {
                Text(UnitFormatter.temperature(sample.tempC))
                    .font(.system(size: temperatureSize, weight: .bold))
                    .monospacedDigit()
                    .foregroundStyle(HUDTheme.primaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Text(MapWeather.description(sample.weatherCode))
                    .textRole(.caption)
                    .foregroundStyle(HUDTheme.secondaryText)
                    .lineLimit(1)
            }
            .layoutPriority(1)
        }
        .accessibilityElement(children: .combine)
    }

    /// New snow, how hard it is falling, wind and visibility at the hour, in
    /// four even columns with a hairline between them: the mark, the value,
    /// its word (owner, 22 Nov: no tinted strip and no boxes).
    private func figures(_ sample: ConditionsSample) -> some View {
        let windKPH = MapWeather.kph(sample.windMS)
        let poorSight = sample.visibilityM < 2_000
        let rate = MapWeather.isSnowy(sample) ? MapWeather.snowfallRate(sample) : nil
        let newSnow = UnitFormatter.snowfall(sample.snow24hCM)
        // Colour only where there is something to notice: new or falling
        // snow, a strong wind, poor sight. A quiet hour is all grey.
        return HStack(spacing: 0) {
            figure(icon: "snowflake", value: newSnow ?? "0", label: "New",
                   tint: newSnow == nil ? HUDTheme.secondaryText : HUDTheme.accentCyan)
            figureDivider
            figure(icon: "cloud.snow", value: rate ?? "None", label: "Falling",
                   tint: rate == nil ? HUDTheme.secondaryText : HUDTheme.accentCyan)
            figureDivider
            figure(icon: windIcon(forKPH: windKPH), value: UnitFormatter.windSpeed(windKPH), label: "Wind",
                   tint: windKPH > 40 ? HUDTheme.accentAmber : HUDTheme.secondaryText)
            figureDivider
            figure(icon: poorSight ? "eye.slash.fill" : "eye", value: UnitFormatter.visibility(sample.visibilityM),
                   label: "Vis", tint: poorSight ? HUDTheme.accentAmber : HUDTheme.secondaryText)
        }
    }

    /// A hairline between two figures: the four read as one row of the card,
    /// not four boxes on it.
    private var figureDivider: some View {
        Rectangle()
            .fill(HUDTheme.secondaryText.opacity(0.22))
            .frame(width: 1, height: 26)
            .accessibilityHidden(true)
    }

    /// Compact: the mark beside the value on one line, the word under it.
    private func figure(icon: String, value: String, label: String, tint: Color) -> some View {
        VStack(spacing: 1) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(tint)
                    .accessibilityHidden(true)
                Text(value)
                    .textRole(.bodyEmph)
                    .monospacedDigit()
                    .foregroundStyle(HUDTheme.primaryText)
            }
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            Text(label)
                .textRole(.caption)
                .foregroundStyle(HUDTheme.secondaryText)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 4)
        .accessibilityElement(children: .combine)
    }

    static func iconTint(for sample: ConditionsSample) -> Color {
        if MapWeather.isStormy(sample) { return HUDTheme.accentRed }
        if MapWeather.isSnowy(sample) { return HUDTheme.accentCyan }
        switch sample.weatherCode {
        case 0: return HUDTheme.accentAmber
        case 1, 2: return HUDTheme.accentAmber.opacity(0.7)
        default: return HUDTheme.secondaryText
        }
    }

    /// Three tiers so lift-closing wind reads without the number.
    private func windIcon(forKPH kph: Double) -> String {
        if kph > 45 { return "wind.snow" }
        return "wind"
    }

    // MARK: Ticks

    private var tickDates: [Date] {
        var tick = self.calendar.nextDate(
            after: rangeStart, matching: DateComponents(minute: 0), matchingPolicy: .nextTime
        ) ?? rangeStart
        var ticks: [Date] = []
        while tick <= rangeEnd {
            ticks.append(tick)
            tick = tick.addingTimeInterval(3_600)
        }
        return ticks
    }

    private func tickTint(at date: Date) -> (color: Color, width: CGFloat, height: CGFloat) {
        // No hourly series means no forecast for that hour.
        guard let conditions, !conditions.hourly.isEmpty else {
            return (color: HUDTheme.secondaryText.opacity(0.3), width: 0.5, height: 6)
        }
        let sample = conditions.sample(at: date)
        if MapWeather.isStormy(sample) {
            return (color: HUDTheme.accentRed.opacity(0.9), width: 1.2, height: 9)
        }
        if MapWeather.isSnowy(sample) {
            return (color: HUDTheme.accentCyan.opacity(0.85), width: 1.0, height: 9)
        }
        if sample.cloudPct > 70 {
            return (color: HUDTheme.secondaryText.opacity(0.55), width: 0.8, height: 7)
        }
        return (color: HUDTheme.accentAmber.opacity(0.55), width: 0.8, height: 7)
    }

    private func xForDate(_ date: Date, width: CGFloat) -> CGFloat {
        let total = rangeEnd.timeIntervalSince(rangeStart)
        let fraction = max(0, min(1, date.timeIntervalSince(rangeStart) / total))
        return CGFloat(fraction) * width
    }

    // MARK: Formatting

    // Cached: the labels re-render many times a second during a drag.
    private static let fullTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        return formatter
    }()

    private static let shortDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("MMMd")
        return formatter
    }()

    /// The day at the resort, since the timeline runs past midnight both ways.
    private func shortDate(_ date: Date) -> String {
        Self.shortDateFormatter.timeZone = timeZone
        #if DEBUG
        let displayedDate = PreviewStage.presentationDate(date, in: timeZone, now: resort.scrubbedSince ?? Date())
        #else
        let displayedDate = date
        #endif
        return Self.shortDateFormatter.string(from: displayedDate)
    }

    private func fullTime(_ date: Date) -> String {
        Self.fullTime(date, in: timeZone, heldSince: resort.scrubbedSince)
    }

    /// `heldSince`: when the timeline left Live (`ResortModel.scrubbedSince`),
    /// which the Debug capture clock reads a scrubbed instant against.
    static func fullTime(_ date: Date, in timeZone: TimeZone, heldSince: Date?) -> String {
        fullTimeFormatter.timeZone = timeZone
        #if DEBUG
        let displayedDate = PreviewStage.presentationDate(date, in: timeZone, now: heldSince ?? Date())
        #else
        let displayedDate = date
        #endif
        return fullTimeFormatter.string(from: displayedDate)
    }
}
