//
//  MeetingResult.swift
//  PowderMeet
//
//  Solver output value types. Extracted from MeetingPointSolver.swift (which
//  had grown past 1400 lines) — these are standalone `nonisolated` value types
//  with no coupling to the solver class internals, so moving them out is pure
//  code motion that keeps the invariant-heavy result contracts easy to find.
//

import Foundation

// MARK: - Results

/// Why a route is being drawn. Meetup routes keep the two-skier language;
/// destination previews use the same strict pathfinding but label the terminal
/// as a place the skier chose rather than pretending another person is there.
nonisolated enum RoutePresentationPurpose: Equatable, Sendable {
    case meetup
    case destination
    case previewDestination

    var mapMarkerVerb: String {
        switch self {
        case .meetup: return "MEET"
        case .destination: return "GO"
        case .previewDestination: return "PREVIEW"
        }
    }
}

/// Evidence that a rendezvous leaves both skiers with a useful legal move
/// after they arrive. This is solver output—not a UI guess from difficulty.
nonisolated struct SharedContinuation: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case ski
        case ride
        case traverse
    }

    let edgeID: String
    let name: String
    let kind: Kind
    /// Downhill geometry reached by the bounded post-meet rollout. These are
    /// factual graph measurements, not distance silently appended to either
    /// skier's accepted navigation route.
    let sharedRunLengthMeters: Double
    let sharedVerticalDropMeters: Double
    /// Group time from the rendezvous until the shared downhill begins. This
    /// includes lift ride and current/modeled queue time when the first action
    /// is a lift.
    let downhillAccessSeconds: Double
    /// Length-weighted modeled pace fit for the least comfortable skier on the
    /// shared descent. This is a soft preference signal, never permission.
    let jointTerrainFit: Double
    /// Distinct, mutually legal first-run identities whose utility stays close
    /// to the best post-meet option. Canonical pieces of one run count once.
    let sharedRunOptionCount: Int
    /// Capped 0...1 post-meet utility used by rendezvous ranking. A minimally
    /// useful run still earns continuation credit; substantial, comfortable,
    /// accessible terrain with real choice earns more without ever overriding
    /// hard traversal gates.
    let quality: Double

    var cardCopy: String {
        let action: String
        switch kind {
        case .ski: action = "SKI"
        case .ride: action = "RIDE"
        case .traverse: action = "TAKE"
        }
        return "BOTH CAN \(action) \(name.uppercased()) NEXT"
    }
}

/// Which solver attempt produced a `MeetingResult`. New interactive solves
/// produce only `.live` or `.nonCanonicalDataset`; relaxed cases remain in the
/// wire enum so older saved/request payloads keep decoding and are visibly
/// non-navigable.
nonisolated enum SolveAttempt: String, Codable, Sendable {
    /// Strict pass — live edge open/closed status respected, both
    /// skiers solved from their actual position.
    case live
    /// Legacy preview — every edge was forced open.
    case forcedOpen
    /// Legacy preview — skier positions were substituted.
    case neighborSubstitution
    /// Legacy preview combining both relaxations.
    case forcedOpenNeighborSubstitution
    /// Strict graph solve over a frozen compatibility snapshot rather than a
    /// canonical immutable server dataset. Useful for explanation only.
    case nonCanonicalDataset

    /// Only strict live solves may be sent or activated. Fallback attempts
    /// remain useful as clearly-labelled explanations, never navigation.
    var isNavigable: Bool { self == .live }
}

