//
//  ActivityImportCompatibilityTests.swift
//  PowderMeetTests
//

import XCTest
import CoreLocation
@testable import PowderMeet

final class ActivityImportCompatibilityTests: XCTestCase {
    func testRouteOnlyWritePreservesStatsAcrossSchemaCompatibilityWithoutLearning() throws {
        let evidence = RecordedPaceEvidence(confidence: 0.99, observations: [])
        let row = ImportedRunWriteRow(
            profile_id: UUID().uuidString, resort_id: "whistler", edge_id: "edge",
            difficulty: "blue", speed_ms: 20, peak_speed_ms: 25, duration_s: 120,
            vertical_m: 200, distance_m: 2400, max_grade_deg: 15,
            run_at: Date(timeIntervalSince1970: 1700000000), dedup_hash: "unique-run",
            source: "slopes", source_file_hash: "file", raw_source_identity: "source-run",
            dataset_version: "v1", matched_segment_ids: ["edge"], edge_observations: [],
            match_confidence: evidence.confidence, match_method: evidence.method,
            equipment_id_at_activity: nil, trail_name: "Peak to Creek", conditions_fp: "default"
        )
        func object(_ value: some Encodable) throws -> [String: Any] {
            try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
        }
        let rich = try object(row)
        let transitional = try object(row.withoutEdgeObservations)
        let legacy = try object(row.legacy)
        for payload in [rich, transitional, legacy] {
            XCTAssertEqual(payload["speed_ms"] as? Double, 20)
            XCTAssertEqual(payload["duration_s"] as? Double, 120)
            XCTAssertEqual(payload["distance_m"] as? Double, 2400)
            XCTAssertEqual(payload["trail_name"] as? String, "Peak to Creek")
            XCTAssertEqual(payload["dedup_hash"] as? String, "unique-run")
        }
        for payload in [rich, transitional] {
            XCTAssertEqual(payload["match_confidence"] as? Double, 0)
            XCTAssertEqual(payload["match_method"] as? String, evidence.method)
            XCTAssertEqual(payload["matched_segment_ids"] as? [String], ["edge"])
            XCTAssertEqual(payload["edge_id"] as? String, "edge")
        }
        XCTAssertEqual((rich["edge_observations"] as? [Any])?.count, 0)
        XCTAssertNil(legacy["edge_id"])
    }

    func testMissingExpandedColumnRetriesLegacyPayload() {
        XCTAssertTrue(ImportedRunSchemaCompatibility.shouldRetryLegacy(
            message: "PGRST204: Could not find the 'edge_observations' column of 'imported_runs' in the schema cache"
        ))
        XCTAssertTrue(ImportedRunSchemaCompatibility.shouldRetryLegacy(
            message: "column imported_runs.dataset_version does not exist"
        ))
        XCTAssertEqual(
            ImportedRunSchemaCompatibility.missingExpandedColumn(
                message: "PGRST204: edge_observations is missing from the schema cache"
            ),
            "edge_observations"
        )
    }

    func testUnrelatedFailuresNeverDowngradePayload() {
        XCTAssertFalse(ImportedRunSchemaCompatibility.shouldRetryLegacy(
            message: "new row violates row-level security policy"
        ))
        XCTAssertFalse(ImportedRunSchemaCompatibility.shouldRetryLegacy(
            message: "network connection was lost"
        ))
        XCTAssertFalse(ImportedRunSchemaCompatibility.shouldRetryLegacy(
            message: "Could not find the 'trail_name' column in the schema cache"
        ))
    }

