//
//  TimelineView.swift
//  PowderMeet
//

import SwiftUI

struct TimelineView: View {
    @Binding var selectedDate: Date
    /// When an active meetup sets this, the scrubber extends forward to
    /// `meetStart + max(timeA, timeB) + 5 min` so users can scrub past the
    /// current instant and see where each skier will be on-route at a
    /// future moment.
    var futureRangeMax: Date? = nil

    /// Live weather (current + hourly forecast + hourly history). When
    /// supplied, the scrubber renders a conditions HUD above the track and
    /// colors tick marks by weather code at that hour. Optional so legacy
    /// call sites still compile.
    var conditions: ResortConditions? = nil

    /// Fires `true` while the user is actively dragging the thumb,
    /// `false` on release. ContentView forwards this to `MountainMapView`
    /// so expensive per-minute GeoJSON rebuilds can coarsen during scrub.
    var onDraggingChanged: ((Bool) -> Void)? = nil

    @State private var isDragging = false
    @State private var referenceNow = Date()
    @Environment(\.scenePhase) private var scenePhase

    /// `Calendar.current` is rebuilt every getter call; cache once so we don't
    /// allocate a Calendar+TimeZone on every body re-evaluation during drag.
    private static let calendar: Calendar = {
        var cal = Calendar.current
        cal.timeZone = .current
        return cal
    }()
    private var calendar: Calendar { Self.calendar }

    // True wall-clock symmetry: last 12h / next 12h, unless an active meetup
    // extends the upper bound.
    private var rangeStart: Date {
        calendar.date(byAdding: .hour, value: -12, to: referenceNow) ?? referenceNow
    }

    private var rangeEnd: Date {
        let defaultEnd = calendar.date(byAdding: .hour, value: 12, to: referenceNow) ?? referenceNow
        guard let futureMax = futureRangeMax else { return defaultEnd }
        return max(defaultEnd, futureMax)
    }

    private var isScrubbingFuture: Bool {
        selectedDate > referenceNow
    }

    /// Best-matching hourly sample at the scrubbed instant, or nil if
    /// `conditions` is unavailable / has no hourly coverage for that time.
    private var hourlyAtSelected: HourlyCondition? {
        conditions?.atTime(selectedDate)
    }

    var body: some View {
        VStack(spacing: 0) {
            conditionsReadout
                .padding(.horizontal, 20)
                .padding(.bottom, 6)

            GeometryReader { geo in
                let w = geo.size.width

                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(HUDTheme.inputBackground)
                        .frame(height: 10)
                        .frame(maxHeight: .infinity, alignment: .center)

                    RoundedRectangle(cornerRadius: 4)
                        .stroke(HUDTheme.cardBorder, lineWidth: 1)
                        .frame(height: 10)
                        .frame(maxHeight: .infinity, alignment: .center)

                    // Weather-tinted ticks: snow = cyan, storm = red, else gray.
                    ForEach(tickDates, id: \.self) { tick in
                        let tx = xForDate(tick, width: w)
                        let tint = tickTint(at: tick)
                        Rectangle()
                            .fill(tint.color)
                            .frame(width: tint.width, height: tint.height)
                            .frame(maxHeight: .infinity, alignment: .center)
                            .offset(x: tx)
                    }

                    // current time marker
                    let nowX = xForDate(referenceNow, width: w)
                    Rectangle()
                        .fill(HUDTheme.primaryText.opacity(0.5))
                        .frame(width: 1.5, height: 16)
                        .frame(maxHeight: .infinity, alignment: .center)
                        .offset(x: nowX - 0.75)

                    let thumbX = xForDate(selectedDate, width: w)
                    Circle()
                        .fill(isScrubbingFuture ? HUDTheme.accentAmber : HUDTheme.accent)
                        .frame(width: 16, height: 16)
                        .overlay(
                            Circle()
                                .stroke((isScrubbingFuture ? HUDTheme.accentAmber : HUDTheme.accent).opacity(0.4), lineWidth: 1)
                        )
                        .shadow(
                            color: (isScrubbingFuture ? HUDTheme.accentAmber : HUDTheme.accent).opacity(isDragging ? 0.5 : 0.2),
                            radius: isDragging ? 6 : 2
                        )
                        .frame(maxHeight: .infinity, alignment: .center)
                        .offset(x: thumbX - 8)
                        .animation(.interactiveSpring(response: 0.15), value: thumbX)
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            if !isDragging {
                                isDragging = true
                                onDraggingChanged?(true)
                            }
                            let t = Double(max(0, min(w, value.location.x))) / Double(w)
                            let secs = rangeStart.timeIntervalSince1970
                                + t * (rangeEnd.timeIntervalSince1970 - rangeStart.timeIntervalSince1970)
                            selectedDate = Date(timeIntervalSince1970: secs)
                        }
                        .onEnded { _ in
                            isDragging = false
                            onDraggingChanged?(false)
                        }
                )
            }
            .frame(height: 24)
            .padding(.horizontal, 20)

