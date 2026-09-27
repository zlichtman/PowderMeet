//
//  PendingLiveRunStoreTests.swift
//  PowderMeetTests
//
//  A live run saved without signal must survive until it can upload, exactly
//  once, and only under the account that recorded it.
//

import XCTest
@testable import PowderMeet

final class PendingLiveRunStoreTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PendingLiveRunStoreTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testQueuedRunRoundTripsExactlyAndDeduplicates() throws {
        let user = UUID()
        let run = row(user: user, hash: "live-a")
        PendingLiveRunStore.append(run, for: user, in: directory)
        PendingLiveRunStore.append(run, for: user, in: directory)

        let loaded = PendingLiveRunStore.load(for: user, in: directory)
        XCTAssertEqual(loaded.count, 1)
        let queued = try XCTUnwrap(loaded.first)
        XCTAssertEqual(queued.dedup_hash, "live-a")
        XCTAssertEqual(queued.run_at, run.run_at)
        XCTAssertEqual(queued.edge_observations, run.edge_observations)
        XCTAssertEqual(queued.trail_name, "Peak to Creek")
    }

    func testRemovingSentRunsKeepsRunsQueuedMeanwhileAndClearsFile() {
        let user = UUID()
        PendingLiveRunStore.append(row(user: user, hash: "sent"), for: user, in: directory)
        PendingLiveRunStore.append(row(user: user, hash: "queued-during-send"), for: user, in: directory)

        PendingLiveRunStore.remove(dedupHashes: ["sent"], for: user, in: directory)
        XCTAssertEqual(PendingLiveRunStore.load(for: user, in: directory).map(\.dedup_hash), ["queued-during-send"])

        PendingLiveRunStore.remove(dedupHashes: ["queued-during-send"], for: user, in: directory)
        XCTAssertFalse(PendingLiveRunStore.hasRows(for: user, in: directory))
    }

    func testQueuesAreIsolatedPerAccount() {
        let recorder = UUID()
        let nextSignIn = UUID()
        PendingLiveRunStore.append(row(user: recorder, hash: "mine"), for: recorder, in: directory)

        XCTAssertTrue(PendingLiveRunStore.load(for: nextSignIn, in: directory).isEmpty)
        XCTAssertFalse(PendingLiveRunStore.hasRows(for: nextSignIn, in: directory))
    }

    func testQueueKeepsNewestRunsWhenOffLongerThanTheCap() {
        let user = UUID()
        for index in 0...PendingLiveRunStore.maximumQueuedRuns {
            PendingLiveRunStore.append(row(user: user, hash: "run-\(index)"), for: user, in: directory)
        }
        let loaded = PendingLiveRunStore.load(for: user, in: directory)
        XCTAssertEqual(loaded.count, PendingLiveRunStore.maximumQueuedRuns)
        XCTAssertEqual(loaded.first?.dedup_hash, "run-1")
        XCTAssertEqual(loaded.last?.dedup_hash, "run-\(PendingLiveRunStore.maximumQueuedRuns)")
    }

    private func row(user: UUID, hash: String) -> ImportedRunWriteRow {
        ImportedRunWriteRow(
            profile_id: user.uuidString, resort_id: "whistler", edge_id: "edge",
            difficulty: "blue", speed_ms: 11, peak_speed_ms: 17, duration_s: 240,
            vertical_m: 410, distance_m: 2600, max_grade_deg: 18,
            run_at: Date(timeIntervalSince1970: 1_790_000_000), dedup_hash: hash,
            source: "live", source_file_hash: "live-\(user.uuidString)-1",
            raw_source_identity: "live-\(user.uuidString)-1",
            dataset_version: nil, matched_segment_ids: ["edge"],
            edge_observations: [EdgePaceObservation(
                edgeId: "edge", speedMs: 11, peakSpeedMs: 17, durationS: 240, distanceM: 2600
            )],
            match_confidence: 0.9, match_method: "connected", equipment_id_at_activity: nil,
            trail_name: "Peak to Creek", conditions_fp: "default"
        )
    }
}
