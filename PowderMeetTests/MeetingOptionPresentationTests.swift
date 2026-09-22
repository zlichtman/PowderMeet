import SwiftUI
import XCTest
@testable import PowderMeet

@MainActor
final class MeetingOptionPresentationTests: XCTestCase {
    func testSpokenRouteValueIncludesBothSkiersAndVisibleLimitations() {
        let value = Self.card().cardAccessibilityValue
        XCTAssertTrue(value.contains("Your route."))
        XCTAssertTrue(value.contains("Alexandria Montgomery's route."))
        XCTAssertTrue(value.contains("8 minutes 14 seconds to 12 minutes 5 seconds"))
        XCTAssertTrue(value.contains("Estimated travel time 12 minutes. Timing range unavailable."))
        XCTAssertTrue(value.contains("UNRATED SECTIONS"))
        XCTAssertTrue(value.contains("Uses your selected skis and avoids your excluded terrain"))
        XCTAssertTrue(value.contains("confirm local signs and conditions before waiting."))
        XCTAssertFalse(value.contains(".."))
    }

    func testVisibleAndSpokenTimingShareUnknownAndZeroUncertaintyRules() {
        let known = MeetingRouteTimePresentation(time: 610, standardDeviation: 90, showRange: true)
        XCTAssertEqual(known.displayText, "8m 14s–12m 5s")
        XCTAssertEqual(known.accessibilityText, "Estimated travel time 8 minutes 14 seconds to 12 minutes 5 seconds.")
        XCTAssertFalse(known.rangeUnavailable)
        for missing in [nil, Double.nan, Double.infinity, -1, Double.greatestFiniteMagnitude] {
            let timing = MeetingRouteTimePresentation(time: 720, standardDeviation: missing, showRange: true)
            XCTAssertEqual(timing.displayText, "12m 0s")
            XCTAssertTrue(timing.rangeUnavailable)
            XCTAssertTrue(timing.accessibilityText.contains("Timing range unavailable"))
        }
        let zero = MeetingRouteTimePresentation(time: 720, standardDeviation: 0, showRange: true)
        XCTAssertEqual(zero.displayText, "12m 0s")
        XCTAssertFalse(zero.rangeUnavailable)
        XCTAssertEqual(MeetingRouteTimePresentation.spokenDuration(3661), "1 hour 1 minute 1 second")
        XCTAssertEqual(MeetingRouteTimePresentation.spokenDuration(0), "0 seconds")
    }

    func testMalformedTimeCannotCrashTheTimingPresenter() {
        for invalid in [Double.nan, .infinity, -1, .greatestFiniteMagnitude] {
            let timing = MeetingRouteTimePresentation(time: invalid, standardDeviation: 30, showRange: true)
            XCTAssertEqual(timing.displayText, "ETA UNAVAILABLE")
            XCTAssertEqual(timing.accessibilityText, "Travel time unavailable.")
        }
    }

    func testSpokenPreviewStartsWithTheSameSafetyWarningAsTheCard() {
        var card = Self.card()
        for (attempt, warning) in [
            (SolveAttempt.nonCanonicalDataset, "Mountain data is not verified"),
            (.forcedOpen, "May use closed terrain"),
            (.neighborSubstitution, "Routing to nearest open point"),
            (.forcedOpenNeighborSubstitution, "May use closed terrain from a nearby point")
        ] {
            card.solveAttempt = attempt
            XCTAssertTrue(card.cardAccessibilityLabel(meetingName: "Meet here")
                .hasPrefix("Preview. \(warning)."))
        }
        card.solveAttempt = .live
        XCTAssertFalse(card.cardAccessibilityLabel(meetingName: "Meet here").hasPrefix("Preview."))
    }

    func testMeasuredPageHeightDoesNotCapLongContentOrUseRemovedPages() {
        XCTAssertEqual(MeetingCardSizing.height(measurements: [0: 1200.2, 1: 1700], cardCount: 2), 1700)
        XCTAssertEqual(MeetingCardSizing.height(measurements: [0: 1200.2, 1: 1700], cardCount: 1), 1201)
        XCTAssertEqual(MeetingCardSizing.height(measurements: [0: 500, 1: .infinity, -1: 2000], cardCount: 2), 500)
    }

    func testMissingUncertaintyCannotBecomeAnExactRange() {
        for value in [nil, Double.nan, Double.infinity, -1] {
            XCTAssertNil(MeetingRouteTimePresentation.usableUncertainty(value))
        }
        XCTAssertEqual(MeetingRouteTimePresentation.usableUncertainty(0), 0)
        XCTAssertEqual(MeetingRouteTimePresentation.usableUncertainty(90), 90)
    }

