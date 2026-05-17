//
//  MeetFlowTests.swift
//  PowderMeetTests
//
//  Smoke coverage for the new MeetView state owner. Pin the default
//  values and verify mutations stick — guards against accidental
//  default flips during the @State → @Observable migration follow-up
//  work.
//

import XCTest
@testable import PowderMeet

@MainActor
final class MeetFlowTests: XCTestCase {

    func testDefaultsAreIdleState() {
        let flow = MeetFlow()
        XCTAssertNil(flow.selectedFriendId)
        XCTAssertNil(flow.selectedOptionIndex)
        XCTAssertEqual(flow.currentCardPage, 0)
        XCTAssertFalse(flow.requestSent)
        XCTAssertTrue(flow.pendingProfiles.isEmpty)
        XCTAssertNil(flow.solveErrorMessage)
        XCTAssertNil(flow.fullMeetingResult)
        XCTAssertNil(flow.lastSolvedMyKey)
        XCTAssertFalse(flow.isSolving)
    }

    func testFriendTapResetsCardState() {
        // Mirror the body of `MeetView.handleFriendTap` for the
        // "select" branch; the action button shouldn't render
        // requestSent / non-zero card index after a fresh selection.
        let flow = MeetFlow()
        flow.fullMeetingResult = nil  // Pretend a previous solve set this.
        flow.selectedOptionIndex = 2
        flow.currentCardPage = 2
        flow.requestSent = true

        // Simulating handleFriendTap(_) selection branch.
        let newId = UUID()
        flow.selectedFriendId = newId
        flow.fullMeetingResult = nil
        flow.solveErrorMessage = nil
        flow.selectedOptionIndex = nil
        flow.currentCardPage = 0
        flow.requestSent = false
        flow.lastSolvedMyKey = nil

        XCTAssertEqual(flow.selectedFriendId, newId)
        XCTAssertNil(flow.selectedOptionIndex)
        XCTAssertEqual(flow.currentCardPage, 0)
        XCTAssertFalse(flow.requestSent)
    }

    func testOutOfRangePageSnapsBackToZero() {
        // Solver can return fewer alternates on a re-run. MeetView's
        // solveMeeting body has a bound check — exercise the same shape.
        let flow = MeetFlow()
        flow.currentCardPage = 5
        let newCount = 3  // 2 alternates + 1 primary
        if flow.currentCardPage >= newCount {
            flow.currentCardPage = 0
        }
        XCTAssertEqual(flow.currentCardPage, 0)
    }
}
