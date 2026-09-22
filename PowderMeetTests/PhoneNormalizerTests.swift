//
//  PhoneNormalizerTests.swift
//  PowderMeetTests
//
//  Phone-number candidate generation for contact match. The function
//  has to span "+1 604…" sign-ups against "(604) 555-1234"-style
//  contacts; every region branch is a separate edge that's worth
//  pinning down.
//

import XCTest
@testable import PowderMeet

final class PhoneNormalizerTests: XCTestCase {

    func testE164InputEmitsBothFormsWhenDialCodeMatches() {
        let cands = PhoneNormalizer.candidates(for: "+1 604-555-1234", defaultRegion: "CA")
        // Always emits the E.164 digits.
        XCTAssertTrue(cands.contains("16045551234"))
        // And the national-only fallback (since CA dial = "1").
        XCTAssertTrue(cands.contains("6045551234"))
    }

    func testNationalUSEmitsNationalAndInternational() {
        let cands = PhoneNormalizer.candidates(for: "(604) 555-1234", defaultRegion: "US")
        XCTAssertTrue(cands.contains("6045551234"))
        // Prepends US dial code "1".
        XCTAssertTrue(cands.contains("16045551234"))
    }

    func testTooShortRejected() {
        XCTAssertTrue(PhoneNormalizer.candidates(for: "12345", defaultRegion: "US").isEmpty)
        XCTAssertTrue(PhoneNormalizer.candidates(for: "555-12", defaultRegion: "US").isEmpty)
    }

    func testEmptyAndWhitespaceRejected() {
        XCTAssertTrue(PhoneNormalizer.candidates(for: "", defaultRegion: "US").isEmpty)
        XCTAssertTrue(PhoneNormalizer.candidates(for: "   ", defaultRegion: "US").isEmpty)
    }

    func testCzechDialCodeMatchesLongestPrefix() {
        // CZ dial code "420" must beat the bare "4" — `dialCode(forE164Digits:)`
        // sorts longest-first to avoid this collision.
        let dial = PhoneNormalizer.dialCode(forE164Digits: "420604555123")
        XCTAssertEqual(dial, "420")
    }

    func testE164WithoutKnownDialCodeFallsBackToDigits() {
        // Made-up region (unknown to the table) — should still emit
        // the digits-only form rather than nothing.
        let cands = PhoneNormalizer.candidates(for: "+999 555 1234567", defaultRegion: "ZZ")
        XCTAssertTrue(cands.contains("9995551234567"))
    }
}
