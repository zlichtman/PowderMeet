//
//  IncomingMeetRequestsSection.swift
//  PowderMeet
//
//  Incoming meet requests — friends asking to ski together right now.
//  Always rendered when non-empty (including during an active meetup),
//  so the user can accept a new request without first ending their
//  current session. Extracted from `MeetView`.
//

import SwiftUI

struct IncomingMeetRequestsSection: View {
    let incoming: [MeetRequest]
    let onMeetAccepted: ((MeetRequest) -> Void)?

    var body: some View {
        VStack(spacing: 8) {
            ForEach(incoming) { request in
                IncomingMeetRequestCard(
                    request: request,
                    onMeetAccepted: onMeetAccepted
                )
            }
        }
    }
}
