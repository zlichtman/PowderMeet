//
//  ISO8601ParserTests.swift
//  PowderMeetTests
//
//  Recent extraction (`Utilities/ISO8601Parser.swift`) collapses the
//  previously-duplicated dual-format dance from the GPX/TCX/FIT parsers.
//  Tests pin both formats and the rejection of malformed input.
//

import XCTest
@testable import PowderMeet

final class ISO8601ParserTests: XCTestCase {

    func testPlainFormatParses() {
        let d = ISO8601Parser.parse("2024-03-12T12:30:00Z")
        XCTAssertNotNil(d)
        XCTAssertEqual(d?.timeIntervalSince1970, 1710246600)
    }

    func testFractionalFormatParses() {
        // Strava / Suunto / Apple Health flavour.
        let d = ISO8601Parser.parse("2024-03-12T12:30:00.123Z")
        XCTAssertNotNil(d)
        XCTAssertEqual(d?.timeIntervalSince1970 ?? 0, 1710246600.123, accuracy: 0.001)
    }

    func testFractionalAndPlainAgreeOnIntegerSecond() {
        let plain = ISO8601Parser.parse("2024-03-12T12:30:00Z")
        let frac  = ISO8601Parser.parse("2024-03-12T12:30:00.000Z")
        XCTAssertNotNil(plain)
        XCTAssertNotNil(frac)
        XCTAssertEqual(plain?.timeIntervalSince1970 ?? -1,
                       frac?.timeIntervalSince1970 ?? -2,
                       accuracy: 1e-3)
    }

    func testTimezoneOffsetParses() {
        // Both formatters accept ±HH:MM offsets, not just Z.
        let d = ISO8601Parser.parse("2024-03-12T07:30:00-05:00")
        XCTAssertNotNil(d)
        XCTAssertEqual(d?.timeIntervalSince1970, 1710246600)
    }

    func testGarbageReturnsNil() {
        XCTAssertNil(ISO8601Parser.parse(""))
        XCTAssertNil(ISO8601Parser.parse("not a date"))
        XCTAssertNil(ISO8601Parser.parse("2024-13-99T99:99:99Z"))
    }
}
