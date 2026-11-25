import Foundation
import MountainCore

/// The one place inputs are coarsened so two phones solving a few seconds apart,
/// or with weather fetched a moment apart, get identical output (invariant I-13).
public enum Quantize {
    public static let timeBucketS = 60.0
    public static let temperatureStepC = 1.0
    public static let windStepMS = 1.0
    public static let visibilityStepM = 500.0
    public static let cloudStepPct = 10.0
    public static let snowStepCM = 1.0
    public static let elevationStepM = 10.0
    public static let windDirectionStepDeg = 10.0

    /// Floors to the 60 s bucket.
    public static func time(_ date: Date) -> Date {
        let t = date.timeIntervalSinceReferenceDate
        return Date(timeIntervalSinceReferenceDate: (t / timeBucketS).rounded(.down) * timeBucketS)
    }

    public static func sample(_ s: ConditionsSample) -> ConditionsSample {
        func step(_ value: Double, _ size: Double) -> Double { (value / size).rounded() * size }
        var q = s
        q.at = Date(timeIntervalSinceReferenceDate: s.at.timeIntervalSinceReferenceDate.rounded())
        q.tempC = step(s.tempC, temperatureStepC)
        q.windMS = max(0, step(s.windMS, windStepMS))
        q.gustMS = max(0, step(s.gustMS, windStepMS))
        q.visibilityM = max(0, step(s.visibilityM, visibilityStepM))
        q.cloudPct = max(0, min(100, step(s.cloudPct, cloudStepPct)))
        q.snow24hCM = max(0, step(s.snow24hCM, snowStepCM))
        q.windDirDeg = s.windDirDeg.map { step($0, windDirectionStepDeg).truncatingRemainder(dividingBy: 360) }
        q.dewPointC = s.dewPointC.map { step($0, temperatureStepC) }
        q.cloudLowPct = s.cloudLowPct.map { max(0, min(100, step($0, cloudStepPct))) }
        q.temp850C = s.temp850C.map { step($0, temperatureStepC) }
        q.temp700C = s.temp700C.map { step($0, temperatureStepC) }
        q.snowDepthCM = s.snowDepthCM.map { max(0, step($0, snowStepCM)) }
        q.snow72hCM = s.snow72hCM.map { max(0, step($0, snowStepCM)) }
        return q
    }

    /// The forecast the cost model reads: samples from two hours before to twelve
    /// hours after the solve, one per instant, anchored at the solve instant by the
    /// fresher current reading.
    public static func conditions(_ conditions: Conditions?, at solveTime: Date) -> Conditions? {
        guard let conditions else { return nil }
        var current = sample(conditions.current)
        current.at = solveTime
        let earliest = solveTime.addingTimeInterval(-2 * 60 * 60)
        let latest = solveTime.addingTimeInterval(12 * 60 * 60)
        var seen = Set<Date>([solveTime])
        var hourly: [ConditionsSample] = []
        for raw in conditions.hourly.sorted(by: { $0.at < $1.at }) {
            let q = sample(raw)
            guard q.at >= earliest, q.at <= latest, seen.insert(q.at).inserted else { continue }
            hourly.append(q)
        }
        if !hourly.isEmpty { hourly.append(current) }
        hourly.sort { $0.at < $1.at }
        var out = conditions
        out.current = current
        out.hourly = hourly
        out.elevationM = conditions.elevationM.map { (($0 / elevationStepM).rounded()) * elevationStepM }
        out.recent = conditions.recent.map {
            RecentConditions(
                at: Date(timeIntervalSinceReferenceDate: $0.at.timeIntervalSinceReferenceDate.rounded()),
                tempC: ($0.tempC / temperatureStepC).rounded() * temperatureStepC,
                cloudPct: $0.cloudPct.map { ($0 / cloudStepPct).rounded() * cloudStepPct }
            )
        }
        return out
    }
}
