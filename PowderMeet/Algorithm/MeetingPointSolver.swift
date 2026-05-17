//
//  MeetingPointSolver.swift
//  PowderMeet
//
//  Finds the optimal meeting point on the mountain graph for N skiers.
//  Runs Dijkstra from each skier's position using a binary heap priority
//  queue, then scores reachable nodes with a multi-factor objective that
//  considers arrival time, balance, hub quality, elevation, and landmark
//  status.  Alternates are picked with geographic diversity so the user
//  sees meaningfully different options.
//
//  All floating-point inputs (time, weather) are normalized to coarse
//  buckets so that two devices solving independently produce identical
//  results even with minor timing or fetch-order differences.
//

import Foundation
import CoreLocation

// MARK: - Results

/// Which solver attempt produced a `MeetingResult`. The solver
/// re-tries with progressively more relaxed constraints when the
/// strict pass fails — those fallback paths can include closed
/// terrain or off-piste neighbor substitutions, so the UI must
/// label them so the user knows the route is a *preview* rather
/// than a fully-trusted route. The default `.live` means the route
/// honored every live constraint (open/closed status, exact
/// positions).
nonisolated enum SolveAttempt: String, Codable, Sendable {
    /// Strict pass — live edge open/closed status respected, both
    /// skiers solved from their actual position.
    case live
    /// Attempt 2 — every edge forced open. Used when at least one
    /// closure broke the only viable path. Route may pass through
    /// trails that are reportedly closed.
    case forcedOpen
    /// Attempt 3 — both skiers' start nodes substituted with the
    /// nearest well-connected neighbor. Used when the strict-position
    /// solve had no path at all. Route starts from a nearby node, not
    /// the user's precise location.
    case neighborSubstitution
}

