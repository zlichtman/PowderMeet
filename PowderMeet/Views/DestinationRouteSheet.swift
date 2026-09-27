//
//  DestinationRouteSheet.swift
//  PowderMeet
//
//  Searchable, glove-friendly landmark routing for lodges, patrol points,
//  signed meeting areas, and lift bases from the canonical rendezvous catalog.
//

import SwiftUI
import CoreLocation

struct DestinationRouteSheet: View {
    @Environment(\.dismiss) private var dismiss

    let destinations: [RendezvousPoint]
    let graph: MountainGraph
    var userLocation: CLLocationCoordinate2D?
    var previewOnly: Bool = false
    @Binding var previewStartNodeID: String?
    var availabilityMessage: String? = nil
    var failureMessage: () -> String? = { nil }
    let onRoute: (RendezvousPoint) async -> Bool

    @State private var query = ""
    @State private var routingPointID: String?
    @State private var routeError: String?

    private var filteredDestinations: [RendezvousPoint] {
        let ordered = LandmarkRoutePolicy.orderedDestinations(destinations)
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return ordered }
        return ordered.filter { point in
            destinationName(point).localizedCaseInsensitiveContains(needle)
                || point.kind.userFacingLabel.localizedCaseInsensitiveContains(needle)
        }
    }

    private var previewStarts: [RendezvousPoint] {
        LandmarkRoutePolicy.orderedDestinations(destinations).filter {
            $0.kind == .liftBase || $0.kind == .midStation
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(HUDTheme.secondaryText)
                TextField("LODGE, PATROL, OR LIFT", text: $query)
                    .hudType(.body)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
            .padding(.horizontal, 12)
            .frame(minHeight: 44)
            .powderControl()
            .padding(.horizontal, 16)
            .padding(.top, 12)

            ScrollView {
                LazyVStack(spacing: 10) {
                    trustHeader
                    if previewOnly { previewStartSelector }
                    if filteredDestinations.isEmpty {
                        emptyState
                    } else {
                        ForEach(filteredDestinations) { point in destinationRow(point) }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
            }
        }
        .background(HUDTheme.mapBackground)
        .powderSheet(title: "Go To")
        .presentationDetents([.medium, .large])
        .alert("Route unavailable", isPresented: Binding(
            get: { routeError != nil },
            set: { if !$0 { routeError = nil } }
        )) {
            Button("OK", role: .cancel) { routeError = nil }
        } message: {
            Text(routeError ?? "Please try again.")
        }
    }

    private var trustHeader: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: previewOnly ? "exclamationmark.triangle.fill" : (availabilityMessage == nil ? "checkmark.shield.fill" : "info.circle"))
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(previewOnly || availabilityMessage != nil ? HUDTheme.accentAmber : HUDTheme.accentGreen)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(previewOnly ? "UNVERIFIED ROUTE PREVIEW" : (availabilityMessage == nil ? "VALIDATED MOUNTAIN LANDMARKS" : "ROUTING NOT AVAILABLE"))
                    .hudType(.label)
                    .foregroundColor(HUDTheme.primaryText)
                    .tracking(0.8)
                Text(previewOnly
                    ? "For testing only. The mountain graph, closures, and lift hours are not verified. Do not use this route for navigation."
                    : (availabilityMessage ?? "Routes honor your terrain limits, selected skis, live closures, lift hours, weather, and GPS confidence."))
                    .font(.system(size: 12))
                    .foregroundColor(HUDTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(HUDTheme.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(HUDTheme.cardBorder, lineWidth: 0.5)
        )
    }

    private var previewStartSelector: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("PREVIEW START · NOT YOUR LOCATION")
                .hudType(.label)
                .foregroundColor(HUDTheme.accentAmber)
                .tracking(0.8)
            Menu {
                if previewStartNodeID != nil {
                    Button("Clear selected start") { previewStartNodeID = nil }
                }
                ForEach(previewStarts) { point in
                    Button(destinationName(point)) { previewStartNodeID = point.nodeID }
                }
            } label: {
                HStack {
                    Text(previewStartNodeID.flatMap { id in
                        previewStarts.first(where: { $0.nodeID == id }).map(destinationName)
                    } ?? (userLocation == nil ? "AUTO-SELECT A START LIFT" : "USE MY LOCATION"))
                        .lineLimit(1)
                    Spacer()
                    Image(systemName: "chevron.up.chevron.down")
                }
                .hudType(.bodyEmph)
                .foregroundColor(HUDTheme.primaryText)
                .frame(maxWidth: .infinity, minHeight: 44)
                .contentShape(Rectangle())
            }
            .accessibilityLabel("Choose preview starting lift")
        }
        .padding(12)
        .background(HUDTheme.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func destinationRow(_ point: RendezvousPoint) -> some View {
        Button {
            guard routingPointID == nil else { return }
            if let availabilityMessage {
                routeError = availabilityMessage
                return
            }
            if previewOnly && userLocation == nil && previewStartNodeID == nil {
                // Make the first tap useful for a remote tester with no GPS
                // fix at this resort. Choose only from lift bases with a
                // directed graph connection to this destination; the solver
                // still enforces the skier's terrain limits.
                let reachable = LandmarkRoutePolicy.nodesReaching(
                    destinationNodeID: point.nodeID,
                    edges: graph.edges
                )
                guard let start = previewStarts.first(where: {
                    $0.nodeID != point.nodeID && reachable.contains($0.nodeID)
                }) else {
                    routeError = "No connected preview starting lift is available for this destination."
                    return
                }
                previewStartNodeID = start.nodeID
            }
            routingPointID = point.id
            Task {
                let succeeded = await onRoute(point)
                routingPointID = nil
                if succeeded {
                    dismiss()
                } else {
                    routeError = failureMessage() ?? "No safe route was found. Check your starting location and try another destination."
                }
            }
        } label: {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(kindColor(point.kind).opacity(0.13))
                        .frame(width: 42, height: 42)
                    Image(systemName: point.kind.systemImageName)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundColor(kindColor(point.kind))
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(destinationName(point).uppercased())
                        .hudType(.bodyEmph)
                        .foregroundColor(HUDTheme.primaryText)
                        .tracking(0.4)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    HStack(spacing: 6) {
                        Text(point.kind.userFacingLabel)
                            .hudType(.caption)
                            .foregroundColor(kindColor(point.kind))
                            .tracking(0.8)
                        if let distance = straightLineDistance(to: point) {
                            Text("·")
                                .foregroundColor(HUDTheme.secondaryText.opacity(0.5))
                            Text(UnitFormatter.distance(distance).uppercased())
                                .hudType(.caption)
                                .foregroundColor(HUDTheme.secondaryText)
                        }
                    }
                }

                Spacer(minLength: 8)

                if routingPointID == point.id {
                    ProgressView()
                        .tint(HUDTheme.accent)
                } else {
                    Image(systemName: "arrow.right.circle.fill")
                        .font(.system(size: 22))
                        .foregroundColor(HUDTheme.accent)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
            .background(HUDTheme.cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(HUDTheme.cardBorder, lineWidth: 0.5)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(routingPointID != nil)
        .accessibilityLabel("\(previewOnly ? "Preview route" : "Route") to \(destinationName(point)), \(point.kind.userFacingLabel)")
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 24, weight: .medium))
            Text(destinations.isEmpty ? (previewOnly ? "NO PREVIEW DESTINATIONS" : "NO VERIFIED DESTINATIONS YET") : "NO LANDMARKS MATCH")
                .hudType(.section)
                .tracking(1)
        }
        .foregroundColor(HUDTheme.secondaryText)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 48)
    }

    private func destinationName(_ point: RendezvousPoint) -> String {
        let trimmed = point.displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmed, !trimmed.isEmpty { return trimmed }
        return MountainNaming(graph).meetingNodeLabel(point.nodeID)
    }

    private func straightLineDistance(to point: RendezvousPoint) -> CLLocationDistance? {
        guard let userLocation,
              let coordinate = graph.nodes[point.nodeID]?.coordinate else { return nil }
        return CLLocation(latitude: userLocation.latitude, longitude: userLocation.longitude)
            .distance(from: CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude))
    }

    private func kindColor(_ kind: RendezvousPoint.Kind) -> Color {
        switch kind {
        case .lodge: return HUDTheme.accentGreen
        case .patrol: return HUDTheme.accentRed
        case .signedMeetingArea: return HUDTheme.accentCyan
        case .liftBase, .midStation: return HUDTheme.accentAmber
        }
    }
}