    func testExpectedWaitDoesNotPromiseArrivalOrderWhenRangesOverlap() {
        let timing = MeetingArrivalPresentation(timeA: 300, timeB: 420, stdA: 90, stdB: 90)
        XCTAssertEqual(timing.togetherText, "7m 0s")
        XCTAssertEqual(timing.comparisonText, "EXPECTED WAIT · YOU ~2m")
        XCTAssertEqual(timing.orderEvidence, .overlapping)
        XCTAssertEqual(timing.detailText, "ARRIVAL RANGES OVERLAP · EITHER SKIER MAY WAIT")
        XCTAssertTrue(timing.comparisonAccessibilityText.contains("you would wait about 2 minutes"))
        XCTAssertTrue(timing.detailAccessibilityText.contains("Either skier may arrive first"))
    }

    func testSwappingSkiersChangesWaitOwnerNotTheUncertainty() {
        let a = MeetingArrivalPresentation(timeA: 300, timeB: 720, stdA: 30, stdB: 50)
        let b = MeetingArrivalPresentation(timeA: 720, timeB: 300, stdA: 50, stdB: 30)
        XCTAssertEqual(a.orderEvidence, .separated)
        XCTAssertEqual(a.orderEvidence, b.orderEvidence)
        XCTAssertEqual(a.togetherText, b.togetherText)
        XCTAssertEqual(a.comparisonText, "EXPECTED WAIT · YOU ~7m")
        XCTAssertEqual(b.comparisonText, "EXPECTED WAIT · FRIEND ~7m")
        XCTAssertEqual(a.detailText, b.detailText)
        XCTAssertTrue(b.comparisonAccessibilityText.contains("your friend would wait about 7 minutes"))
    }

    func testSimilarMeansAreNotAPromiseToArriveTogether() {
        let timing = MeetingArrivalPresentation(timeA: 600, timeB: 620, stdA: 200, stdB: 200)
        XCTAssertEqual(timing.comparisonText, "SIMILAR ESTIMATED ARRIVALS")
        XCTAssertEqual(timing.orderEvidence, .overlapping)
        XCTAssertFalse(timing.comparisonText.contains("ARRIVE TOGETHER"))
        XCTAssertTrue(timing.detailText.contains("EITHER SKIER MAY WAIT"))
    }

    func testMissingMalformedAndOverflowingUncertaintyNeverPromiseOrder() {
        for missing in [nil, Double.nan, .infinity, -1, .greatestFiniteMagnitude] {
            for swapped in [false, true] {
                let timing = MeetingArrivalPresentation(timeA: 100, timeB: 500,
                    stdA: swapped ? 0 : missing, stdB: swapped ? missing : 0)
                XCTAssertEqual(timing.orderEvidence, .unavailable)
                XCTAssertTrue(timing.detailText.contains("TIMING RANGE UNAVAILABLE"))
            }
        }
        XCTAssertTrue(MeetingRouteTimePresentation.shouldShowRanges(stdA: nil, stdB: nil))
        XCTAssertTrue(MeetingRouteTimePresentation.shouldShowRanges(stdA: 0, stdB: nil))
        XCTAssertFalse(MeetingRouteTimePresentation.shouldShowRanges(stdA: 0, stdB: 0))
    }

    func testMalformedMeanCannotBeHiddenByTheOtherSkier() {
        for invalid in [Double.nan, .infinity, -1, .greatestFiniteMagnitude] {
            for swapped in [false, true] {
                let timing = MeetingArrivalPresentation(timeA: swapped ? 600 : invalid,
                    timeB: swapped ? invalid : 600, stdA: 90, stdB: 90)
                XCTAssertEqual(timing.togetherText, "ETA UNAVAILABLE")
                XCTAssertEqual(timing.comparisonText, "WAIT ESTIMATE UNAVAILABLE")
                XCTAssertEqual(timing.orderEvidence, .unavailable)
            }
        }
    }

    func testCardSpeaksTheSameWaitAndOrderLimitationItShows() {
        let card = Self.card(stdA: 90, stdB: 90)
        XCTAssertTrue(card.cardAccessibilityValue.contains("you would wait about 2 minutes"))
        XCTAssertTrue(card.cardAccessibilityValue.contains("modeled arrival ranges overlap"))
        XCTAssertFalse(card.cardAccessibilityValue.contains("~2m"))
        XCTAssertTrue(Self.card().cardAccessibilityValue.contains("timing range is unavailable"))
    }

