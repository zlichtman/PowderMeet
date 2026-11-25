import Foundation
import Testing
@testable import DescentKit

/// A run's top speed is the speed held for 3 s, not a GPS peak, so a fix
/// snap cannot put a 30 m/s figure on a profile card.
struct TopSpeedTests {
    /// Each Slopes run with the imported descent that overlaps it most; the
    /// action carries Slopes' own `topSpeed`.
    private static func slopesPairs(_ url: URL) throws -> [(action: SlopesMetadata.Action, descent: Descent)] {
        let reader = try ZipReader(data: Data(contentsOf: url))
        let entry = try #require(reader.entry(named: "Metadata.xml"))
        let metadata = try #require(SlopesMetadata.parse(reader.read(entry)))
        let descents = try CorpusTests.imported(url).descents
        return metadata.runs.compactMap { action in
            let best = descents.max { overlap($0, action) < overlap($1, action) }
            guard let best, overlap(best, action) > 0.25 * action.durationS else { return nil }
            return (action, best)
        }
    }

    private static func overlap(_ descent: Descent, _ action: SlopesMetadata.Action) -> TimeInterval {
        max(0, min(descent.endedAt, action.end).timeIntervalSince(max(descent.startedAt, action.start)))
    }

    /// Descent 11 (counting from 0) of the 4 January Big Sky day showed
    /// 30.0 m/s while the phone's own speed never passed 10.4.
    @Test func bigSkyRun11IsNotAGPSSpike() throws {
        let url = CorpusTests.log("2025-01-04-big-sky.slopes")
        let descent = try CorpusTests.imported(url).descents[11]
        let reported = descent.points.compactMap(\.speedMS).max() ?? 0
        #expect(reported > 10 && reported < 10.5, "the phone's own peak was 10.4 m/s")
        let top = try #require(descent.stats.topSpeedMS)
        #expect(top <= reported, "\(top) m/s")
        #expect(top > 7, "\(top) m/s")
        let slopes = try #require(Self.slopesPairs(url).first { $0.descent.startedAt == descent.startedAt })
        #expect(top <= slopes.action.topSpeedMS + 3.5)
    }

    /// Slopes' figure is the reference where the file has one. Ours may be
    /// lower, because a speed must be held for 3 s, but never believably
    /// higher.
    @Test func everyCorpusRunHasABelievableTopSpeed() throws {
        var checked = 0
        var highest = 0.0
        for url in try CorpusTests.corpus() {
            let name = url.lastPathComponent
            if url.pathExtension == "slopes" {
                for (action, descent) in try Self.slopesPairs(url) {
                    let top = try #require(descent.stats.topSpeedMS, "\(name) run \(action.number)")
                    #expect(top <= GPXSpeedStats.peakSpeedCeiling)
                    highest = max(highest, top)
                    guard action.topSpeedMS > 0 else { continue }
                    checked += 1
                    #expect(top <= action.topSpeedMS + 3.5,
                            "\(name) run \(action.number): \(top) m/s, Slopes says \(action.topSpeedMS)")
                }
            } else {
                for descent in try CorpusTests.imported(url).descents {
                    let top = descent.stats.topSpeedMS ?? 0
                    highest = max(highest, top)
                    #expect(top <= GPXSpeedStats.peakSpeedCeiling, "\(name)")
                }
            }
        }
        #expect(checked > 300, "only \(checked) runs had a Slopes figure")
        print("TOPSPEED checked=\(checked) highest=\(highest)")
    }

    @Test func aSpikeInsideTheTrackIsNotHeldLongEnough() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let points = (0..<20).map { i in
            TrackPoint(
                lat: 50 - Double(i) * 0.00008, lon: -122, elevationM: 1_800 - Double(i),
                timestamp: start.addingTimeInterval(Double(i)), speedMS: i == 10 ? 40 : 9
            )
        }
        #expect(GPXSpeedStats.peakSpeed(points) == 9)
        #expect(GPXSpeedStats.topSpeed(points: points, claimed: 30) == 9)
        #expect(GPXSpeedStats.topSpeed(points: points, claimed: 11) == 11)
    }

    @Test func fileWithoutSpeedsUsesStraightLineDistance() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        var points = (0..<30).map { i in
            TrackPoint(
                lat: 50 + Double(i) * 10 / 111_195, lon: -122, elevationM: 1_800 - Double(i),
                timestamp: start.addingTimeInterval(Double(i))
            )
        }
        #expect(abs(GPXSpeedStats.peakSpeed(points) - 10) < 0.1)
        // One fix thrown 400 m off does not make the run fast.
        points[15].lat += 400 / 111_195
        let top = GPXSpeedStats.peakSpeed(points)
        #expect(abs(top - 10) < 0.1, "got \(top)")
    }
}
