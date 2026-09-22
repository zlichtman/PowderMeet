//
//  PendingFriendRequestsSection.swift
//  PowderMeet
//
//  Pending *friend* requests (sent to me by users who want to be my
//  friend) — distinct from incoming *meet* requests (an existing
//  friend asking to ski with me right now). Extracted from `MeetView`
//  per the section split. Owns no state; takes the snapshot lists as
//  inputs so SwiftUI can short-circuit when the parent re-evaluates
//  for unrelated reasons.
//

import SwiftUI

struct PendingFriendRequestsSection: View {
    let pendingReceived: [Friendship]
    let pendingProfiles: [UUID: UserProfile]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(pendingReceived) { request in
                PendingRequestCard(
                    request: request,
                    requestProfile: pendingProfiles[request.requesterId]
                )
            }
        }
    }
}
