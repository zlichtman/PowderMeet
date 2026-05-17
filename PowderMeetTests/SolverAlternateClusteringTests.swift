//
//  SolverAlternateClusteringTests.swift
//  PowderMeetTests
//
//  Empirical diversity harness for `MeetingPointSolver.diverseAlternates`.
//
//  Loads a captured resort fixture (operator-exported via RoutingTestSheet's
//  EXPORT GRAPH FIXTURE button), runs the solver from a deterministic
//  sample of skier-pair start positions, and dumps a CSV recording
//  haversine distances from each alternate to the primary meeting node
//  and to every other alternate.
//
//  Goal: quantify the spatial spread of alternates produced by the
//  current solver tuning so any change to `diverseAlternates` /
//  `pairwiseDistanceLadderMeters` / `twoSkierAlternateCount` can be
//  validated against the before/after CSV.
//
//  Operator step (one-shot per resort):
//   1. Boot the simulator at the target resort.
//   2. Live-status double-tap → RoutingTestSheet (DEBUG/TestFlight only).
//   3. Tap EXPORT GRAPH FIXTURE.
//   4. Move the resulting `<resortId>-fixture.json` into
//      `PowderMeetTests/Fixtures/`.
//   5. Re-run this test; CSV path printed to console.
//
//  The test gracefully SKIPS when no fixture is bundled, so the test
//  suite stays green even on a fresh clone with no fixtures captured
//  yet. Hard `XCTAssert`s on the spread metrics are intentionally
//  deferred until empirical data informs the right bars — until then
//  the test is a measurement, not a regression gate.
//

import XCTest
import CoreLocation
@testable import PowderMeet

final class SolverAlternateClusteringTests: XCTestCase {

    // MARK: - Fixture-driven runs

    /// Vail spread analysis. SKIPS until `vail-fixture.json` is dropped
    /// into `PowderMeetTests/Fixtures/`. See the operator step at the
    /// top of this file.
    func testAlternateSpread_Vail() throws {
        guard let graph = Self.loadFixture("vail-fixture") else {
            throw XCTSkip("vail-fixture.json missing — capture via RoutingTestSheet → EXPORT GRAPH FIXTURE, drop into PowderMeetTests/Fixtures/")
        }
        try emitSpreadCSV(for: graph, fixtureName: "vail")
    }

    /// Park City spread analysis. SKIPS until `parkcity-fixture.json` is
    /// captured. Same workflow as the Vail test above.
    func testAlternateSpread_ParkCity() throws {
        guard let graph = Self.loadFixture("parkcity-fixture") else {
            throw XCTSkip("parkcity-fixture.json missing — capture via RoutingTestSheet → EXPORT GRAPH FIXTURE, drop into PowderMeetTests/Fixtures/")
        }
        try emitSpreadCSV(for: graph, fixtureName: "parkcity")
    }

    // MARK: - Spread emitter

