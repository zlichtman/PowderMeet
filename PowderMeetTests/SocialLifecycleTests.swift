//
//  SocialLifecycleTests.swift
//  PowderMeetTests
//

import XCTest
@testable import PowderMeet

final class SocialLifecycleTests: XCTestCase {
    private func meetRequest(
        id: UUID = UUID(),
        senderID: UUID,
        receiverID: UUID,
        status: MeetRequestStatus = .accepted,
        createdAt: Date?,
        datasetVersion: String? = "manifest-1:graph-11:sha"
    ) -> MeetRequest {
        MeetRequest(
            id: id,
            senderId: senderID,
            receiverId: receiverID,
            resortId: "vail",
            meetingNodeId: "lift-base",
            meetingNodeElevation: 2_500,
            meetingNodeDisplayName: "Gondola Base",
            senderPositionNodeId: "sender-start",
            receiverPositionNodeId: "receiver-start",
            senderEtaSeconds: 300,
            receiverEtaSeconds: 360,
            senderPathEdgeIds: ["sender-edge"],
            receiverPathEdgeIds: ["receiver-edge"],
            status: status,
            createdAt: createdAt,
            expiresAt: nil,
            graphSnapshotDate: "2026-08-13",
            manifestVersion: 1,
            datasetVersion: datasetVersion
        )
    }

    func testMeetRequestLegalTransitions() {
        XCTAssertEqual(
            MeetRequestStateMachine.next(from: .pending, on: .accept),
            .accepted
        )
        XCTAssertEqual(
            MeetRequestStateMachine.next(from: .pending, on: .decline),
            .declined
        )
        XCTAssertEqual(
            MeetRequestStateMachine.next(from: .pending, on: .expire),
            .expired
        )
        XCTAssertEqual(
            MeetRequestStateMachine.next(from: .accepted, on: .expire),
            .expired
        )
    }

    func testMeetRequestIllegalAndDuplicateTransitionsAreRejected() {
        for terminal in [MeetRequestStatus.declined, .expired] {
            XCTAssertNil(MeetRequestStateMachine.next(from: terminal, on: .accept))
            XCTAssertNil(MeetRequestStateMachine.next(from: terminal, on: .decline))
            XCTAssertNil(MeetRequestStateMachine.next(from: terminal, on: .expire))
        }
        XCTAssertNil(MeetRequestStateMachine.next(from: .accepted, on: .accept))
        XCTAssertNil(MeetRequestStateMachine.next(from: .accepted, on: .decline))
        XCTAssertFalse(MeetRequestStatus.pending.isTerminal)
        XCTAssertFalse(MeetRequestStatus.accepted.isTerminal)
        XCTAssertTrue(MeetRequestStatus.declined.isTerminal)
        XCTAssertTrue(MeetRequestStatus.expired.isTerminal)
    }

    func testMeetRequestStatusDecodesFromExistingWireShape() throws {
        let json = """
        {
          "id": "11111111-1111-1111-1111-111111111111",
          "sender_id": "22222222-2222-2222-2222-222222222222",
          "receiver_id": "33333333-3333-3333-3333-333333333333",
          "resort_id": "test",
          "meeting_node_id": "base-1",
          "meeting_node_elevation": 2500,
          "status": "accepted"
        }
        """
        let request = try JSONDecoder().decode(MeetRequest.self, from: Data(json.utf8))
        XCTAssertEqual(request.status, .accepted)
        XCTAssertEqual(request.meetingNodeId, "base-1")
    }

    func testFriendshipStatusDecodesFromExistingWireShape() throws {
        let json = """
        {
          "id": "11111111-1111-1111-1111-111111111111",
          "requester_id": "22222222-2222-2222-2222-222222222222",
          "addressee_id": "33333333-3333-3333-3333-333333333333",
          "status": "pending"
        }
        """
        let friendship = try JSONDecoder().decode(Friendship.self, from: Data(json.utf8))
        XCTAssertEqual(friendship.status, .pending)
    }

