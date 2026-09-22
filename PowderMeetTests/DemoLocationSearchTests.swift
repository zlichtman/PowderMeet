import SwiftUI
import XCTest
@testable import PowderMeet

@MainActor
final class DemoLocationSearchTests: XCTestCase {
    func testSearchHandlesAccentsApostrophesAndWhitespace() {
        XCTAssertTrue(DemoLocationSearch.matches("Pika’s Traverse · Blue", query: "  PIKAS  traverse "))
        XCTAssertTrue(DemoLocationSearch.matches("Crête du Midi", query: "crete midi"))
        XCTAssertTrue(DemoLocationSearch.matches("Peak-to-Creek · #2", query: "peak creek"))
        XCTAssertTrue(DemoLocationSearch.matches("Dave Murray Downhill", query: "murray dave"))
        XCTAssertFalse(DemoLocationSearch.matches("Peak to Creek", query: "peak bowl"))
    }

    func testWhitespaceAndPunctuationOnlyQueriesDoNotHideLocations() {
        for query in ["", "  ", "\n\t", "’ -"] {
            XCTAssertTrue(DemoLocationSearch.matches("Blue Line", query: query))
        }
    }

    func testLongDemoNamesAtStandardTextSize() throws {
        try renderRow(size: .large, label: "standard")
    }

    func testLongDemoNamesAtAccessibilityTextSize() throws {
        try renderRow(size: .accessibility3, label: "accessibility")
    }

    private func renderRow(size: DynamicTypeSize, label: String) throws {
        let entry = RoutingTestSheet.PickerEntry(id: "trail", nodeId: "top", trailGroupId: "g",
            name: "Whistler Village Gondola Connector — Upper Olympic · Blue",
            kind: .trail, difficulty: .blue, elevation: 2100)
        let view = RoutingTestSheet.rowLabel(entry, isSelected: true, largeText: size.isAccessibilitySize)
            .frame(width: 370)
            .background(HUDTheme.mapBackground)
            .environment(\.dynamicTypeSize, size)
            .environment(\.colorScheme, .dark)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.uiImage)
        XCTAssertEqual(image.size.width, 370, accuracy: 0.5)
        XCTAssertGreaterThan(image.size.height, 44)
        XCTAssertLessThan(image.size.height, 600)
        let attachment = XCTAttachment(image: image)
        attachment.name = "demo-location-\(label)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
