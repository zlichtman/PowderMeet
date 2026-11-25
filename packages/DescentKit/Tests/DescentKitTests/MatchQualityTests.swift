import Foundation
import MountainCore
import Testing
@testable import DescentKit

/// Scores the trail matcher over the GPS corpus against the published resort
/// bundles. The bundles are not in the repository: set `DESCENTKIT_BUNDLES`
/// to a directory of `<resort>.json.gz` bundle files to run it; without it
/// the test is skipped. Thresholds sit just under what MatcherVersion 2
/// scored over a larger corpus (17 resorts, 531 descents): matched 97.4 %, time on
/// the map 85.5 %, placed frames within 30 m 93.1 %, 2.62 section changes
/// per km, Slopes run time on the map 85.7 %, Slopes lift time inside
/// descents 0.4 %, simulated descents on their true trail 95.8 %, about
/// 15 ms per descent in a debug build on an M-series Mac.
///
/// Slopes exports say when the skier was on a lift and when on a run, not
/// which trail, so trail identity is scored on simulated descents: random
/// downhill paths through each graph, a fix every 4 s at 10 m/s with 6 m
/// noise and a wander of up to 20 m across the trail; and, harder, the
/// `MatchScorecard` descents from lift tops at 1 Hz with a wandering GPS bias.
///
/// MatcherVersion 3 on the 15 published resorts (410 descents, bundle ids
/// as published on 2026-11-21): 16 unmatched, 80.3 % of time named, 48
/// flickers (146 under version 2); scorecard main trail exact 96.3 % (94.1 %),
/// within one 100 %, fixes on the true trail 95.2 % (94.9 %).
struct MatchQualityTests {
    static let bundleDirectory = ProcessInfo.processInfo.environment["DESCENTKIT_BUNDLES"]

