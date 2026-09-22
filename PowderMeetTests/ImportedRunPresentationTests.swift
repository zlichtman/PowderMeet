import SwiftUI
import XCTest
@testable import PowderMeet

@MainActor
final class ImportedRunPresentationTests: XCTestCase {
    func testMatchStatusUsesProvenanceNotJustConfidence() {
        func status(_ method: String?, _ confidence: Double = 1) -> ImportedRunMatchStatus {
            .init(method: method, confidence: confidence, dataset: "v1", edgeID: "a", segments: ["a"])
        }
        XCTAssertEqual(status("polyline_sequence"), .connected)
        XCTAssertEqual(status("polyline_sequence", 0.74), .approximate)
        XCTAssertEqual(status("relaxed_name"), .approximate)
        XCTAssertEqual(status("nearest_name"), .nearby)
        XCTAssertEqual(status("unmatched"), .unmatched)
        XCTAssertEqual(status(nil), .unverified)
        XCTAssertEqual(status("future_method"), .unverified)
        XCTAssertEqual(status("display_only_invalid_metrics"), .unverified)
    }

    func testIncompleteTopologyCannotDisplayConnectedMatch() {
        for (dataset, edge, segments, confidence) in [
            (nil as String?, "a", ["a"], 1.0),
            (" ", "a", ["a"], 1.0),
            ("v1", "a", [], 1.0),
            ("v1", "a", ["b"], 1.0),
            ("v1", "a", ["a", " "], 1.0),
            ("v1", "a", ["a"], Double.nan),
            ("v1", "a", ["a"], 1.1)
        ] {
            XCTAssertEqual(ImportedRunMatchStatus(method: "polyline_sequence", confidence: confidence,
                                                   dataset: dataset, edgeID: edge, segments: segments), .unverified)
        }
    }

    func testRouteOnlyStatusRequiresCompleteRouteIdentity() {
        let method = RecordedPaceEvidence.routeOnlyMethod
        XCTAssertEqual(ImportedRunMatchStatus(method: method, confidence: 0,
                       dataset: "v1", edgeID: "a", segments: ["a"]), .routeOnly)
        XCTAssertEqual(ImportedRunMatchStatus(method: method, confidence: 0,
                       dataset: nil, edgeID: "a", segments: ["a"]), .unverified)
        XCTAssertEqual(ImportedRunMatchStatus(method: method, confidence: 0,
                       dataset: "v1", edgeID: "a", segments: ["b"]), .unverified)
        XCTAssertEqual(ImportedRunMatchStatus.routeOnly.label, "ROUTE ONLY")
    }

    func testRealColorWordsInTrailNamesArePreserved() {
        for name in ["Blue Line", "Green Acres", "Black Forest", "Blue Sky Basin"] {
            XCTAssertEqual(ImportedRunsView.stripColorWords(name), name)
            XCTAssertEqual(ImportedRunsView.stripColorWords("\(name) · Blue"), name)
        }
        XCTAssertEqual(ImportedRunsView.stripColorWords("Riva Ridge (Black) · Black"), "Riva Ridge")
        XCTAssertEqual(ImportedRunsView.stripColorWords("Blue Run"), "Run")
    }

    func testLogRowsAtStandardTextSize() throws {
        try renderRows(size: .large, label: "standard")
    }

    func testLogRowsAtAccessibilityTextSize() throws {
        try renderRows(size: .accessibility3, label: "accessibility")
    }

