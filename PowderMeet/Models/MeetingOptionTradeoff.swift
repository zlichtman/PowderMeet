import Foundation

/// Turns an alternate from an opaque ordinal into the clearest material
/// tradeoff versus the top recommendation. All choices already satisfy hard
/// terrain/closure gates; these labels describe preference, never permission.
nonisolated enum MeetingOptionTradeoff {
    struct Metrics: Equatable, Sendable {
        /// Nil when any run is unrated or includes non-ordinal park features.
        let maxTerrainRank: Int?
        let latestArrivalSeconds: Double
        let waitSpreadSeconds: Double
        /// Nil is unknown, not a perfectly predictable zero-second deviation.
        let uncertaintySeconds: Double?
        let liftBoardings: Int
        let traverseMeters: Double

        init(
            pathA: [GraphEdge],
            pathB: [GraphEdge],
            timeA: Double,
            timeB: Double,
            stdA: Double?,
            stdB: Double?
        ) {
            let runs = (pathA + pathB).filter { $0.kind == .run }
            let ranks = runs.compactMap { edge -> Int? in
                    guard let difficulty = edge.attributes.difficulty else { return nil }
                    switch difficulty {
                    case .green: return 0
                    case .blue: return 1
                    case .black: return 2
                    // Park features are not an ordinal black-run rating.
                    case .terrainPark: return nil
                    case .doubleBlack: return 3
                    }
                }
            maxTerrainRank = ranks.count == runs.count ? (ranks.max() ?? 0) : nil
            latestArrivalSeconds = max(timeA, timeB)
            waitSpreadSeconds = abs(timeA - timeB)
            if let stdA, let stdB, stdA.isFinite, stdB.isFinite, stdA >= 0, stdB >= 0 {
                let combined = hypot(stdA, stdB)
                uncertaintySeconds = combined.isFinite ? combined : nil
            } else {
                uncertaintySeconds = nil
            }
            liftBoardings = (pathA + pathB).filter {
                $0.kind == .lift && $0.attributes.chargesLiftWait != false
            }.count
            traverseMeters = (pathA + pathB)
                .filter { $0.kind == .traverse }
                .reduce(0) { $0 + $1.attributes.lengthMeters }
        }

        init(
            maxTerrainRank: Int?,
            latestArrivalSeconds: Double,
            waitSpreadSeconds: Double,
            uncertaintySeconds: Double?,
            liftBoardings: Int,
            traverseMeters: Double = 0
        ) {
            self.maxTerrainRank = maxTerrainRank.flatMap { (0...3).contains($0) ? $0 : nil }
            self.latestArrivalSeconds = latestArrivalSeconds
            self.waitSpreadSeconds = waitSpreadSeconds
            self.uncertaintySeconds = uncertaintySeconds.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
            self.liftBoardings = liftBoardings
            self.traverseMeters = traverseMeters
        }
    }

    static func label(
        primary: Metrics,
        alternate: Metrics,
        ordinal: Int
    ) -> String {
        if let alternateRank = alternate.maxTerrainRank, let primaryRank = primary.maxTerrainRank,
           alternateRank < primaryRank {
            return "EASIER TERRAIN"
        }
        if alternate.latestArrivalSeconds + 30 < primary.latestArrivalSeconds {
            return "QUICKER ARRIVAL"
        }
        if alternate.traverseMeters + 100 < primary.traverseMeters,
           alternate.traverseMeters <= primary.traverseMeters * 0.75 {
            return "LESS SKATING"
        }
        if alternate.waitSpreadSeconds + 60 < primary.waitSpreadSeconds {
            return "CLOSER ARRIVALS"
        }
        if let alternateUncertainty = alternate.uncertaintySeconds,
           let primaryUncertainty = primary.uncertaintySeconds,
           alternateUncertainty + 30 < primaryUncertainty,
           alternateUncertainty <= primaryUncertainty * 0.85 {
            return "MORE PREDICTABLE"
        }
        if alternate.liftBoardings < primary.liftBoardings {
            return "FEWER LIFTS"
        }
        return "ALTERNATE STOP \(max(2, ordinal))"
    }

    /// Names the strongest user-visible advantage of the solver's first pick.
    /// The solver may also prefer a better verified stopping area, so when no
    /// route metric dominates we deliberately say BEST BALANCE rather than
    /// inventing a single reason that was not decisive.
    static func primaryLabel(
        primary: Metrics,
        alternates: [Metrics]
    ) -> String {
        // Diversity filtering and bounded search can omit other valid stops.
        // No displayed alternate is not proof that no other stop exists.
        guard !alternates.isEmpty else { return "RECOMMENDED STOP" }

        if alternates.allSatisfy({
            $0.latestArrivalSeconds >= primary.latestArrivalSeconds + 30
        }) {
            return "FASTEST TOGETHER"
        }
        if alternates.allSatisfy({
            $0.waitSpreadSeconds >= primary.waitSpreadSeconds + 60
        }) {
            return "BEST SYNC"
        }
        if let primaryUncertainty = primary.uncertaintySeconds,
           alternates.allSatisfy({
               guard let other = $0.uncertaintySeconds else { return false }
               return other >= primaryUncertainty + 30 && primaryUncertainty <= other * 0.85
           }) {
            return "MOST PREDICTABLE"
        }
        if let primaryRank = primary.maxTerrainRank, alternates.allSatisfy({
            guard let other = $0.maxTerrainRank else { return false }
            return other > primaryRank
        }) {
            return "EASIEST TOP PICK"
        }
        if alternates.allSatisfy({
            $0.liftBoardings > primary.liftBoardings
        }) {
            return "FEWEST LIFTS"
        }
        return "BEST BALANCE"
    }
}