    func testOnlyEvidenceBackedNamesCanUpgradeAnExistingRun() {
        XCTAssertFalse(ImportedRunNameQuality.isConcrete("Unnamed Green Trail"))
        XCTAssertFalse(ImportedRunNameQuality.isConcrete("Unnamed Double Black Trail · #12"))
        XCTAssertFalse(ImportedRunNameQuality.isConcrete("Unnamed Unknown Trail"))
        XCTAssertTrue(ImportedRunNameQuality.isConcrete("The Unnamed Couloir"))
        XCTAssertFalse(ImportedRunNameQuality.isConcrete(nil))
        XCTAssertFalse(ImportedRunNameQuality.isConcrete("Run"))
        XCTAssertFalse(ImportedRunNameQuality.isConcrete("Blue Run · 3:14 PM"))
        XCTAssertTrue(ImportedRunNameQuality.isConcrete("Dave Murray Downhill"))
        XCTAssertNil(ImportedRunNameQuality.concreteName("Run"))
        XCTAssertEqual(
            ImportedRunNameQuality.concreteName("  Dave Murray Downhill  "),
            "Dave Murray Downhill"
        )
        XCTAssertTrue(ImportedRunNameQuality.shouldUpgrade(
            existingName: "Run · 3:14 PM",
            existingConfidence: 0,
            candidateName: "Dave Murray Downhill",
            candidateConfidence: 0.4
        ))
        XCTAssertFalse(ImportedRunNameQuality.shouldUpgrade(
            existingName: "Dave Murray Downhill",
            existingConfidence: 0.8,
            candidateName: "Lower Franz's",
            candidateConfidence: 0.4
        ))
    }

    func testEverySupportedFormatCanBeDetectedFromContentOrExtension() throws {
        let base = URL(fileURLWithPath: "/tmp/activity")
        let fit = Data([14, 0, 0, 0, 0, 0, 0, 0]) + Data(".FIT".utf8) + Data([0, 0])
        let sqlite = Data("SQLite format 3\u{0}payload".utf8)
        let zip = Data([0x50, 0x4B, 0x03, 0x04])
        let gpx = try XCTUnwrap("<g:gpx xmlns:g=\"urn:gpx\"/>".data(using: .utf8))
        let tcx = try XCTUnwrap("<t:TrainingCenterDatabase xmlns:t=\"urn:tcx\"/>".data(using: .utf8))
        let backup = try XCTUnwrap("{\"export_schema_version\":5}".data(using: .utf8))

        XCTAssertEqual(ActivityFileFormat.detect(url: base, data: fit), .fit)
        XCTAssertEqual(ActivityFileFormat.detect(url: base, data: sqlite), .slopes)
        XCTAssertEqual(ActivityFileFormat.detect(url: base, data: zip), .slopes)
        XCTAssertEqual(ActivityFileFormat.detect(url: base, data: gpx), .gpx)
        XCTAssertEqual(ActivityFileFormat.detect(url: base, data: tcx), .tcx)
        XCTAssertEqual(ActivityFileFormat.detect(url: base, data: backup), .powdermeetBackup)
    }

    func testModernSlopesArchiveParsesAndSegments() throws {
        let metadata = """
        <Activity runCount="1" locationName="Whistler Blackcomb"
          start="2026-01-10 17:10:00 +0000" end="2026-01-10 17:10:20 +0000"
          recordStart="2026-01-10 17:10:00 +0000" recordEnd="2026-01-10 17:10:20 +0000"
          duration="20" distance="100" vertical="20" topSpeed="8">
          <actions>
            <Action type="Run" numberOfType="1"
              start="2026-01-10 17:10:00 +0000" end="2026-01-10 17:10:20 +0000"
              duration="20" topSpeed="8" avgSpeed="5" distance="100" vertical="20"/>
          </actions>
        </Activity>
        """
        let csv = (0...10).map { index in
            let seconds = index * 2
            let latitude = 50.09 - Double(index) * 0.00002
            let elevation = 2_000 - Double(index) * 2
            return "\(1768065000 + seconds),\(latitude),-122.95,\(elevation),0,5,3,4"
        }.joined(separator: "\n")
        let archive = storedZip(entries: [
            ("Metadata.xml", Data(metadata.utf8)),
            ("GPS.csv", Data(csv.utf8))
        ])
        let slopesURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("fixture-\(UUID().uuidString).slopes")
        try archive.write(to: slopesURL, options: .atomic)
        defer { try? FileManager.default.removeItem(at: slopesURL) }

        let slopes: ParsedActivity
        switch SlopesParser.parseUnified(url: slopesURL, sourceFileHash: "local-slopes") {
        case .success(let activity):
            slopes = activity
        case .failure(let error):
            return XCTFail("Real Slopes archive failed to parse: \(error.localizedDescription)")
        }
        XCTAssertEqual(slopes.segments.count, 1)
        XCTAssertEqual(slopes.segments.first?.boundary, .authoritativeDownhillRun)
        XCTAssertEqual(
            SkiActivitySegmenter.downhillRunSegments(from: slopes.segments).count,
            1
        )

        // Regression for the user-visible "Slopes just says Run" failure:
        // the parsed native Run must retain enough ordered geometry to pass
        // through the same directed matcher used by ActivityImporter and
        // recover a concrete canonical graph label.
        let top = GraphNode(
            id: "top",
            coordinate: .init(latitude: 50.09, longitude: -122.95),
            elevation: 2_000,
            kind: .trailHead
        )
        let bottom = GraphNode(
            id: "bottom",
            coordinate: .init(latitude: 50.0898, longitude: -122.95),
            elevation: 1_980,
            kind: .trailEnd
        )
        let namedEdge = GraphEdge(
            id: "peak-to-creek",
            sourceID: top.id,
            targetID: bottom.id,
            kind: .run,
            geometry: [top.coordinate, bottom.coordinate],
            attributes: EdgeAttributes(
                difficulty: .blue,
                lengthMeters: 100,
                verticalDrop: 20,
                trailName: "Peak to Creek",
                isOpen: true,
                trailGroupId: "peak-to-creek"
            )
        )
        let graph = MountainGraph(
            resortID: "whistler",
            nodes: [top.id: top, bottom.id: bottom],
            edges: [namedEdge]
        )
        let run = try XCTUnwrap(
            SkiActivitySegmenter.downhillRunSegments(from: slopes.segments).first
        )
        let match = try XCTUnwrap(
            TrailMatcher(graph: graph).matchRunTopology(
                SegmentedRun(points: run.points, isLift: false)
            )
        )
        XCTAssertEqual(match.primaryEdge.id, namedEdge.id)
        XCTAssertEqual(
            ImportedRunNameQuality.evidenceBackedTrailName(
                for: match.primaryEdge,
                naming: MountainNaming(graph)
            ),
            "Peak to Creek"
        )
    }