    func testUnknownWireStatusesFailClosed() {
        XCTAssertThrowsError(try JSONDecoder().decode(
            MeetRequestStatus.self,
            from: Data("\"cancelled\"".utf8)
        ))
        XCTAssertThrowsError(try JSONDecoder().decode(
            FriendshipStatus.self,
            from: Data("\"mystery\"".utf8)
        ))
    }

    func testSubscriptionStateRejectsDuplicateAndConcurrentStarts() {
        let name = "meets:user"
        XCTAssertTrue(RealtimeSubscriptionState.stopped.canBegin(channelName: name))
        XCTAssertFalse(
            RealtimeSubscriptionState.connecting(channelName: name)
                .canBegin(channelName: name)
        )
        XCTAssertFalse(
            RealtimeSubscriptionState.listening(channelName: name)
                .canBegin(channelName: name)
        )
        XCTAssertTrue(
            RealtimeSubscriptionState.listening(channelName: name)
                .canBegin(channelName: name, forceReconnect: true)
        )
        XCTAssertTrue(
            RealtimeSubscriptionState.listening(channelName: "meets:old")
                .canBegin(channelName: name)
        )
        XCTAssertFalse(
            RealtimeSubscriptionState.stopping(channelName: name)
                .canBegin(channelName: name, forceReconnect: true)
        )
    }

    func testLiveTransportStateAllowsOnlyARealResortTransition() {
        XCTAssertTrue(LiveTransportState.stopped.canStart(resortID: "vail"))
        XCTAssertFalse(
            LiveTransportState.connecting(resortID: "vail").canStart(resortID: "vail")
        )
        XCTAssertFalse(
            LiveTransportState.live(resortID: "vail").canStart(resortID: "vail")
        )
        XCTAssertTrue(
            LiveTransportState.live(resortID: "vail").canStart(resortID: "parkcity")
        )
        XCTAssertFalse(
            LiveTransportState.stopping(resortID: "vail").canStart(resortID: "parkcity")
        )
    }

    func testActiveMeetRoleMapsLocalAndPartnerETAsToWireColumns() {
        let senderUpdate = ActiveMeetParticipantRole.sender.etaUpdate(localETA: 42)
        XCTAssertEqual(senderUpdate.sender, 42)
        XCTAssertNil(senderUpdate.receiver)

        let receiverUpdate = ActiveMeetParticipantRole.receiver.etaUpdate(localETA: 84)
        XCTAssertNil(receiverUpdate.sender)
        XCTAssertEqual(receiverUpdate.receiver, 84)

        XCTAssertEqual(
            ActiveMeetParticipantRole.sender.partnerETA(
                senderETA: 42,
                receiverETA: 84
            ),
            84
        )
        XCTAssertEqual(
            ActiveMeetParticipantRole.receiver.partnerETA(
                senderETA: 42,
                receiverETA: 84
            ),
            42
        )
    }

    func testActiveMeetPollingEndsCancelledOrExpiredSessionsAndRefreshesAcceptedETA() {
        let now = Date(timeIntervalSince1970: 1_000)
        XCTAssertEqual(
            ActiveMeetPollClassifier.action(
                status: .accepted,
                expiresAt: now.addingTimeInterval(60),
                now: now
            ),
            .updateETA
        )
        XCTAssertEqual(
            ActiveMeetPollClassifier.action(status: .expired, expiresAt: nil, now: now),
            .endMeet
        )
        XCTAssertEqual(
            ActiveMeetPollClassifier.action(
                status: .pending,
                expiresAt: now,
                now: now
            ),
            .endMeet
        )
        XCTAssertEqual(
            ActiveMeetPollClassifier.action(status: .pending, expiresAt: nil, now: now),
            .ignore
        )
    }