    /// Run the solver from a deterministic sample of start-pairs on
    /// `graph` and emit a CSV recording the spread metrics for every
    /// alternate. Writes to `NSTemporaryDirectory()` so the path is
    /// stable across test runs.
    private func emitSpreadCSV(for graph: MountainGraph, fixtureName: String) throws {
        let me = UserProfile.defaultProfile(id: UUID())
        let friend = UserProfile.defaultProfile(id: UUID())

        let nodeIDs = graph.nodes.keys.sorted()
        guard nodeIDs.count >= 20 else {
            throw XCTSkip("\(fixtureName) graph too small for meaningful diversity analysis (need >=20 nodes, got \(nodeIDs.count))")
        }

        // Deterministic start-pair sample: walk the sorted node list at
        // a stride so pairs are spread across the graph instead of
        // clustered near one corner. 24 pairs strikes a balance between
        // coverage and runtime.
        let pairCount = 24
        let stride = max(1, nodeIDs.count / pairCount)
        var pairs: [(String, String)] = []
        for i in 0..<pairCount {
            let aIdx = (i * stride) % nodeIDs.count
            let bIdx = (aIdx + nodeIDs.count / 3) % nodeIDs.count
            let a = nodeIDs[aIdx]
            let b = nodeIDs[bIdx]
            if a != b { pairs.append((a, b)) }
        }

        var rows: [String] = [
            "pair_idx,positionA,positionB,primary_node,max_time_s,alt_count,alt_idx,alt_node,dist_from_primary_m,min_dist_from_other_alts_m"
        ]
        var totalAlts = 0
        for (pairIdx, (a, b)) in pairs.enumerated() {
            let solver = MeetingPointSolver(graph: graph)
            guard let result = solver.solve(
                skierA: me, positionA: a,
                skierB: friend, positionB: b
            ) else { continue }

            let primary = result.meetingNode
            let altCount = result.alternates.count
            totalAlts += altCount

            for (i, alt) in result.alternates.enumerated() {
                let dPrim = MeetingPointSolver.haversineMeters(
                    primary.coordinate, alt.node.coordinate
                )
                let others = result.alternates.enumerated().filter { $0.offset != i }
                let dMin: Double = others.isEmpty
                    ? .infinity
                    : (others.map {
                        MeetingPointSolver.haversineMeters(
                            $0.element.node.coordinate, alt.node.coordinate
                        )
                    }.min() ?? .infinity)

                rows.append([
                    String(pairIdx),
                    a, b,
                    primary.id,
                    String(Int(result.maxTime.rounded())),
                    String(altCount),
                    String(i),
                    alt.node.id,
                    String(Int(dPrim.rounded())),
                    dMin.isFinite ? String(Int(dMin.rounded())) : ""
                ].joined(separator: ","))
            }
        }

        let csv = rows.joined(separator: "\n")
        let outPath = NSTemporaryDirectory() + "pm-alt-spread-\(fixtureName).csv"
        try csv.write(toFile: outPath, atomically: true, encoding: .utf8)

        // Loud console print so the path is easy to grab from the test
        // log. Not using `XCTAttachment` so the CSV remains readable on
        // command-line `xcodebuild test` output, not just inside Xcode.
        print("[SolverAlternateClusteringTests] \(fixtureName): \(pairs.count) pairs, \(totalAlts) alternates")
        print("[SolverAlternateClusteringTests] csv: \(outPath)")

        // Sanity check: every successful solve produced AT LEAST one
        // alternate for a graph of this size. If `totalAlts == 0` the
        // diversity ladder collapsed to "no alternates qualify" for
        // every pair, which is a regression worth surfacing.
        XCTAssertGreaterThan(totalAlts, 0,
            "Solver produced 0 alternates across \(pairs.count) pairs on \(fixtureName) — diversity ladder likely too strict")

        // Soft target — informational only. Captured here so future
        // tuning of `pairwiseDistanceLadderMeters` can see the
        // distribution without re-deriving it from the CSV every
        // time. Quantiles are computed in the test, not asserted.
        let distancesFromPrimary = rows.dropFirst().compactMap { row -> Double? in
            let cols = row.split(separator: ",")
            guard cols.count >= 9, let d = Double(cols[8]) else { return nil }
            return d
        }.sorted()
        if !distancesFromPrimary.isEmpty {
            let p10 = quantile(distancesFromPrimary, q: 0.10)
            let p50 = quantile(distancesFromPrimary, q: 0.50)
            let p90 = quantile(distancesFromPrimary, q: 0.90)
            print(String(
                format: "[SolverAlternateClusteringTests] %@: dist_from_primary p10=%dm p50=%dm p90=%dm",
                fixtureName as NSString,
                Int(p10), Int(p50), Int(p90)
            ))
        }
    }

    // MARK: - Helpers

    private static func loadFixture(_ name: String) -> MountainGraph? {
        let bundle = Bundle(for: SolverAlternateClusteringTests.self)
        // Try Fixtures/ subdir first (preferred layout), then bundle
        // root (in case Xcode flattened the subdir at copy-resource
        // time). Returning nil is the gracefully-skip path; callers
        // throw `XCTSkip`.
        let candidate = bundle.url(forResource: name, withExtension: "json", subdirectory: "Fixtures")
            ?? bundle.url(forResource: name, withExtension: "json")
        guard let url = candidate else { return nil }
        do {
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode(MountainGraph.self, from: data)
        } catch {
            print("[SolverAlternateClusteringTests] fixture decode failed for \(name): \(error)")
            return nil
        }
    }

    /// Linear-interpolation quantile on a SORTED array. `q` in [0, 1].
    private func quantile(_ sorted: [Double], q: Double) -> Double {
        guard !sorted.isEmpty else { return .nan }
        if sorted.count == 1 { return sorted[0] }
        let pos = q * Double(sorted.count - 1)
        let lower = Int(pos.rounded(.down))
        let upper = min(lower + 1, sorted.count - 1)
        let frac = pos - Double(lower)
        return sorted[lower] * (1 - frac) + sorted[upper] * frac
    }
}
