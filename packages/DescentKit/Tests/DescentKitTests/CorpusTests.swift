import Foundation
import MountainCore
import Testing
@testable import DescentKit

/// The GPS corpus is real ski-day data from several resorts and trackers, so a
/// parser or segmenter regression that only shows up on production files
/// fails here. `Fixtures/expected.json` holds the truth per file: the file's
/// own run list and total where it has one, a hand reading of the elevation
/// profile where it has none or where its list is physically wrong. None of it
/// is this package's output.
struct CorpusTests {
    struct Expected: Decodable {
        struct File: Decodable {
            var sourceApp: String
            var format: String
            var descents: Int
            var verticalM: Double
            var truth: String

            private enum CodingKeys: String, CodingKey {
                case sourceApp = "source_app"
                case format, descents, truth
                case verticalM = "vertical_m"
            }
        }
        var files: [String: File]
        /// SHA-256 of every descent's content hash, one per line, in file
        /// order. The same value on macOS and Linux is the proof that
        /// importing and hashing are stable across platforms.
        var hashDigest: String

        private enum CodingKeys: String, CodingKey {
            case files
            case hashDigest = "hash_digest"
        }
    }

    static let fixtures: URL = {
        guard let url = Bundle.module.url(forResource: "Fixtures", withExtension: nil) else {
            fatalError("Fixtures folder is missing from the test bundle")
        }
        return url
    }()

