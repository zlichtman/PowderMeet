//
//  AnimationTimeline.swift
//  PowderMeet
//
//  Generic, map-agnostic timeline DSL. A timeline is a list of `Beat`s —
//  each a work closure scheduled at a specific offset from start. The
//  timeline runs on an injected `Clock`, so production code uses the
//  system clock while tests can inject a `ContinuousClock` or a manual
//  clock to scrub through beats deterministically.
//
//  Why not Timer / Combine / CADisplayLink:
//   - Cancelling a `Task`-driven sequence unwinds every pending `Task.sleep`
//     atomically on one `.cancel()`. Multiple timers need bespoke teardown.
//   - Each beat is naturally annotated with a label for `os_signpost` debug.
//   - Testability: an injected clock makes the whole sequence pure.
//

import Foundation
import os

struct Beat: Sendable {
    let offset: Duration
    let label: String
    let work: @MainActor @Sendable () -> Void

    static func at(_ offset: Duration, _ label: String, _ work: @escaping @MainActor @Sendable () -> Void) -> Beat {
        Beat(offset: offset, label: label, work: work)
    }
}

extension Duration {
    static func ms(_ value: Int) -> Duration { .milliseconds(value) }
}

struct AnimationTimeline: Sendable {
    let name: String
    let beats: [Beat]

    /// Runs every beat in order on the given clock. Sleeps between beats
    /// are cooperative — cancelling the outer Task aborts cleanly.
    /// Emits `os_signpost` intervals per beat for Instruments visibility.
    @MainActor
    func run<C: Clock>(on clock: C = ContinuousClock()) async where C.Duration == Duration {
        let signposter = OSSignposter(subsystem: "com.powdermeet", category: "choreography")
        let start = clock.now
        for beat in beats {
            let target = start.advanced(by: beat.offset)
            do {
                try await clock.sleep(until: target, tolerance: nil)
            } catch is CancellationError {
                return
            } catch {
                // Non-cancellation sleep failures shouldn't happen on
                // ContinuousClock, but if a custom clock throws we want
                // a trace instead of silent timeline death.
                let logger = Logger(subsystem: "com.powdermeet", category: "choreography")
                logger.error("[\(name).\(beat.label)] sleep failed: \(error.localizedDescription)")
                return
            }
            if Task.isCancelled { return }
            let signpostID = signposter.makeSignpostID()
            let state = signposter.beginInterval("beat", id: signpostID, "\(name).\(beat.label)")
            beat.work()
            signposter.endInterval("beat", state)
        }
    }
}