nonisolated struct MeetingResult: Equatable {
    let meetingNode: GraphNode
    let pathA: [GraphEdge]              // edges skier A takes
    let pathB: [GraphEdge]              // edges skier B takes
    var timeA: Double                   // seconds for skier A; live session updates remaining ETA
    var timeB: Double                   // seconds for skier B; partner broadcasts update this
    var alternates: [AlternateMeeting]  // runner-up options (var so the post-solve annotator can populate per-leg times)
    /// Portion of the first canonical edge already traversed at solve time.
    /// The path retains the full edge for validation, while map/tracker/ghost
    /// consumers trim this completed prefix from what they present.
    var initialEdgeFractionA: Double = 0
    var initialEdgeFractionB: Double = 0
    /// Dataset-curated, human-recognizable rendezvous landmark. Kept separate
    /// from graph identity so routing remains stable if display copy improves.
    var meetingDisplayName: String? = nil
    /// Exact stopping-point metadata that made this node eligible. This lets
    /// choice cards explain whether the destination is a lift base, lodge,
    /// signed meeting area, mid-station, or patrol point. Legacy/session rows
    /// can leave it nil and derive a conservative type from the graph node.
    var rendezvousPoint: RendezvousPoint? = nil
    /// Factual environmental context for why waiting exposure affected this
    /// stop's rank. Nil in ordinary weather and for legacy/session results.
    var rendezvousReason: String? = nil
    /// First useful edge both skiers can legally take after the later arrival.
    /// Nil for terminal stops and when a shallow rollout finds only dead ends.
    var sharedContinuation: SharedContinuation? = nil
    /// One-sentence "why this route" for skier A. Filled by the route
    /// instruction builder after the solve — e.g. "Wide groomed blues — matched
    /// your preference" or "Avoided Steep Gully — gradient exceeds your comfort."
    var routeReasonA: String? = nil
    /// One-sentence "why this route" for skier B.
    var routeReasonB: String? = nil
    /// Per-edge traverse times in seconds, paralleling `pathA`. Filled
    /// by the post-solve enrichment so the meeting-option / route
    /// summary cards can show a per-leg time breakdown ("LIFT 6: 8 min,
    /// FRONTSIDE: 3 min") instead of just the aggregate. Same length
    /// as `pathA` when populated; `nil` for legacy / fallback solves
    /// that didn't run the enrichment.
    var legTimesA: [Double]? = nil
    /// Per-edge traverse times for skier B. See `legTimesA`.
    var legTimesB: [Double]? = nil
    /// Standard deviation of `timeA` in seconds (1σ). Populated by
    /// the solver from per-edge variance threaded through Dijkstra:
    /// observation variance from `profile_edge_speeds` (delta-method
    /// converted speed→time) when available, coefficient-of-variation
    /// fallback otherwise. UI uses `±1.28σ` to render P10–P90 ranges
    /// — surfaces honest uncertainty instead of falsely-precise point
    /// estimates. The same variance is also part of the candidate
    /// scoring (CVaR β term) so the *recommendation*, not just the
    /// display, prefers paths with predictable times.
    var etaStdSecondsA: Double? = nil
    /// Standard deviation of `timeB` in seconds. See `etaStdSecondsA`.
    var etaStdSecondsB: Double? = nil
    /// Which solver attempt produced this result. The strict
    /// `.live` pass is the default; fallback attempts are stamped
    /// by the caller (`MeetView.solveMeeting`) so the route card
    /// can show a "PREVIEW" pill rather than letting the user
    /// trust a route through closed terrain.
    var solveAttempt: SolveAttempt = .live
    /// Presentation-only route intent. Excluded from equality for the same
    /// reason as the annotation fields above: it never changes path physics.
    var presentationPurpose: RoutePresentationPurpose = .meetup

    var maxTime: Double { max(timeA, timeB) }
    var totalTime: Double { timeA + timeB }

    /// Equality compares the SOLVE OUTPUT only — meeting node, paths,
    /// times, alternate identity. Post-hoc annotation fields
    /// (`legTimesA/B`, `routeReasonA/B`, `rendezvousReason`,
    /// `sharedContinuation`, `etaStdSecondsA/B`, `solveAttempt`) are
    /// intentionally excluded. The annotator
    /// pass fills those AFTER the result is first set on the view's
    /// flow object, which produces a second observable mutation; if
    /// `==` included them, every re-solve that matched the prior
    /// solve's core would still register as "different" (nil
    /// `legTimes` then annotated `legTimes`) and SwiftUI would
    /// rebuild the `MeetingOptionsSection.resultCards` body each
    /// time. Excluding annotations means stable solves render
    /// stable cards.
    static func == (lhs: MeetingResult, rhs: MeetingResult) -> Bool {
        guard lhs.meetingNode.id == rhs.meetingNode.id else { return false }
        guard lhs.timeA == rhs.timeA, lhs.timeB == rhs.timeB else { return false }
        guard lhs.initialEdgeFractionA == rhs.initialEdgeFractionA,
              lhs.initialEdgeFractionB == rhs.initialEdgeFractionB else { return false }
        guard pathIds(lhs.pathA) == pathIds(rhs.pathA) else { return false }
        guard pathIds(lhs.pathB) == pathIds(rhs.pathB) else { return false }
        return lhs.alternates == rhs.alternates
    }
}

