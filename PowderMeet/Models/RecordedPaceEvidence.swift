import Foundation

/// A geometric route match is not itself a timed pace measurement.
/// Both file imports and live recording must use this boundary before saving.
nonisolated struct RecordedPaceEvidence {
    static let routeOnlyMethod = "polyline_sequence_no_pace"
    let confidence: Double
    let method: String

    init(confidence: Double, observations: [EdgePaceObservation]) {
        if observations.isEmpty {
            // Existing server recomputes can substitute whole-run averages
            // for empty single-edge observations. Zero is the compatible
            // learning exclusion flag, NOT the geometric match confidence.
            // Keep dataset/edge/segment identity and activity stats unchanged.
            self.confidence = 0
            method = Self.routeOnlyMethod
        } else {
            self.confidence = confidence
            method = "polyline_sequence"
        }
    }

    /// Schemas older than match_confidence cannot express route-only evidence.
    /// Keep the name/statistics there, but withhold the learning edge key.
    static func legacyEdgeID(_ edgeID: String?, method: String) -> String? {
        method == routeOnlyMethod ? nil : edgeID
    }
}