    func testLastResortTrailNamingProjectsToLongPolylineSegments() throws {
        let top = GraphNode(
            id: "top",
            coordinate: .init(latitude: 40, longitude: -106),
            elevation: 2_200,
            kind: .trailHead
        )
        let bottom = GraphNode(
            id: "bottom",
            coordinate: .init(latitude: 40.02, longitude: -106),
            elevation: 1_800,
            kind: .trailEnd
        )
        let edge = GraphEdge(
            id: "long-run",
            sourceID: top.id,
            targetID: bottom.id,
            kind: .run,
            geometry: [top.coordinate, bottom.coordinate],
            attributes: EdgeAttributes(
                difficulty: .blue,
                lengthMeters: 2_200,
                trailName: "Long Fall Line",
                isOpen: true
            )
        )
        let graph = MountainGraph(
            resortID: "test",
            nodes: [top.id: top, bottom.id: bottom],
            edges: [edge]
        )
        // Deliberately offset far enough for strict/relaxed matching to fail,
        // while the centroid remains within the display-only 300 m tier and
        // more than 1 km from either sparse graph vertex.
        let points = [
            GPXTrackPoint(latitude: 40.009, longitude: -105.9978, elevation: 2_020),
            GPXTrackPoint(latitude: 40.011, longitude: -105.9978, elevation: 1_980)
        ]
        let matcher = TrailMatcher(graph: graph)
        let segment = SegmentedRun(points: points, isLift: false)

        XCTAssertNil(matcher.bestEffortNameMatch(for: segment))
        XCTAssertEqual(matcher.nearestRunEdgeByCentroid(for: segment)?.id, edge.id)
    }

