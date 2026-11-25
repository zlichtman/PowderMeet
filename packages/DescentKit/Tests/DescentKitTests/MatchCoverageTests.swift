import Foundation
import MountainCore
import Testing
@testable import DescentKit

/// Per-resort naming coverage of the GPS corpus against a directory of bundles:
/// how many descents each resort gets, and how much of their time the matcher
/// puts on a named trail, on an unnamed edge, or off the map. A measurement, not
/// a gate: it runs only with `DESCENTKIT_BUNDLES` set, prints a table, and with
/// `DESCENTKIT_COVERAGE_OUT` set also writes the rows and the longest gaps as JSON.
struct MatchCoverageTests {
    struct Row: Codable {
        var resort: String
        var descents = 0, namedDescents = 0, unnamedDescents = 0, unmatchedDescents = 0
        var seconds = 0.0, namedSeconds = 0.0, unnamedSeconds = 0.0, offMapSeconds = 0.0
    }

    struct Gap: Codable {
        var resort: String, file: String, kind: String, seconds: Double
        var at: String, lon: Double, lat: Double, edge: String?
    }

    @Test(.enabled(if: MatchQualityTests.bundleDirectory != nil, "set DESCENTKIT_BUNDLES"))
    func namingCoveragePerResort() throws {
        let bundles = try MatchQualityTests.bundles(in: try #require(MatchQualityTests.bundleDirectory))
        var rows: [String: Row] = [:]
        var gaps: [Gap] = []
        for url in try CorpusTests.corpus() {
            for descent in try CorpusTests.imported(url).descents {
                let bundle = MatchQualityTests.resort(for: descent.points, in: bundles)
                let resort = bundle.map(\.resortID) ?? "(no bundle) " + url.deletingPathExtension().lastPathComponent
                var row = rows[resort] ?? Row(resort: resort)
                row.descents += 1
                let duration = descent.endedAt.timeIntervalSince(descent.startedAt)
                row.seconds += duration
                guard let bundle else {
                    row.unmatchedDescents += 1
                    row.offMapSeconds += duration
                    rows[resort] = row
                    continue
                }
                let match = TrailMatcher.match(descent: descent, in: bundle)
                if !match.isMatched {
                    row.unmatchedDescents += 1
                } else if match.sections.contains(where: { $0.kind != .offMap && $0.name != nil }) {
                    row.namedDescents += 1
                } else {
                    row.unnamedDescents += 1
                }
                for section in match.sections {
                    let named = section.kind != .offMap && section.name != nil
                    if named { row.namedSeconds += section.durationS }
                    else if section.kind == .offMap { row.offMapSeconds += section.durationS }
                    else { row.unnamedSeconds += section.durationS }
                    guard !named, section.durationS >= 20 else { continue }
                    let middle = section.enterAt.addingTimeInterval(section.durationS / 2)
                    let point = descent.points.min {
                        abs(($0.timestamp ?? .distantPast).timeIntervalSince(middle)) < abs(($1.timestamp ?? .distantPast).timeIntervalSince(middle))
                    }
                    gaps.append(Gap(
                        resort: resort, file: url.lastPathComponent,
                        kind: section.kind == .offMap ? "off_map" : "unnamed_\(section.kind.rawValue)",
                        seconds: section.durationS, at: ISO8601DateFormatter().string(from: section.enterAt),
                        lon: point?.lon ?? 0, lat: point?.lat ?? 0,
                        edge: section.edgeIDs.first?.rawValue
                    ))
                }
                rows[resort] = row
            }
        }
        for row in rows.values.sorted(by: { $0.resort < $1.resort }) {
            let time = max(row.seconds, 1)
            print(String(
                format: "Coverage %@: %d descents, %d named / %d unnamed / %d unmatched; time named %.3f unnamed %.3f off %.3f",
                row.resort, row.descents, row.namedDescents, row.unnamedDescents, row.unmatchedDescents,
                row.namedSeconds / time, row.unnamedSeconds / time, row.offMapSeconds / time
            ))
        }
        if let out = ProcessInfo.processInfo.environment["DESCENTKIT_COVERAGE_OUT"] {
            struct Report: Codable { var rows: [Row]; var gaps: [Gap] }
            let report = Report(
                rows: rows.values.sorted { $0.resort < $1.resort },
                gaps: gaps.sorted { $0.seconds > $1.seconds }
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(report).write(to: URL(fileURLWithPath: out))
        }
    }
}
