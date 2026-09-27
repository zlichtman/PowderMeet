//
//  ActivityCalibration.swift
//  PowderMeet
//
//  Pure, testable calibration derived from trustworthy imported observations.
//

import Foundation

nonisolated enum ActivityCalibration {
    /// Blends observed pace into a terrain preference without ever escalating
    /// a user-declared hard limit. Zero is the persisted representation of
    /// AVOID in the profile editor; an activity proves what happened once, not
    /// that the skier wants future routes to use that terrain.
    static func mergedTerrainPreference(
        existing: Double,
        inferred: Double,
        observationWeight: Double = 0.6
    ) -> Double? {
        guard existing > 0 else { return nil }
        let weight = max(0, min(1, observationWeight))
        return existing * (1 - weight) + inferred * weight
    }

    static func medianSpeeds(
        from runs: [MatchedRun]
    ) -> [RunDifficulty: Double] {
        var grouped: [RunDifficulty: [Double]] = [:]
        for run in runs {
            guard let speed = run.profileCalibrationSpeed,
                  let difficulty = run.difficulty else {
                continue
            }
            grouped[difficulty, default: []].append(speed)
        }
        return grouped.mapValues(median)
    }

    /// Learns terrain preferences only from like-for-like difficulty cohorts.
    /// Pooling all runs together confounds terrain with difficulty (for example,
    /// black mogul speeds compared with blue groomer speeds).
    static func inferConditionPreferences(
        from runs: [MatchedRun]
    ) -> ConditionInference {
        let eligible = runs.filter(\.isProfileCalibrationEligible)
        return ConditionInference(
            mogulRatio: stratifiedRatio(eligible) {
                $0.hasMoguls
            },
            ungroomedRatio: stratifiedRatio(eligible) {
                guard let groomed = $0.isGroomed else { return nil }
                return !groomed
            },
            gladedRatio: stratifiedRatio(eligible) {
                $0.isGladed
            },
            narrowRatio: stratifiedRatio(eligible) {
                guard let width = $0.widthMeters else { return nil }
                if width < 12 { return true }
                if width >= 20 { return false }
                return nil
            },
            exposureRatio: stratifiedRatio(eligible) {
                guard let exposure = $0.fallLineExposure else { return nil }
                if exposure > 0.7 { return true }
                if exposure < 0.3 { return false }
                return nil
            }
        )
    }

    private static func stratifiedRatio(
        _ runs: [MatchedRun],
        classifiedAsCondition: (MatchedRun) -> Bool?
    ) -> Double? {
        var condition: [RunDifficulty: [Double]] = [:]
        var control: [RunDifficulty: [Double]] = [:]
        for run in runs {
            guard let difficulty = run.difficulty,
                  let speed = run.profileCalibrationSpeed,
                  let isCondition = classifiedAsCondition(run) else {
                continue
            }
            if isCondition {
                condition[difficulty, default: []].append(speed)
            } else {
                control[difficulty, default: []].append(speed)
            }
        }

        let ratios: [Double] = RunDifficulty.allCases.compactMap { difficulty in
            guard let conditionSpeeds = condition[difficulty],
                  let controlSpeeds = control[difficulty],
                  conditionSpeeds.count >= 3,
                  controlSpeeds.count >= 3 else {
                return nil
            }
            let denominator = median(controlSpeeds)
            guard denominator > 0 else { return nil }
            return median(conditionSpeeds) / denominator
        }
        guard !ratios.isEmpty else { return nil }
        return max(0.1, min(2.0, median(ratios)))
    }

    static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let midpoint = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (sorted[midpoint - 1] + sorted[midpoint]) / 2
        }
        return sorted[midpoint]
    }
}