    /// Opt-in local audit against a private real export copied into the app's
    /// simulator Documents directory. CI never depends on private activity
    /// data; absence of the fixture is an explicit skip.
    @MainActor
    func testLocalWhistlerSlopesReconstructsDeclaredRunsAndNames() async throws {
        try requirePrivateImportAudit()
        let installed = FileManager.default.urls(
            for: .documentDirectory,
            in: .userDomainMask
        )[0].appendingPathComponent("Whistler.slopes")
        let local = repositoryFixture(
            "January 14, 2026 - Whistler Blackcomb.slopes"
        )
        guard let url = [installed, local].first(where: {
            FileManager.default.fileExists(atPath: $0.path)
        }) else {
            throw XCTSkip("private local Slopes fixture is not installed")
        }
        let parsed: ParsedActivity
        switch SlopesParser.parseUnified(url: url, sourceFileHash: "local-whistler") {
        case .success(let activity): parsed = activity
        case .failure(let error):
            return XCTFail("Real Slopes export failed: \(error.localizedDescription)")
        }
        let runs = SkiActivitySegmenter.downhillRunSegments(from: parsed.segments)
        XCTAssertEqual(parsed.segments.count, 10)
        XCTAssertEqual(runs.count, 10)

        let graph = try await offlineWhistlerGraph()
        // Independent coverage oracle: derive named groups from raw edges,
        // not the same summary helper that the picker itself consumes.
        let namedGroupIDs = Set(graph.runs.compactMap { edge -> String? in
            guard let name = edge.attributes.trailName,
                  !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return edge.attributes.trailGroupId ?? edge.id
        })
        let demoTrails = RoutingTestSheet.trailEntries(in: graph)
        XCTAssertEqual(Set(demoTrails.compactMap(\.trailGroupId)), namedGroupIDs)
        XCTAssertEqual(demoTrails.count, namedGroupIDs.count)
        XCTAssertGreaterThan(
            demoTrails.count,
            600,
            "Whistler's demo list should expose its complete named trail catalog"
        )
        let matcher = TrailMatcher(graph: graph)
        let naming = MountainNaming(graph)
        var matchTiers: [String] = []
        let labels = runs.enumerated().compactMap { runIndex, run -> String? in
            let segment = SegmentedRun(points: run.points, isLift: false)
            var samples: [TrailMatchSampleEvidence] = []
            let evaluation = matcher.evaluateRunTopology(segment, recordSample: { samples.append($0) })
            if case .success(let strict) = evaluation {
                matchTiers.append("strict: \(strict.primaryEdge.id)")
                matchTiers.append("sequence: " + strict.segmentIDs.map { id in
                    let name = graph.edge(byID: id).flatMap { ImportedRunNameQuality.evidenceBackedTrailName(for: $0, naming: naming) }
                    return "\(id)=\(name ?? "[unnamed]")"
                }.joined(separator: " → "))
                return ImportedRunNameQuality.evidenceBackedTrailName(for: strict.primaryEdge, naming: naming)
            }
            if case .failure(let reason) = evaluation {
                matchTiers.append("rejection: \(reason)")
                retainMatchEvidence(name: "Slopes-run-\(runIndex + 1)", reason: reason, samples: samples)
            }
            if let relaxed = matcher.bestEffortNameMatch(for: segment) {
                matchTiers.append("approximate: \(relaxed.id)")
                return ImportedRunNameQuality.evidenceBackedTrailName(for: relaxed, naming: naming)
            }
            if let nearest = matcher.nearestRunEdgeByCentroid(for: segment) {
                matchTiers.append("centroid-only: \(nearest.id)")
                return ImportedRunNameQuality.evidenceBackedTrailName(for: nearest, naming: naming)
            }
            matchTiers.append("unmatched")
            return nil
        }.filter(ImportedRunNameQuality.isConcrete)
        retainAudit(name: "Slopes", runCount: runs.count, labels: labels, tiers: matchTiers)
        XCTAssertEqual(labels.count, runs.count, "Every declared Whistler run should resolve to an evidence-backed trail label")
    }

