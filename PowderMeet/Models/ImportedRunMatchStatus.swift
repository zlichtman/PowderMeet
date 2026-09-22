import Foundation

/// Presentation of recorded match provenance, not a claim of ground truth
/// and not a replacement for routing's independent learning-eligibility gates.
nonisolated enum ImportedRunMatchStatus: Equatable {
    case connected, routeOnly, approximate, nearby, unverified, unmatched

    init(method: String?, confidence: Double?, dataset: String?, edgeID: String?, segments: [String]?) {
        switch method {
        case "relaxed_name": self = .approximate
        case "nearest_name": self = .nearby
        case "unmatched": self = .unmatched
        case "polyline_sequence", RecordedPaceEvidence.routeOnlyMethod:
            guard let dataset, !dataset.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let edgeID, !edgeID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let segments, !segments.isEmpty, segments.contains(edgeID),
                  segments.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }),
                  let confidence, confidence.isFinite, (0...1).contains(confidence) else {
                self = .unverified
                return
            }
            self = method == RecordedPaceEvidence.routeOnlyMethod
                ? .routeOnly : (confidence >= 0.75 ? .connected : .approximate)
        default: self = .unverified
        }
    }

    var label: String {
        switch self {
        case .connected: return "CONNECTED MATCH"
        case .routeOnly: return "ROUTE ONLY"
        case .approximate: return "APPROXIMATE"
        case .nearby: return "NEARBY NAME"
        case .unverified: return "UNVERIFIED"
        case .unmatched: return "UNMATCHED"
        }
    }

    var explanation: String {
        switch self {
        case .connected:
            return "Your GPS matched a connected route in the recorded mountain dataset. This is an algorithmic match, not confirmation of which trail you skied."
        case .routeOnly:
            return "Your GPS matched a connected route, but did not provide enough timed forward movement to measure trail pace. Your activity statistics are kept; this match does not train routing speed. The trail match is algorithmic, not confirmed."
        case .approximate:
            return "This is a possible trail name, not a confirmed route. The match did not meet the requirements for confident trail attribution."
        case .nearby:
            return "A nearby trail supplied this name. Your recorded route was not matched to that trail, and this name alone does not train routing pace."
        case .unverified:
            return "Match evidence is unavailable or incomplete for this saved activity. Its trail name should not be treated as confirmed."
        case .unmatched:
            return "Your activity is saved, but its route has not been matched to the mountain graph. Any name from the recording has not been verified."
        }
    }
}