    /// Every log in `Fixtures/GPSLogs/<format>/`, ordered by file name, which
    /// starts with the day.
    static func corpus() throws -> [URL] {
        let root = fixtures.appendingPathComponent("GPSLogs")
        return try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { !$0.lastPathComponent.hasPrefix(".") }
            .flatMap { try FileManager.default.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil) }
            .filter { !$0.lastPathComponent.hasPrefix(".") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// One corpus log by file name; its folder is its extension.
    static func log(_ name: String) -> URL {
        fixtures.appendingPathComponent("GPSLogs")
            .appendingPathComponent((name as NSString).pathExtension)
            .appendingPathComponent(name)
    }

    static func expected() throws -> Expected {
        try JSONDecoder().decode(
            Expected.self, from: Data(contentsOf: fixtures.appendingPathComponent("expected.json"))
        )
    }

    static func imported(_ url: URL) throws -> ImportedActivity {
        try ActivityImporter.importActivity(fileName: url.lastPathComponent, data: Data(contentsOf: url))
    }

    /// Descents within 1 (or 5 %) of the truth and vertical within 8 %.
    static func withinTolerance(descents: Int, verticalM: Double, of truth: Expected.File) -> Bool {
        let allowed = max(1, Int((Double(truth.descents) * 0.05).rounded(.down)))
        return abs(descents - truth.descents) <= allowed
            && abs(verticalM - truth.verticalM) <= 0.08 * truth.verticalM
    }

    @Test func everyCorpusFileImportsWithinToleranceOfTheTruth() throws {
        let expected = try Self.expected()
        let urls = try Self.corpus()
        #expect(urls.count == 39)
        #expect(Set(urls.map(\.lastPathComponent)) == Set(expected.files.keys))

        var report = "file\tsource app\tformat\tresult\tdescents ours\tdescents truth\tvertical ours\tvertical truth\ttruth from\tpass\n"
        var exact = 0
        for url in urls {
            let name = url.lastPathComponent
            let truth = try #require(expected.files[name])
            let result = try Self.imported(url)
            let vertical = result.totalVerticalM
            let pass = Self.withinTolerance(descents: result.descents.count, verticalM: vertical, of: truth)
            #expect(pass, "\(name): \(result.descents.count) descents, \(Int(vertical)) m; truth \(truth.descents), \(Int(truth.verticalM)) m")
            #expect(result.format?.rawValue == truth.format, "\(name)")
            #expect(truth.sourceApp.hasPrefix(result.sourceApp ?? "?"), "\(name): \(result.sourceApp ?? "nil")")
            if result.descents.count == truth.descents { exact += 1 }
            for descent in result.descents {
                #expect(descent.points.count >= 2, "\(name)")
                #expect(descent.endedAt > descent.startedAt, "\(name)")
                #expect(descent.points.allSatisfy { $0.timestamp != nil }, "\(name)")
            }
            for (earlier, later) in zip(result.descents, result.descents.dropFirst()) {
                #expect(later.startedAt >= earlier.endedAt, "\(name): descents overlap in time")
            }
            report += "\(name)\t\(truth.sourceApp)\t\(truth.format)\tparsed\t\(result.descents.count)\t\(truth.descents)\t\(Int(vertical))\t\(Int(truth.verticalM))\t\(truth.truth)\t\(pass ? "yes" : "NO")\n"
        }
        // Exact agreement is not required of any one file, but most must have it.
        #expect(exact >= 36, "only \(exact) of 39 files have exactly the true descent count")
        if let path = ProcessInfo.processInfo.environment["DESCENTKIT_REPORT"] {
            try report.write(toFile: path, atomically: true, encoding: .utf8)
        }
    }

    /// The harder case, and the one every GPX, TCX and FIT import depends on:
    /// the same Slopes days with the run list thrown away, so the segmenter
    /// has only the GPS log.
    @Test func segmenterAloneFindsTheRunsInSlopesDays() throws {
        let expected = try Self.expected()
        var report = ""
        var exact = 0
        var withinOne = 0
        var total = 0
        for url in try Self.corpus() where url.pathExtension == "slopes" {
            let name = url.lastPathComponent
            let truth = try #require(expected.files[name])
            let activity = try SlopesParser.parse(Data(contentsOf: url), honouringRunList: false)
            let descents = DescentSegmenter.segments(activity)
            let difference = abs(descents.count - truth.descents)
            let allowed = max(2, Int((Double(truth.descents) * 0.10).rounded(.down)))
            #expect(difference <= allowed, "\(name): \(descents.count) from the track alone, truth \(truth.descents)")
            total += 1
            if difference == 0 { exact += 1 }
            if difference <= 1 { withinOne += 1 }
            report += "\(name)\t\(descents.count)\t\(truth.descents)\n"
        }
        #expect(total == 37)
        #expect(exact >= 23, "exact on only \(exact) of \(total)")
        #expect(withinOne >= 35, "within one on only \(withinOne) of \(total)")
        if let path = ProcessInfo.processInfo.environment["DESCENTKIT_REPORT"] {
            try report.write(toFile: path + ".track-only", atomically: true, encoding: .utf8)
        }
    }

    @Test func contentHashesAreStableAndDistinct() throws {
        let expected = try Self.expected()
        var all: [String] = []
        for url in try Self.corpus() {
            let name = url.lastPathComponent
            let first = try Self.imported(url).descents.map(DescentHasher.contentHash)
            let second = try Self.imported(url).descents.map(DescentHasher.contentHash)
            #expect(first == second, "\(name): hashes changed between two parses")
            #expect(Set(first).count == first.count, "\(name): two descents share a hash")
            #expect(first.allSatisfy { $0.utf8.count == 64 }, "\(name)")
            all += first
        }
        #expect(SHA256.hex(Data(all.joined(separator: "\n").utf8)) == expected.hashDigest)
    }

    @Test func hashIgnoresSourceAndStatisticsButNotTheTrack() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let points = (0..<60).map { i in
            TrackPoint(
                lat: 50.1 - Double(i) * 0.0001, lon: -122.95, elevationM: 1_800 - Double(i) * 3,
                timestamp: start.addingTimeInterval(Double(i))
            )
        }
        let end = start.addingTimeInterval(59)
        let fromSlopes = Descent(
            source: .slopes, startedAt: start, endedAt: end, points: points,
            stats: DescentStats(topSpeedMS: 14)
        )
        let live = Descent(source: .live, startedAt: start, endedAt: end, points: points)
        #expect(DescentHasher.contentHash(fromSlopes) == DescentHasher.contentHash(live))

        var moved = points
        moved[30].lat += 0.001
        let other = Descent(source: .live, startedAt: start, endedAt: end, points: moved)
        #expect(DescentHasher.contentHash(other) != DescentHasher.contentHash(live))

        // A stationary wait before and after the run does not change it.
        let wait = (1...20).map { i in
            TrackPoint(lat: 50.1, lon: -122.95, elevationM: 1_800, timestamp: start.addingTimeInterval(Double(-i)))
        }.reversed()
        let after = (1...20).map { i in
            TrackPoint(
                lat: points[59].lat, lon: -122.95, elevationM: points[59].elevationM,
                timestamp: end.addingTimeInterval(Double(i))
            )
        }
        let padded = Descent(source: .live, startedAt: start, endedAt: end, points: wait + points + after)
        #expect(DescentHasher.contentHash(padded) == DescentHasher.contentHash(live))
    }
}