    /// Gated audit of the two private full-day Garmin GPX recordings kept in
    /// `_local`. These have no lap semantics, so each physical downhill run
    /// must be reconstructed from the raw track and then named from the graph.
    @MainActor
    func testLocalWhistlerGPXReconstructsSpecificNamedRuns() async throws {
        try requirePrivateImportAudit()
        let documents = FileManager.default.urls(
            for: .documentDirectory,
            in: .userDomainMask
        )[0]
        let installed = [1, 2].map {
            documents.appendingPathComponent("Whistler-Garmin-\($0).gpx")
        }
        let repositoryFiles = [
            repositoryFixture("2026-03-12 13:25:50.gpx"),
            repositoryFixture("2026-04-25 12:00:50.gpx")
        ]
        let urls = installed.allSatisfy({ FileManager.default.fileExists(atPath: $0.path) })
            ? installed
            : repositoryFiles
        guard urls.allSatisfy({ FileManager.default.fileExists(atPath: $0.path) }) else {
            throw XCTSkip("private local Garmin GPX fixtures are not installed")
        }

        let graph = try await offlineWhistlerGraph()
        let matcher = TrailMatcher(graph: graph)
        let naming = MountainNaming(graph)

        for url in urls {
            let parsed = GPXParser.parseUnified(
                data: try Data(contentsOf: url),
                sourceFileHash: url.lastPathComponent
            )
            let runs = SkiActivitySegmenter.downhillRunSegments(from: parsed.segments)
            XCTAssertGreaterThan(runs.count, 1, "A full-day GPX must reconstruct individual descents")

            var matchTiers: [String] = []
            let names = runs.enumerated().compactMap { runIndex, run -> String? in
                let segment = SegmentedRun(points: run.points, isLift: false)
                var samples: [TrailMatchSampleEvidence] = []
                let evaluation = matcher.evaluateRunTopology(segment, recordSample: { samples.append($0) })
                if case .success(let strict) = evaluation {
                    matchTiers.append("strict: \(strict.primaryEdge.id)")
                    matchTiers.append("sequence: " + strict.segmentIDs.map { id in
                        let name = graph.edge(byID: id).flatMap { ImportedRunNameQuality.evidenceBackedTrailName(for: $0, naming: naming) }
                        return "\(id)=\(name ?? "[unnamed]")"
                    }.joined(separator: " → "))
                    return ImportedRunNameQuality.evidenceBackedTrailName(for: strict.primaryEdge, naming: naming)
                }
                if case .failure(let reason) = evaluation {
                    matchTiers.append("rejection: \(reason)")
                    retainMatchEvidence(name: "\(url.lastPathComponent)-run-\(runIndex + 1)", reason: reason, samples: samples)
                }
                if let relaxed = matcher.bestEffortNameMatch(for: segment) {
                    matchTiers.append("approximate: \(relaxed.id)")
                    return ImportedRunNameQuality.evidenceBackedTrailName(for: relaxed, naming: naming)
                }
                if let nearest = matcher.nearestRunEdgeByCentroid(for: segment) {
                    matchTiers.append("centroid-only: \(nearest.id)")
                    return ImportedRunNameQuality.evidenceBackedTrailName(for: nearest, naming: naming)
                }
                matchTiers.append("unmatched")
                return nil
            }.filter(ImportedRunNameQuality.isConcrete)
            retainAudit(name: url.lastPathComponent, runCount: runs.count, labels: names, tiers: matchTiers)
            XCTAssertEqual(
                names.count,
                runs.count,
                "Every reconstructed GPX descent should resolve to a specific trail"
            )
        }
    }

    /// Explicit immutable local input: never call a loader that can start a
    /// remote snapshot build as a side effect of a private-file test.
    @MainActor
    private func offlineWhistlerGraph() async throws -> MountainGraph {
        let path = try XCTUnwrap(ProcessInfo.processInfo.environment["POWDERMEET_PRIVATE_DATASET"],
            "Set POWDERMEET_PRIVATE_DATASET to a local CachedMountainDataset JSON")
        let envelope = try JSONDecoder().decode(CachedMountainDataset.self,
            from: Data(contentsOf: URL(fileURLWithPath: path)))
        XCTAssertEqual(envelope.dataset.resortID, "whistler")
        XCTAssertEqual(envelope.graph.resortID, "whistler")
        XCTAssertEqual(try XCTUnwrap(envelope.graphFingerprint), envelope.graph.fingerprint)
        let identity = XCTAttachment(string: "Source: \(envelope.dataset.source)\nVersion: \(envelope.dataset.version.identifier)\nFingerprint: \(envelope.graph.fingerprint)")
        identity.name = "Private audit dataset identity"
        identity.lifetime = .keepAlways
        add(identity)
        if envelope.dataset.source == .canonicalServer { return envelope.graph }
        return await GraphEnricher.enrich(envelope.graph, resortId: "whistler")
    }

    /// Explicit private-audit attachment only; GPS coordinates never enter
    /// production logs or repository fixtures through this diagnostic hook.
    private func retainMatchEvidence(name: String, reason: TrailMatchFailure, samples: [TrailMatchSampleEvidence]) {
        struct Report: Encodable {
            let activity: String
            let failure: String
            let samples: [TrailMatchSampleEvidence]
        }
        do {
            let data = try JSONEncoder().encode(Report(activity: name, failure: String(describing: reason), samples: samples))
            let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
            attachment.name = "Private match geometry - \(name)"
            attachment.lifetime = .keepAlways
            add(attachment)
        } catch {
            XCTFail("Could not retain private matching evidence: \(error)")
        }
    }