    func testHostedPagerMeasuresAccessibilityCardBeyondOldHeightBudget() async throws {
        let measured = expectation(description: "Actual card height measured inside page container")
        var actualHeight: CGFloat?
        var observedSizes: [String] = []
        let host = UIHostingController(rootView: PagerHarness { height, pageHeight in
            observedSizes.append("content=\(height), page=\(pageHeight)")
            if actualHeight == nil && pageHeight >= height - 1 {
                actualHeight = height
                measured.fulfill()
            }
        }.environment(\.dynamicTypeSize, .accessibility3).environment(\.colorScheme, .dark))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 1000))
        window.rootViewController = host
        window.isHidden = false
        defer { window.isHidden = true }
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        await fulfillment(of: [measured], timeout: 10)
        XCTAssertGreaterThan(try XCTUnwrap(actualHeight, observedSizes.joined(separator: "; ")), 620)
    }

    private struct PagerHarness: View {
        let onMeasured: (CGFloat, CGFloat) -> Void
        @State private var heights: [Int: CGFloat] = [:]
        @State private var pageHeight: CGFloat = 0
        var body: some View {
            ScrollView {
            VStack {
            TabView {
                MeetingOptionPresentationTests.card().measuredMeetingPage(index: 0).tag(0)
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .frame(width: 370, height: MeetingCardSizing.height(measurements: heights, cardCount: 1))
            .background(GeometryReader { geometry in
                Color.clear.preference(key: PagerExtentPreference.self, value: geometry.size.height)
            })
            .onPreferenceChange(MeetingCardHeightPreference.self) { value in
                heights = value
            }
            .onPreferenceChange(PagerExtentPreference.self) { pageHeight in
                self.pageHeight = pageHeight
            }
            .onChange(of: heights) { _, heights in
                if let height = heights[0], height > 0 { onMeasured(height, pageHeight) }
            }
            .onChange(of: pageHeight) { _, pageHeight in
                if let height = heights[0], height > 0 { onMeasured(height, pageHeight) }
            }
            }
            }
        }
    }

    private struct PagerExtentPreference: PreferenceKey {
        nonisolated static var defaultValue: CGFloat { 0 }
        nonisolated static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
            // Empty sibling preferences must not erase the measured extent.
            value = max(value, nextValue())
        }
    }

    static func card(stdA: Double? = 90, stdB: Double? = nil) -> MeetingOptionCardView {
        let node = GraphNode(id: "meet", coordinate: .init(latitude: 50.1, longitude: -122.9),
                             elevation: 2100, kind: .midStation)
        func edge(_ id: String, name: String, difficulty: RunDifficulty?) -> GraphEdge {
            GraphEdge(id: id, sourceID: "start", targetID: node.id, kind: .run, geometry: [],
                      attributes: EdgeAttributes(difficulty: difficulty, lengthMeters: 700,
                          trailName: name, isOpen: true))
        }
        let path = [edge("blue", name: "Whistler Village Gondola Connector", difficulty: .blue),
                    edge("unknown", name: "Upper Olympic Return", difficulty: nil)]
        return MeetingOptionCardView(index: 0, label: "RECOMMENDED STOP", node: node,
            pathA: path, pathB: path, timeA: 610, timeB: 720,
            legTimesA: [300, 310], legTimesB: [350, 370],
            routeReasonA: "Uses your selected skis and avoids your excluded terrain",
            routeReasonB: "Keeps both routes within the agreed mountain dataset",
            etaStdSecondsA: stdA, etaStdSecondsB: stdB,
            meetingDisplayName: "Whistler Village Gondola — Upper Olympic Mid-Station Meeting Area",
            rendezvousPoint: nil,
            rendezvousReason: "This designated stopping area is sheltered from the forecast wind; confirm local signs and conditions before waiting.",
            sharedContinuation: nil, graph: nil, friendName: "Alexandria Montgomery",
            solveAttempt: .nonCanonicalDataset, isSelected: true, onSelect: {})
    }

    func testDetailedOptionAtStandardTextSize() throws {
        try render(size: .large, label: "standard")
    }

    func testDetailedOptionAtAccessibilityTextSize() throws {
        try render(size: .accessibility3, label: "accessibility")
    }

    func testOverlappingArrivalRangesAtStandardTextSize() throws {
        try render(size: .large, label: "overlapping-ranges", card: Self.card(stdA: 90, stdB: 90))
    }

    private func render(size: DynamicTypeSize, label: String, card: MeetingOptionCardView? = nil) throws {
        let view = (card ?? Self.card()).frame(width: 370)
            .background(HUDTheme.mapBackground)
            .environment(\.dynamicTypeSize, size).environment(\.colorScheme, .dark)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.uiImage)
        XCTAssertEqual(image.size.width, 370, accuracy: 0.5)
        XCTAssertGreaterThan(image.size.height, 200)
        XCTAssertLessThan(image.size.height, 3000)
        let attachment = XCTAttachment(image: image)
        attachment.name = "meeting-option-\(label)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
