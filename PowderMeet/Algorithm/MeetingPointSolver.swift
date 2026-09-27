//
//  MeetingPointSolver.swift
//  PowderMeet
//
//  Finds the optimal explicit rendezvous point for N skiers. Routing may pass
//  through any eligible graph node, but termination is restricted to the
//  dataset's validated `RendezvousCatalog`. Candidates are ranked by the
//  reliability-first safety/product objective in `RendezvousRank`.
//
//  All floating-point inputs (time, weather) are normalized to coarse
//  buckets so that two devices solving independently produce identical
//  results even with minor timing or fetch-order differences.
//

import Foundation
import CoreLocation

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
    private let rendezvousCatalog: RendezvousCatalog

    private struct RankedCandidate {
        let point: RendezvousPoint
        let rank: RendezvousRank
        let timeA: Double
        let timeB: Double
        let varA: Double
        let varB: Double
        let labelIDA: Int
        let labelIDB: Int
        let sharedContinuation: SharedContinuation?

        var nodeID: String { point.nodeID }
    }

    private struct RankedCandidateN {
        let point: RendezvousPoint
        let rank: RendezvousRank
        let times: [Double]

        var nodeID: String { point.nodeID }
    }

    /// A shallow post-meet route whose first edge is the action shown in the
    /// option card and whose accumulated run geometry proves that the group can
    /// reach worthwhile downhill terrain together. Kept internal because the
    /// accepted meetup still ends at the rendezvous; this is ranking evidence,
    /// not a silently appended navigation route.
    private struct SharedContinuationPath {
        let firstEdge: GraphEdge
        let edgeIDs: [String]
        let sharedRunLengthMeters: Double
        let sharedVerticalDropMeters: Double
        let groupCompletionSeconds: Double
        /// Group time from the rendezvous until the first mutually legal run
        /// begins. Includes connector travel, lift ride, and the same live or
        /// modeled queue time used by normal route traversal.
        let downhillAccessSeconds: Double
        /// Length-weighted pace fit of the least comfortable skier on each run
        /// edge, after terrain, conditions, learned pace, and skis are modeled.
        let jointTerrainFit: Double
        /// Changes between physical action types (for example lift → run), not
        /// raw edge boundaries. Splitting one trail into several canonical
        /// segments must not make the same ski corridor look worse.
        let actionTransitionCount: Int
        /// Stable identity of the first run reached by this rollout. Used to
        /// measure real route choice without counting canonical segments.
        let runOptionIdentity: String

        var utility: Double {
            SharedLapUtility.score(
                runLengthMeters: sharedRunLengthMeters,
                verticalDropMeters: sharedVerticalDropMeters,
                actionTransitionCount: actionTransitionCount,
                downhillAccessSeconds: downhillAccessSeconds,
                jointTerrainFit: jointTerrainFit
            )
        }
    }

    /// Set after `solve()` returns nil — provides a structured reason for the failure.
    private(set) var lastFailureReason: SolveFailureReason?

    /// Optional time-of-day for sun exposure and lift hours.
    var solveTime: Date?
    /// Resort latitude for solar position calculations.
    var resortLatitude: Double?
    /// Resort longitude for solar noon correction.
    var resortLongitude: Double?
    /// Resort-local offset returned by the weather feed, including DST.
    var resortUTCOffsetSeconds: Int?
    /// Resort-wide operating window from reviewed bundled data. Unknown
    /// resorts retain the conservative legacy 07:00–21:00 bounds.
    var liftOpenHour: Int = TraversalConstants.Lift.minSafeHour
    var liftCloseHour: Int = TraversalConstants.Lift.maxSafeHour
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
    /// Hourly resort forecast. Quantized and bounded by `buildContext` before
    /// it can influence edge weights or cache identity.
    var hourlyWeather: [HourlyCondition] = []
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
    /// Per-skier selected equipment snapshot. Missing entry means neutral
    /// physics; equipment never changes route eligibility.
    var equipmentByProfile: [String: SkiPerformanceProfile] = [:]
    /// Immutable dataset identity corresponding to `graph`.
    var datasetVersion: String?

    init(graph: MountainGraph, rendezvousCatalog: RendezvousCatalog? = nil) {
        self.graph = graph
        self.rendezvousCatalog = rendezvousCatalog ?? .derived(from: graph)
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

        // Round solve time down to the current one-minute window.
        // Both devices in the same minute get identical time-dependent costs.
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
        let normalizedTemperature = (temperatureC / tempStep).rounded() * tempStep
        let normalizedElevation = (stationElevationM / elevStep).rounded() * elevStep
        let normalizedWind = (windSpeedKmh / windStep).rounded() * windStep
        let normalizedVisibility = (visibilityKm / visStep).rounded() * visStep
        let normalizedCloud = max(0, min(100, ((cloudCoverPercent + 5) / 10) * 10))
        let normalizedHourlyWeather: [TraversalContext.WeatherSample] = {
            guard let normalizedTime else { return [] }
            let earliest = normalizedTime.addingTimeInterval(-2 * 60 * 60)
            let latest = normalizedTime.addingTimeInterval(12 * 60 * 60)
            var seenTimes = Set<Int64>()
            var samples: [TraversalContext.WeatherSample] = hourlyWeather
                .sorted { $0.time < $1.time }
                .compactMap { sample -> TraversalContext.WeatherSample? in
                    guard sample.time >= earliest, sample.time <= latest else { return nil }
                    let timestamp = Int64(sample.time.timeIntervalSinceReferenceDate.rounded())
                    guard seenTimes.insert(timestamp).inserted else { return nil }
                    return TraversalContext.WeatherSample(
                        time: Date(timeIntervalSinceReferenceDate: Double(timestamp)),
                        temperatureCelsius: (sample.temperatureC / tempStep).rounded() * tempStep,
                        windSpeedKmh: (sample.windSpeedKph / windStep).rounded() * windStep,
                        visibilityKm: (sample.visibilityKm / visStep).rounded() * visStep,
                        cloudCoverPercent: max(
                            0,
                            min(100, ((sample.cloudCoverPercent + 5) / 10) * 10)
                        ),
                        snowfallCm: max(0, (sample.snowfallCm * 10).rounded() / 10)
                    )
                }
            // The current block is fresher than the hourly series. Anchor the
            // curve at the quantized solve instant so forecast interpolation
            // begins from observed now rather than replacing it with the
            // nearest coarser hourly sample.
            samples.removeAll { $0.time == normalizedTime }
            samples.append(TraversalContext.WeatherSample(
                time: normalizedTime,
                temperatureCelsius: normalizedTemperature,
                windSpeedKmh: normalizedWind,
                visibilityKm: normalizedVisibility,
                cloudCoverPercent: normalizedCloud,
                snowfallCm: 0
            ))
            return samples.sorted { $0.time < $1.time }
        }()

        return TraversalContext(
            solveTime: normalizedTime,
            latitude: resortLatitude,
            longitude: resortLongitude,
            utcOffsetSeconds: resortUTCOffsetSeconds,
            liftOpenHour: liftOpenHour,
            liftCloseHour: liftCloseHour,
            temperatureCelsius: normalizedTemperature,
            stationElevationM: normalizedElevation,
            windSpeedKmh: normalizedWind,
            visibilityKm: normalizedVisibility,
            freshSnowCm: freshSnowCm.rounded(),                  // 1 cm steps
            // Quantize cloud cover to the nearest 10% — matches the
            // granularity of the upstream weather feed and keeps the
            // value Int. Without this, two devices that fetched
            // weather a few seconds apart could disagree on a single
            // percent and produce different cached solves.
            cloudCoverPercent: normalizedCloud,
            hourlyWeather: normalizedHourlyWeather,
            edgeSpeedHistory: history,
            datasetVersion: datasetVersion,
            equipment: skierID.flatMap { equipmentByProfile[$0] }
        )
    }

    // MARK: - Debug Fingerprinting

    /// Content-complete routing fingerprint. MountainGraph covers every node,
    /// edge, and routing attribute—including mutable open state and live lift
    /// waits. The former open-ID-only checksum returned cached routes after a
    /// queue changed because all edges remained open.
    private func graphFingerprint() -> String {
        graph.fingerprint
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
        return "\(p.skillLevel) ski=\(p.preferredSkiId?.uuidString ?? "-") spd=[\(spd)] m=\(String(format: "%.2f", p.conditionMoguls)) u=\(String(format: "%.2f", p.conditionUngroomed)) i=\(String(format: "%.2f", p.conditionIcy)) g=\(String(format: "%.2f", p.conditionGladed)) \(cont)"
    }

    /// Content-complete fingerprint of the per-edge skill memory. Recency
    /// weighting can change the rolling values without changing row or sample
    /// counts, so a count-only key can return a stale route.
    private static func edgeSpeedHistoryFingerprint(_ history: [String: [String: PerEdgeSpeed]]) -> String {
        PerEdgeSpeed.historyFingerprint(history)
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
        SolverLog.debug("[SOLVER] EquipmentA: \(ctxA.equipment?.fingerprint ?? "neutral")")
        SolverLog.debug("[SOLVER] EquipmentB: \(ctxB.equipment?.fingerprint ?? "neutral")")
        SolverLog.debug("[SOLVER] Context: temp=\(ctxA.temperatureCelsius)°C wind=\(ctxA.windSpeedKmh)km/h vis=\(ctxA.visibilityKm)km snow=\(ctxA.freshSnowCm)cm cloud=\(ctxA.cloudCoverPercent)% time=\(timeStr)")
        SolverLog.debug("[SOLVER] ══════════════════════════════════")
    }

    // MARK: - 2-Skier Solve (Enhanced)

    func solve(
        skierA: UserProfile, positionA: String,
        skierB: UserProfile, positionB: String
    ) -> MeetingResult? {
        solve(
            skierA: skierA,
            originA: .node(positionA),
            skierB: skierB,
            originB: .node(positionB)
        )
    }

    func solve(
        skierA: UserProfile, originA: RoutingOrigin,
        skierB: UserProfile, originB: RoutingOrigin
    ) -> MeetingResult? {
        lastFailureReason = nil

        let positionA = originA.startNodeID
        let positionB = originB.startNodeID

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
        // bucketised (time → 1min, temp/wind/vis/snow → quantised) so
        // close-in-time repeat solves land on the same key. The
        // combined-history fingerprint covers BOTH skiers' histories
        // — invalidates when either side gets fresh per-edge data.
        let combinedHistoryFp = "A:\(Self.edgeSpeedHistoryFingerprint(contextA.edgeSpeedHistory))|B:\(Self.edgeSpeedHistoryFingerprint(contextB.edgeSpeedHistory))"
        let cacheKey = SolverCache.CacheKey(
            graphFingerprint: graphFingerprint(),
            rendezvousFingerprint: rendezvousCatalog.fingerprint,
            positionA: originA.cacheFingerprint,
            positionB: originB.cacheFingerprint,
            profileA: Self.profileFingerprint(skierA),
            profileB: Self.profileFingerprint(skierB),
            contextSignature: "A:\(Self.contextSignature(contextA))"
                + "|B:\(Self.contextSignature(contextB))",
            edgeSpeedHistoryFingerprint: combinedHistoryFp
        )
        if let cached = Self.solutionCache.value(for: cacheKey) {
            SolverLog.debug("[SOLVER] cache hit — returning memoised result")
            return cached
        }

        // ── Pre-solve exact-position validation ──
        // A strict result must start at the supplied graph nodes. The former
        // escape-node substitution silently teleported skiers up to 2 km and
        // still labelled the result `.live`; dead ends now fail honestly and
        // may only appear through the caller's explicit preview attempts.
        let effectiveA = positionA
        let effectiveB = positionB

        let usableA = originIsUsable(originA, skier: skierA, context: contextA)
        if !usableA {
            SolverLog.debug("[SOLVER] Skier A at dead-end \(positionA) — exact start rejected")
            lastFailureReason = originFailureReason(originA, skier: skierA, context: contextA)
            return nil
        }

        let usableB = originIsUsable(originB, skier: skierB, context: contextB)
        if !usableB {
            SolverLog.debug("[SOLVER] Skier B at dead-end \(positionB) — exact start rejected")
            lastFailureReason = originFailureReason(originB, skier: skierB, context: contextB)
            return nil
        }

        // ── Dijkstra from each skier (using effective positions) ──
        let distA = dijkstra(from: effectiveA, skier: skierA, origin: originA)
        let distB = dijkstra(from: effectiveB, skier: skierB, origin: originB)

        // Failure-only diagnostic. Relaxing the P90 deadline gate while
        // preserving mean lift hours, closures, and capability limits proves
        // that a route exists physically but is too fragile near last chair.
        // Keep this lazy so ordinary successful solves pay no second search.
        func deadlineRelaxedRendezvous() -> Set<String> {
            guard solveTime != nil, !rendezvousCatalog.points.isEmpty else {
                return []
            }
            let relaxedA = dijkstra(
                from: effectiveA, skier: skierA, origin: originA,
                ignoreLiftDeadlineRisk: true
            )
            let relaxedB = dijkstra(
                from: effectiveB, skier: skierB, origin: originB,
                ignoreLiftDeadlineRisk: true
            )
            return Set(relaxedA.keys).intersection(Set(relaxedB.keys))
                .intersection(rendezvousCatalog.nodeIDs)
        }

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
            let deadlineRendezvous = deadlineRelaxedRendezvous()
            if !deadlineRendezvous.isEmpty {
                SolverLog.debug("[SOLVER] Last-chair risk blocked \(deadlineRendezvous.count) otherwise reachable rendezvous points")
                lastFailureReason = .liftDeadlineRisk
                return nil
            }
            // Probe whether the failure was purely skill-gated. Re-run
            // Dijkstra for both skiers with the difficulty / glade
            // hard-blocks relaxed (open/closed status still respected).
            // If THAT pass produces a non-empty intersection, the
            // original failure was about skill, not topology — give
            // the user the right copy via .skillGatedPath instead of
            // a generic "no path" message.
            let relaxedA = dijkstra(from: effectiveA, skier: skierA, origin: originA, ignoreSkillGates: true)
            let relaxedB = dijkstra(from: effectiveB, skier: skierB, origin: originB, ignoreSkillGates: true)
            let relaxedRendezvous = Set(relaxedA.keys)
                .intersection(Set(relaxedB.keys))
                .intersection(rendezvousCatalog.nodeIDs)
            if !relaxedRendezvous.isEmpty {
                SolverLog.debug("[SOLVER] Skill-gated failure — relaxed pass found \(relaxedRendezvous.count) eligible rendezvous points")
                lastFailureReason = .skillGatedPath(diagnostics: capabilityDiagnostics(
                    relaxedA: relaxedA,
                    relaxedB: relaxedB,
                    eligibleNodeIDs: relaxedRendezvous,
                    skierA: skierA,
                    skierB: skierB,
                    startA: effectiveA,
                    startB: effectiveB
                ))
            } else {
                SolverLog.debug("[SOLVER] No reachable intersection — returning nil")
                lastFailureReason = rendezvousCatalog.points.isEmpty
                    ? .noEligibleRendezvous
                    : .noReachableRendezvous
            }
            return nil
        }
        SolverLog.debug("[SOLVER] Reachable intersection: \(reachable.count) nodes")

        guard !rendezvousCatalog.points.isEmpty else {
            lastFailureReason = .noEligibleRendezvous
            return nil
        }

        let pointByNode = Dictionary(
            uniqueKeysWithValues: rendezvousCatalog.points.map { ($0.nodeID, $0) }
        )
        let eligibleReachable = reachable.intersection(rendezvousCatalog.nodeIDs)
        guard !eligibleReachable.isEmpty else {
            let deadlineRendezvous = deadlineRelaxedRendezvous()
            if !deadlineRendezvous.isEmpty {
                SolverLog.debug("[SOLVER] Last-chair risk blocked \(deadlineRendezvous.count) otherwise reachable rendezvous points")
                lastFailureReason = .liftDeadlineRisk
                return nil
            }
            // Diagnose an ability-only miss without weakening the real solve.
            // Closed edges remain closed during this probe.
            let relaxedA = dijkstra(from: effectiveA, skier: skierA, origin: originA, ignoreSkillGates: true)
            let relaxedB = dijkstra(from: effectiveB, skier: skierB, origin: originB, ignoreSkillGates: true)
            let relaxedRendezvous = Set(relaxedA.keys)
                .intersection(Set(relaxedB.keys))
                .intersection(rendezvousCatalog.nodeIDs)
            lastFailureReason = relaxedRendezvous.isEmpty
                ? .noReachableRendezvous
                : .skillGatedPath(diagnostics: capabilityDiagnostics(
                    relaxedA: relaxedA,
                    relaxedB: relaxedB,
                    eligibleNodeIDs: relaxedRendezvous,
                    skierA: skierA,
                    skierB: skierB,
                    startA: effectiveA,
                    startB: effectiveB
                ))
            return nil
        }

        // Reliability-first objective:
        //  1. earliest dependable group arrival, combining the latest mean
        //     arrival with wait imbalance, joint ETA uncertainty, and bounded
        //     real-world stop confidence/quality costs
        //  2. earliest latest mean arrival
        //  3. smallest wait spread, then lowest route uncertainty
        //  4. highest catalog confidence and rendezvous quality (also retained
        //     as exact tie-breaks after their bounded score contribution)
        //  5. stable ID (cross-run deterministic tie-break)
        let candidates: [RankedCandidate] = eligibleReachable.compactMap { nodeID in
            guard let point = pointByNode[nodeID],
                  let pair = bestApproachPair(
                    at: nodeID,
                    resultA: distA,
                    resultB: distB
                  ) else { return nil }
            let entryA = pair.a
            let entryB = pair.b

            // Select the two approaches together from their bounded Pareto
            // frontiers. This minimizes dependable *group* arrival rather
            // than throwing away valid labels after optimizing each skier in
            // isolation. The helper excludes material mean-time detours;
            // fairness may choose the rendezvous, never a needlessly long way
            // to the same rendezvous.
            let totalVariance = entryA.varianceTime + entryB.varianceTime
            let latestArrival = max(entryA.time, entryB.time)
            let sharedContinuation = sharedContinuation(
                at: point,
                profiles: [skierA, skierB],
                contexts: [contextA, contextB],
                departureOffsetSeconds: latestArrival
            )
            return RankedCandidate(
                point: point,
                rank: RendezvousRank(
                    latestArrivalSeconds: latestArrival,
                    waitSpreadSeconds: abs(entryA.time - entryB.time),
                    uncertaintySeconds: totalVariance > 0 ? totalVariance.squareRoot() : 0,
                    waitPenaltyAlpha: rendezvousWaitPenaltyAlpha(
                        at: point,
                        context: contextA,
                        arrivalOffsetSeconds: latestArrival
                    ),
                    approachSimplicityPenaltySeconds: pair.simplicityPenaltySeconds,
                    continuationPenalty: sharedContinuationPenalty(
                        at: point,
                        sharedContinuation: sharedContinuation
                    ),
                    confidencePenalty: 1 - point.confidence,
                    qualityPenalty: 1 - point.quality,
                    stableID: point.id
                ),
                timeA: entryA.time,
                timeB: entryB.time,
                varA: entryA.varianceTime,
                varB: entryB.varianceTime,
                labelIDA: entryA.labelID,
                labelIDB: entryB.labelID,
                sharedContinuation: sharedContinuation
            )
        }.sorted { $0.rank < $1.rank }

        // ── Debug: top 10 candidates ──
        let naming = MountainNaming(graph)
        SolverLog.debug("[SOLVER] Ranked eligible rendezvous points: \(candidates.count)")
        for (i, c) in candidates.prefix(10).enumerated() {
            let hub = graph.outgoing(from: c.nodeID).count
            let elev = graph.nodes[c.nodeID].map { String(format: "%.0fm", $0.elevation) } ?? "?"
            let name = c.point.displayName ?? naming.meetingNodeLabel(c.nodeID)
            SolverLog.debug("[SOLVER]  \(i+1). \(c.nodeID) reliable=\(String(format: "%.1f", c.rank.reliabilityScoreSeconds)) latest=\(String(format: "%.1f", c.rank.latestArrivalSeconds)) spread=\(String(format: "%.1f", c.rank.waitSpreadSeconds)) uncertainty=\(String(format: "%.1f", c.rank.uncertaintySeconds)) continuationPenalty=\(String(format: "%.2f", c.rank.continuationPenalty)) quality=\(String(format: "%.2f", c.point.quality)) hub=\(hub) elev=\(elev) \"\(name)\"")
        }

        guard let best = candidates.first,
              let bestNode = graph.nodes[best.nodeID] else { return nil }

        let pathA = reconstructPath(
            from: effectiveA, to: best.nodeID, dist: distA, labelID: best.labelIDA
        )
        let pathB = reconstructPath(
            from: effectiveB, to: best.nodeID, dist: distB, labelID: best.labelIDB
        )

        // ── Diverse alternates: geographic minimum spacing ──
        var alts = diverseAlternates(
            from: candidates.dropFirst(),
            bestNode: bestNode,
            bestLabelA: best.labelIDA,
            positionA: effectiveA,
            positionB: effectiveB,
            distA: distA,
            distB: distB,
            count: SolverConstants.Alternates.twoSkierAlternateCount
        )
        for index in alts.indices {
            alts[index].initialEdgeFractionA = originA.initialFraction(
                forFirstEdgeID: alts[index].pathA.first?.id
            )
            alts[index].initialEdgeFractionB = originB.initialFraction(
                forFirstEdgeID: alts[index].pathB.first?.id
            )
        }

        let bestName = best.point.displayName ?? naming.meetingNodeLabel(best.nodeID)
        SolverLog.debug("[SOLVER] Best: \(best.nodeID) \"\(bestName)\" tA=\(String(format: "%.1f", best.timeA))s tB=\(String(format: "%.1f", best.timeB))s | \(alts.count) alternates")

        // Stddev = sqrt(varianceTime) for each side. Solver-side population
        // means every strict result (primary + alternates) carries the
        // uncertainty surface for its exact selected path, replacing the
        // post-hoc path-variance helper that previously ran in MeetView.
        let stdA = best.varA > 0 ? best.varA.squareRoot() : 0
        let stdB = best.varB > 0 ? best.varB.squareRoot() : 0

        let result = MeetingResult(
            meetingNode: bestNode, pathA: pathA, pathB: pathB,
            timeA: best.timeA, timeB: best.timeB, alternates: alts,
            initialEdgeFractionA: originA.initialFraction(forFirstEdgeID: pathA.first?.id),
            initialEdgeFractionB: originB.initialFraction(forFirstEdgeID: pathB.first?.id),
            meetingDisplayName: best.point.displayName,
            rendezvousPoint: best.point,
            rendezvousReason: rendezvousWaitAssessment(
                at: best.point,
                context: contextA,
                arrivalOffsetSeconds: max(best.timeA, best.timeB)
            ).reason,
            sharedContinuation: best.sharedContinuation,
            routeReasonA: nil, routeReasonB: nil,
            etaStdSecondsA: stdA, etaStdSecondsB: stdB
        )
        Self.solutionCache.set(result, for: cacheKey)
        return result
    }

    /// Compact string signature for a TraversalContext. Used in cache keys so
    /// two solves that bucketise to the same environmental context hit the
    /// same cached result. `solveTime` is already quantized to a one-minute
    /// bucket upstream; retaining that bucket is required because lift waits
    /// and sun exposure can change edge weights over the day.
    static func contextSignature(_ c: TraversalContext) -> String {
        let lat = c.latitude.map { String(format: "%.3f", $0) } ?? "-"
        let lon = c.longitude.map { String(format: "%.3f", $0) } ?? "-"
        let utcOffset = c.utcOffsetSeconds.map(String.init) ?? "-"
        let timeBucket = c.solveTime.map {
            String(Int64($0.timeIntervalSinceReferenceDate.rounded()))
        } ?? "-"
        let forecast = c.hourlyWeather.map {
            "\(Int64($0.time.timeIntervalSinceReferenceDate.rounded())):"
                + String(format: "%.1f", $0.temperatureCelsius) + ","
                + String(format: "%.1f", $0.windSpeedKmh) + ","
                + String(format: "%.1f", $0.visibilityKm) + ","
                + "\($0.cloudCoverPercent),"
                + String(format: "%.1f", $0.snowfallCm)
        }.joined(separator: ";")
        return "lat=\(lat) lon=\(lon) utcOffset=\(utcOffset) time=\(timeBucket) "
            + "liftHours=\(c.liftOpenHour)-\(c.liftCloseHour) "
            + "T=\(String(format: "%.1f", c.temperatureCelsius)) "
            + "E=\(String(format: "%.0f", c.stationElevationM)) "
            + "W=\(String(format: "%.1f", c.windSpeedKmh)) "
            + "V=\(String(format: "%.1f", c.visibilityKm)) "
            + "S=\(String(format: "%.0f", c.freshSnowCm)) "
            + "C=\(c.cloudCoverPercent) forecast=\(forecast) "
            + "equipment=\(c.equipment?.fingerprint ?? "neutral")"
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
        dist: DijkstraResult,
        labelID: Int? = nil
    ) -> String? {
        var currentLabelID = labelID ?? dist[nodeID]?.labelID
        while let labelID = currentLabelID,
              let entry = dist.labelsByID[labelID],
              entry.nodeID != start {
            guard let edgeID = entry.viaEdgeID else { return nil }
            if let edge = graph.edge(byID: edgeID), edge.kind == .lift {
                return edge.id
            }
            currentLabelID = entry.previousLabelID
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
        from candidates: ArraySlice<RankedCandidate>,
        bestNode: GraphNode,
        bestLabelA: Int,
        positionA: String,
        positionB: String,
        distA: DijkstraResult,
        distB: DijkstraResult,
        count: Int
    ) -> [AlternateMeeting] {

        let liftZoneMap = buildLiftZoneNodeMap()
        let ladder = SolverConstants.Alternates.pairwiseDistanceLadderMeters

        // Walk strict-to-loose, but stop as soon as we have two meaningful
        // choices. Four is a maximum, not a quota: relaxing geographic
        // constraints merely to fill a carousel produces fake variety.
        var bestDiverseAttempt: [AlternateMeeting] = []
        let usefulChoiceCount = min(2, count)
        for minDistM in ladder {
            let attempt = pickAlternates(
                from: candidates,
                bestNode: bestNode,
                bestLabelA: bestLabelA,
                positionA: positionA,
                positionB: positionB,
                distA: distA,
                distB: distB,
                count: count,
                minPairwiseDistanceMeters: minDistM,
                liftZoneMap: liftZoneMap
            )
            if attempt.count > bestDiverseAttempt.count {
                bestDiverseAttempt = attempt
            }
            if attempt.count >= usefulChoiceCount {
                return attempt
            }
        }

        if !bestDiverseAttempt.isEmpty {
            return bestDiverseAttempt
        }

        // Last resort: when every eligible point shares the primary's cluster,
        // expose only the best other node. One honest nearby fallback is useful;
        // four near-identical pins are not.
        var result: [AlternateMeeting] = []
        for item in candidates {
            guard result.isEmpty else { break }
            guard let node = graph.nodes[item.nodeID] else { continue }
            if node.id == bestNode.id { continue }
            if result.contains(where: { $0.node.id == item.nodeID }) { continue }

            let altPathA = reconstructPath(
                from: positionA, to: item.nodeID, dist: distA, labelID: item.labelIDA
            )
            let altPathB = reconstructPath(
                from: positionB, to: item.nodeID, dist: distB, labelID: item.labelIDB
            )
            result.append(AlternateMeeting(
                node: node,
                pathA: altPathA,
                pathB: altPathB,
                timeA: item.timeA,
                timeB: item.timeB,
                meetingDisplayName: item.point.displayName,
                rendezvousPoint: item.point,
                sharedContinuation: item.sharedContinuation,
                etaStdSecondsA: item.varA > 0 ? item.varA.squareRoot() : 0,
                etaStdSecondsB: item.varB > 0 ? item.varB.squareRoot() : 0
            ))
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
        from candidates: ArraySlice<RankedCandidate>,
        bestNode: GraphNode,
        bestLabelA: Int,
        positionA: String,
        positionB: String,
        distA: DijkstraResult,
        distB: DijkstraResult,
        count: Int,
        minPairwiseDistanceMeters: Double,
        liftZoneMap: [String: String]
    ) -> [AlternateMeeting] {

        var seenClusters: Set<String> = []
        let bestLastLift = lastLiftEdgeID(
            to: bestNode.id, from: positionA, dist: distA, labelID: bestLabelA
        )
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

            let lastLift = lastLiftEdgeID(
                to: item.nodeID, from: positionA, dist: distA, labelID: item.labelIDA
            )
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

            let altPathA = reconstructPath(
                from: positionA, to: item.nodeID, dist: distA, labelID: item.labelIDA
            )
            let altPathB = reconstructPath(
                from: positionB, to: item.nodeID, dist: distB, labelID: item.labelIDB
            )
            result.append(AlternateMeeting(
                node: node,
                pathA: altPathA,
                pathB: altPathB,
                timeA: item.timeA,
                timeB: item.timeB,
                meetingDisplayName: item.point.displayName,
                rendezvousPoint: item.point,
                sharedContinuation: item.sharedContinuation,
                etaStdSecondsA: item.varA > 0 ? item.varA.squareRoot() : 0,
                etaStdSecondsB: item.varB > 0 ? item.varB.squareRoot() : 0
            ))
        }

        return result
    }

    /// Haversine distance in metres between two `CLLocationCoordinate2D`
    /// values. Thin delegate to the single canonical `haversine(from:to:)`
    /// in `Models/Resort.swift` — kept as a `nonisolated static` on the
    /// solver so the hot path (which can run detached) still calls it by
    /// this name, but the formula itself lives in exactly one place now.
    nonisolated static func haversineMeters(
        _ a: CLLocationCoordinate2D,
        _ b: CLLocationCoordinate2D
    ) -> Double {
        haversine(from: a, to: b)
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

        // Every route remains anchored to its supplied start node. Multi-skier
        // solves follow the same no-teleport contract as the two-skier path.
        for (i, skier) in skiers.enumerated() {
            let context = ctx(for: skier.profile.id.uuidString)
            let usable = originIsUsable(
                .node(skier.positionNodeID),
                skier: skier.profile,
                context: context
            )
            if !usable {
                SolverLog.debug("[SOLVER] Skier \(i) at dead-end \(skier.positionNodeID) — exact start rejected")
                lastFailureReason = originFailureReason(.node(skier.positionNodeID),
                    skier: skier.profile, context: context)
                return nil
            }
        }

        let dijkstraResults = skiers.map { dijkstra(from: $0.positionNodeID, skier: $0.profile) }

        func deadlineRelaxedRendezvous() -> Set<String> {
            guard solveTime != nil, !rendezvousCatalog.points.isEmpty else {
                return []
            }
            var reachable: Set<String>?
            for skier in skiers {
                let relaxed = Set(dijkstra(
                    from: skier.positionNodeID,
                    skier: skier.profile,
                    ignoreLiftDeadlineRisk: true
                ).keys)
                reachable = reachable.map { $0.intersection(relaxed) } ?? relaxed
            }
            return (reachable ?? []).intersection(rendezvousCatalog.nodeIDs)
        }

        for (i, d) in dijkstraResults.enumerated() {
            SolverLog.debug("[SOLVER] Dijkstra[\(i)] reached \(d.count) nodes")
        }

        // Intersect reachable node sets
        var reachable = Set(dijkstraResults[0].keys)
        for result in dijkstraResults.dropFirst() {
            reachable.formIntersection(result.keys)
        }
        guard !reachable.isEmpty else {
            if !deadlineRelaxedRendezvous().isEmpty {
                lastFailureReason = .liftDeadlineRisk
                return nil
            }
            SolverLog.debug("[SOLVER] No reachable intersection — returning nil")
            lastFailureReason = rendezvousCatalog.points.isEmpty
                ? .noEligibleRendezvous
                : .noReachableRendezvous
            return nil
        }
        SolverLog.debug("[SOLVER] Reachable intersection: \(reachable.count) nodes")

        guard !rendezvousCatalog.points.isEmpty else {
            lastFailureReason = .noEligibleRendezvous
            return nil
        }
        let pointByNode = Dictionary(
            uniqueKeysWithValues: rendezvousCatalog.points.map { ($0.nodeID, $0) }
        )
        let eligibleReachable = reachable.intersection(rendezvousCatalog.nodeIDs)
        guard !eligibleReachable.isEmpty else {
            if !deadlineRelaxedRendezvous().isEmpty {
                lastFailureReason = .liftDeadlineRisk
                return nil
            }
            var relaxedReachable: Set<String>?
            for skier in skiers {
                let relaxed = Set(dijkstra(
                    from: skier.positionNodeID,
                    skier: skier.profile,
                    ignoreSkillGates: true
                ).keys)
                relaxedReachable = relaxedReachable.map { $0.intersection(relaxed) } ?? relaxed
            }
            let relaxedRendezvous = (relaxedReachable ?? []).intersection(rendezvousCatalog.nodeIDs)
            lastFailureReason = relaxedRendezvous.isEmpty
                ? .noReachableRendezvous
                : .skillGatedPath(diagnostics: [])
            return nil
        }

        let orderedContexts = skiers.map { ctx(for: $0.profile.id.uuidString) }
        let scored: [RankedCandidateN] = eligibleReachable.compactMap { nodeID in
            guard let point = pointByNode[nodeID] else { return nil }
            let entries = dijkstraResults.compactMap { $0[nodeID] }
            guard entries.count == skiers.count else { return nil }
            let times = entries.map(\.time)
            let maxTime = times.max() ?? 0
            let minTime = times.min() ?? 0
            let totalVariance = entries.reduce(0) { $0 + $1.varianceTime }
            return RankedCandidateN(
                point: point,
                rank: RendezvousRank(
                    latestArrivalSeconds: maxTime,
                    waitSpreadSeconds: maxTime - minTime,
                    uncertaintySeconds: totalVariance > 0 ? totalVariance.squareRoot() : 0,
                    waitPenaltyAlpha: rendezvousWaitPenaltyAlpha(
                        at: point,
                        context: orderedContexts[0],
                        arrivalOffsetSeconds: maxTime
                    ),
                    approachSimplicityPenaltySeconds: entries
                        .map(\.simplicityPenaltySeconds)
                        .max() ?? 0,
                    continuationPenalty: sharedContinuationPenalty(
                        at: point,
                        profiles: skiers.map(\.profile),
                        contexts: orderedContexts,
                        departureOffsetSeconds: maxTime
                    ),
                    confidencePenalty: 1 - point.confidence,
                    qualityPenalty: 1 - point.quality,
                    stableID: point.id
                ),
                times: times
            )
        }.sorted { $0.rank < $1.rank }

        // Debug: top 10
        let nNaming = MountainNaming(graph)
        SolverLog.debug("[SOLVER] Top N-skier candidates (\(scored.count) after filters):")
        for (i, c) in scored.prefix(10).enumerated() {
            let timesStr = c.times.map { String(format: "%.1f", $0) }.joined(separator: ",")
            let name = c.point.displayName ?? nNaming.meetingNodeLabel(c.nodeID)
            SolverLog.debug("[SOLVER]  \(i+1). \(c.nodeID) reliable=\(String(format: "%.1f", c.rank.reliabilityScoreSeconds)) latest=\(String(format: "%.1f", c.rank.latestArrivalSeconds)) spread=\(String(format: "%.1f", c.rank.waitSpreadSeconds)) times=[\(timesStr)] \"\(name)\"")
        }

        guard let best = scored.first,
              let bestNode = graph.nodes[best.nodeID] else { return nil }

        // Reconstruct paths
        let paths: [(skier: UserProfile, path: [GraphEdge], time: Double)] = zip(skiers, zip(dijkstraResults, best.times)).map { skier, pair in
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
        let probeStart = skiers[0].positionNodeID
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

        let bestName = best.point.displayName ?? nNaming.meetingNodeLabel(best.nodeID)
        SolverLog.debug("[SOLVER] N-skier best: \(best.nodeID) \"\(bestName)\" | \(alts.count) alternates")

        return MeetingResultN(meetingNode: bestNode, paths: paths, alternates: alts)
    }

    /// Softly prefer a rendezvous from which everyone has at least one common
    /// legal next edge at the time the last skier arrives. This is not a hard
    /// requirement: terminal bases, lodges, patrol, and end-of-day meetups
    /// remain valid. Purpose-built stopping areas receive only a small penalty
    /// because stopping there may itself be the goal.
    private func sharedContinuationPenalty(
        at point: RendezvousPoint,
        sharedContinuation: SharedContinuation?
    ) -> Double {
        if let sharedContinuation {
            // Finding any real downhill continuation is materially better than
            // a dead end, but a token trail fragment should not score the same
            // as a full shared lap. Existence earns 50% of the available
            // credit; bounded length, vertical, access, fit, and choice
            // evidence earn the other half.
            return 0.50 * (1 - min(1, max(0, sharedContinuation.quality)))
        }
        switch point.kind {
        case .signedMeetingArea, .lodge, .patrol:
            return 0.35
        case .liftBase, .midStation:
            return 1
        }
    }

    private func sharedContinuationPenalty(
        at point: RendezvousPoint,
        profiles: [UserProfile],
        contexts: [TraversalContext],
        departureOffsetSeconds: Double
    ) -> Double {
        sharedContinuationPenalty(
            at: point,
            sharedContinuation: sharedContinuation(
                at: point,
                profiles: profiles,
                contexts: contexts,
                departureOffsetSeconds: departureOffsetSeconds
            )
        )
    }

    /// Find the best useful shared first move with a bounded three-edge search.
    /// The rollout must reach enough mutually legal downhill geometry to count;
    /// a lift into a long connector and then a dead end is not a shared lap.
    /// Searching three edges covers the common mountain shapes (lift → run,
    /// connector → run, lift → connector → run) without turning every
    /// rendezvous score into another resort-wide route solve.
    private func sharedContinuation(
        at point: RendezvousPoint,
        profiles: [UserProfile],
        contexts: [TraversalContext],
        departureOffsetSeconds: Double
    ) -> SharedContinuation? {
        guard profiles.count == contexts.count, !profiles.isEmpty else { return nil }

        // The accepted routes end at the rendezvous, but the advertised shared
        // move must remain possible after two humans locate one another and
        // regroup. Advance the operational clock before evaluating the first
        // edge so last-chair and forecast gates cannot assume an instantaneous
        // handoff. Keep the card's downhill-access metric relative to this
        // ready-to-depart instant so the handoff is not mislabeled as lift or
        // connector travel.
        let operationalDepartureOffsetSeconds = departureOffsetSeconds
            + SolverConstants.Scoring.sharedMeetupHandoffSeconds

        func traversalTimes(
            for edge: GraphEdge,
            offset: Double,
            previousEdge: GraphEdge?
        ) -> [Double]? {
            let values = zip(profiles, contexts).compactMap { profile, context in
                profile.traverseTime(
                    for: edge,
                    context: context,
                    arrivalTimeOffsetSeconds: offset,
                    previousEdge: previousEdge
                )
            }
            return values.count == profiles.count ? values : nil
        }

        func isMeaningfulRun(lengthMeters: Double, verticalDropMeters: Double) -> Bool {
            lengthMeters >= 75 || verticalDropMeters >= 10
        }

        var paths: [SharedContinuationPath] = []
        let maximumEdges = 3

        func search(
            from nodeID: String,
            path: [GraphEdge],
            visitedNodes: Set<String>,
            departureOffset: Double,
            runLengthMeters: Double,
            verticalDropMeters: Double,
            downhillAccessSeconds: Double?,
            terrainFitWeightedMeters: Double,
            firstRunOptionIdentity: String?
        ) {
            guard path.count < maximumEdges else { return }
            for edge in graph.outgoing(from: nodeID).sorted(by: { $0.id < $1.id }) {
                guard let times = traversalTimes(for: edge, offset: departureOffset, previousEdge: path.last)
                else { continue }

                // A real ski lap commonly closes at the lift base where it
                // began. Let a downhill edge prove that terminal loop, but
                // never recurse through an already visited node. This preserves
                // cycle safety while recognizing lift → run → same-base laps.
                let closesVisitedLoop = visitedNodes.contains(edge.targetID)

                let groupSeconds = times.max() ?? 0
                let nextOffset = departureOffset + groupSeconds
                let nextPath = path + [edge]
                let nextRunLength = runLengthMeters
                    + (edge.kind == .run ? max(0, edge.attributes.lengthMeters) : 0)
                let nextVerticalDrop = verticalDropMeters
                    + (edge.kind == .run ? max(0, edge.attributes.verticalDrop) : 0)
                let nextDownhillAccessSeconds = downhillAccessSeconds
                    ?? (edge.kind == .run
                        ? departureOffset - operationalDepartureOffsetSeconds
                        : nil)
                let edgeRunLength = edge.kind == .run
                    ? max(0, edge.attributes.lengthMeters)
                    : 0
                let edgeTerrainFit = edge.kind == .run
                    ? SharedLapUtility.jointTerrainFit(
                        profiles: profiles,
                        edge: edge,
                        traversalSeconds: times
                    )
                    : 1
                let nextTerrainFitWeightedMeters = terrainFitWeightedMeters
                    + edgeRunLength * edgeTerrainFit
                let nextJointTerrainFit = nextRunLength > 0
                    ? nextTerrainFitWeightedMeters / nextRunLength
                    : 1
                let nextFirstRunOptionIdentity = firstRunOptionIdentity
                    ?? (edge.kind == .run
                        ? SharedLapUtility.optionIdentity(for: edge)
                        : nil)

                if isMeaningfulRun(
                    lengthMeters: nextRunLength,
                    verticalDropMeters: nextVerticalDrop
                ) {
                    let actionTransitionCount = zip(nextPath, nextPath.dropFirst())
                        .reduce(into: 0) { count, pair in
                            if pair.0.kind != pair.1.kind { count += 1 }
                        }
                    paths.append(SharedContinuationPath(
                        firstEdge: nextPath[0],
                        edgeIDs: nextPath.map(\.id),
                        sharedRunLengthMeters: nextRunLength,
                        sharedVerticalDropMeters: nextVerticalDrop,
                        groupCompletionSeconds: nextOffset - departureOffsetSeconds,
                        downhillAccessSeconds: nextDownhillAccessSeconds ?? 0,
                        jointTerrainFit: nextJointTerrainFit,
                        actionTransitionCount: actionTransitionCount,
                        runOptionIdentity: nextFirstRunOptionIdentity
                            ?? "edge:\(edge.id)"
                    ))
                }

                guard !closesVisitedLoop else { continue }

                var nextVisited = visitedNodes
                nextVisited.insert(edge.targetID)
                search(
                    from: edge.targetID,
                    path: nextPath,
                    visitedNodes: nextVisited,
                    departureOffset: nextOffset,
                    runLengthMeters: nextRunLength,
                    verticalDropMeters: nextVerticalDrop,
                    downhillAccessSeconds: nextDownhillAccessSeconds,
                    terrainFitWeightedMeters: nextTerrainFitWeightedMeters,
                    firstRunOptionIdentity: nextFirstRunOptionIdentity
                )
            }
        }

        search(
            from: point.nodeID,
            path: [],
            visitedNodes: [point.nodeID],
            departureOffset: operationalDepartureOffsetSeconds,
            runLengthMeters: 0,
            verticalDropMeters: 0,
            downhillAccessSeconds: nil,
            terrainFitWeightedMeters: 0,
            firstRunOptionIdentity: nil
        )

        guard let best = paths.sorted(by: { lhs, rhs in
            if lhs.utility != rhs.utility { return lhs.utility > rhs.utility }
            if lhs.edgeIDs.count != rhs.edgeIDs.count {
                return lhs.edgeIDs.count < rhs.edgeIDs.count
            }
            if lhs.groupCompletionSeconds != rhs.groupCompletionSeconds {
                return lhs.groupCompletionSeconds < rhs.groupCompletionSeconds
            }
            return lhs.edgeIDs.lexicographicallyPrecedes(rhs.edgeIDs)
        }).first else { return nil }

        let minimumOptionUtility = max(
            SolverConstants.Scoring.sharedRunOptionMinimumUtility,
            best.utility
                - SolverConstants.Scoring.sharedRunVarietyRelativeUtilityWindow
        )
        let viableRunOptionIDs = Set(paths.compactMap { path -> String? in
            guard path.utility >= minimumOptionUtility,
                  path.jointTerrainFit
                    >= SolverConstants.Scoring.sharedRunOptionMinimumTerrainFit
            else { return nil }
            return path.runOptionIdentity
        })
        let sharedRunOptionCount = max(1, viableRunOptionIDs.count)
        let quality = SharedLapUtility.scoreWithVariety(
            baseScore: best.utility,
            optionCount: sharedRunOptionCount
        )

        let fallback: String
        let kind: SharedContinuation.Kind
        switch best.firstEdge.kind {
        case .run:
            fallback = "A SHARED RUN"
            kind = .ski
        case .lift:
            fallback = "A SHARED LIFT"
            kind = .ride
        case .traverse:
            fallback = "A SHARED CONNECTOR"
            kind = .traverse
        }
        let name = MountainNaming(graph)
            .edgeLabel(best.firstEdge, style: .bareName)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return SharedContinuation(
            edgeID: best.firstEdge.id,
            name: name.isEmpty ? fallback : name,
            kind: kind,
            sharedRunLengthMeters: best.sharedRunLengthMeters,
            sharedVerticalDropMeters: best.sharedVerticalDropMeters,
            downhillAccessSeconds: best.downhillAccessSeconds,
            jointTerrainFit: best.jointTerrainFit,
            sharedRunOptionCount: sharedRunOptionCount,
            quality: quality
        )
    }

    /// Weather at the predicted group-arrival instant controls how costly a
    /// timing mismatch is. Temperature is adjusted to the rendezvous elevation;
    /// wind and visibility come from the same interpolated forecast already
    /// used by edge traversal. Both skiers share that physical weather, so one
    /// canonical context is sufficient and keeps cross-device ranking stable.
    private func rendezvousWaitPenaltyAlpha(
        at point: RendezvousPoint,
        context: TraversalContext,
        arrivalOffsetSeconds: Double
    ) -> Double {
        rendezvousWaitAssessment(
            at: point,
            context: context,
            arrivalOffsetSeconds: arrivalOffsetSeconds
        ).alpha
    }

    private func rendezvousWaitAssessment(
        at point: RendezvousPoint,
        context: TraversalContext,
        arrivalOffsetSeconds: Double
    ) -> (alpha: Double, reason: String?) {
        let arrivalDate = context.solveTime?.addingTimeInterval(arrivalOffsetSeconds)
        let weather = context.weather(at: arrivalDate)
        let elevation = graph.nodes[point.nodeID]?.elevation ?? context.stationElevationM
        let temperature = context.temperatureAt(
            elevationM: elevation,
            at: arrivalDate
        )
        let alpha = SolverConstants.Scoring.weatherAwareWaitPenaltyAlpha(
            temperatureCelsius: temperature,
            windSpeedKmh: weather.windSpeedKmh,
            visibilityKm: weather.visibilityKm,
            rendezvousKind: point.kind
        )
        let reason = RendezvousWaitExplanation.copy(
            temperatureCelsius: temperature,
            windSpeedKmh: weather.windSpeedKmh,
            visibilityKm: weather.visibilityKm,
            rendezvousKind: point.kind
        )
        return (alpha, reason)
    }

    private func capabilityDiagnostics(
        relaxedA: DijkstraResult,
        relaxedB: DijkstraResult,
        eligibleNodeIDs: Set<String>,
        skierA: UserProfile,
        skierB: UserProfile,
        startA: String,
        startB: String
    ) -> [SkierCapabilityDiagnostic] {
        let selected = eligibleNodeIDs.compactMap { nodeID -> (
            id: String,
            latest: Double,
            labelA: Int,
            labelB: Int
        )? in
            guard let a = relaxedA[nodeID], let b = relaxedB[nodeID] else {
                return nil
            }
            return (nodeID, max(a.time, b.time), a.labelID, b.labelID)
        }.min {
            if $0.latest != $1.latest { return $0.latest < $1.latest }
            return $0.id < $1.id
        }
        guard let selected else { return [] }

        func diagnostic(
            skier: UserProfile,
            path: [GraphEdge]
        ) -> SkierCapabilityDiagnostic? {
            var seen: Set<RunCapabilityBlocker> = []
            var ordered: [RunCapabilityBlocker] = []
            for blocker in path.flatMap({ skier.capabilityBlockers(for: $0) }) {
                if seen.insert(blocker).inserted { ordered.append(blocker) }
            }
            guard !ordered.isEmpty else { return nil }
            return SkierCapabilityDiagnostic(
                skierID: skier.id,
                skierName: skier.displayName,
                blockers: ordered
            )
        }

        return [
            diagnostic(
                skier: skierA,
                path: reconstructPath(
                    from: startA,
                    to: selected.id,
                    dist: relaxedA,
                    labelID: selected.labelA
                )
            ),
            diagnostic(
                skier: skierB,
                path: reconstructPath(
                    from: startB,
                    to: selected.id,
                    dist: relaxedB,
                    labelID: selected.labelB
                )
            ),
        ].compactMap { $0 }
    }

    // MARK: - Dijkstra (Binary Heap)

    private struct DijkstraEntry {
        let labelID: Int
        let nodeID: String
        let time: Double
        /// Correlated within contiguous physical actions, independent across
        /// actions. Keep the current block's standard deviation as search
        /// state because it determines covariance with the next fragment.
        let uncertainty: RouteTimeUncertainty
        var varianceTime: Double { uncertainty.varianceTime }
        /// User-visible trail/lift changes along this label. Stored separately
        /// from mean time so ETAs remain physical rather than padded.
        let actionTransitionCount: Int
        var lastActionIdentity: String? { uncertainty.lastActionIdentity }
        // The incoming lift segment determines whether an outgoing segment
        // continues an already-boarded ride. Keep this state distinct even
        // when two different physical lifts share a displayed name/group.
        var liftArrivalState: String? {
            lastActionIdentity?.hasPrefix("lift:") == true ? viaEdgeID : nil
        }
        let previousLabelID: Int?
        let viaEdgeID: String?

        var simplicityPenaltySeconds: Double {
            RouteSimplicity.preferencePenaltySeconds(
                forTransitionCount: actionTransitionCount
            )
        }

        var reliabilityScore: Double {
            time + SolverConstants.Scoring.cvarBeta * varianceTime.squareRoot()
                + simplicityPenaltySeconds
        }
    }

    /// A bounded Pareto path search result. `bestByNode` is the dependable
    /// route selected for scoring; `labelsByID` retains its exact parent chain
    /// even when the best route to a predecessor node is a different label.
    private struct DijkstraResult {
        let bestByNode: [String: DijkstraEntry]
        let frontierByNode: [String: [DijkstraEntry]]
        let labelsByID: [Int: DijkstraEntry]

        var count: Int { bestByNode.count }
        var keys: Dictionary<String, DijkstraEntry>.Keys { bestByNode.keys }
        subscript(nodeID: String) -> DijkstraEntry? { bestByNode[nodeID] }
        func labels(at nodeID: String) -> [DijkstraEntry] {
            frontierByNode[nodeID] ?? []
        }
    }

    private struct ApproachPair {
        let a: DijkstraEntry
        let b: DijkstraEntry

        var latestArrival: Double { max(a.time, b.time) }
        var jointUncertainty: Double {
            (a.varianceTime + b.varianceTime).squareRoot()
        }
        var simplicityPenaltySeconds: Double {
            max(a.simplicityPenaltySeconds, b.simplicityPenaltySeconds)
        }
        var reliabilityScore: Double {
            latestArrival
                + SolverConstants.Scoring.cvarBeta * jointUncertainty
                + simplicityPenaltySeconds
        }
    }

    /// Pick the exact dependable two-person approach pair at one stop. The
    /// Dijkstra frontiers are bounded (currently eight labels each), so the
    /// at-most-64 combinations are cheap and deterministic. Wait imbalance is
    /// intentionally absent here: it ranks *stops* later, but must not send a
    /// skier around a longer loop simply to arrive at the same stop later.
    private func bestApproachPair(
        at nodeID: String,
        resultA: DijkstraResult,
        resultB: DijkstraResult
    ) -> ApproachPair? {
        func reasonableLabels(in result: DijkstraResult) -> [DijkstraEntry] {
            let labels = result.labels(at: nodeID)
            guard let fastest = labels.map(\.time).min() else { return [] }
            let allowance = max(
                SolverConstants.Scoring.dependablePathMaximumExtraSeconds,
                fastest * SolverConstants.Scoring.dependablePathMaximumExtraFraction
            )
            return labels.filter { $0.time <= fastest + allowance }
        }

        let labelsA = reasonableLabels(in: resultA)
        let labelsB = reasonableLabels(in: resultB)
        guard !labelsA.isEmpty, !labelsB.isEmpty else { return nil }

        func preferred(_ lhs: ApproachPair, over rhs: ApproachPair) -> Bool {
            if lhs.reliabilityScore != rhs.reliabilityScore {
                return lhs.reliabilityScore < rhs.reliabilityScore
            }
            if lhs.latestArrival != rhs.latestArrival {
                return lhs.latestArrival < rhs.latestArrival
            }
            if lhs.jointUncertainty != rhs.jointUncertainty {
                return lhs.jointUncertainty < rhs.jointUncertainty
            }
            if lhs.a.reliabilityScore != rhs.a.reliabilityScore {
                return lhs.a.reliabilityScore < rhs.a.reliabilityScore
            }
            if lhs.b.reliabilityScore != rhs.b.reliabilityScore {
                return lhs.b.reliabilityScore < rhs.b.reliabilityScore
            }
            if lhs.a.labelID != rhs.a.labelID {
                return lhs.a.labelID < rhs.a.labelID
            }
            return lhs.b.labelID < rhs.b.labelID
        }

        var best: ApproachPair?
        for a in labelsA {
            for b in labelsB {
                let candidate = ApproachPair(a: a, b: b)
                guard let currentBest = best else {
                    best = candidate
                    continue
                }
                if preferred(candidate, over: currentBest) {
                    best = candidate
                }
            }
        }
        return best
    }

    private struct PathQueueEntry {
        let labelID: Int
        let nodeID: String
        let reliabilityScore: Double
        let time: Double
        let varianceTime: Double
        let viaEdgeID: String
    }

    private func dijkstra(
        from startNodeID: String,
        skier: UserProfile,
        earlyExitTarget: String? = nil,
        origin: RoutingOrigin? = nil,
        ignoreSkillGates: Bool = false,
        ignoreLiftDeadlineRisk: Bool = false
    ) -> DijkstraResult {
        // Per-skier context so this skier's edge weights consult
        // their own per-edge history (set via
        // `edgeSpeedHistoryByProfile[skier.id]`); falls back to the
        // shared `edgeSpeedHistory` for single-skier callers that
        // never set the per-skier dict.
        let context = buildContext(for: skier.id.uuidString)
        var labelsByID: [Int: DijkstraEntry] = [:]
        var frontierByNode: [String: [Int]] = [:]
        var nextLabelID = 0
        var heap = BinaryHeap<PathQueueEntry> {
            if $0.reliabilityScore != $1.reliabilityScore {
                return $0.reliabilityScore < $1.reliabilityScore
            }
            if $0.time != $1.time { return $0.time < $1.time }
            if $0.varianceTime != $1.varianceTime { return $0.varianceTime < $1.varianceTime }
            if $0.nodeID != $1.nodeID { return $0.nodeID < $1.nodeID }
            if $0.viaEdgeID != $1.viaEdgeID { return $0.viaEdgeID < $1.viaEdgeID }
            return $0.labelID < $1.labelID
        }

        let positionStdSeconds = (origin?.positionUncertaintyMeters ?? 0)
            / SolverConstants.Scoring.positionUncertaintySpeedMetersPerSecond
        let initialVariance = positionStdSeconds * positionStdSeconds
        let start = DijkstraEntry(
            labelID: nextLabelID,
            nodeID: startNodeID,
            time: 0,
            uncertainty: RouteTimeUncertainty(initialVariance: initialVariance),
            actionTransitionCount: 0,
            previousLabelID: nil,
            viaEdgeID: nil
        )
        labelsByID[nextLabelID] = start
        frontierByNode[startNodeID] = [nextLabelID]
        heap.insert(PathQueueEntry(
            labelID: nextLabelID,
            nodeID: startNodeID,
            reliabilityScore: start.reliabilityScore,
            time: 0,
            varianceTime: initialVariance,
            viaEdgeID: ""
        ))
        nextLabelID += 1

        func preferred(_ lhs: DijkstraEntry, _ rhs: DijkstraEntry) -> Bool {
            if lhs.reliabilityScore != rhs.reliabilityScore {
                return lhs.reliabilityScore < rhs.reliabilityScore
            }
            if lhs.time != rhs.time { return lhs.time < rhs.time }
            if lhs.varianceTime != rhs.varianceTime { return lhs.varianceTime < rhs.varianceTime }
            if lhs.actionTransitionCount != rhs.actionTransitionCount {
                return lhs.actionTransitionCount < rhs.actionTransitionCount
            }
            if (lhs.viaEdgeID ?? "") != (rhs.viaEdgeID ?? "") {
                return (lhs.viaEdgeID ?? "") < (rhs.viaEdgeID ?? "")
            }
            return lhs.labelID < rhs.labelID
        }

        while let queued = heap.extractMin() {
            // Lazy deletion: a label removed by dominance or the per-node
            // frontier cap remains in the heap but must not be expanded.
            guard frontierByNode[queued.nodeID]?.contains(queued.labelID) == true,
                  let current = labelsByID[queued.labelID] else { continue }

            // Single-target early exit: once we pop the target, its distance
            // is finalised (Dijkstra invariant) — bail so we skip the rest
            // of the graph. Only applied by `pathTo(...)`; the multi-target
            // meet-solve still walks the full graph to populate every
            // candidate meeting node.
            if current.nodeID == earlyExitTarget { break }

            // Normal outgoing edges (runs, lifts up, traverses).
            // `arrivalTimeOffsetSeconds: current.time` makes lift waits
            // and lift-hours gating evaluate at the time the skier will
            // *arrive* at this edge, not at solve time. Without it, a
            // 14-minute path to a busy lift uses the now-wait instead
            // of the now+14-min wait, and the recommendation can land
            // the user in a queue that grew while they were skiing
            // toward it — or a lift that closed during their approach.
            for edge in graph.outgoing(from: current.nodeID).sorted(by: { $0.id < $1.id }) {
                if current.previousLabelID == nil,
                   let requiredEdgeID = origin?.approachEdgeID,
                   edge.id != requiredEdgeID {
                    continue
                }
                let isFractionalApproach = current.previousLabelID == nil
                    && origin?.approachEdgeID == edge.id
                let remainingFraction = isFractionalApproach
                    ? (origin?.remainingFraction ?? 1)
                    : 1
                guard let cost = RouteTraversalEvaluator.evaluate(
                    edge: edge,
                    profile: skier,
                    context: context,
                    elapsedSeconds: current.time,
                    approachVariance: current.varianceTime,
                    remainingFraction: remainingFraction,
                    ignoreSkillGates: ignoreSkillGates,
                    ignoreLiftDeadlineRisk: ignoreLiftDeadlineRisk,
                    previousEdge: current.viaEdgeID.flatMap { graph.edge(byID: $0) }
                ) else { continue }
                let newTime = current.time + cost.seconds

                // Do not grant confidence merely because one trail was
                // represented by more storage fragments.
                var uncertainty = current.uncertainty
                uncertainty.append(edge: edge, variance: cost.variance)
                let newVariance = uncertainty.varianceTime
                let actionIdentity = RouteSimplicity.actionIdentity(for: edge)
                let transitionIncrement = current.lastActionIdentity.map {
                    $0 == actionIdentity ? 0 : 1
                } ?? 0
                let newEntry = DijkstraEntry(
                    labelID: nextLabelID,
                    nodeID: edge.targetID,
                    time: newTime,
                    uncertainty: uncertainty,
                    actionTransitionCount: current.actionTransitionCount + transitionIncrement,
                    previousLabelID: current.labelID,
                    viaEdgeID: edge.id
                )

                let existingIDs = frontierByNode[edge.targetID] ?? []
                let existing = existingIDs.compactMap { labelsByID[$0] }

                // A route is irrelevant only when another route is no slower
                // AND no more uncertain or complex. Compare only labels whose
                // final action identity matches: that identity determines
                // whether the next edge adds another user-visible transition,
                // so unlike raw node distance it is part of the search state.
                let isDominated = existing.contains {
                    $0.lastActionIdentity == newEntry.lastActionIdentity
                        && $0.liftArrivalState == newEntry.liftArrivalState
                        && $0.time <= newEntry.time
                        && $0.varianceTime <= newEntry.varianceTime
                        && $0.uncertainty.currentActionStdSeconds <= newEntry.uncertainty.currentActionStdSeconds
                        && $0.actionTransitionCount <= newEntry.actionTransitionCount
                }
                if isDominated { continue }

                var keptIDs = existing.filter {
                    !(
                        $0.lastActionIdentity == newEntry.lastActionIdentity
                            && $0.liftArrivalState == newEntry.liftArrivalState
                            && newEntry.time <= $0.time
                            && newEntry.varianceTime <= $0.varianceTime
                            && newEntry.uncertainty.currentActionStdSeconds <= $0.uncertainty.currentActionStdSeconds
                            && newEntry.actionTransitionCount <= $0.actionTransitionCount
                    )
                }.map(\.labelID)
                labelsByID[nextLabelID] = newEntry
                keptIDs.append(nextLabelID)
                keptIDs.sort {
                    guard let lhs = labelsByID[$0], let rhs = labelsByID[$1] else { return $0 < $1 }
                    return preferred(lhs, rhs)
                }
                if keptIDs.count > SolverConstants.Scoring.maxParetoLabelsPerNode {
                    // The pairwise detour limit is anchored to fastest mean
                    // arrival, not the lowest reliability score. Keep that
                    // anchor even when many low-variance alternatives score
                    // better; otherwise truncation can silently redefine a
                    // forty-second detour as the fastest available approach.
                    let fastestID = keptIDs.min {
                        guard let lhs = labelsByID[$0], let rhs = labelsByID[$1] else { return $0 < $1 }
                        if lhs.time != rhs.time { return lhs.time < rhs.time }
                        return preferred(lhs, rhs)
                    }!
                    let limit = SolverConstants.Scoring.maxParetoLabelsPerNode
                    let preferredIDs = Array(keptIDs.prefix(limit))
                    if preferredIDs.contains(fastestID) {
                        keptIDs = preferredIDs
                    } else {
                        // Remaining labels stay reliability-ordered. The
                        // resolved frontier is sorted again before selection.
                        keptIDs = Array(preferredIDs.dropLast()) + [fastestID]
                    }
                }
                frontierByNode[edge.targetID] = keptIDs

                if keptIDs.contains(nextLabelID) {
                    heap.insert(PathQueueEntry(
                        labelID: nextLabelID,
                        nodeID: edge.targetID,
                        reliabilityScore: newEntry.reliabilityScore,
                        time: newTime,
                        varianceTime: newVariance,
                        viaEdgeID: edge.id
                    ))
                }
                nextLabelID += 1
            }

        }

        let resolvedFrontiers = frontierByNode.reduce(into: [String: [DijkstraEntry]]()) { result, item in
            // A fractional start is physically past the source node. It may
            // never be offered as a zero-second rendezvous behind the skier.
            if origin?.approachEdgeID != nil, item.key == startNodeID { return }
            let candidates = item.value.compactMap { labelsByID[$0] }
            result[item.key] = candidates.sorted(by: preferred)
        }
        let bestByNode = resolvedFrontiers.reduce(into: [String: DijkstraEntry]()) { result, item in
            if let best = item.value.first { result[item.key] = best }
        }
        return DijkstraResult(
            bestByNode: bestByNode,
            frontierByNode: resolvedFrontiers,
            labelsByID: labelsByID
        )
    }

    // MARK: - Single-Target Pathfinding

    /// Find the most dependable path and time for one skier to a specific target.
    /// Used when the meeting node is already agreed upon (e.g. an accepted request).
    /// Production callers keep `ignoreSkillGates` false. The relaxed form is exposed
    /// only for diagnostics and tests; it must never activate navigation.
    func pathTo(
        target: String,
        from start: String,
        skier: UserProfile,
        ignoreSkillGates: Bool = false
    ) -> (path: [GraphEdge], time: Double, etaStdSeconds: Double)? {
        pathTo(
            target: target,
            from: .node(start),
            skier: skier,
            ignoreSkillGates: ignoreSkillGates
        )
    }

    func pathTo(
        target: String,
        from origin: RoutingOrigin,
        skier: UserProfile,
        ignoreSkillGates: Bool = false
    ) -> (path: [GraphEdge], time: Double, etaStdSeconds: Double)? {
        let start = origin.startNodeID
        let dist = dijkstra(
            from: start,
            skier: skier,
            earlyExitTarget: target,
            origin: origin,
            ignoreSkillGates: ignoreSkillGates
        )
        guard let entry = dist[target] else { return nil }
        let path = reconstructPath(from: start, to: target, dist: dist)
        let etaStdSeconds = entry.varianceTime > 0 ? entry.varianceTime.squareRoot() : 0
        return (path, entry.time, etaStdSeconds)
    }

    /// Re-cost an already agreed exact path with the same arrival-time physics
    /// and variance model used by search. This is the canonical bridge for
    /// request activation and stale-partner route validation: those flows must
    /// not preserve an old ETA range or drop uncertainty merely because they
    /// are validating a stored edge sequence instead of choosing a new one.
    func metrics(
        for path: [GraphEdge],
        skier: UserProfile,
        initialEdgeFraction: Double = 0
    ) -> (time: Double, etaStdSeconds: Double)? {
        let context = buildContext(for: skier.id.uuidString)
        var elapsed = 0.0
        var uncertainty = RouteTimeUncertainty()
        for (index, edge) in path.enumerated() {
            let remainingFraction = index == 0
                ? 1 - max(0, min(1, initialEdgeFraction))
                : 1
            guard let cost = RouteTraversalEvaluator.evaluate(
                edge: edge,
                profile: skier,
                context: context,
                elapsedSeconds: elapsed,
                approachVariance: uncertainty.varianceTime,
                remainingFraction: remainingFraction,
                previousEdge: index > 0 ? path[index - 1] : nil
            ) else { return nil }
            elapsed += cost.seconds
            uncertainty.append(edge: edge, variance: cost.variance)
        }
        return (elapsed, uncertainty.varianceTime.squareRoot())
    }

    /// Distinguish a closed/disconnected start from terrain excluded by the
    /// skier's limits. Relaxation is diagnostic only; it never returns a route.
    private func originFailureReason(
        _ origin: RoutingOrigin, skier: UserProfile, context: TraversalContext
    ) -> SolveFailureReason {
        let edges: [GraphEdge]
        if let edgeID = origin.approachEdgeID {
            guard let edge = graph.edge(byID: edgeID),
                  edge.sourceID == origin.startNodeID,
                  edge.targetID == origin.approachTargetNodeID else {
                return .skierAtDeadEnd(skierName: skier.displayName)
            }
            edges = [edge]
        } else {
            edges = graph.outgoing(from: origin.startNodeID)
        }
        var seen = Set<RunCapabilityBlocker>()
        var blockers: [RunCapabilityBlocker] = []
        for edge in edges.sorted(by: { $0.id < $1.id }) where skier.traverseTime(
            for: edge, context: context, ignoreSkillGates: true,
            remainingFraction: origin.approachEdgeID == nil ? 1 : origin.remainingFraction
        ) != nil {
            for blocker in skier.capabilityBlockers(for: edge) where seen.insert(blocker).inserted {
                blockers.append(blocker)
            }
        }
        guard !blockers.isEmpty else { return .skierAtDeadEnd(skierName: skier.displayName) }
        return .startingTerrainBlocked(diagnostic: SkierCapabilityDiagnostic(
            skierID: skier.id, skierName: skier.displayName, blockers: blockers))
    }

    private func originIsUsable(
        _ origin: RoutingOrigin,
        skier: UserProfile,
        context: TraversalContext
    ) -> Bool {
        if let edgeID = origin.approachEdgeID {
            guard let edge = graph.edge(byID: edgeID),
                  edge.sourceID == origin.startNodeID,
                  edge.targetID == origin.approachTargetNodeID else { return false }
            return skier.traverseTime(
                for: edge,
                context: context,
                remainingFraction: origin.remainingFraction
            ) != nil
        }
        // A skier already standing at a validated stopping point does not need
        // an outgoing edge to meet there. This matters when every onward lift
        // has closed or the curated stop is a terminal base: staying put is a
        // valid zero-distance route, not a dead-end failure.
        if rendezvousCatalog.nodeIDs.contains(origin.startNodeID) {
            return true
        }
        return graph.outgoing(from: origin.startNodeID).contains {
            skier.traverseTime(for: $0, context: context) != nil
        }
    }

    // MARK: - Path Reconstruction

    private func reconstructPath(
        from start: String,
        to end: String,
        dist: DijkstraResult,
        labelID: Int? = nil
    ) -> [GraphEdge] {
        var path: [GraphEdge] = []
        var currentLabelID = labelID ?? dist[end]?.labelID

        while let labelID = currentLabelID,
              let entry = dist.labelsByID[labelID],
              entry.nodeID != start {
            guard let edgeID = entry.viaEdgeID else { break }
            if let edge = graph.edge(byID: edgeID) {
                path.insert(edge, at: 0)
            }
            currentLabelID = entry.previousLabelID
        }

        return path
    }

    // MARK: - Coordinate Distance

}
