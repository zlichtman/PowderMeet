import Foundation
import Testing
@testable import DescentKit

/// Live recording must give the same runs as importing the day afterwards,
/// each run once, also when the app is relaunched halfway.
struct LiveRunBufferTests {
    @Test func fixByFixGivesTheSameRunsAsTheWholeDayOnceEach() throws {
        var day = SyntheticTrack.day(laps: 4)
        // A long stop at the bottom of a run must not close it early.
        day += SyntheticTrack.wait(at: day[day.count - 1], seconds: 900)
        let whole = DescentSegmenter.segments(ParsedActivity(source: .live, segments: [ParsedSegment(
            number: 0, startTime: nil, endTime: nil, durationS: nil, points: day
        )]))

        var buffer = LiveRunBuffer()
        var live: [Descent] = []
        for (index, point) in day.enumerated() {
            live += buffer.append(point, accuracyM: 5)
            if index == day.count / 2 {
                // The app is killed and relaunched: the buffer comes back from disk.
                buffer = try JSONDecoder().decode(LiveRunBuffer.self, from: JSONEncoder().encode(buffer))
            }
        }
        // The last lap has no lift after it, so only stopping closes it.
        #expect(live.count == whole.count - 1)
        live += buffer.flush()

        #expect(live.count == whole.count)
        for (recorded, imported) in zip(live, whole) {
            #expect(abs(recorded.startedAt.timeIntervalSince(imported.startedAt)) < 10)
            #expect(abs((recorded.stats.verticalM ?? 0) - (imported.stats.verticalM ?? 0)) < 20)
            #expect(recorded.source == .live)
        }
        #expect(buffer.isEmpty)
        #expect(buffer.flush().isEmpty)
    }

    /// One raw altitude spike during a pause used to read as a lift ride:
    /// the run was handed out and the rest of it became a second run.
    @Test func oneAltitudeGlitchDuringAPauseDoesNotSplitTheRun() {
        var day = [SyntheticTrack.origin]
        day += SyntheticTrack.lift(from: day[day.count - 1], climbM: 300, seconds: 400)
        day += SyntheticTrack.wait(at: day[day.count - 1], seconds: 40)
        day += SyntheticTrack.run(from: day[day.count - 1], dropM: 150, seconds: 90)
        var pause = SyntheticTrack.wait(at: day[day.count - 1], seconds: 90)
        pause[20].elevationM = (pause[20].elevationM ?? 0) + 40
        day += pause
        day += SyntheticTrack.run(from: day[day.count - 1], dropM: 150, seconds: 90)
        day += SyntheticTrack.wait(at: day[day.count - 1], seconds: 30)

        var buffer = LiveRunBuffer()
        var live: [Descent] = []
        for point in day { live += buffer.append(point, accuracyM: 5) }
        #expect(live.isEmpty)
        live += buffer.flush()
        #expect(live.count == 1)
        #expect(abs((live.first?.stats.verticalM ?? 0) - 300) < 20)
    }

    @Test func inaccurateAndRepeatedFixesAreDropped() {
        var buffer = LiveRunBuffer()
        let point = SyntheticTrack.origin
        _ = buffer.append(point, accuracyM: 5)
        _ = buffer.append(point, accuracyM: 5)
        var far = point
        far.timestamp = point.timestamp?.addingTimeInterval(5)
        _ = buffer.append(far, accuracyM: 120)
        #expect(buffer.points.count == 1)
    }
}