            HStack {
                Text(shortDate(rangeStart))
                    .font(.system(size: 8, weight: .medium, design: .monospaced))
                    .foregroundColor(HUDTheme.secondaryText.opacity(0.5))
                    .tracking(0.5)

                Spacer()

                Button {
                    withAnimation(.interactiveSpring(response: 0.22, dampingFraction: 0.86)) {
                        selectedDate = referenceNow
                    }
                } label: {
                    Text(fullTime(selectedDate))
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundColor(HUDTheme.accent)
                        .tracking(1)
                }
                .buttonStyle(.plain)

                Spacer()

                Text(shortDate(rangeEnd))
                    .font(.system(size: 8, weight: .medium, design: .monospaced))
                    .foregroundColor(HUDTheme.secondaryText.opacity(0.5))
                    .tracking(0.5)
            }
            .padding(.horizontal, 20)
            .padding(.top, 4)
        }
        .padding(.vertical, 8)
        .overlay(
            Rectangle()
                .fill(HUDTheme.cardBorder)
                .frame(height: 0.5),
            alignment: .bottom
        )
        .onAppear {
            referenceNow = Date()
        }
        // Keep `referenceNow` current after long-lived sessions — otherwise
        // a user who left the app running overnight would see a 24h window
        // centered on yesterday's open time.
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                referenceNow = Date()
            }
        }
    }

    // MARK: - Conditions Readout

    /// One-line HUD above the scrubber showing weather at the scrubbed
    /// time. Displayed whenever hourly data is available — otherwise a
    /// low-key "no forecast" placeholder so the row height stays stable.
    @ViewBuilder
    private var conditionsReadout: some View {
        HStack(spacing: 10) {
            if let h = hourlyAtSelected {
                HStack(spacing: 4) {
                    Image(systemName: h.sfSymbol)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(iconTint(for: h))
                        .frame(width: 14)
                    Text(UnitFormatter.temperature(h.temperatureC))
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundColor(HUDTheme.primaryText)
                }

                if h.snowfallCm > 0.05 {
                    labelBadge(
                        icon: "snowflake",
                        text: "\(formatTenths(h.snowfallCm))cm/hr",
                        tint: HUDTheme.accentCyan
                    )
                }

                labelBadge(
                    icon: windIcon(for: h.windSpeedKph),
                    text: UnitFormatter.windSpeed(h.windSpeedKph),
                    tint: h.windSpeedKph > 40 ? HUDTheme.accentAmber : HUDTheme.secondaryText
                )

                labelBadge(
                    icon: "cloud.fill",
                    text: "\(h.cloudCoverPercent)%",
                    tint: HUDTheme.secondaryText
                )

                if h.visibilityKm < 2 {
                    labelBadge(
                        icon: "eye.slash.fill",
                        text: formatVisibility(h.visibilityKm),
                        tint: HUDTheme.accentAmber
                    )
                }

                Spacer(minLength: 0)
            } else {
                Text(conditions == nil ? "LIVE WEATHER LOADING…" : "NO FORECAST AT THIS HOUR")
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundColor(HUDTheme.secondaryText.opacity(0.6))
                    .tracking(1)
                Spacer(minLength: 0)
            }
        }
        .frame(height: 16)
    }

    private func labelBadge(icon: String, text: String, tint: Color) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon)
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(tint)
            Text(text)
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundColor(HUDTheme.primaryText.opacity(0.88))
        }
    }

    private func iconTint(for h: HourlyCondition) -> Color {
        if h.isStormy { return HUDTheme.accentRed }
        if h.isSnowy  { return HUDTheme.accentCyan }
        switch h.weatherCode {
        case 0:       return HUDTheme.accentAmber
        case 1, 2:    return HUDTheme.accentAmber.opacity(0.7)
        default:      return HUDTheme.secondaryText
        }
    }

    private func windIcon(for kph: Double) -> String {
        // Three tiers so users get a visual cue on lift-closing wind without
        // reading the number. Previously all three branches returned "wind"
        // which made the function dead.
        if kph > 45 { return "wind.snow" }      // gale / likely lift holds
        if kph > 20 { return "wind" }           // moderate
        return "wind.circle"                    // calm / light
    }

    private func formatTenths(_ v: Double) -> String {
        String(format: "%.1f", v)
    }

    private func formatVisibility(_ km: Double) -> String {
        if km < 1 { return String(format: "%.1fkm", km) }
        return String(format: "%.0fkm", km)
    }

    // MARK: - Ticks

    private var tickDates: [Date] {
        let cal = calendar
        var tick = cal.nextDate(
            after: rangeStart,
            matching: DateComponents(minute: 0),
            matchingPolicy: .nextTime
        ) ?? rangeStart

        var ticks: [Date] = []
        while tick <= rangeEnd {
            ticks.append(tick)
            tick = cal.date(byAdding: .hour, value: 1, to: tick) ?? tick.addingTimeInterval(3600)
        }
        return ticks
    }

    private func tickTint(at date: Date) -> (color: Color, width: CGFloat, height: CGFloat) {
        guard let c = conditions, let h = c.atTime(date) else {
            return (HUDTheme.secondaryText.opacity(0.3), 0.5, 6)
        }
        if h.isStormy {
            return (HUDTheme.accentRed.opacity(0.9), 1.2, 9)
        }
        if h.isSnowy {
            return (HUDTheme.accentCyan.opacity(0.85), 1.0, 9)
        }
        if h.cloudCoverPercent > 70 {
            return (HUDTheme.secondaryText.opacity(0.55), 0.8, 7)
        }
        return (HUDTheme.accentAmber.opacity(0.55), 0.8, 7)
    }

    private func xForDate(_ date: Date, width: CGFloat) -> CGFloat {
        let total = rangeEnd.timeIntervalSince(rangeStart)
        let elapsed = date.timeIntervalSince(rangeStart)
        let t = max(0, min(1, elapsed / total))
        return CGFloat(t) * width
    }

    private func fullTime(_ date: Date) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "h:mm a"
        return fmt.string(from: date).uppercased()
    }

    private func shortDate(_ date: Date) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "MMM d, h:mm a"
        return fmt.string(from: date).uppercased()
    }
}

#Preview {
    @Previewable @State var date: Date = .now
    return VStack {
        TimelineView(selectedDate: $date)
            .background(HUDTheme.headerBackground)
    }
    .background(HUDTheme.mapBackground)
    .preferredColorScheme(.dark)
}