nonisolated struct MeetingResult: Equatable {
    let meetingNode: GraphNode
    let pathA: [GraphEdge]              // edges skier A takes
    let pathB: [GraphEdge]              // edges skier B takes
    let timeA: Double                   // seconds for skier A
    let timeB: Double                   // seconds for skier B
    var alternates: [AlternateMeeting]  // runner-up options (var so the post-solve annotator can populate per-leg times)
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

    var maxTime: Double { max(timeA, timeB) }
    var totalTime: Double { timeA + timeB }

    /// Equality compares the SOLVE OUTPUT only — meeting node, paths,
    /// times, alternate identity. Post-hoc annotation fields
    /// (`legTimesA/B`, `routeReasonA/B`, `etaStdSecondsA/B`,
    /// `solveAttempt`) are intentionally excluded. The annotator
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
    /// Per-edge time breakdown for skier A's path. Populated by
    /// MeetView's post-solve annotator (same pattern as the primary
    /// `MeetingResult.legTimesA`). Nil until annotated; cards hide
    /// the per-step time when nil.
    var legTimesA: [Double]? = nil
    /// Per-edge time breakdown for skier B's path. See `legTimesA`.
    var legTimesB: [Double]? = nil

    /// Equality compares solve-output fields only. Same rationale as
    /// `MeetingResult.==`: ignore the legTimes annotation so a fresh
    /// pre-annotation copy and a later annotated copy compare equal
    /// when their underlying paths agree.
    static func == (lhs: AlternateMeeting, rhs: AlternateMeeting) -> Bool {
        guard lhs.node.id == rhs.node.id else { return false }
        guard lhs.timeA == rhs.timeA, lhs.timeB == rhs.timeB else { return false }
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

// MARK: - Traversal Context

/// Bundles all environmental conditions for the weight function.
/// Built once per solve, passed to every `traverseTime()` call.
/// Values are pre-normalized for cross-device determinism.
nonisolated struct TraversalContext: Sendable {
    let solveTime: Date?
    let latitude: Double?
    let longitude: Double?
    let temperatureCelsius: Double
    let stationElevationM: Double     // DEM elevation of weather station
    let windSpeedKmh: Double
    let visibilityKm: Double
    let freshSnowCm: Double
    let cloudCoverPercent: Int
    /// Per-edge rolling-average speed history loaded from
    /// `profile_edge_speeds`. Outer key is `edge_id`; inner key is
    /// `conditions_fp` (Phase 2.1 — bucketed weather + surface).
    /// `traverseTime` computes the fingerprint for the current edge
    /// and conditions, looks up the matching bucket, falls back to
    /// the `default` bucket, then to bucketed-difficulty. Empty dict
    /// = no history available; behaves identically to the pre-
    /// Phase-2 traverseTime.
    let edgeSpeedHistory: [String: [String: PerEdgeSpeed]]

    /// Minimum observations before we trust the rolling per-edge speed
    /// over the bucketed median. One run is signal but not enough to
    /// commit; three is a reasonable confidence floor while still being
    /// reachable on a normal weekend.
    static let edgeHistoryMinObservations = 3

    init(
        solveTime: Date?,
        latitude: Double?,
        longitude: Double?,
        temperatureCelsius: Double,
        stationElevationM: Double,
        windSpeedKmh: Double,
        visibilityKm: Double,
        freshSnowCm: Double,
        cloudCoverPercent: Int,
        edgeSpeedHistory: [String: [String: PerEdgeSpeed]] = [:]
    ) {
        self.solveTime = solveTime
        self.latitude = latitude
        self.longitude = longitude
        self.temperatureCelsius = temperatureCelsius
        self.stationElevationM = stationElevationM
        self.windSpeedKmh = windSpeedKmh
        self.visibilityKm = visibilityKm
        self.freshSnowCm = freshSnowCm
        self.cloudCoverPercent = cloudCoverPercent
        self.edgeSpeedHistory = edgeSpeedHistory
    }

    /// Look up the rolling-average row that best matches the current
    /// conditions for `edge`. Tries the live-conditions bucket first,
    /// then the legacy `default` bucket (which covers all rows
    /// imported before the conditions_fp pipeline went live AND every
    /// row written by `ActivityImporter` since — only `LiveRunRecorder`
    /// stamps live fingerprints today). Returns `nil` when the edge
    /// has no recorded history at all, prompting the caller to fall
    /// back to bucketed-difficulty speeds.
    func observation(for edge: GraphEdge) -> PerEdgeSpeed? {
        guard let perEdge = edgeSpeedHistory[edge.id], !perEdge.isEmpty else {
            return nil
        }
        let surface = ConditionsFingerprint.SurfaceFlags(
            hasMoguls: edge.attributes.hasMoguls,
            isUngroomed: edge.attributes.isGroomed == false,
            isGladed: edge.attributes.isGladed
        )
        let liveFp = ConditionsFingerprint.fingerprint(
            temperatureC: temperatureCelsius,
            windSpeedKph: windSpeedKmh,
            snowfallLast24hCm: freshSnowCm,
            visibilityKm: visibilityKm,
            cloudCoverPercent: cloudCoverPercent,
            surface: surface
        )
        if let row = perEdge[liveFp] { return row }
        if let row = perEdge[ConditionsFingerprint.defaultBucket] { return row }
        // Last resort — pick whichever bucket has the most observations
        // so a near-miss on the fingerprint doesn't drop us back to
        // bucketed-difficulty when we DO have data, just under a
        // different conditions cohort.
        return perEdge.values.max(by: { $0.observationCount < $1.observationCount })
    }

    /// Lapse-rate adjusted temperature at a given elevation.
    func temperatureAt(elevationM: Double) -> Double {
        let deltaM = elevationM - stationElevationM
        return temperatureCelsius + deltaM * (-6.5 / 1000.0)
    }
}

// MARK: - Solve Failure Reasons

/// Structured reason for why the solver returned nil.
enum SolveFailureReason {
    case skierAtDeadEnd(skierName: String)
    case noReachableIntersection
    case skillGatedPath
    case allLiftsClosedInArea
    case unknownPosition

    var userMessage: String {
        switch self {
        case .skierAtDeadEnd(let name):
            return "\(name) is at a location with no available routes. Try moving closer to a lift or trail."
        case .noReachableIntersection:
            return "No path connects both positions. This can happen when lifts are closed or trails are too difficult."
        case .skillGatedPath:
            return "The only connecting routes are too difficult for one or both skiers."
        case .allLiftsClosedInArea:
            return "All lifts in the area appear to be closed. Routes can't be calculated without lift access."
        case .unknownPosition:
            return "Unable to determine skier position on the mountain."
        }
    }
}

// MARK: - Solution Cache

/// Bounded LRU cache for successful 2-skier solves. Shared across solver
/// instances because callers typically create a fresh solver per request —
/// cache-on-instance would be wasted. Cache key spans everything the result
/// depends on, so entries for stale graphs never collide with live ones.
///
/// **Concurrency contract.** `@unchecked Sendable` — all mutable state
/// (`order`, `store`) is guarded by an `NSLock`, so concurrent access from
/// multiple `Task.detached` solves is safe. `MeetingResult` itself is a
/// value type holding `Sendable` members. The cache lives as a static on
/// `MeetingPointSolver`, accessed from any actor; do not let mutation paths
/// escape outside the lock or eject the lock-and-defer pattern from
/// `value(for:)` / `set(_:for:)`. Long-term direction is `os.Mutex` (or an
/// actor wrapper) under Swift 6 strict-concurrency, but `@unchecked Sendable
/// + NSLock` is the production-safe interim — `Mutex` is iOS 18+ only and
/// the deployment target still includes 17.6.
nonisolated final class SolverCache: @unchecked Sendable {
    struct CacheKey: Hashable {
        let graphFingerprint: String
        let positionA: String
        let positionB: String
        let profileA: String
        let profileB: String
        let contextSignature: String
        /// Hash of the per-edge skill memory the solver consulted. Must
        /// be in the key — `traverseTime` reads `edgeSpeedHistory` via
        /// `TraversalContext`, so importing a run (which mutates the
        /// dict) needs to invalidate prior cached paths for the same
        /// (positions, profiles, weather). Without this field, a re-solve
        /// after import returned the stale path and the user's calibration
        /// was silently ignored.
        let edgeSpeedHistoryFingerprint: String
    }

    private var order: [CacheKey] = []
    private var store: [CacheKey: MeetingResult] = [:]
    private let capacity: Int
    private let lock = NSLock()

    init(capacity: Int = 128) {
        self.capacity = capacity
    }

    func value(for key: CacheKey) -> MeetingResult? {
        lock.lock(); defer { lock.unlock() }
        guard let result = store[key] else { return nil }
        if let idx = order.firstIndex(of: key) { order.remove(at: idx) }
        order.append(key)
        return result
    }

    func set(_ result: MeetingResult, for key: CacheKey) {
        lock.lock(); defer { lock.unlock() }
        if store[key] == nil {
            order.append(key)
        } else if let idx = order.firstIndex(of: key) {
            order.remove(at: idx); order.append(key)
        }
        store[key] = result
        while order.count > capacity {
            let evict = order.removeFirst()
            store.removeValue(forKey: evict)
        }
    }

    func clear() {
        lock.lock(); defer { lock.unlock() }
        order.removeAll()
        store.removeAll()
    }
}

// MARK: - Solver

// `nonisolated` — pure compute class, must run off the main actor so
// Whistler-scale Dijkstra doesn't hitch the SwiftUI thread when the user
// pages through meet cards. Project default isolation is MainActor; opt
// out here. `@unchecked Sendable` because mutable config is set before
// the solve and not touched concurrently — caller contract is "configure
// fully on main, then dispatch to a Task.detached that owns the solve."
nonisolated final class MeetingPointSolver: @unchecked Sendable {

    /// Shared across instances. 128 entries ≈ tens of kilobytes; bounded
    /// LRU so long sessions don't leak.
    static let solutionCache = SolverCache(capacity: 128)

    private let graph: MountainGraph

    /// Set after `solve()` returns nil — provides a structured reason for the failure.
    private(set) var lastFailureReason: SolveFailureReason?

    /// Optional time-of-day for sun exposure and lift hours.
    var solveTime: Date?
    /// Resort latitude for solar position calculations.
    var resortLatitude: Double?
    /// Resort longitude for solar noon correction.
    var resortLongitude: Double?
    /// Current temperature for snow condition model.
    var temperatureC: Double = -2
    /// Current wind speed at resort (km/h).
    var windSpeedKmh: Double = 0
    /// Current visibility in km (10 = clear, <1 = whiteout).
    var visibilityKm: Double = 10
    /// Fresh snowfall in last 24h (cm).
    var freshSnowCm: Double = 0
    /// Cloud cover percentage (0–100).
    var cloudCoverPercent: Int = 0
    /// DEM elevation of weather station (meters) for lapse rate.
    var stationElevationM: Double = 0
    /// Per-edge skill memory keyed by `edge_id`. Set externally before
    /// `solve()` so `traverseTime` can prefer per-edge rolling averages
    /// over the bucketed-difficulty profile speed when enough
    /// observations exist. Empty = no history; behaves identically to
    /// pre-Phase-2 solving.
    ///
    /// Used as the fallback history when no per-profile entry exists
    /// in `edgeSpeedHistoryByProfile`. Single-skier callers
    /// (`LiveRunRecorder`, `RoutingTestSheet`, anything that solves
    /// for the local user only) can keep setting this directly.
    var edgeSpeedHistory: [String: [String: PerEdgeSpeed]] = [:]

    /// Per-skier per-edge history, keyed by `UserProfile.id`. Inner
    /// shape mirrors `edgeSpeedHistory`: `[edge_id: [conditions_fp: row]]`.
    /// Set by the two-skier meet path so each skier traverses with
    /// their own rolling speeds — without this, the local user's
    /// history bleeds into the friend's edge weights. Missing entries
    /// fall back to `edgeSpeedHistory`, then empty.
    var edgeSpeedHistoryByProfile: [String: [String: [String: PerEdgeSpeed]]] = [:]

    init(graph: MountainGraph) {
        self.graph = graph
    }

    // MARK: - Deterministic Context Builder

    /// Public façade — every external caller (MeetView post-solve
    /// narrative, route-instruction builder, route-reason builder)
    /// must use this rather than constructing a TraversalContext by
    /// hand. Guarantees the context the *narrative* sees matches
    /// what the *solve* used: same quantization, same selected
    /// per-skier history. Pass `nil` for skierID when no specific
    /// skier is in scope (uses the fallback `edgeSpeedHistory`).
    func makeContext(for skierID: String? = nil) -> TraversalContext {
        return buildContext(for: skierID)
    }

    /// Build a TraversalContext from current solver state.
    /// Normalizes all values to coarse buckets so two devices that
    /// fetched weather or pressed "solve" a few seconds apart produce
    /// the exact same edge weights.
    ///
    /// `skierID` selects which per-skier `edgeSpeedHistory` slot to
    /// use. Falls back to the shared `edgeSpeedHistory` when no
    /// per-profile entry exists, so single-skier call sites that set
    /// `edgeSpeedHistory` directly stay correct.
    private func buildContext(for skierID: String? = nil) -> TraversalContext {
        let history: [String: [String: PerEdgeSpeed]] = {
            if let id = skierID, let perSkier = edgeSpeedHistoryByProfile[id] {
                return perSkier
            }
            return edgeSpeedHistory
        }()

        // Round solve time to the nearest 15-minute window.
        // Both devices in the same quarter-hour get identical sun exposure.
        let normalizedTime: Date? = {
            guard let t = solveTime else { return nil }
            let interval = t.timeIntervalSinceReferenceDate
            let bucket = SolverConstants.Determinism.timeBucketSeconds
            let rounded = (interval / bucket).rounded(.down) * bucket
            return Date(timeIntervalSinceReferenceDate: rounded)
        }()

        let tempStep = SolverConstants.Determinism.tempQuantizationCelsius
        let elevStep = SolverConstants.Determinism.elevQuantizationMeters
        let windStep = SolverConstants.Determinism.windQuantizationKph
        let visStep  = SolverConstants.Determinism.visQuantizationKm

        return TraversalContext(
            solveTime: normalizedTime,
            latitude: resortLatitude,
            longitude: resortLongitude,
            temperatureCelsius: (temperatureC / tempStep).rounded() * tempStep,
            stationElevationM: (stationElevationM / elevStep).rounded() * elevStep,
            windSpeedKmh: (windSpeedKmh / windStep).rounded() * windStep,
            visibilityKm: (visibilityKm / visStep).rounded() * visStep,
            freshSnowCm: freshSnowCm.rounded(),                  // 1 cm steps
            // Quantize cloud cover to the nearest 10% — matches the
            // granularity of the upstream weather feed and keeps the
            // value Int. Without this, two devices that fetched
            // weather a few seconds apart could disagree on a single
            // percent and produce different cached solves.
            cloudCoverPercent: ((cloudCoverPercent + 5) / 10) * 10,
            edgeSpeedHistory: history
        )
    }

    // MARK: - Debug Fingerprinting

    /// FNV-style stable checksum over a list of strings. Process-stable
    /// (unlike `Array.hashValue` / `String.hashValue`) so two devices
    /// can compare the exact same hex digest in their logs. Used by
    /// both `graphFingerprint` and `edgeSpeedHistoryFingerprint`.
    private static func stableChecksum(_ strings: [String]) -> UInt64 {
        var checksum: UInt64 = 0
        for s in strings {
            for byte in s.utf8 {
                checksum = checksum &* 31 &+ UInt64(byte)
            }
            checksum = checksum &* 31 &+ 0x7C   // '|' separator
        }
        return checksum & 0xFFFFFFFF
    }

    /// Deterministic fingerprint of the graph's open-edge set.
    /// If two devices print different hashes, their graphs diverged
    /// (e.g. enricher fetched at different times).
    private func graphFingerprint() -> String {
        let openEdges = graph.edges.filter { $0.attributes.isOpen }
        let sortedIds = openEdges.map(\.id).sorted()
        let cksum = Self.stableChecksum(sortedIds)
        return "n:\(graph.nodes.count) e:\(graph.edges.count) open:\(openEdges.count) cksum:\(String(format: "%08x", cksum))"
    }

    /// One-line summary of a profile's algorithm-relevant fields.
    /// Doubles as a solution-cache key component, so every field that
    /// `traverseTime` reads MUST appear here — if a continuous-skill slider
    /// moves but the fingerprint doesn't change, the solver returns a stale
    /// cached path that was computed under the old weights.
    /// (`edgeSpeedHistory` is also read by `traverseTime` but lives on
    /// the solver instance instead of the profile — see
    /// `edgeSpeedHistoryFingerprint` below.)
    private static func profileFingerprint(_ p: UserProfile) -> String {
        let spd = [p.speedGreen, p.speedBlue, p.speedBlack, p.speedDoubleBlack, p.speedTerrainPark]
            .map { $0.map { String(format: "%.1f", $0) } ?? "-" }
            .joined(separator: ",")
        func f(_ v: Double?) -> String { v.map { String(format: "%.2f", $0) } ?? "-" }
        let cont = "gCap=\(f(p.maxComfortableGradientDegrees)) mT=\(f(p.mogulTolerance)) nT=\(f(p.narrowTrailTolerance)) eT=\(f(p.exposureTolerance)) cT=\(f(p.crustConditionTolerance))"
        return "\(p.skillLevel) spd=[\(spd)] m=\(String(format: "%.2f", p.conditionMoguls)) u=\(String(format: "%.2f", p.conditionUngroomed)) i=\(String(format: "%.2f", p.conditionIcy)) g=\(String(format: "%.2f", p.conditionGladed)) \(cont)"
    }

    /// Compact fingerprint of the per-edge skill memory (`edgeSpeedHistory`).
    /// Cache key component — without this, an import that mutates
    /// `currentEdgeSpeeds` upstream would not invalidate cached solves
    /// for the same (positions, profiles, weather) tuple.
    ///
    /// Sum of `observationCount` is enough on top of the sorted edge-id
    /// list: any new import either adds a new edge id (changes the list)
    /// or increments an existing edge's observationCount (changes the
    /// sum). Cheap to compute (one pass over keys + one reduce); runs
    /// once per solve next to the existing fingerprints.
    private static func edgeSpeedHistoryFingerprint(_ history: [String: [String: PerEdgeSpeed]]) -> String {
        if history.isEmpty { return "∅" }
        let sortedIds = history.keys.sorted()
        let totalObs = history.values.reduce(0) { acc, perEdge in
            acc + perEdge.values.reduce(0) { $0 + $1.observationCount }
        }
        let totalBuckets = history.values.reduce(0) { $0 + $1.count }
        let cksum = stableChecksum(sortedIds)
        return "n=\(history.count) buckets=\(totalBuckets) obs=\(totalObs) cksum=\(String(format: "%08x", cksum))"
    }

    /// Print everything both devices need to compare.
    private func logFingerprint(
        positionA: String, positionB: String,
        skierA: UserProfile, skierB: UserProfile
    ) {
        let ctxA = buildContext(for: skierA.id.uuidString)
        let ctxB = buildContext(for: skierB.id.uuidString)
        let timeStr: String
        if let t = ctxA.solveTime {
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime]
            timeStr = f.string(from: t)
        } else { timeStr = "nil" }

        SolverLog.debug("[SOLVER] ═══════════ FINGERPRINT ═══════════")
        SolverLog.debug("[SOLVER] Graph: \(graphFingerprint())")
        SolverLog.debug("[SOLVER] Positions: A=\(positionA) B=\(positionB)")
        SolverLog.debug("[SOLVER] ProfileA: \(Self.profileFingerprint(skierA))")
        SolverLog.debug("[SOLVER] ProfileB: \(Self.profileFingerprint(skierB))")
        SolverLog.debug("[SOLVER] HistoryA: \(Self.edgeSpeedHistoryFingerprint(ctxA.edgeSpeedHistory))")
        SolverLog.debug("[SOLVER] HistoryB: \(Self.edgeSpeedHistoryFingerprint(ctxB.edgeSpeedHistory))")
        SolverLog.debug("[SOLVER] Context: temp=\(ctxA.temperatureCelsius)°C wind=\(ctxA.windSpeedKmh)km/h vis=\(ctxA.visibilityKm)km snow=\(ctxA.freshSnowCm)cm cloud=\(ctxA.cloudCoverPercent)% time=\(timeStr)")
        SolverLog.debug("[SOLVER] ══════════════════════════════════")
    }

    // MARK: - 2-Skier Solve (Enhanced)

    func solve(
        skierA: UserProfile, positionA: String,
        skierB: UserProfile, positionB: String
    ) -> MeetingResult? {
        lastFailureReason = nil

        // ── Debug fingerprint ──
        logFingerprint(positionA: positionA, positionB: positionB,
                       skierA: skierA, skierB: skierB)

        // Per-skier contexts so each skier's edge weights consult
        // their own per-edge history — without this, the local user's
        // rolling speeds bleed into the friend's predicted times.
        let contextA = buildContext(for: skierA.id.uuidString)
        let contextB = buildContext(for: skierB.id.uuidString)

        // ── Cache lookup ──
        // Key spans everything the solve depends on. Context is already
        // bucketised (time → 15min, temp/wind/vis/snow → quantised) so
        // close-in-time repeat solves land on the same key. The
        // combined-history fingerprint covers BOTH skiers' histories
        // — invalidates when either side gets fresh per-edge data.
        let combinedHistoryFp = "A:\(Self.edgeSpeedHistoryFingerprint(contextA.edgeSpeedHistory))|B:\(Self.edgeSpeedHistoryFingerprint(contextB.edgeSpeedHistory))"
        let cacheKey = SolverCache.CacheKey(
            graphFingerprint: graphFingerprint(),
            positionA: positionA,
            positionB: positionB,
            profileA: Self.profileFingerprint(skierA),
            profileB: Self.profileFingerprint(skierB),
            contextSignature: Self.contextSignature(contextA),
            edgeSpeedHistoryFingerprint: combinedHistoryFp
        )
        if let cached = Self.solutionCache.value(for: cacheKey) {
            SolverLog.debug("[SOLVER] cache hit — returning memoised result")
            return cached
        }

        // ── Pre-solve dead-end detection ──
        // Check if each skier's position has usable outgoing edges.
        // If not, try to find an escape node they can walk to.
        var effectiveA = positionA
        var escapeTimeA: Double = 0
        var effectiveB = positionB
        var escapeTimeB: Double = 0

        let usableA = graph.outgoing(from: positionA).contains { skierA.traverseTime(for: $0, context: contextA) != nil }
        if !usableA {
            if let escape = graph.findEscapeNode(from: positionA, profile: skierA, context: contextA) {
                SolverLog.debug("[SOLVER] Skier A at dead-end \(positionA) — redirecting to escape node \(escape.nodeID) (+\(String(format: "%.0f", escape.walkTime))s walk)")
                effectiveA = escape.nodeID
                escapeTimeA = escape.walkTime
            } else {
                SolverLog.debug("[SOLVER] Skier A at dead-end \(positionA) — no escape node found")
                lastFailureReason = .skierAtDeadEnd(skierName: skierA.displayName)
                return nil
            }
        }

        let usableB = graph.outgoing(from: positionB).contains { skierB.traverseTime(for: $0, context: contextB) != nil }
        if !usableB {
            if let escape = graph.findEscapeNode(from: positionB, profile: skierB, context: contextB) {
                SolverLog.debug("[SOLVER] Skier B at dead-end \(positionB) — redirecting to escape node \(escape.nodeID) (+\(String(format: "%.0f", escape.walkTime))s walk)")
                effectiveB = escape.nodeID
                escapeTimeB = escape.walkTime
            } else {
                SolverLog.debug("[SOLVER] Skier B at dead-end \(positionB) — no escape node found")
                lastFailureReason = .skierAtDeadEnd(skierName: skierB.displayName)
                return nil
            }
        }

        // ── Dijkstra from each skier (using effective positions) ──
        let distA = dijkstra(from: effectiveA, skier: skierA)
        let distB = dijkstra(from: effectiveB, skier: skierB)

        SolverLog.debug("[SOLVER] Dijkstra A reached \(distA.count) nodes, B reached \(distB.count) nodes")

        // Debug: check if either skier can reach lift nodes
        let liftsInGraph = graph.edges.filter { $0.kind == .lift }
        let liftBaseNodeIds = Set(liftsInGraph.map(\.sourceID))
        let liftTopNodeIds = Set(liftsInGraph.map(\.targetID))
        let aReachesLiftBases = Set(distA.keys).intersection(liftBaseNodeIds).count
        let aReachesLiftTops = Set(distA.keys).intersection(liftTopNodeIds).count
        let bReachesLiftBases = Set(distB.keys).intersection(liftBaseNodeIds).count
        let bReachesLiftTops = Set(distB.keys).intersection(liftTopNodeIds).count
        SolverLog.debug("[SOLVER] Lifts in graph: \(liftsInGraph.count) (open: \(liftsInGraph.filter { $0.attributes.isOpen }.count))")
        SolverLog.debug("[SOLVER] A reaches: \(aReachesLiftBases) lift bases, \(aReachesLiftTops) lift tops")
        SolverLog.debug("[SOLVER] B reaches: \(bReachesLiftBases) lift bases, \(bReachesLiftTops) lift tops")
        // Debug: elevation range of reachable nodes per skier
        let elevsA = distA.keys.compactMap { graph.nodes[$0]?.elevation }
        let elevsB = distB.keys.compactMap { graph.nodes[$0]?.elevation }
        if let minA = elevsA.min(), let maxA = elevsA.max() {
            SolverLog.debug("[SOLVER] A elevation range: \(Int(minA))m — \(Int(maxA))m")
        }
        if let minB = elevsB.min(), let maxB = elevsB.max() {
            SolverLog.debug("[SOLVER] B elevation range: \(Int(minB))m — \(Int(maxB))m")
        }

        let reachable = Set(distA.keys).intersection(Set(distB.keys))
        guard !reachable.isEmpty else {
            // Probe whether the failure was purely skill-gated. Re-run
            // Dijkstra for both skiers with the difficulty / glade
            // hard-blocks relaxed (open/closed status still respected).
            // If THAT pass produces a non-empty intersection, the
            // original failure was about skill, not topology — give
            // the user the right copy via .skillGatedPath instead of
            // a generic "no path" message.
            let relaxedA = dijkstra(from: effectiveA, skier: skierA, ignoreSkillGates: true)
            let relaxedB = dijkstra(from: effectiveB, skier: skierB, ignoreSkillGates: true)
            let relaxedIntersection = Set(relaxedA.keys).intersection(Set(relaxedB.keys))
            if !relaxedIntersection.isEmpty {
                SolverLog.debug("[SOLVER] Skill-gated failure — relaxed pass found \(relaxedIntersection.count) reachable nodes")
                lastFailureReason = .skillGatedPath
            } else {
                SolverLog.debug("[SOLVER] No reachable intersection — returning nil")
                lastFailureReason = .noReachableIntersection
            }
            return nil
        }
        SolverLog.debug("[SOLVER] Reachable intersection: \(reachable.count) nodes")

        // ── Precompute elevation range for scoring ──
        let elevations = reachable.compactMap { graph.nodes[$0]?.elevation }
        let minElev = elevations.min() ?? 0
        let maxElev = elevations.max() ?? 0
        let elevRange = maxElev - minElev

        // ── Multi-factor scoring ──
        //
        // Primary:   time-based score per preference mode
        // Factor 2:  hub quality — nodes with more outgoing edges are
        //            easier to ski from after meeting (more choices)
        // Factor 3:  elevation band — slight preference for mid-mountain
        //            (avoids base-area crowds and exposed summits)
        // Factor 4:  landmark bonus — lift bases/tops/mid-stations are
        //            unambiguous meeting landmarks
        //
        // All factors are in SECONDS so they're commensurable with time.

        // Compute the time range across candidates to scale secondary factors.
        // At small resorts (time spread ~15s), secondary factors should be mild.
        // At large resorts (time spread ~300s), they can be more significant.
        let allTimes: [Double] = reachable.compactMap { nodeID in
            guard let rawA = distA[nodeID]?.time, let rawB = distB[nodeID]?.time else { return nil }
            let tA = rawA + escapeTimeA
            let tB = rawB + escapeTimeB
            return max(tA, tB)
        }
        let timeRange = (allTimes.max() ?? 0) - (allTimes.min() ?? 0)
        // Secondary factor scale: 5% of time range, clamped to [min, max] seconds.
        let secondaryScale = min(
            SolverConstants.Scoring.secondaryFactorMaxSeconds,
            max(SolverConstants.Scoring.secondaryFactorMinSeconds,
                timeRange * SolverConstants.Scoring.secondaryFactorScalePercent)
        )

        let scored: [(nodeID: String, score: Double, timeA: Double, timeB: Double, varA: Double, varB: Double)] = reachable.compactMap { nodeID in
            guard let entryA = distA[nodeID], let entryB = distB[nodeID] else { return nil }
            let rawA = entryA.time
            let rawB = entryB.time
            // Add escape walk time for skiers redirected from dead-ends
            let tA = rawA + escapeTimeA
            let tB = rawB + escapeTimeB
            // Path variance threaded through DijkstraEntry. Treats edges
            // as independent (Var(sum) = Σ Var(edge)). Escape segments
            // are not graph-resolved so their variance is not tracked;
            // use the bucketed CV fallback to avoid under-reporting
            // uncertainty for routes that include an escape.
            let escapeVarA = pow(escapeTimeA * 0.15, 2)
            let escapeVarB = pow(escapeTimeB * 0.15, 2)
            let varA = entryA.varianceTime + escapeVarA
            let varB = entryB.varianceTime + escapeVarB

            // ── Factor 1: Time score (CVaR-aware) ──
            // Optimal: minimise the worst-case arrival rather than the
            // mean. We model `max(tA, tB)` plus a stochastic tail term
            // proportional to the joint stddev — paths with predictable
            // times beat paths whose mean is the same but whose worst
            // case is bad ("looked great then a 25-min line ate it").
            // The hard `maxImbalanceSeconds` filter still rejects the
            // worst offenders; this shapes within it.
            let waitPenaltyAlpha = SolverConstants.Scoring.waitPenaltyAlpha
            let cvarBeta = SolverConstants.Scoring.cvarBeta
            // Joint stddev under independence: max(tA, tB) is bounded
            // above by sqrt(varA + varB) for the worst-case sum, but we
            // only weight by stddev (β · σ_joint) so the term scales
            // sensibly. β ~ 0.5 makes a 60s combined stddev cost 30s
            // of "score" — comparable to the secondary factors.
            let jointStd = (varA + varB > 0) ? (varA + varB).squareRoot() : 0
            let timeScore = max(tA, tB) + waitPenaltyAlpha * abs(tA - tB) + cvarBeta * jointStd

            // ── Factor 2: Hub quality (more open exits → better) ──
            let hubCount = Double(graph.outgoing(from: nodeID).count)
            let hubBonus = -min(hubCount / SolverConstants.Scoring.hubBonusDivisor, 1.0) * secondaryScale

            // ── Factor 3: Elevation band — skiers want to keep skiing, not meet at base ──
            var elevPenalty = 0.0
            if let nodeElev = graph.nodes[nodeID]?.elevation, elevRange > 100 {
                let norm = (nodeElev - minElev) / elevRange // 0 = base, 1 = summit
                // Strong penalty for base area — nobody wants to meet at the parking lot.
                // Mild penalty for exposed summit. Sweet spot is mid-mountain.
                if norm < SolverConstants.Scoring.elevPenaltyBaseThreshold {
                    elevPenalty = secondaryScale * SolverConstants.Scoring.elevPenaltyBaseArea
                } else if norm > SolverConstants.Scoring.elevPenaltySummitThreshold {
                    elevPenalty = secondaryScale * SolverConstants.Scoring.elevPenaltySummit
                }
            }

            // ── Factor 4: Landmark bonus ──
            let landmarkBonus: Double = {
                guard let kind = graph.nodes[nodeID]?.kind else { return 0 }
                switch kind {
                case .liftBase, .liftTop, .midStation:
                    return -secondaryScale * SolverConstants.Scoring.landmarkBonusScale
                default: return 0
                }
            }()

            let totalScore = timeScore + hubBonus + elevPenalty + landmarkBonus
            return (nodeID, totalScore, tA, tB, varA, varB)

        }.sorted(by: { a, b in
            // Deterministic tie-breaker: lexicographic node ID
            if a.score != b.score { return a.score < b.score }
            return a.nodeID < b.nodeID
        })

        // ── Filters ──

        // Remove trivial (meeting at one skier's own position)
        let nonTrivial = scored.filter { $0.nodeID != positionA && $0.nodeID != positionB }
        let afterTrivial = nonTrivial.isEmpty ? scored : nonTrivial

        // Hard imbalance: reject if one skier waits longer than maxImbalanceSeconds.
        let maxImbalanceSeconds = SolverConstants.Scoring.maxImbalanceSeconds
        let balanced = afterTrivial.filter { abs($0.timeA - $0.timeB) <= maxImbalanceSeconds }
        let candidates = balanced.isEmpty ? afterTrivial : balanced

        // ── Debug: top 10 candidates ──
        let naming = MountainNaming(graph)
        SolverLog.debug("[SOLVER] Top candidates (after filters: \(candidates.count) of \(scored.count)):")
        for (i, c) in candidates.prefix(10).enumerated() {
            let hub = graph.outgoing(from: c.nodeID).count
            let elev = graph.nodes[c.nodeID].map { String(format: "%.0fm", $0.elevation) } ?? "?"
            let name = naming.nodeLabel(c.nodeID, style: .canonical)
            SolverLog.debug("[SOLVER]  \(i+1). \(c.nodeID) score=\(String(format: "%.1f", c.score)) (tA=\(String(format: "%.1f", c.timeA)) tB=\(String(format: "%.1f", c.timeB))) hub=\(hub) elev=\(elev) \"\(name)\"")
        }

        guard let best = candidates.first,
              let bestNode = graph.nodes[best.nodeID] else { return nil }

        let pathA = reconstructPath(from: effectiveA, to: best.nodeID, dist: distA)
        let pathB = reconstructPath(from: effectiveB, to: best.nodeID, dist: distB)

        // ── Diverse alternates: geographic minimum spacing ──
        let alts = diverseAlternates(
            from: candidates.dropFirst(),
            bestNode: bestNode,
            positionA: effectiveA,
            positionB: effectiveB,
            distA: distA,
            distB: distB,
            count: SolverConstants.Alternates.twoSkierAlternateCount
        )

        SolverLog.debug("[SOLVER] Best: \(best.nodeID) \"\(naming.nodeLabel(best.nodeID, style: .canonical))\" tA=\(String(format: "%.1f", best.timeA))s tB=\(String(format: "%.1f", best.timeB))s | \(alts.count) alternates")

        // Stddev = sqrt(varianceTime) for each side. Solver-side
        // population means every result (primary + alternates from
        // forced-open / neighbor-substitution fallbacks) carries the
        // uncertainty surface for the cards, replacing the post-hoc
        // path-variance helper that previously ran in MeetView.
        let stdA = best.varA > 0 ? best.varA.squareRoot() : 0
        let stdB = best.varB > 0 ? best.varB.squareRoot() : 0

        let result = MeetingResult(
            meetingNode: bestNode, pathA: pathA, pathB: pathB,
            timeA: best.timeA, timeB: best.timeB, alternates: alts,
            routeReasonA: nil, routeReasonB: nil,
            etaStdSecondsA: stdA, etaStdSecondsB: stdB
        )
        Self.solutionCache.set(result, for: cacheKey)
        return result
    }

    /// Compact string signature for a TraversalContext. Used in cache keys so
    /// two solves that bucketise to the same environmental context hit the
    /// same cached result. We deliberately omit `solveTime` here: callers
    /// quantize it to a 15-minute bucket upstream, and including the raw
    /// second-precision timestamp would defeat that bucketing (every solve
    /// 1+ second apart would miss the cache).
    private static func contextSignature(_ c: TraversalContext) -> String {
        let lat = c.latitude.map { String(format: "%.3f", $0) } ?? "-"
        let lon = c.longitude.map { String(format: "%.3f", $0) } ?? "-"
        return "lat=\(lat) lon=\(lon) T=\(String(format: "%.1f", c.temperatureCelsius)) E=\(String(format: "%.0f", c.stationElevationM)) W=\(String(format: "%.1f", c.windSpeedKmh)) V=\(String(format: "%.1f", c.visibilityKm)) S=\(String(format: "%.0f", c.freshSnowCm)) C=\(c.cloudCoverPercent)"
    }

    // MARK: - Diverse Alternates

    /// Maps a `liftBase`/`liftTop` node to the lift edge it terminates.
    /// Used by the lift-served-zone clustering: two candidate nodes that
    /// resolve to the same lift edge belong to the same behavioral zone
    /// (a skier riding *that* lift hits both), so we keep at most one of
    /// them as an alternate. Multiple lifts sharing a base resolve
    /// deterministically to the lift with the smallest edge ID.
    private func buildLiftZoneNodeMap() -> [String: String] {
        var liftBaseToEdge: [String: String] = [:]
        var liftTopToEdge: [String: String] = [:]
        for edge in graph.edges where edge.kind == .lift {
            if let existing = liftBaseToEdge[edge.sourceID] {
                if edge.id < existing { liftBaseToEdge[edge.sourceID] = edge.id }
            } else {
                liftBaseToEdge[edge.sourceID] = edge.id
            }
            if let existing = liftTopToEdge[edge.targetID] {
                if edge.id < existing { liftTopToEdge[edge.targetID] = edge.id }
            } else {
                liftTopToEdge[edge.targetID] = edge.id
            }
        }
        var combined = liftBaseToEdge
        for (node, edgeID) in liftTopToEdge where combined[node] == nil {
            combined[node] = edgeID
        }
        return combined
    }

    /// Last lift edge ID along the Dijkstra-recovered path from `start`
    /// to `nodeID`. Returns `nil` for paths with no lift segment (e.g.
    /// pure-traverse routes between adjacent peaks). Walks the parent
    /// chain backwards so we don't need to materialise the full path
    /// just to inspect its lifts.
    private func lastLiftEdgeID(
        to nodeID: String,
        from start: String,
        dist: [String: DijkstraEntry]
    ) -> String? {
        var current = nodeID
        while current != start {
            guard let entry = dist[current], let edgeID = entry.viaEdgeID,
                  let prev = entry.previousNodeID else { return nil }
            if let edge = graph.edge(byID: edgeID), edge.kind == .lift {
                return edge.id
            }
            current = prev
        }
        return nil
    }

    /// Lift-served-zone cluster key for a candidate. Direct membership
    /// (node IS a lift base / top) wins; otherwise we attribute the
    /// candidate to the last lift in the path that fed it. Falls back
    /// to a 150m euclidean grid bucket when no lift relationship exists
    /// (mid-trail cat-tracks, traverse-only resorts) so unservable
    /// graphs still produce spread-out alternates.
    private func clusterKey(
        for nodeID: String,
        node: GraphNode,
        liftZoneMap: [String: String],
        lastLiftOnPath: String?
    ) -> String {
        if let edgeID = liftZoneMap[nodeID] { return "lift:\(edgeID)" }
        if let edgeID = lastLiftOnPath { return "lift:\(edgeID)" }
        let latBucket = (node.coordinate.latitude * 1000).rounded() / 10
        let lonBucket = (node.coordinate.longitude * 1000).rounded() / 10
        return "euc:\(latBucket):\(lonBucket)"
    }

    /// Pick up to `count` alternates with progressive geographic
    /// diversity. Walks the `pairwiseDistanceLadderMeters` ladder
    /// strict-to-loose: try to fill all slots with alternates
    /// ≥ladder[0] metres apart (haversine) from the primary and from
    /// each previously-chosen alternate; if fewer than `count`
    /// candidates qualify, relax to the next ladder rung. Lift-zone
    /// + 150 m grid clustering applies at every rung except the
    /// final no-constraint fallback. Earlier the only diversity
    /// constraint was lift-zone clustering, which is *semantic*
    /// (one per lift) rather than *geographic* — a resort with three
    /// parallel chairs to the same peak yielded three alternates in
    /// the same drainage basin. The haversine gate spreads alternates
    /// across the mountain instead.
    private func diverseAlternates(
        from candidates: ArraySlice<(nodeID: String, score: Double, timeA: Double, timeB: Double, varA: Double, varB: Double)>,
        bestNode: GraphNode,
        positionA: String,
        positionB: String,
        distA: [String: DijkstraEntry],
        distB: [String: DijkstraEntry],
        count: Int
    ) -> [AlternateMeeting] {

        let liftZoneMap = buildLiftZoneNodeMap()
        let ladder = SolverConstants.Alternates.pairwiseDistanceLadderMeters

        // Walk the ladder. Return as soon as a rung produces `count`
        // alternates; otherwise try the next-looser rung.
        for minDistM in ladder {
            let attempt = pickAlternates(
                from: candidates,
                bestNode: bestNode,
                positionA: positionA,
                positionB: positionB,
                distA: distA,
                distB: distB,
                count: count,
                minPairwiseDistanceMeters: minDistM,
                liftZoneMap: liftZoneMap
            )
            if attempt.count >= count {
                return attempt
            }
        }

        // Last resort: drop ALL diversity constraints (haversine AND
        // cluster). Score-sorted, dedup by node id only. Reached only
        // on graphs too small / sparse to satisfy any rung — same
        // shape as the prior fallback so behaviour on tiny resorts is
        // preserved.
        var result: [AlternateMeeting] = []
        for item in candidates {
            guard result.count < count else { break }
            guard let node = graph.nodes[item.nodeID] else { continue }
            if node.id == bestNode.id { continue }
            if result.contains(where: { $0.node.id == item.nodeID }) { continue }

            let altPathA = reconstructPath(from: positionA, to: item.nodeID, dist: distA)
            let altPathB = reconstructPath(from: positionB, to: item.nodeID, dist: distB)
            result.append(AlternateMeeting(node: node, pathA: altPathA, pathB: altPathB, timeA: item.timeA, timeB: item.timeB))
        }
        return result
    }

    /// One pass at filling `count` alternates given a specific
    /// minimum-pairwise-distance threshold. Helper for the ladder
    /// in `diverseAlternates`. Lift-zone / grid clustering always
    /// applies; the haversine gate is skipped when
    /// `minPairwiseDistanceMeters == 0` (matching the original
    /// behaviour for the bottom of the ladder).
    private func pickAlternates(
        from candidates: ArraySlice<(nodeID: String, score: Double, timeA: Double, timeB: Double, varA: Double, varB: Double)>,
        bestNode: GraphNode,
        positionA: String,
        positionB: String,
        distA: [String: DijkstraEntry],
        distB: [String: DijkstraEntry],
        count: Int,
        minPairwiseDistanceMeters: Double,
        liftZoneMap: [String: String]
    ) -> [AlternateMeeting] {

        var seenClusters: Set<String> = []
        let bestLastLift = lastLiftEdgeID(to: bestNode.id, from: positionA, dist: distA)
        seenClusters.insert(clusterKey(
            for: bestNode.id, node: bestNode,
            liftZoneMap: liftZoneMap, lastLiftOnPath: bestLastLift
        ))
        // Seed the picked-coords list with the primary so the haversine
        // gate evaluates alternates against IT as well as against
        // already-picked alternates.
        var pickedCoords: [CLLocationCoordinate2D] = [bestNode.coordinate]
        var result: [AlternateMeeting] = []

        for item in candidates {
            guard result.count < count else { break }
            guard let node = graph.nodes[item.nodeID] else { continue }
            if node.id == bestNode.id { continue }

            let lastLift = lastLiftEdgeID(to: item.nodeID, from: positionA, dist: distA)
            let key = clusterKey(
                for: item.nodeID, node: node,
                liftZoneMap: liftZoneMap, lastLiftOnPath: lastLift
            )
            if seenClusters.contains(key) { continue }

            // Haversine pairwise gate. Skipped when threshold is 0
            // so the bottom of the ladder degrades to lift-zone-only.
            if minPairwiseDistanceMeters > 0 {
                let coord = node.coordinate
                let tooClose = pickedCoords.contains { existing in
                    Self.haversineMeters(existing, coord) < minPairwiseDistanceMeters
                }
                if tooClose { continue }
            }

            seenClusters.insert(key)
            pickedCoords.append(node.coordinate)

            let altPathA = reconstructPath(from: positionA, to: item.nodeID, dist: distA)
            let altPathB = reconstructPath(from: positionB, to: item.nodeID, dist: distB)
            result.append(AlternateMeeting(node: node, pathA: altPathA, pathB: altPathB, timeA: item.timeA, timeB: item.timeB))
        }

        return result
    }

    /// Haversine distance in metres between two `CLLocationCoordinate2D`
    /// values. Mirrors the file-scope `haversine(from:to:)` in
    /// `Models/Resort.swift` (which takes a different coordinate
    /// struct); duplicated here so the solver doesn't depend on the
    /// `Coordinate` wrapper. `nonisolated static` so it's safely
    /// callable from any actor context (the solver's hot path can
    /// run detached).
    nonisolated static func haversineMeters(
        _ a: CLLocationCoordinate2D,
        _ b: CLLocationCoordinate2D
    ) -> Double {
        let R = 6_371_000.0
        let dLat = (b.latitude - a.latitude) * .pi / 180
        let dLon = (b.longitude - a.longitude) * .pi / 180
        let lat1 = a.latitude * .pi / 180
        let lat2 = b.latitude * .pi / 180
        let x = sin(dLat / 2) * sin(dLat / 2)
              + cos(lat1) * cos(lat2) * sin(dLon / 2) * sin(dLon / 2)
        let c = 2 * atan2(sqrt(x), sqrt(1 - x))
        return R * c
    }

    // MARK: - N-Skier Solve (Enhanced)

    func solve(
        skiers: [(profile: UserProfile, positionNodeID: String)]
    ) -> MeetingResultN? {
        lastFailureReason = nil
        guard !skiers.isEmpty else { return nil }

        SolverLog.debug("[SOLVER] N-skier solve with \(skiers.count) skiers")
        SolverLog.debug("[SOLVER] Graph: \(graphFingerprint())")
        for (i, s) in skiers.enumerated() {
            SolverLog.debug("[SOLVER] Skier \(i): pos=\(s.positionNodeID) \(Self.profileFingerprint(s.profile))")
        }

        // Per-skier contexts so each skier's edge weights consult
        // their own per-edge history. Pre-build a small lookup so we
        // don't rebuild the context inside the dead-end loop.
        let skierContexts: [String: TraversalContext] = Dictionary(
            uniqueKeysWithValues: skiers.map { ($0.profile.id.uuidString, buildContext(for: $0.profile.id.uuidString)) }
        )
        func ctx(for skierID: String) -> TraversalContext {
            skierContexts[skierID] ?? buildContext()
        }

        // ── Pre-solve dead-end detection ──
        var effectiveSkiers = skiers
        var escapeTimes: [Double] = Array(repeating: 0, count: skiers.count)

        for (i, skier) in skiers.enumerated() {
            let context = ctx(for: skier.profile.id.uuidString)
            let usable = graph.outgoing(from: skier.positionNodeID).contains {
                skier.profile.traverseTime(for: $0, context: context) != nil
            }
            if !usable {
                if let escape = graph.findEscapeNode(from: skier.positionNodeID, profile: skier.profile, context: context) {
                    SolverLog.debug("[SOLVER] Skier \(i) at dead-end \(skier.positionNodeID) — redirecting to \(escape.nodeID) (+\(String(format: "%.0f", escape.walkTime))s)")
                    effectiveSkiers[i] = (skier.profile, escape.nodeID)
                    escapeTimes[i] = escape.walkTime
                } else {
                    SolverLog.debug("[SOLVER] Skier \(i) at dead-end \(skier.positionNodeID) — no escape")
                    lastFailureReason = .skierAtDeadEnd(skierName: skier.profile.displayName)
                    return nil
                }
            }
        }

        // Run Dijkstra from each skier's effective position
        let dijkstraResults = effectiveSkiers.map { dijkstra(from: $0.positionNodeID, skier: $0.profile) }

        for (i, d) in dijkstraResults.enumerated() {
            SolverLog.debug("[SOLVER] Dijkstra[\(i)] reached \(d.count) nodes")
        }

        // Intersect reachable node sets
        var reachable = Set(dijkstraResults[0].keys)
        for result in dijkstraResults.dropFirst() {
            reachable.formIntersection(result.keys)
        }
        guard !reachable.isEmpty else {
            SolverLog.debug("[SOLVER] No reachable intersection — returning nil")
            lastFailureReason = .noReachableIntersection
            return nil
        }
        SolverLog.debug("[SOLVER] Reachable intersection: \(reachable.count) nodes")

        // Precompute elevation range
        let elevations = reachable.compactMap { graph.nodes[$0]?.elevation }
        let minElev = elevations.min() ?? 0
        let maxElev = elevations.max() ?? 0
        let elevRange = maxElev - minElev

        // Compute time range for scaling secondary factors
        let allMaxTimes: [Double] = reachable.compactMap { nodeID in
            let rawTimes = dijkstraResults.compactMap { $0[nodeID]?.time }
            guard rawTimes.count == skiers.count else { return nil }
            let times = zip(rawTimes, escapeTimes).map { $0 + $1 }
            return times.max()
        }
        let nTimeRange = (allMaxTimes.max() ?? 0) - (allMaxTimes.min() ?? 0)
        let nSecondaryScale = min(
            SolverConstants.Scoring.secondaryFactorMaxSeconds,
            max(SolverConstants.Scoring.secondaryFactorMinSeconds,
                nTimeRange * SolverConstants.Scoring.secondaryFactorScalePercent)
        )

        // Multi-factor scoring
        let allScored: [(nodeID: String, score: Double, times: [Double])] = reachable.compactMap { nodeID in
            let rawTimes = dijkstraResults.compactMap { $0[nodeID]?.time }
            guard rawTimes.count == skiers.count else { return nil }
            // Add escape walk times for skiers redirected from dead-ends
            let times = zip(rawTimes, escapeTimes).map { $0 + $1 }

            // Factor 1: Time score (see 2-skier branch for wait-penalty rationale)
            let waitPenaltyAlpha = SolverConstants.Scoring.waitPenaltyAlpha
            let maxT = times.max() ?? 0
            let minT = times.min() ?? 0
            let timeScore = maxT + waitPenaltyAlpha * (maxT - minT)

            // Factor 2: Hub quality
            let hubCount = Double(graph.outgoing(from: nodeID).count)
            let hubBonus = -min(hubCount / SolverConstants.Scoring.hubBonusDivisor, 1.0) * nSecondaryScale

            // Factor 3: Elevation band — prefer mid-mountain over base
            var elevPenalty = 0.0
            if let nodeElev = graph.nodes[nodeID]?.elevation, elevRange > 100 {
                let norm = (nodeElev - minElev) / elevRange
                if norm < SolverConstants.Scoring.elevPenaltyBaseThreshold {
                    elevPenalty = nSecondaryScale * SolverConstants.Scoring.elevPenaltyBaseArea
                } else if norm > SolverConstants.Scoring.elevPenaltySummitThreshold {
                    elevPenalty = nSecondaryScale * SolverConstants.Scoring.elevPenaltySummit
                }
            }

            // Factor 4: Landmark bonus
            let landmarkBonus: Double = {
                guard let kind = graph.nodes[nodeID]?.kind else { return 0 }
                switch kind {
                case .liftBase, .liftTop, .midStation:
                    return -nSecondaryScale * SolverConstants.Scoring.landmarkBonusScale
                default: return 0
                }
            }()

            return (nodeID, timeScore + hubBonus + elevPenalty + landmarkBonus, times)
        }.sorted(by: { a, b in
            if a.score != b.score { return a.score < b.score }
            return a.nodeID < b.nodeID
        })

        // Hard imbalance filter
        let maxImbalanceSeconds = SolverConstants.Scoring.maxImbalanceSeconds
        let balancedN = allScored.filter { item in
            let spread = (item.times.max() ?? 0) - (item.times.min() ?? 0)
            return spread <= maxImbalanceSeconds
        }
        let scored = balancedN.isEmpty ? allScored : balancedN

        // Debug: top 10
        let nNaming = MountainNaming(graph)
        SolverLog.debug("[SOLVER] Top N-skier candidates (\(scored.count) after filters):")
        for (i, c) in scored.prefix(10).enumerated() {
            let timesStr = c.times.map { String(format: "%.1f", $0) }.joined(separator: ",")
            let name = nNaming.nodeLabel(c.nodeID, style: .canonical)
            SolverLog.debug("[SOLVER]  \(i+1). \(c.nodeID) score=\(String(format: "%.1f", c.score)) times=[\(timesStr)] \"\(name)\"")
        }

        guard let best = scored.first,
              let bestNode = graph.nodes[best.nodeID] else { return nil }

        // Reconstruct paths
        let paths: [(skier: UserProfile, path: [GraphEdge], time: Double)] = zip(effectiveSkiers, zip(dijkstraResults, best.times)).map { skier, pair in
            let (dist, time) = pair
            let path = reconstructPath(from: skier.positionNodeID, to: best.nodeID, dist: dist)
            return (skier: skier.profile, path: path, time: time)
        }

        // Lift-served-zone alternates for N-skier. Path-attribution uses
        // the first skier's Dijkstra result; "the lift that fed this
        // candidate" is shared across the group whenever a lift is the
        // load-bearing reason a candidate is reachable, so attributing
        // by skier 0 still produces meaningful per-zone deduping.
        let liftZoneMap = buildLiftZoneNodeMap()
        let probeStart = effectiveSkiers[0].positionNodeID
        let probeDist = dijkstraResults[0]
        var seenClusters: Set<String> = []
        let bestLastLift = lastLiftEdgeID(to: bestNode.id, from: probeStart, dist: probeDist)
        seenClusters.insert(clusterKey(
            for: bestNode.id, node: bestNode,
            liftZoneMap: liftZoneMap, lastLiftOnPath: bestLastLift
        ))

        var alts: [AlternateMeetingN] = []
        for item in scored.dropFirst() {
            guard alts.count < SolverConstants.Alternates.nSkierAlternateCount else { break }
            guard let node = graph.nodes[item.nodeID] else { continue }
            let lastLift = lastLiftEdgeID(to: item.nodeID, from: probeStart, dist: probeDist)
            let key = clusterKey(
                for: item.nodeID, node: node,
                liftZoneMap: liftZoneMap, lastLiftOnPath: lastLift
            )
            if seenClusters.contains(key) { continue }
            seenClusters.insert(key)
            alts.append(AlternateMeetingN(node: node, times: item.times))
        }
        let targetAlternates = SolverConstants.Alternates.nSkierAlternateCount
        if alts.count < targetAlternates {
            for item in scored.dropFirst() {
                guard alts.count < targetAlternates else { break }
                if alts.contains(where: { $0.node.id == item.nodeID }) { continue }
                guard let node = graph.nodes[item.nodeID] else { continue }
                alts.append(AlternateMeetingN(node: node, times: item.times))
            }
        }

        SolverLog.debug("[SOLVER] N-skier best: \(best.nodeID) \"\(nNaming.nodeLabel(best.nodeID, style: .canonical))\" | \(alts.count) alternates")

        return MeetingResultN(meetingNode: bestNode, paths: paths, alternates: alts)
    }

    // MARK: - Dijkstra (Binary Heap)

    private struct DijkstraEntry {
        let time: Double
        /// Sum of per-edge time variance (s²) along the path from
        /// `startNodeID` to this node. Treats edges as independent —
        /// reasonable approximation given that the dominant
        /// uncertainty sources (lift queues, weather effects on
        /// run speed) decorrelate across the topology distances we
        /// route over. Var(sum) = Σ Var(edge), so the path's stddev
        /// is `sqrt(varianceTime)`. Drives the CVaR-aware scoring
        /// in the candidate loop and the ETA-range UI.
        let varianceTime: Double
        let previousNodeID: String?
        let viaEdgeID: String?
    }

    /// Per-edge time variance in s². Combines observation variance
    /// from `profile_edge_speeds` (delta-method conversion of speed
    /// variance to time variance) with a coefficient-of-variation
    /// fallback for edges with no recorded data:
    /// - Observed (≥3 samples, var > 0): `Var(t) ≈ (t/v)² · Var(v)`.
    /// - Run, no observation: `(0.15 · t)²` — 15% CV.
    /// - Lift, no observation: `(0.30 · t)²` — 30% CV; queue
    ///   volatility is the dominant uncertainty source.
    /// - Traverse, no observation: `(0.10 · t)²` — flat traverses
    ///   are the most predictable.
    private static func edgeTimeVariance(
        traverseTime: Double,
        edge: GraphEdge,
        observation: PerEdgeSpeed?
    ) -> Double {
        guard traverseTime > 0 else { return 0 }
        if let obs = observation,
           obs.observationCount >= TraversalContext.edgeHistoryMinObservations,
           obs.rollingSpeedMs > 0,
           obs.rollingSpeedVarianceMs2 > 0 {
            // Delta method: σ_t ≈ (t/v) · σ_v ; Var(t) = (t/v)² · Var(v).
            let ratio = traverseTime / obs.rollingSpeedMs
            return (ratio * ratio) * obs.rollingSpeedVarianceMs2
        }
        let cv: Double
        switch edge.kind {
        case .lift:     cv = 0.30
        case .run:      cv = 0.15
        case .traverse: cv = 0.10
        }
        let std = traverseTime * cv
        return std * std
    }

    private func dijkstra(
        from startNodeID: String,
        skier: UserProfile,
        earlyExitTarget: String? = nil,
        ignoreSkillGates: Bool = false
    ) -> [String: DijkstraEntry] {
        // Per-skier context so this skier's edge weights consult
        // their own per-edge history (set via
        // `edgeSpeedHistoryByProfile[skier.id]`); falls back to the
        // shared `edgeSpeedHistory` for single-skier callers that
        // never set the per-skier dict.
        let context = buildContext(for: skier.id.uuidString)
        var dist: [String: DijkstraEntry] = [:]
        var visited: Set<String> = []
        var heap = BinaryHeap<(nodeID: String, time: Double)> { $0.time < $1.time }

        dist[startNodeID] = DijkstraEntry(
            time: 0, varianceTime: 0, previousNodeID: nil, viaEdgeID: nil
        )
        heap.insert((startNodeID, 0))

        while let current = heap.extractMin() {
            // Lazy deletion: skip if already visited (stale entry)
            guard !visited.contains(current.nodeID) else { continue }
            visited.insert(current.nodeID)

            // Single-target early exit: once we pop the target, its distance
            // is finalised (Dijkstra invariant) — bail so we skip the rest
            // of the graph. Only applied by `pathTo(...)`; the multi-target
            // meet-solve still walks the full graph to populate every
            // candidate meeting node.
            if current.nodeID == earlyExitTarget { break }

            // Pull the cumulative variance for the current node BEFORE
            // walking outgoing edges so each relaxation reads from a
            // consistent snapshot.
            let cumulativeVariance = dist[current.nodeID]?.varianceTime ?? 0

            // Normal outgoing edges (runs, lifts up, traverses).
            // `arrivalTimeOffsetSeconds: current.time` makes lift waits
            // and lift-hours gating evaluate at the time the skier will
            // *arrive* at this edge, not at solve time. Without it, a
            // 14-minute path to a busy lift uses the now-wait instead
            // of the now+14-min wait, and the recommendation can land
            // the user in a queue that grew while they were skiing
            // toward it — or a lift that closed during their approach.
            for edge in graph.outgoing(from: current.nodeID) {
                guard let traverseTime = skier.traverseTime(
                    for: edge,
                    context: context,
                    ignoreSkillGates: ignoreSkillGates,
                    arrivalTimeOffsetSeconds: current.time
                ) else { continue }

                let newTime = current.time + traverseTime

                if let existing = dist[edge.targetID] {
                    if existing.time < newTime { continue }
                    // Deterministic tie-break: on equal time, prefer the
                    // lexicographically smaller viaEdgeID. Without this two
                    // devices can pick different paths under equal-time ties,
                    // which leaks into the meeting-node score and can land
                    // them at different nodes.
                    if existing.time == newTime {
                        if let existingEdge = existing.viaEdgeID, existingEdge <= edge.id { continue }
                    }
                }

                // Per-edge variance (s²). Independence assumption gives
                // Var(path) = Σ Var(edge); the cumulative variance to
                // this target is the parent's variance plus this edge's.
                let edgeVariance = Self.edgeTimeVariance(
                    traverseTime: traverseTime,
                    edge: edge,
                    observation: context.observation(for: edge)
                )
                let newVariance = cumulativeVariance + edgeVariance

                dist[edge.targetID] = DijkstraEntry(
                    time: newTime,
                    varianceTime: newVariance,
                    previousNodeID: current.nodeID,
                    viaEdgeID: edge.id
                )
                heap.insert((edge.targetID, newTime))
            }

        }

        return dist
    }

    // MARK: - Single-Target Pathfinding

    /// Find the shortest path and time for a single skier to a specific target node.
    /// Used when the meeting node is already agreed upon (e.g., accepted meet request).
    /// `ignoreSkillGates: true` lets meet-accept fallback solves succeed when the
    /// receiver's profile is stricter than what the sender computed against — without
    /// it, the receiver lands on the empty-path branch ("activateRoute(receiver):
    /// fallback solve returned nil") and sees no nav HUD.
    func pathTo(
        target: String,
        from start: String,
        skier: UserProfile,
        ignoreSkillGates: Bool = false
    ) -> (path: [GraphEdge], time: Double)? {
        let dist = dijkstra(from: start, skier: skier, earlyExitTarget: target, ignoreSkillGates: ignoreSkillGates)
        guard let entry = dist[target] else { return nil }
        let path = reconstructPath(from: start, to: target, dist: dist)
        return (path, entry.time)
    }

    // MARK: - Path Reconstruction

    private func reconstructPath(from start: String, to end: String, dist: [String: DijkstraEntry]) -> [GraphEdge] {
        var path: [GraphEdge] = []
        var current = end

        while current != start {
            guard let entry = dist[current], let edgeID = entry.viaEdgeID,
                  let prevNode = entry.previousNodeID else { break }
            if let edge = graph.edge(byID: edgeID) {
                path.insert(edge, at: 0)
            }
            current = prevNode
        }

        return path
    }

    // MARK: - Coordinate Distance

    /// Squared distance between two coordinates in degrees² (for comparison only).
    private func coordDistSq(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        let dlat = a.latitude - b.latitude
        let dlon = a.longitude - b.longitude
        return dlat * dlat + dlon * dlon
    }
}