/// Shared by `MeetingResult.==` and `AlternateMeeting.==`; defined at
/// file scope rather than inside the equality closures so Swift's type
/// inference picks `[GraphEdge]` → `[String]` directly instead of
/// fighting a parameterised key path inside an operator overload.
/// `nonisolated` so it can be called from the `==` operators on the
/// `nonisolated` `MeetingResult` / `AlternateMeeting` structs (which
/// run from the solver's static `solutionCache` outside any actor).
nonisolated private func pathIds(_ path: [GraphEdge]) -> [String] {
    path.map { $0.id }
}

nonisolated struct AlternateMeeting: Equatable {
    let node: GraphNode
    let pathA: [GraphEdge]
    let pathB: [GraphEdge]
    let timeA: Double
    let timeB: Double
    var initialEdgeFractionA: Double = 0
    var initialEdgeFractionB: Double = 0
    var meetingDisplayName: String? = nil
    var rendezvousPoint: RendezvousPoint? = nil
    var sharedContinuation: SharedContinuation? = nil
    var routeReasonA: String? = nil
    var routeReasonB: String? = nil
    /// Per-edge time breakdown for skier A's path. Populated by
    /// MeetView's post-solve annotator (same pattern as the primary
    /// `MeetingResult.legTimesA`). Nil until annotated; cards hide
    /// the per-step time when nil.
    var legTimesA: [Double]? = nil
    /// Per-edge time breakdown for skier B's path. See `legTimesA`.
    var legTimesB: [Double]? = nil
    /// Standard deviation for skier A's alternate path. Alternates participate
    /// in the same reliability ranking as the primary, so dropping their
    /// uncertainty would make the option cards look falsely precise.
    var etaStdSecondsA: Double? = nil
    /// Standard deviation for skier B's alternate path.
    var etaStdSecondsB: Double? = nil

    /// Equality compares solve-output fields only. Same rationale as
    /// `MeetingResult.==`: ignore the legTimes annotation so a fresh
    /// pre-annotation copy and a later annotated copy compare equal
    /// when their underlying paths agree.
    static func == (lhs: AlternateMeeting, rhs: AlternateMeeting) -> Bool {
        guard lhs.node.id == rhs.node.id else { return false }
        guard lhs.timeA == rhs.timeA, lhs.timeB == rhs.timeB else { return false }
        guard lhs.initialEdgeFractionA == rhs.initialEdgeFractionA,
              lhs.initialEdgeFractionB == rhs.initialEdgeFractionB else { return false }
        guard pathIds(lhs.pathA) == pathIds(rhs.pathA) else { return false }
        return pathIds(lhs.pathB) == pathIds(rhs.pathB)
    }
}

/// Result for N-skier solve (generalizes MeetingResult).
struct MeetingResultN {
    let meetingNode: GraphNode
    let paths: [(skier: UserProfile, path: [GraphEdge], time: Double)]
    let alternates: [AlternateMeetingN]

    var maxTime: Double { paths.map(\.time).max() ?? 0 }
    var totalTime: Double { paths.map(\.time).reduce(0, +) }
}

struct AlternateMeetingN {
    let node: GraphNode
    let times: [Double]
    var maxTime: Double { times.max() ?? 0 }
}