    private func renderRows(size: DynamicTypeSize, label: String) throws {
        let scenarios = [
            ("polyline_sequence", "Blue Line", "slopes"),
            (RecordedPaceEvidence.routeOnlyMethod, "Peak to Creek", "tcx"),
            ("relaxed_name", "Whistler Village Gondola Connector — Upper Olympic", "gpx"),
            ("nearest_name", "Green Acres", "fit"),
            ("legacy", "Black Forest", "powdermeet"),
            ("unmatched", "Run", "healthkit")
        ]
        let rows = try scenarios.map { scenario -> (ImportedRunRecord, String) in
            let object: [String: Any] = [
                "id": UUID().uuidString, "profile_id": UUID().uuidString,
                "resort_id": "whistler", "edge_id": "a", "difficulty": "blue",
                "speed_ms": 9, "peak_speed_ms": 12, "duration_s": 134,
                "vertical_m": 200, "distance_m": 1200, "max_grade_deg": 15,
                "run_at": 1700000000, "created_at": 1700000000,
                "source": scenario.2, "trail_name": scenario.1,
                "dataset_version": "v1", "matched_segment_ids": ["a"],
                "match_confidence": 1, "match_method": scenario.0
            ]
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .secondsSince1970
            return (try decoder.decode(ImportedRunRecord.self, from: JSONSerialization.data(withJSONObject: object)), scenario.1)
        }
        let view = VStack(spacing: 0) {
            ForEach(rows.indices, id: \.self) { i in ImportedRunLogRow(run: rows[i].0, trailName: rows[i].1) }
        }
        .frame(width: 370)
        .background(HUDTheme.mapBackground)
        .environment(\.dynamicTypeSize, size)
        .environment(\.colorScheme, .dark)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.uiImage)
        XCTAssertEqual(image.size.width, 370, accuracy: 0.5)
        XCTAssertGreaterThan(image.size.height, 250)
        XCTAssertLessThan(image.size.height, 1800)
        let attachment = XCTAttachment(image: image)
        attachment.name = "activity-log-\(label)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testRouteDetailsPreserveOrderedGroupsUnnamedSectionsAndRevisits() throws {
        let dataset = routeDataset()
        let details = ImportedRunRouteIndex(dataset: dataset).details(for: try routeRecord(dataset))
        XCTAssertNil(details.unavailableReason)
        XCTAssertEqual(details.sections.map(\.title), ["Blue Line", "Unnamed trail section", "Blue Line", "Blue Line"])
        XCTAssertEqual(details.sections.map(\.segmentIDs), [["a", "b"], ["c"], ["d"], ["e"]])
        XCTAssertEqual(Set(details.sections.map(\.id)).count, 4)
    }

    func testRouteDetailsRequireExactResortAndDataset() throws {
        let dataset = routeDataset()
        let index = ImportedRunRouteIndex(dataset: dataset)
        for override in [["resort_id": "other"], ["dataset_version": "other"]] {
            XCTAssertEqual(index.details(for: try routeRecord(dataset, override: override)),
                           .unavailable(.recordedDatasetNotLoaded))
        }
    }

    func testRouteDetailsRejectEntireBrokenSequence() throws {
        let dataset = routeDataset()
        let index = ImportedRunRouteIndex(dataset: dataset)
        for ids in [["a", "missing", "c"], ["a", "c"], ["a", "lift"], ["a", "a"]] {
            XCTAssertEqual(index.details(for: try routeRecord(dataset, override: ["matched_segment_ids": ids])),
                           .unavailable(.incompleteSequence))
        }
    }

    func testNameHintsCannotBecomeRecordedRoutes() throws {
        let dataset = routeDataset()
        let index = ImportedRunRouteIndex(dataset: dataset)
        for method in ["relaxed_name", "nearest_name", "unmatched", "legacy", "future"] {
            XCTAssertEqual(index.details(for: try routeRecord(dataset, override: ["match_method": method])),
                           .unavailable(.noTopology))
        }
        XCTAssertEqual(index.details(for: try routeRecord(dataset, override: ["matched_segment_ids": []])),
                       .unavailable(.noTopology))
    }

    func testHistoricalRouteSurvivesClosureAndRouteOnlyRetainsSequence() throws {
        let dataset = routeDataset(closed: true)
        let index = ImportedRunRouteIndex(dataset: dataset)
        for method in ["polyline_sequence", RecordedPaceEvidence.routeOnlyMethod] {
            let details = index.details(for: try routeRecord(dataset, override: ["match_method": method]))
            XCTAssertNil(details.unavailableReason)
            XCTAssertEqual(details.sections.flatMap(\.segmentIDs), ["a", "b", "c", "d", "e"])
        }
    }

    func testRouteDetailsAtStandardAndAccessibilitySizes() throws {
        let dataset = routeDataset()
        let run = try routeRecord(dataset)
        let route = ImportedRunRouteIndex(dataset: dataset).details(for: run)
        for size in [DynamicTypeSize.large, .accessibility3] {
            let view = ImportedRunDetailsContent(run: run, trailName: "Blue Line → Lower Mountain", route: route)
                .padding(20).frame(width: 370).background(HUDTheme.mapBackground)
                .environment(\.dynamicTypeSize, size).environment(\.colorScheme, .dark)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            let image = try XCTUnwrap(renderer.uiImage)
            XCTAssertEqual(image.size.width, 370, accuracy: 0.5)
            XCTAssertGreaterThan(image.size.height, 300)
            XCTAssertLessThan(image.size.height, 2400)
            let attachment = XCTAttachment(image: image)
            attachment.name = "run-route-details-\(size)"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }

    private func routeDataset(closed: Bool = false) -> MountainDataset {
        let nodes = (0...5).map { i in
            GraphNode(id: "n\(i)", coordinate: .init(latitude: 50 - Double(i) * 0.001, longitude: -122),
                      elevation: 2000 - Double(i) * 100, kind: .trailHead)
        }
        let ids = ["a", "b", "c", "d", "e"]
        let groups = ["blue", "blue", "unknown", "blue", "different-blue"]
        var edges = ids.enumerated().map { i, id in
            GraphEdge(id: id, sourceID: nodes[i].id, targetID: nodes[i + 1].id, kind: .run,
                      geometry: [nodes[i].coordinate, nodes[i + 1].coordinate],
                      attributes: EdgeAttributes(difficulty: .blue, lengthMeters: 150, verticalDrop: 100,
                          trailName: i == 2 ? "Unnamed Blue Trail" : "Blue Line", isOpen: !closed,
                          trailGroupId: groups[i]))
        }
        edges.append(GraphEdge(id: "lift", sourceID: "n1", targetID: "n2", kind: .lift,
                               geometry: [nodes[1].coordinate, nodes[2].coordinate], attributes: EdgeAttributes()))
        return MountainDataset(resortID: "test", version: .init(manifestVersion: 1, graphVersion: "v13",
            contentSHA256: String(repeating: "a", count: 64)), snapshotDate: nil, source: .canonicalServer,
            graph: MountainGraph(resortID: "test", nodes: Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0) }), edges: edges))
    }

    private func routeRecord(_ dataset: MountainDataset, override: [String: Any] = [:]) throws -> ImportedRunRecord {
        var object: [String: Any] = [
            "id": UUID().uuidString, "profile_id": UUID().uuidString,
            "resort_id": dataset.resortID, "edge_id": "a", "difficulty": "blue",
            "speed_ms": 9, "duration_s": 134, "vertical_m": 500, "distance_m": 750,
            "max_grade_deg": 15, "run_at": 1700000000, "created_at": 1700000000,
            "source": "slopes", "trail_name": "Blue Line", "dataset_version": dataset.version.identifier,
            "matched_segment_ids": ["a", "b", "c", "d", "e"], "match_confidence": 1,
            "match_method": "polyline_sequence"
        ]
        object.merge(override) { _, new in new }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try decoder.decode(ImportedRunRecord.self, from: JSONSerialization.data(withJSONObject: object))
    }
}
