//
//  MountainRepositoryTests.swift
//  PowderMeetTests
//

import XCTest
import CoreLocation
@testable import PowderMeet

final class MountainRepositoryTests: XCTestCase {
    func testRetainsExactCanonicalVersionsAndSelectsHighestCurrentVersion() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MountainRepositoryTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = MountainRepository(cacheDirectory: directory)
        let v2 = makeDataset(manifestVersion: 2, shaCharacter: "b", source: .canonicalServer)
        let v1 = makeDataset(manifestVersion: 1, shaCharacter: "a", source: .canonicalServer)

        await repository.save(v2)
        await repository.save(v1) // saved later, but lower manifest

        let current = await repository.loadCanonical(resortID: "test")
        let exactV1 = await repository.loadCanonical(resortID: "test", manifestVersion: 1)
        XCTAssertEqual(current?.version.manifestVersion, 2)
        XCTAssertEqual(exactV1?.version.contentSHA256, String(repeating: "a", count: 64))
    }

    func testLegacyWriteDoesNotEvictCanonicalDataset() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MountainRepositoryTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = MountainRepository(cacheDirectory: directory)
        let canonical = makeDataset(manifestVersion: 3, shaCharacter: "c", source: .canonicalServer)
        let legacy = makeDataset(manifestVersion: nil, shaCharacter: "d", source: .legacySnapshot)

        await repository.save(canonical)
        await repository.save(legacy)

        let loadedCanonical = await repository.loadCanonical(resortID: "test")
        let loadedLegacy = await repository.loadLegacy(resortID: "test")
        XCTAssertEqual(loadedCanonical?.version.manifestVersion, 3)
        XCTAssertEqual(loadedLegacy?.dataset.source, .legacySnapshot)
    }

    func testExactCanonicalLookupDistinguishesSameManifestRebuilds() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MountainRepositoryTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = MountainRepository(cacheDirectory: directory)
        let first = makeDataset(
            manifestVersion: 8,
            shaCharacter: "a",
            source: .canonicalServer
        )
        let rebuilt = makeDataset(
            manifestVersion: 8,
            shaCharacter: "b",
            source: .canonicalServer
        )

        await repository.save(first)
        await repository.save(rebuilt)

        let exactFirst = await repository.loadCanonical(
            resortID: "test",
            exactVersion: first.version
        )
        let exactRebuilt = await repository.loadCanonical(
            resortID: "test",
            exactVersion: rebuilt.version
        )
        XCTAssertEqual(exactFirst?.version, first.version)
        XCTAssertEqual(exactRebuilt?.version, rebuilt.version)
    }

    func testInvalidCanonicalDatasetIsNotPersisted() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MountainRepositoryTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = MountainRepository(cacheDirectory: directory)
        let node = GraphNode(
            id: "only",
            coordinate: .init(latitude: 39.6, longitude: -106.3),
            elevation: 3_000,
            kind: .junction
        )
        let invalid = MountainDataset(
            resortID: "test",
            version: MountainDatasetVersion(
                manifestVersion: 4,
                graphVersion: MountainRepository.canonicalGraphVersion,
                contentSHA256: String(repeating: "e", count: 64)
            ),
            snapshotDate: "2026-08-02",
            source: .canonicalServer,
            graph: MountainGraph(resortID: "test", nodes: [node.id: node], edges: [])
        )

        await repository.save(invalid)

        let loaded = await repository.loadCanonical(resortID: "test")
        XCTAssertNil(loaded)
        XCTAssertTrue(
            (try FileManager.default.contentsOfDirectory(atPath: directory.path)).isEmpty
        )
    }

    func testCanonicalCacheWithTamperedFingerprintIsIgnored() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MountainRepositoryTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = MountainRepository(cacheDirectory: directory)
        let dataset = makeDataset(
            manifestVersion: 5,
            shaCharacter: "f",
            source: .canonicalServer
        )
        await repository.save(dataset)
        let file = try XCTUnwrap(
            FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil
            ).first
        )
        let data = try Data(contentsOf: file)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        object["graphFingerprint"] = "tampered"
        try JSONSerialization.data(withJSONObject: object).write(to: file, options: .atomic)

        let loaded = await repository.loadCanonical(resortID: "test")

        XCTAssertNil(loaded)
    }

    private func makeDataset(
        manifestVersion: Int?,
        shaCharacter: Character,
        source: MountainDataset.Source
    ) -> MountainDataset {
        let start = GraphNode(
            id: "start",
            coordinate: .init(latitude: 39.6, longitude: -106.3),
            elevation: 3_000,
            kind: .trailHead
        )
        let end = GraphNode(
            id: "end",
            coordinate: .init(latitude: 39.599, longitude: -106.3),
            elevation: 2_900,
            kind: .trailEnd
        )
        let edge = GraphEdge(
            id: "run",
            sourceID: start.id,
            targetID: end.id,
            kind: .run,
            geometry: [start.coordinate, end.coordinate],
            attributes: EdgeAttributes(
                difficulty: .blue,
                lengthMeters: 111,
                verticalDrop: 100,
                averageGradient: 42,
                maxGradient: 45,
                trailName: "Test Run",
                isOfficiallyValidated: true
            )
        )
        return MountainDataset(
            resortID: "test",
            version: MountainDatasetVersion(
                manifestVersion: manifestVersion,
                graphVersion: source == .canonicalServer
                    ? MountainRepository.canonicalGraphVersion
                    : MountainRepository.expectedLegacyVersion,
                contentSHA256: String(repeating: shaCharacter, count: 64)
            ),
            snapshotDate: "2026-08-02",
            source: source,
            graph: MountainGraph(
                resortID: "test",
                nodes: [start.id: start, end.id: end],
                edges: [edge]
            )
        )
    }
}
