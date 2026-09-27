import XCTest
@testable import PowderMeet

final class ConnectedTrailPathSearchTests: XCTestCase {
    private typealias Candidate = ConnectedTrailPathSearch.Candidate

    private func sample(_ id: String, from: String, to: String, along: Double = 20,
                        cost: Double = 0, stopped: Bool = false) -> Candidate {
        .init(edgeID: id, sourceID: from, targetID: to, alongMeters: along,
              cost: cost, isTerminalStationary: stopped)
    }

    func testForkAmbiguitySurvivesRejoiningTheSameFinalEdge() {
        let frames = [
            [sample("approach", from: "top", to: "split")],
            [sample("left", from: "split", to: "join"), sample("right", from: "split", to: "join")],
            [sample("finish", from: "join", to: "base")]
        ]
        guard case .failure(.ambiguousConnectedRoutes(let best, let alternative)) = ConnectedTrailPathSearch.resolve(frames) else {
            return XCTFail("Rejoining must not erase the earlier ambiguity")
        }
        XCTAssertEqual(best, ["approach", "left", "finish"])
        XCTAssertEqual(alternative, ["approach", "right", "finish"])
    }

    func testDifferentJunctionAssignmentsOfOneRouteAreNotAmbiguous() throws {
        let a = sample("upper", from: "top", to: "mid")
        let b = sample("lower", from: "mid", to: "base")
        let frames = [[a], [a, b], [b]]
        let indices = try ConnectedTrailPathSearch.resolve(frames).get()
        XCTAssertEqual(route(indices, frames: frames), ["upper", "lower"])
    }

    func testLaterEvidenceResolvesEarlierAmbiguity() throws {
        let frames = [
            [sample("a", from: "top-a", to: "join-a"), sample("b", from: "top-b", to: "join-b")],
            [sample("finish", from: "join-b", to: "base")]
        ]
        XCTAssertEqual(route(try ConnectedTrailPathSearch.resolve(frames).get(), frames: frames), ["b", "finish"])
    }

    func testFloatingPointTieIsNotAProbabilityThreshold() throws {
        let a = sample("a", from: "top", to: "base")
        let b = sample("b", from: "top", to: "base", cost: 1e-12)
        guard case .failure(.ambiguousConnectedRoutes) = ConnectedTrailPathSearch.resolve([[a, b]]) else {
            return XCTFail("Numerical noise must not choose a trail")
        }
        let separated = sample("b", from: "top", to: "base", cost: 0.01)
        XCTAssertEqual(try ConnectedTrailPathSearch.resolve([[a, separated]]).get(), [0])
    }

    func testSelfLoopCannotBypassBackwardGateButOtherIncomingStateSurvives() throws {
        let loop = sample("loop", from: "j", to: "j", along: 100)
        let retreat = sample("loop", from: "j", to: "j", along: 0)
        guard case .failure(.noConnectedTransition) = ConnectedTrailPathSearch.resolve([[loop], [retreat]]) else {
            return XCTFail("A self-loop must obey the same-edge movement gate")
        }
        let arriving = sample("approach", from: "top", to: "j", cost: 1)
        let frames = [[loop, arriving], [retreat]]
        XCTAssertEqual(route(try ConnectedTrailPathSearch.resolve(frames).get(), frames: frames), ["approach", "loop"])
    }

    func testStationaryFrameCannotTransferOrAddRepeatedVotes() throws {
        let a = sample("a", from: "top", to: "j")
        let b = sample("b", from: "j", to: "base", stopped: true)
        guard case .failure(.noConnectedTransition) = ConnectedTrailPathSearch.resolve([[a], [b]]) else {
            return XCTFail("No trail transfer from a stopped fix")
        }
        let c = sample("c", from: "other", to: "j", cost: 0.5)
        let stoppedA = sample("a", from: "top", to: "j", cost: 100, stopped: true)
        let stoppedC = sample("c", from: "other", to: "j", stopped: true)
        XCTAssertEqual(try ConnectedTrailPathSearch.resolve([[a, c], [stoppedA, stoppedC]]).get(), [0, 0])
    }

    func testIndexedSearchMatchesExhaustiveEnumeration() throws {
        // The independent oracle enumerates assignments, then deduplicates
        // complete edge sequences. It has no top-two or endpoint indexing.
        var state: UInt64 = 0x504F57444552
        func next(_ bound: Int) -> Int {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Int((state >> 32) % UInt64(bound))
        }
        let topology = [("a", "top", "j"), ("b", "top", "j"), ("c", "j", "base"), ("loop", "j", "j")]
        for trial in 0..<120 {
            let frames: [[Candidate]] = (0..<5).map { frame in
                let stopped = frame == 4 && next(3) == 0
                let chosen = topology.filter { _ in next(4) != 0 }
                return (chosen.isEmpty ? [topology[0]] : chosen).map { edge in
                    sample(edge.0, from: edge.1, to: edge.2, along: Double(next(5) * 20),
                           cost: Double(next(4)), stopped: stopped)
                }.sorted { $0.cost == $1.cost ? $0.edgeID < $1.edgeID : $0.cost < $1.cost }
            }
            var costs: [[String]: Double] = [:]
            func walk(_ indices: [Int], cost: Double) {
                let frame = indices.count
                if frame == frames.count {
                    let key = route(indices, frames: frames)
                    costs[key] = min(costs[key] ?? .infinity, cost)
                    return
                }
                for (i, candidate) in frames[frame].enumerated() {
                    if let last = indices.last {
                        let previous = frames[frame - 1][last]
                        let legal = previous.edgeID == candidate.edgeID
                            ? candidate.alongMeters >= previous.alongMeters - 15
                            : !candidate.isTerminalStationary && previous.targetID == candidate.sourceID
                        if !legal { continue }
                    }
                    walk(indices + [i], cost: cost + (frame > 0 && candidate.isTerminalStationary ? 0 : candidate.cost))
                }
            }
            walk([], cost: 0)
            let minimum = costs.values.min()
            let best = costs.filter { $0.value == minimum }
            let result = ConnectedTrailPathSearch.resolve(frames)
            switch result {
            case .success(let indices):
                XCTAssertEqual(best.count, 1, "trial \(trial)")
                XCTAssertNotNil(best[route(indices, frames: frames)], "trial \(trial)")
                let cost = indices.enumerated().reduce(0.0) { sum, item in
                    let candidate = frames[item.offset][item.element]
                    return sum + (item.offset > 0 && candidate.isTerminalStationary ? 0 : candidate.cost)
                }
                XCTAssertEqual(cost, minimum, "trial \(trial)")
            case .failure(.ambiguousConnectedRoutes(let first, let second)):
                XCTAssertGreaterThan(best.count, 1, "trial \(trial)")
                XCTAssertNotEqual(first, second)
                XCTAssertNotNil(best[first], "trial \(trial)")
                XCTAssertNotNil(best[second], "trial \(trial)")
            case .failure:
                XCTAssertTrue(costs.isEmpty, "trial \(trial): \(result)")
            }
        }
    }

    private func route(_ indices: [Int], frames: [[Candidate]]) -> [String] {
        var result: [String] = []
        for (frame, index) in indices.enumerated() {
            let id = frames[frame][index].edgeID
            if result.last != id { result.append(id) }
        }
        return result
    }
}