    private func retainAudit(name: String, runCount: Int, labels: [String], tiers: [String]) {
        let report = "Physical runs: \(runCount)\nConcrete labels: \(labels.count)\nMatch tiers in run order:\n"
            + tiers.joined(separator: "\n") + "\nResolved labels:\n" + labels.joined(separator: "\n")
        let attachment = XCTAttachment(string: report)
        attachment.name = "Private import audit - \(name)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Private activity exports live under the ignored `_local` directory in
    /// developer checkouts. Resolve from this source file so the audit works
    /// regardless of Xcode's test-process working directory while CI remains
    /// fixture-free and explicitly skips.
    private func repositoryFixture(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("_local/gps-logs")
            .appendingPathComponent(name)
    }

    /// Private full-day exports are deliberately excluded from the ordinary
    /// suite: the Garmin graph-matching audit alone is large enough to add many
    /// minutes to every test run. Opt in when validating the real files with
    /// `POWDERMEET_RUN_PRIVATE_IMPORT_AUDIT=1` in the test environment.
    private func requirePrivateImportAudit() throws {
        guard ProcessInfo.processInfo.environment[
            "POWDERMEET_RUN_PRIVATE_IMPORT_AUDIT"
        ] == "1" else {
            throw XCTSkip(
                "private import audit disabled; set POWDERMEET_RUN_PRIVATE_IMPORT_AUDIT=1"
            )
        }
    }

    /// Small stored-entry ZIP writer used only to model the exact modern
    /// `.slopes` container (Metadata.xml + GPS.csv) without private fixtures.
    private func storedZip(entries: [(name: String, data: Data)]) -> Data {
        struct CentralEntry {
            let name: Data
            let data: Data
            let offset: UInt32
        }
        var archive = Data()
        var centralEntries: [CentralEntry] = []

        for entry in entries {
            let name = Data(entry.name.utf8)
            let offset = UInt32(archive.count)
            append(UInt32(0x04034B50), to: &archive)
            append(UInt16(20), to: &archive)
            append(UInt16(0), to: &archive) // flags
            append(UInt16(0), to: &archive) // stored
            append(UInt16(0), to: &archive) // time
            append(UInt16(0), to: &archive) // date
            append(UInt32(0), to: &archive) // CRC unused by ZipReader
            append(UInt32(entry.data.count), to: &archive)
            append(UInt32(entry.data.count), to: &archive)
            append(UInt16(name.count), to: &archive)
            append(UInt16(0), to: &archive)
            archive.append(name)
            archive.append(entry.data)
            centralEntries.append(CentralEntry(name: name, data: entry.data, offset: offset))
        }

        let centralOffset = UInt32(archive.count)
        for entry in centralEntries {
            append(UInt32(0x02014B50), to: &archive)
            append(UInt16(20), to: &archive) // made by
            append(UInt16(20), to: &archive) // needed
            append(UInt16(0), to: &archive)  // flags
            append(UInt16(0), to: &archive)  // stored
            append(UInt16(0), to: &archive)
            append(UInt16(0), to: &archive)
            append(UInt32(0), to: &archive)
            append(UInt32(entry.data.count), to: &archive)
            append(UInt32(entry.data.count), to: &archive)
            append(UInt16(entry.name.count), to: &archive)
            append(UInt16(0), to: &archive) // extra
            append(UInt16(0), to: &archive) // comment
            append(UInt16(0), to: &archive) // disk
            append(UInt16(0), to: &archive) // internal attributes
            append(UInt32(0), to: &archive) // external attributes
            append(entry.offset, to: &archive)
            archive.append(entry.name)
        }

        let centralSize = UInt32(archive.count) - centralOffset
        append(UInt32(0x06054B50), to: &archive)
        append(UInt16(0), to: &archive)
        append(UInt16(0), to: &archive)
        append(UInt16(centralEntries.count), to: &archive)
        append(UInt16(centralEntries.count), to: &archive)
        append(centralSize, to: &archive)
        append(centralOffset, to: &archive)
        append(UInt16(0), to: &archive)
        return archive
    }

    private func append<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
    }
}