struct DestinationRouteSummary: View {
    let result: MeetingResult
    let graph: MountainGraph?
    let onClear: () -> Void

    private var destinationName: String {
        if let name = result.meetingDisplayName, !name.isEmpty { return name }
        if let graph { return MountainNaming(graph).meetingNodeLabel(result.meetingNode.id) }
        return "Destination"
    }

    private var etaText: String {
        let seconds = max(0, result.timeA)
        let minutes = max(1, Int((seconds / 60).rounded()))
        if let sigma = result.etaStdSecondsA, sigma.isFinite, sigma > 0 {
            let spreadMinutes = max(1, Int((1.28 * sigma / 60).rounded()))
            return "\(minutes) MIN ±\(spreadMinutes)"
        }
        return "\(minutes) MIN"
    }

    private var firstStep: RouteStep? {
        RouteStepConsolidator.consolidate(result.pathA, graph: graph).first
    }

    private var isUnverifiedPreview: Bool { result.solveAttempt == .nonCanonicalDataset }

    var body: some View {
        HStack(spacing: 11) {
            Image(systemName: result.rendezvousPoint?.kind.systemImageName ?? "location.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(HUDTheme.routeMeeting)
                .frame(width: 30, height: 30)
                .background(HUDTheme.routeMeeting.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(isUnverifiedPreview ? "PREVIEW" : "GO TO")
                        .hudType(.caption)
                        .foregroundColor(isUnverifiedPreview ? HUDTheme.accentAmber : HUDTheme.routeMeeting)
                        .tracking(1)
                    Text(destinationName.uppercased())
                        .hudType(.section)
                        .foregroundColor(HUDTheme.primaryText)
                        .tracking(0.4)
                        .lineLimit(1)
                }
                if isUnverifiedPreview {
                    Text("UNVERIFIED MAP · NOT FOR NAVIGATION")
                        .hudType(.caption)
                        .foregroundColor(HUDTheme.accentAmber)
                        .tracking(0.5)
                        .lineLimit(1)
                } else if let firstStep {
                    Text("\(firstStep.isLiftStep ? "RIDE" : "START ON") \(firstStep.name.uppercased())")
                        .hudType(.caption)
                        .foregroundColor(HUDTheme.secondaryText)
                        .tracking(0.5)
                        .lineLimit(1)
                } else if let reason = result.routeReasonA {
                    Text(reason)
                        .font(.system(size: 11))
                        .foregroundColor(HUDTheme.secondaryText)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 6)

            Text(isUnverifiedPreview ? "~\(etaText)" : etaText)
                .hudType(.label)
                .foregroundColor(HUDTheme.routeSkierA)
                .tracking(0.5)
                .fixedSize()

            Button(action: onClear) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(HUDTheme.secondaryText)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Clear destination route")
        }
        .padding(.leading, 14)
        .padding(.trailing, 4)
        .padding(.vertical, 6)
        .background(HUDTheme.headerBackground)
        .overlay(
            Rectangle().fill(HUDTheme.cardBorder).frame(height: 0.5),
            alignment: .bottom
        )
    }
}
