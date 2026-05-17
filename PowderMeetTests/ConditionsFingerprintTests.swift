//
//  ConditionsFingerprintTests.swift
//  PowderMeetTests
//
//  Pin the bucket boundaries + key order. Two clients producing the
//  same observation MUST emit byte-identical strings — the DB groups
//  on this column verbatim, so any drift fragments the rolling-speed
//  buckets and silently halves the sample count.
//

import XCTest
@testable import PowderMeet

final class ConditionsFingerprintTests: XCTestCase {

    private let groomedSurface = ConditionsFingerprint.SurfaceFlags(
        hasMoguls: false, isUngroomed: false, isGladed: false
    )

    func testDeterministicForSameInputs() {
        let a = ConditionsFingerprint.fingerprint(
            temperatureC: -3, windSpeedKph: 18, snowfallLast24hCm: 7,
            visibilityKm: 12, cloudCoverPercent: 60,
            surface: groomedSurface
        )
        let b = ConditionsFingerprint.fingerprint(
            temperatureC: -3, windSpeedKph: 18, snowfallLast24hCm: 7,
            visibilityKm: 12, cloudCoverPercent: 60,
            surface: groomedSurface
        )
        XCTAssertEqual(a, b)
        XCTAssertFalse(a.isEmpty)
    }

    func testTemperatureBucketsBy5() {
        // -3 → -5 bucket; 1 → 0 bucket; 6 → 5 bucket
        let n3 = ConditionsFingerprint.fingerprint(
            temperatureC: -3, windSpeedKph: nil, snowfallLast24hCm: nil,
            visibilityKm: nil, cloudCoverPercent: nil, surface: groomedSurface
        )
        let n2 = ConditionsFingerprint.fingerprint(
            temperatureC: -2, windSpeedKph: nil, snowfallLast24hCm: nil,
            visibilityKm: nil, cloudCoverPercent: nil, surface: groomedSurface
        )
        XCTAssertTrue(n3.contains("tempC=-5"))
        XCTAssertTrue(n2.contains("tempC=-5"))
        XCTAssertEqual(n3, n2, "Adjacent values inside the same 5°C bucket must produce equal fingerprints")
    }

    func testWindBucketsBy10() {
        let w12 = ConditionsFingerprint.fingerprint(
            temperatureC: nil, windSpeedKph: 12, snowfallLast24hCm: nil,
            visibilityKm: nil, cloudCoverPercent: nil, surface: groomedSurface
        )
        let w19 = ConditionsFingerprint.fingerprint(
            temperatureC: nil, windSpeedKph: 19, snowfallLast24hCm: nil,
            visibilityKm: nil, cloudCoverPercent: nil, surface: groomedSurface
        )
        XCTAssertEqual(w12, w19, "12 and 19 kph both round down to 10")
    }

    func testSnowfallBucketsCeil() {
        // 4 cm of snow → bucket 5; 0.5 cm → bucket 5 too; 0 → bucket 0.
        let s4 = ConditionsFingerprint.fingerprint(
            temperatureC: nil, windSpeedKph: nil, snowfallLast24hCm: 4,
            visibilityKm: nil, cloudCoverPercent: nil, surface: groomedSurface
        )
        XCTAssertTrue(s4.contains("snow=5"))

        let s0 = ConditionsFingerprint.fingerprint(
            temperatureC: nil, windSpeedKph: nil, snowfallLast24hCm: 0,
            visibilityKm: nil, cloudCoverPercent: nil, surface: groomedSurface
        )
        XCTAssertTrue(s0.contains("snow=0"))
    }

    func testVisibilityCappedAt15() {
        let lo = ConditionsFingerprint.fingerprint(
            temperatureC: nil, windSpeedKph: nil, snowfallLast24hCm: nil,
            visibilityKm: 100, cloudCoverPercent: nil, surface: groomedSurface
        )
        let hi = ConditionsFingerprint.fingerprint(
            temperatureC: nil, windSpeedKph: nil, snowfallLast24hCm: nil,
            visibilityKm: 15, cloudCoverPercent: nil, surface: groomedSurface
        )
        XCTAssertEqual(lo, hi, "100 km cap to 15 km")
    }

    func testKeysAreSorted() {
        // Ordering must be alphabetical regardless of which fields are present.
        let fp = ConditionsFingerprint.fingerprint(
            temperatureC: 0, windSpeedKph: 0, snowfallLast24hCm: 0,
            visibilityKm: 10, cloudCoverPercent: 50,
            surface: ConditionsFingerprint.SurfaceFlags(
                hasMoguls: true, isUngroomed: true, isGladed: false
            )
        )
        let parts = fp.split(separator: "|").map(String.init)
        XCTAssertEqual(parts, parts.sorted(), "Keys not in alpha order: \(fp)")
    }

    func testSurfaceFlagsDistinguishBuckets() {
        let groomed = ConditionsFingerprint.fingerprint(
            temperatureC: 0, windSpeedKph: 0, snowfallLast24hCm: 0,
            visibilityKm: 10, cloudCoverPercent: 50, surface: groomedSurface
        )
        let mogulled = ConditionsFingerprint.fingerprint(
            temperatureC: 0, windSpeedKph: 0, snowfallLast24hCm: 0,
            visibilityKm: 10, cloudCoverPercent: 50,
            surface: ConditionsFingerprint.SurfaceFlags(hasMoguls: true, isUngroomed: false, isGladed: false)
        )
        XCTAssertNotEqual(groomed, mogulled)
    }

    func testDefaultBucketSentinelExposed() {
        XCTAssertEqual(ConditionsFingerprint.defaultBucket, "default")
    }
}