    @Test(.enabled(if: bundleDirectory != nil, "set DESCENTKIT_BUNDLES to the published bundles"))
    func corpusMatchesWellAgainstThePublishedBundles() throws {
        let bundles = try Self.bundles(in: try #require(Self.bundleDirectory))
        try #require(!bundles.isEmpty)

        var descents = 0, matched = 0, frames = 0, within30 = 0, changes = 0, repeats = 0, unnamedLabels = 0
        var time = 0.0, matchedTime = 0.0, sectionTime = 0.0, onMapTime = 0.0, distance = 0.0, elapsed = 0.0
        var slopesRunInside = 0.0, slopesRunOnMap = 0.0, liftTime = 0.0, liftInside = 0.0
        let expected = try CorpusTests.expected()
        var rows: [MatchScorecard.LogRow] = []
        var table = "log\truns\ttruth\tplaced\tunmatched\tnamed%\tunnamed%\toffNear%\toffFar%\trepeats\tflickers\n"
        for url in try CorpusTests.corpus() {
            let file = try CorpusTests.imported(url).descents
            let row = MatchScorecard.row(for: url, descents: file, bundles: bundles)
            rows.append(row)
            let truth = expected.files[url.lastPathComponent]?.descents ?? 0
            let t = max(row.seconds, 1)
            table += String(
                format: "%@\t%d\t%d\t%d\t%d\t%.1f\t%.1f\t%.1f\t%.1f\t%d\t%d\n", row.file, row.descents, truth,
                row.placed, row.unmatched, 100 * row.namedSeconds / t, 100 * row.unnamedSeconds / t,
                100 * row.offNearSeconds / t, 100 * row.offFarSeconds / t, row.repeats, row.flickers
            )
            var placed: [DescentMatch] = []
            for descent in file {
                guard let bundle = Self.resort(for: descent.points, in: bundles) else { continue }
                let clock = ContinuousClock.now
                let match = TrailMatcher.match(descent: descent, in: bundle)
                elapsed += Self.seconds(ContinuousClock.now - clock)
                placed.append(match)
                descents += 1
                let duration = descent.endedAt.timeIntervalSince(descent.startedAt)
                time += duration
                if match.isMatched { matched += 1; matchedTime += duration }
                let stored = match.matched.map(\.edgeID.stored)
                if Set(stored).count < stored.count { repeats += 1 }
                if match.isMatched, let id = match.primaryEdgeID, let edge = bundle.graph.edge(id),
                   edge.name == nil, edge.group.flatMap({ bundle.group($0) }) == nil { unnamedLabels += 1 }
                for section in match.sections {
                    sectionTime += section.durationS
                    if section.kind != .offMap { onMapTime += section.durationS }
                    distance += section.distanceM
                }
                changes += max(0, match.sections.count - 1)
                if case .success(let raw) = TrailMatcher(graph: bundle.graph).evaluate(descent.points) {
                    frames += raw.frames.filter { $0.edgeID != nil }.count
                    within30 += raw.frames.filter { $0.edgeID != nil && $0.distanceM <= 30 }.count
                }
            }
            for action in Self.slopesActions(url) ?? [] {
                if action.isRun {
                    for section in placed.flatMap(\.sections) {
                        let shared = Self.overlap(section.enterAt, section.exitAt, action.start, action.end)
                        slopesRunInside += shared
                        if section.kind != .offMap { slopesRunOnMap += shared }
                    }
                } else {
                    liftTime += action.end.timeIntervalSince(action.start)
                    liftInside += file.reduce(0) { $0 + Self.overlap($1.startedAt, $1.endedAt, action.start, action.end) }
                }
            }
        }
        let synthetic = Self.simulatedShareOnTheTrueTrail(bundles)
        var realistic = MatchScorecard.SyntheticScore()
        for (index, bundle) in bundles.enumerated() {
            let score = MatchScorecard.simulated(bundle, count: 40, seed: 7 + UInt64(index))
            realistic.add(score)
            table += String(
                format: "sim %@\t%d\tmain %.3f\twithin one %.3f\tunmatched %.3f\tfixes %.3f\tsequence %.3f\n",
                bundle.resortID, score.descents, score.mainExactShare, score.mainWithinOneShare,
                score.unmatchedShare, score.fixShare, score.sequenceShare
            )
        }
        let placedSeconds = rows.reduce(0) { $0 + ($1.placed > 0 ? $1.seconds : 0) }
        table += String(
            format: "overall: unmatched %d of %d; named %.3f offNear %.3f offFar %.3f; repeats %d flickers %d; sim main %.3f within one %.3f unmatched %.3f fixes %.3f sequence %.3f\n",
            rows.reduce(0) { $0 + $1.unmatched }, rows.reduce(0) { $0 + $1.placed },
            rows.reduce(0) { $0 + $1.namedSeconds } / placedSeconds, rows.reduce(0) { $0 + $1.offNearSeconds } / placedSeconds,
            rows.reduce(0) { $0 + $1.offFarSeconds } / placedSeconds, rows.reduce(0) { $0 + $1.repeats },
            rows.reduce(0) { $0 + $1.flickers }, realistic.mainExactShare, realistic.mainWithinOneShare,
            realistic.unmatchedShare, realistic.fixShare, realistic.sequenceShare
        )
        print(table)
        if let path = ProcessInfo.processInfo.environment["DESCENTKIT_MATCH_REPORT"] {
            try table.write(toFile: path, atomically: true, encoding: .utf8)
        }

        let score = (
            matched: Double(matched) / Double(descents), matchedTime: matchedTime / time,
            onMap: onMapTime / sectionTime, within30: Double(within30) / Double(frames),
            changesPerKm: Double(changes) / (distance / 1_000),
            slopesRunOnMap: slopesRunOnMap / slopesRunInside, liftInside: liftInside / liftTime,
            synthetic: synthetic, msPerDescent: 1_000 * elapsed / Double(descents)
        )
        print("MatchQuality \(descents) descents: \(score); repeated edges in \(repeats), unnamed labels \(unnamedLabels)")
        // Alpine Valley and Snow King (98 descents) have no published bundle yet.
        #expect(descents > 400)
        #expect(rows.reduce(0) { $0 + $1.flickers } <= 60)
        #expect(realistic.mainExactShare >= 0.95)
        #expect(realistic.unmatchedShare <= 0.01)
        #expect(realistic.fixShare >= 0.94)
        #expect(score.matched >= 0.95)
        #expect(score.matchedTime >= 0.92)
        #expect(score.onMap >= 0.82)
        #expect(score.within30 >= 0.90)
        #expect(score.changesPerKm <= 3.0)
        #expect(score.slopesRunOnMap >= 0.83)
        #expect(score.liftInside <= 0.01)
        #expect(score.synthetic >= 0.93)
    }

    // MARK: - Helpers

    static func bundles(in directory: String) throws -> [ResortBundle] {
        let urls = try FileManager.default.contentsOfDirectory(
            at: URL(fileURLWithPath: directory), includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.hasSuffix(".json.gz") }.sorted { $0.path < $1.path }
        return try urls.map { url in
            let data = try Data(contentsOf: url)
            return try BundleLoader.load(data: data, expectedID: try #require(BundleID(SHA256.hex(data))))
        }
    }

    /// The published resort whose bounding box holds the middle of the track,
    /// as the import path chooses it.
    static func resort(for points: [TrackPoint], in bundles: [ResortBundle]) -> ResortBundle? {
        guard !points.isEmpty else { return nil }
        let middle = points[points.count / 2].coordinate
        return bundles.filter { $0.bbox.contains(middle) }
            .min { Geo.haversineM($0.center, middle) < Geo.haversineM($1.center, middle) }
    }

    static func slopesActions(_ url: URL) -> [SlopesMetadata.Action]? {
        guard url.pathExtension == "slopes", let data = try? Data(contentsOf: url),
              let reader = try? ZipReader(data: data), let entry = reader.entry(named: "Metadata.xml"),
              let xml = try? reader.read(entry) else { return nil }
        return SlopesMetadata.parse(xml)?.actions
    }

    static func overlap(_ a: Date, _ b: Date, _ c: Date, _ d: Date) -> Double {
        max(0, min(b, d).timeIntervalSince(max(a, c)))
    }

    static func seconds(_ d: Duration) -> Double {
        Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
    }

    /// Deterministic SplitMix64.
    struct Random {
        var state: UInt64
        mutating func next() -> Double {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return Double((z ^ (z >> 31)) >> 11) / Double(UInt64(1) << 53)
        }
        mutating func index(_ count: Int) -> Int { min(count - 1, Int(next() * Double(count))) }
        mutating func gaussian() -> Double {
            (-2 * log(max(1e-12, next()))).squareRoot() * cos(2 * .pi * next())
        }
    }

    /// Trail identity as sections are built: group, else name and kind.
    static func identity(_ edge: Edge) -> String {
        edge.group.map { "g:" + $0.rawValue } ?? "n:\(edge.name ?? ""):\(edge.kind == .run ? "run" : "connection")"
    }

    static func identity(_ section: RunSection) -> String {
        guard section.kind != .offMap else { return "off" }
        return section.groupID.map { "g:" + $0.rawValue }
            ?? "n:\(section.name ?? ""):\(section.kind == .run ? "run" : "connection")"
    }

    /// Share of simulated fixes whose section is the trail they were drawn on.
    static func simulatedShareOnTheTrueTrail(_ bundles: [ResortBundle]) -> Double {
        var random = Random(state: 42)
        var correct = 0, total = 0
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        for bundle in bundles {
            let graph = bundle.graph
            let starts = graph.edges.filter { $0.kind == .run && $0.lengthM > 150 && $0.geometry.count >= 2 }
            guard !starts.isEmpty else { continue }
            for _ in 0..<20 {
                var edge = starts[random.index(starts.count)]
                var path = [edge], length = edge.lengthM
                while length < 1_500 {
                    let next = graph.outgoing(from: edge.to).filter { $0.kind != .lift && $0.geometry.count >= 2 }
                    guard !next.isEmpty else { break }
                    edge = next[random.index(next.count)]
                    path.append(edge)
                    length += edge.lengthM
                }
                var points: [TrackPoint] = [], truth: [String] = []
                var wander = 0.0, clock = 0.0, carry = 0.0
                for edge in path {
                    for (a, b) in zip(edge.geometry, edge.geometry.dropFirst()) {
                        let segment = Geo.haversineM(a.coordinate, b.coordinate)
                        guard segment > 0 else { continue }
                        var s = carry
                        while s < segment {
                            let f = s / segment
                            let lat = a.lat + (b.lat - a.lat) * f, lon = a.lon + (b.lon - a.lon) * f
                            let ky = 111_132.0, kx = 111_320.0 * cos(lat * .pi / 180)
                            // Unit normal to the segment, in metres.
                            let nx = -(b.lat - a.lat) * ky, ny = (b.lon - a.lon) * kx
                            let norm = max(1e-9, (nx * nx + ny * ny).squareRoot())
                            wander = max(-20, min(20, wander + random.gaussian() * 4))
                            let ex = wander * nx / norm + random.gaussian() * 6
                            let ey = wander * ny / norm + random.gaussian() * 6
                            points.append(TrackPoint(
                                lat: lat + ey / ky, lon: lon + ex / kx, elevationM: a.eleM + (b.eleM - a.eleM) * f,
                                timestamp: start.addingTimeInterval(clock)
                            ))
                            truth.append(identity(edge))
                            clock += 4
                            s += 40
                        }
                        carry = s - segment
                    }
                }
                guard points.count >= 5 else { continue }
                // A path whose bundle elevations do not fall is still a descent.
                if let top = points.first?.elevationM, let bottom = points.last?.elevationM, bottom > top - 5 {
                    for i in points.indices { points[i].elevationM = nil }
                }
                let descent = Descent(
                    source: .gpx, startedAt: start, endedAt: start.addingTimeInterval(clock - 4), points: points
                )
                let sections = TrailMatcher.match(descent: descent, in: bundle).sections
                for (i, point) in points.enumerated() {
                    guard let t = point.timestamp else { continue }
                    total += 1
                    if let section = sections.first(where: { $0.enterAt <= t && t < $0.exitAt }) ?? sections.last,
                       identity(section) == truth[i] {
                        correct += 1
                    }
                }
            }
        }
        return total > 0 ? Double(correct) / Double(total) : 0
    }
}