    func testActiveMeetRecoveryRequiresRecentAcceptedExactDatasetParticipant() {
        let now = Date(timeIntervalSince1970: 10_000)
        let me = UUID()
        let friend = UUID()
        XCTAssertTrue(ActiveMeetRecoveryPolicy.isRecoverable(
            meetRequest(
                senderID: me,
                receiverID: friend,
                createdAt: now.addingTimeInterval(-60)
            ),
            currentUserID: me,
            now: now
        ))
        XCTAssertFalse(ActiveMeetRecoveryPolicy.isRecoverable(
            meetRequest(
                senderID: me,
                receiverID: friend,
                status: .pending,
                createdAt: now.addingTimeInterval(-60)
            ),
            currentUserID: me,
            now: now
        ))
        XCTAssertFalse(ActiveMeetRecoveryPolicy.isRecoverable(
            meetRequest(
                senderID: me,
                receiverID: friend,
                createdAt: now.addingTimeInterval(-ActiveMeetRecoveryPolicy.maximumAge - 1)
            ),
            currentUserID: me,
            now: now
        ))
        XCTAssertFalse(ActiveMeetRecoveryPolicy.isRecoverable(
            meetRequest(
                senderID: me,
                receiverID: friend,
                createdAt: now.addingTimeInterval(-60),
                datasetVersion: nil
            ),
            currentUserID: me,
            now: now
        ))
        XCTAssertFalse(ActiveMeetRecoveryPolicy.isRecoverable(
            meetRequest(
                senderID: me,
                receiverID: friend,
                createdAt: now.addingTimeInterval(-60)
            ),
            currentUserID: UUID(),
            now: now
        ))
    }

    func testActiveMeetRecoveryChoosesNewestStableRequest() throws {
        let now = Date(timeIntervalSince1970: 10_000)
        let me = UUID()
        let friend = UUID()
        let olderID = UUID(uuidString: "00000000-0000-4000-8000-000000000001")!
        let newerID = UUID(uuidString: "00000000-0000-4000-8000-000000000002")!
        let selected = try XCTUnwrap(ActiveMeetRecoveryPolicy.newestRecoverable(
            from: [
                meetRequest(
                    id: olderID,
                    senderID: me,
                    receiverID: friend,
                    createdAt: now.addingTimeInterval(-120)
                ),
                meetRequest(
                    id: newerID,
                    senderID: friend,
                    receiverID: me,
                    createdAt: now.addingTimeInterval(-60)
                ),
            ],
            currentUserID: me,
            now: now
        ))
        XCTAssertEqual(selected.id, newerID)
    }

    func testPendingTerminationPreventsRecoveryAndExpiresDefensively() {
        let now = Date(timeIntervalSince1970: 10_000)
        let me = UUID()
        let friend = UUID()
        let endedID = UUID()
        let stillActiveID = UUID()
        let ended = meetRequest(
            id: endedID,
            senderID: me,
            receiverID: friend,
            createdAt: now.addingTimeInterval(-60)
        )
        let active = meetRequest(
            id: stillActiveID,
            senderID: friend,
            receiverID: me,
            createdAt: now.addingTimeInterval(-120)
        )

        XCTAssertEqual(ActiveMeetRecoveryPolicy.newestRecoverable(
            from: [ended, active],
            currentUserID: me,
            now: now,
            excludingRequestIDs: [endedID]
        )?.id, stillActiveID)

        let recent = UUID()
        let stale = UUID()
        let implausiblyFuture = UUID()
        let retained = PendingMeetTerminationPolicy.retained([
            recent: now.addingTimeInterval(-60),
            stale: now.addingTimeInterval(-PendingMeetTerminationPolicy.retention - 1),
            implausiblyFuture: now.addingTimeInterval(
                PendingMeetTerminationPolicy.allowableFutureClockSkew + 1
            ),
        ], now: now)
        XCTAssertEqual(Set(retained.keys), [recent])
    }
}
