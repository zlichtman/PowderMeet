//
//  ActivityCorpusParseTests.swift
//  PowderMeetTests
//
//  Parses every recording in Fixtures/GPSLogs. The corpus is real ski-day
//  data from several resorts and trackers, so a parser regression that only
//  shows up on production files fails here rather than on a phone.
//

import XCTest
@testable import PowderMeet

final class ActivityCorpusParseTests: XCTestCase {
    private func corpusURLs() throws -> [URL] {
        let folder = try XCTUnwrap(
            Bundle(for: Self.self).url(forResource: "GPSLogs", withExtension: nil),
            "GPSLogs folder reference is missing from the test bundle"
        )
        let files = try FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: nil
        )
        return files
            .filter { !$0.lastPathComponent.hasPrefix(".") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    func testEveryCorpusFileParsesIntoSegments() throws {
        let urls = try corpusURLs()
        XCTAssertGreaterThan(urls.count, 0, "corpus is empty")

        for url in urls {
            let name = url.lastPathComponent
            let data = try Data(contentsOf: url)
            let format = try XCTUnwrap(
                ActivityFileFormat.detect(url: url, data: data),
                "\(name): format not detected"
            )

            let activity: ParsedActivity
            switch format {
            case .slopes:
                switch SlopesParser.parseUnified(url: url, sourceFileHash: name) {
                case .success(let parsed): activity = parsed
                case .failure(let error):
                    XCTFail("\(name): \(error.localizedDescription)")
                    continue
                }
            case .gpx:
                activity = GPXParser.parseUnified(data: data, sourceFileHash: name)
            case .tcx:
                activity = TCXParser.parseUnified(data: data, sourceFileHash: name)
            case .fit:
                activity = FITParser.parseUnified(data: data, sourceFileHash: name)
            case .powdermeetBackup:
                XCTFail("\(name): backups do not belong in the activity corpus")
                continue
            }

            XCTAssertFalse(activity.segments.isEmpty, "\(name): parsed no segments")
            if format == .slopes {
                XCTAssertGreaterThan(
                    SkiActivitySegmenter.downhillRunSegments(from: activity.segments).count,
                    0,
                    "\(name): no downhill runs recovered"
                )
            }
        }
    }
}
