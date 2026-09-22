import Foundation

/// One timing presentation for the visual card and its spoken route summary.
nonisolated struct MeetingRouteTimePresentation {
    let displayText: String
    let accessibilityText: String
    let rangeUnavailable: Bool

    init(time: Double, standardDeviation: Double?, showRange: Bool) {
        guard let spokenMean = Self.spokenDuration(time) else {
            displayText = "ETA UNAVAILABLE"
            accessibilityText = "Travel time unavailable."
            rangeUnavailable = false
            return
        }
        if showRange, let range = Self.modeledRange(time: time, standardDeviation: standardDeviation) {
            let low = range.lowerBound
            let high = range.upperBound
            if let spokenLow = Self.spokenDuration(low), let spokenHigh = Self.spokenDuration(high) {
                displayText = low == high ? UnitFormatter.formatTime(low)
                    : "\(UnitFormatter.formatTime(low))–\(UnitFormatter.formatTime(high))"
                accessibilityText = low == high ? "Estimated travel time \(spokenLow)."
                    : "Estimated travel time \(spokenLow) to \(spokenHigh)."
                rangeUnavailable = false
                return
            }
        }
        displayText = UnitFormatter.formatTime(time)
        rangeUnavailable = showRange
        accessibilityText = "Estimated travel time \(spokenMean)."
            + (showRange ? " Timing range unavailable." : "")
    }

    /// Spell units for speech instead of relying on interpretation of m/s
    /// abbreviations. Safe conversion also rejects malformed/nonfinite times.
    static func spokenDuration(_ seconds: Double) -> String? {
        guard seconds.isFinite, seconds >= 0,
              let whole = Int(exactly: seconds.rounded(.down)) else { return nil }
        let hours = whole / 3600
        let minutes = (whole % 3600) / 60
        let remainder = whole % 60
        var parts: [String] = []
        if hours > 0 { parts.append("\(hours) \(hours == 1 ? "hour" : "hours")") }
        if minutes > 0 { parts.append("\(minutes) \(minutes == 1 ? "minute" : "minutes")") }
        if remainder > 0 || parts.isEmpty {
            parts.append("\(remainder) \(remainder == 1 ? "second" : "seconds")")
        }
        return parts.joined(separator: " ")
    }

    static func usableUncertainty(_ value: Double?) -> Double? {
        value.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
    }

    /// These are modeled per-route ranges, not calibrated joint arrival
    /// probabilities. The same bounds inform both route text and overlap.
    static func modeledRange(time: Double, standardDeviation: Double?) -> ClosedRange<Double>? {
        guard spokenDuration(time) != nil,
              let deviation = usableUncertainty(standardDeviation) else { return nil }
        let low = max(0, time - 1.28 * deviation)
        let high = time + 1.28 * deviation
        guard spokenDuration(low) != nil, spokenDuration(high) != nil else { return nil }
        return low...high
    }

    static func shouldShowRanges(stdA: Double?, stdB: Double?) -> Bool {
        // Unknown on either route must not silently become an exact ETA.
        guard let a = usableUncertainty(stdA), let b = usableUncertainty(stdB) else { return true }
        return max(a, b) >= 30
    }
}

/// Explain the cost of waiting without asserting that the mean arrival order
/// is certain. No independence assumption or combined probability is invented.
nonisolated struct MeetingArrivalPresentation {
    enum OrderEvidence: Equatable { case overlapping, separated, unavailable }

    let togetherText: String
    let togetherAccessibilityText: String
    let comparisonText: String
    let comparisonAccessibilityText: String
    let detailText: String
    let detailAccessibilityText: String
    let orderEvidence: OrderEvidence

    init(timeA: Double, timeB: Double, stdA: Double?, stdB: Double?) {
        guard MeetingRouteTimePresentation.spokenDuration(timeA) != nil,
              MeetingRouteTimePresentation.spokenDuration(timeB) != nil,
              let together = MeetingRouteTimePresentation.spokenDuration(max(timeA, timeB)) else {
            togetherText = "ETA UNAVAILABLE"
            togetherAccessibilityText = "Arrival estimate unavailable."
            comparisonText = "WAIT ESTIMATE UNAVAILABLE"
            comparisonAccessibilityText = "Waiting time unavailable."
            detailText = "RECALCULATE BOTH ROUTES"
            detailAccessibilityText = "Recalculate both routes."
            orderEvidence = .unavailable
            return
        }
        togetherText = UnitFormatter.formatTime(max(timeA, timeB))
        togetherAccessibilityText = "Estimated time until you are together: \(together)."

        let difference = abs(timeA - timeB)
        if difference <= 30 {
            comparisonText = "SIMILAR ESTIMATED ARRIVALS"
            comparisonAccessibilityText = "The current arrival estimates are within 30 seconds of each other."
        } else {
            let minutes = difference >= 60
            let amount = (minutes ? difference / 60 : difference).rounded()
            let count = String(format: "%.0f", amount)
            let unit = minutes ? (amount == 1 ? "minute" : "minutes") : (amount == 1 ? "second" : "seconds")
            let person = timeA < timeB ? "YOU" : "FRIEND"
            comparisonText = "EXPECTED WAIT · \(person) ~\(count)\(minutes ? "m" : "s")"
            comparisonAccessibilityText = "Based on the current estimates, \(timeA < timeB ? "you" : "your friend") would wait about \(count) \(unit)."
        }

        guard let rangeA = MeetingRouteTimePresentation.modeledRange(time: timeA, standardDeviation: stdA),
              let rangeB = MeetingRouteTimePresentation.modeledRange(time: timeB, standardDeviation: stdB) else {
            orderEvidence = .unavailable
            detailText = "ARRIVAL ORDER UNCERTAIN · TIMING RANGE UNAVAILABLE"
            detailAccessibilityText = "Arrival order is uncertain because a timing range is unavailable."
            return
        }
        if rangeA.overlaps(rangeB) {
            orderEvidence = .overlapping
            detailText = "ARRIVAL RANGES OVERLAP · EITHER SKIER MAY WAIT"
            detailAccessibilityText = "The modeled arrival ranges overlap. Either skier may arrive first and wait."
        } else {
            orderEvidence = .separated
            detailText = "WAIT MAY CHANGE WITH PACE, LIFTS & CONDITIONS"
            detailAccessibilityText = "The modeled arrival ranges do not overlap, but the wait may change with pace, lifts and conditions."
        }
    }
}
