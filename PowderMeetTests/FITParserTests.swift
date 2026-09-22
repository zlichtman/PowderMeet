//
//  FITParserTests.swift
//  PowderMeetTests
//

import XCTest
@testable import PowderMeet

final class FITParserTests: XCTestCase {
    func testCompressedTimestampRecordIsDecodedWithEnhancedMetrics() throws {
        let data = makeCompressedRecordFixture(
            fullTimestamp: 1_000,
            compressedOffset: 10
        )

        let activity = FITParser.parseUnified(
            data: data,
            sourceFileHash: "fixture"
        )
        let points = try XCTUnwrap(activity.segments.first?.points)
        XCTAssertEqual(activity.segments.first?.boundary, .providerHint)

        XCTAssertEqual(points.count, 2)
        XCTAssertEqual(
            try XCTUnwrap(points[1].timestamp)
                .timeIntervalSince(try XCTUnwrap(points[0].timestamp)),
            2,
            accuracy: 0.001
        )
        XCTAssertEqual(try XCTUnwrap(points[0].elevation), 3_000, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(points[1].elevation), 2_990, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(points[0].speed), 8, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(points[1].speed), 9, accuracy: 0.001)
        try ActivityImportTrailMatchAssertions.assertResolvesConcreteTrail(points)
    }

    func testCompressedTimestampRolloverUsesNextThirtyTwoSecondWindow() {
        XCTAssertEqual(
            FITParser.reconstructedTimestamp(previous: 1_021, offset: 2),
            1_026
        )
    }

    func testDeclaredDataPastEndFailsClosed() {
        var data = makeCompressedRecordFixture(
            fullTimestamp: 1_000,
            compressedOffset: 10
        )
        data[4] = 0xFF
        data[5] = 0xFF
        data[6] = 0xFF
        data[7] = 0x7F

        XCTAssertTrue(FITParser.parse(data: data).isEmpty)
    }

    func testFileCRCMismatchFailsClosed() {
        var data = makeCompressedRecordFixture(
            fullTimestamp: 1_000,
            compressedOffset: 10
        )
        data[data.count - 1] ^= 0xFF

        XCTAssertTrue(FITParser.parse(data: data).isEmpty)
    }

    func testValidCRCWithTruncatedRecordStillFailsClosed() {
        var data = makeCompressedRecordFixture(
            fullTimestamp: 1_000,
            compressedOffset: 10
        )
        data.removeLast(2)
        data.removeLast()
        let shortenedDataSize = UInt32(data.count - 14)
        data[4] = UInt8(truncatingIfNeeded: shortenedDataSize)
        data[5] = UInt8(truncatingIfNeeded: shortenedDataSize >> 8)
        data[6] = UInt8(truncatingIfNeeded: shortenedDataSize >> 16)
        data[7] = UInt8(truncatingIfNeeded: shortenedDataSize >> 24)
        append(FITParser.crc16(data), to: &data)

        XCTAssertTrue(FITParser.parse(data: data).isEmpty)
    }

    func testChainedFITMembersDecodeAllRecords() throws {
        var first = makeCompressedRecordFixture(
            fullTimestamp: 1_000,
            compressedOffset: 10
        )
        first.append(makeCompressedRecordFixture(
            fullTimestamp: 2_000,
            compressedOffset: 12
        ))

        let points = try XCTUnwrap(FITParser.parse(data: first).first?.points)
        XCTAssertEqual(points.count, 4)
        XCTAssertLessThan(
            try XCTUnwrap(points[1].timestamp),
            try XCTUnwrap(points[2].timestamp)
        )
    }

    private func makeCompressedRecordFixture(
        fullTimestamp: UInt32,
        compressedOffset: UInt8
    ) -> Data {
        var records: [UInt8] = []

        appendDefinition(
            to: &records,
            localType: 0,
            fields: [
                (253, 4, 0x86),
                (0, 4, 0x85),
                (1, 4, 0x85),
                (73, 4, 0x86),
                (78, 4, 0x86),
            ]
        )
        records.append(0)
        append(fullTimestamp, to: &records)
        append(Int32(465_000_000), to: &records)
        append(Int32(-1_265_000_000), to: &records)
        append(UInt32(8_000), to: &records)
        append(UInt32(17_500), to: &records)

        appendDefinition(
            to: &records,
            localType: 1,
            fields: [
                (0, 4, 0x85),
                (1, 4, 0x85),
                (73, 4, 0x86),
                (78, 4, 0x86),
            ]
        )
        records.append(0x80 | (1 << 5) | (compressedOffset & 0x1F))
        append(Int32(464_999_000), to: &records)
        append(Int32(-1_265_001_000), to: &records)
        append(UInt32(9_000), to: &records)
        append(UInt32(17_450), to: &records)

        var bytes: [UInt8] = [
            14,
            0x20,
            0,
            0,
        ]
        append(UInt32(records.count), to: &bytes)
        bytes.append(contentsOf: Array(".FIT".utf8))
        bytes.append(contentsOf: [0, 0])
        bytes.append(contentsOf: records)
        append(FITParser.crc16(Data(bytes)), to: &bytes)
        return Data(bytes)
    }

    private func appendDefinition(
        to bytes: inout [UInt8],
        localType: UInt8,
        fields: [(UInt8, UInt8, UInt8)]
    ) {
        bytes.append(0x40 | localType)
        bytes.append(0)
        bytes.append(0)
        append(UInt16(20), to: &bytes)
        bytes.append(UInt8(fields.count))
        for field in fields {
            bytes.append(contentsOf: [field.0, field.1, field.2])
        }
    }

    private func append(_ value: UInt16, to bytes: inout [UInt8]) {
        bytes.append(UInt8(truncatingIfNeeded: value))
        bytes.append(UInt8(truncatingIfNeeded: value >> 8))
    }

    private func append(_ value: UInt32, to bytes: inout [UInt8]) {
        bytes.append(UInt8(truncatingIfNeeded: value))
        bytes.append(UInt8(truncatingIfNeeded: value >> 8))
        bytes.append(UInt8(truncatingIfNeeded: value >> 16))
        bytes.append(UInt8(truncatingIfNeeded: value >> 24))
    }

    private func append(_ value: Int32, to bytes: inout [UInt8]) {
        append(UInt32(bitPattern: value), to: &bytes)
    }

    private func append(_ value: UInt16, to data: inout Data) {
        data.append(UInt8(truncatingIfNeeded: value))
        data.append(UInt8(truncatingIfNeeded: value >> 8))
    }
}
