//
//  EpicTerrainScraperTests.swift
//  PowderMeetTests
//

import XCTest
@testable import PowderMeet

final class EpicTerrainScraperTests: XCTestCase {
    func testSummerFeedCannotAlterSkiTrailsOrLifts() throws {
        let html = feed(areas: [[
            "Name": "All Summer Terrain",
            "Trails": [
                ["Name": "Avanti Lane", "TrailType": "Biking", "IsOpen": true],
                ["Name": "Meadow Loop", "TrailType": 2, "IsOpen": false]
            ],
            "Lifts": [
                ["Name": "Gondola One", "Status": "Open", "WaitTimeInMinutes": 5]
            ]
        ]])

        let parsed = try XCTUnwrap(EpicTerrainScraper.parseTerrainFeed(html: html, slug: "vail"))

        XCTAssertTrue(parsed.allTrails.isEmpty)
        XCTAssertTrue(parsed.allLifts.isEmpty)
    }

    func testWinterDisplayFeedParsesStatusAndBracesInsideStrings() throws {
        let first = feed(areas: [])
        let second = feed(areas: [[
            "Name": "Game Creek {North}",
            "Trails": [[
                "Id": 1,
                "Name": "Dealer's Choice {Upper}",
                "Difficulty": "Black",
                "TrailType": "Skiing",
                "IsOpen": true,
                "IsGroomed": false
            ]],
            "Lifts": [[
                "Name": "Game Creek Express",
                "Status": "Open",
                "WaitTimeInMinutes": "4"
            ]]
        ]])

        let parsed = try XCTUnwrap(EpicTerrainScraper.parseTerrainFeed(
            html: first + second,
            slug: "vail"
        ))

        XCTAssertEqual(parsed.allTrails.count, 1)
        XCTAssertEqual(parsed.allTrails[0].name, "Dealer's Choice {Upper}")
        XCTAssertEqual(parsed.allTrails[0].difficulty, 3)
        XCTAssertTrue(parsed.allTrails[0].isOpen)
        XCTAssertEqual(parsed.allLifts.count, 1)
        XCTAssertTrue(parsed.allLifts[0].isOpen)
        XCTAssertEqual(parsed.allLifts[0].waitTimeInMinutes, 4)
    }

    func testMalformedFeedFailsInsteadOfReturningEmptySuccess() {
        XCTAssertNil(EpicTerrainScraper.parseTerrainFeed(
            html: "FR.TerrainStatusFeed = {not-json};",
            slug: "vail"
        ))
    }

    private func feed(areas: [[String: Any]]) -> String {
        let object: [String: Any] = [
            "Date": "2026-01-02T12:00:00Z",
            "GroomingAreas": areas
        ]
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return "<script>FR.TerrainStatusFeed = \(String(decoding: data, as: UTF8.self));</script>"
    }
}
