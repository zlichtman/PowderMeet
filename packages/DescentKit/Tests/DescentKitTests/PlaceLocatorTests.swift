import Foundation
import MountainCore
import Testing
@testable import DescentKit

/// The run or lift label on the Whistler Blackcomb bundle.
struct PlaceLocatorTests {
    private let bundle: ResortBundle
    private let locator: PlaceLocator
    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    init() throws {
        let name = "whistler-blackcomb.95236f0065c782dd745561fa4e153845c6a9f568cbd7cdf1e1087c43ee0ef16d"
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("MountainCore/Tests/Fixtures/\(name).json.gz")
        let id = try #require(BundleID(String(name.split(separator: ".")[1])))
        bundle = try BundleLoader.load(data: Data(contentsOf: url), expectedID: id)
        locator = PlaceLocator(bundle: bundle)
    }

    private func edge(_ id: String) throws -> Edge {
        try #require(bundle.graph.edges.first { $0.id == EdgeID(id) })
    }

    private func position(
        _ coordinate: Coordinate, speed: Double? = nil, heading: Double? = nil, second: TimeInterval = 0
    ) -> SkierPosition {
        SkierPosition(
            coordinate: coordinate, accuracyM: 5, speedMS: speed, headingDeg: heading,
            capturedAt: start.addingTimeInterval(second)
        )
    }

    @Test func pointOnRunNamesIt() throws {
        let traverse = try edge("w1316176761:5").geometry
        let a = traverse[4], b = traverse[5]
        let middle = Coordinate(lon: (a.lon + b.lon) / 2, lat: (a.lat + b.lat) / 2)
        let reading = locator.locate(position(middle), after: nil)
        #expect(reading.place == .run(name: "Pika's Traverse", difficulty: .green))
    }

    @Test func movingUpLiftLineIsRidingIt() throws {
        let line = try edge("w32775430:0").geometry
        let a = line[4].coordinate, b = line[5].coordinate
        let middle = Coordinate(lon: (a.lon + b.lon) / 2, lat: (a.lat + b.lat) / 2)
        let reported = locator.locate(position(middle, speed: 4, heading: bearing(a, b)), after: nil)
        #expect(reported.place == .lift(name: "Peak Express"))

        // No course, a fix a second at chair speed: the fixes add up to a direction.
        let steps = Int(Geo.haversineM(a, b) / 4)
        var reading: PlaceReading?
        for step in 0...steps {
            let f = Double(step) / Double(steps)
            let along = Coordinate(lon: a.lon + (b.lon - a.lon) * f, lat: a.lat + (b.lat - a.lat) * f)
            reading = locator.locate(position(along, second: Double(step)), after: reading)
        }
        #expect(steps >= 5)
        #expect(reading?.place == .lift(name: "Peak Express"))
    }

    @Test func standingAtLiftBaseIsNotRidingIt() throws {
        let lift = try edge("w32775430:0")
        let base = try #require(bundle.graph.nodes[lift.from]).coordinate
        let standing = locator.locate(position(base, speed: 0), after: nil)
        #expect(standing.place != .lift(name: "Peak Express"))
        let queued = locator.locate(position(base, speed: 0, second: 30), after: standing)
        #expect(queued.place != .lift(name: "Peak Express"))

        let up = bearing(lift.geometry[0].coordinate, lift.geometry[1].coordinate)
        let leaving = locator.locate(position(base, speed: 3, heading: up, second: 60), after: queued)
        #expect(leaving.place == .lift(name: "Peak Express"))
    }

    /// A point between two named runs, nearer the second but within the hold
    /// distance of the first: without a previous answer it is the second run,
    /// after one on the first it stays on the first.
    @Test func previousRunHoldsBetweenParallelRuns() throws {
        var found = false
        search: for run in bundle.graph.edges where run.kind == .run && run.name != nil && run.geometry.count >= 3 {
            let index = run.geometry.count / 2
            let on = run.geometry[index].coordinate
            let across = bearing(run.geometry[index - 1].coordinate, run.geometry[index + 1].coordinate) + 90
            let first = locator.locate(position(on), after: nil)
            guard case .run = first.place else { continue }
            for side in [0.0, 180.0] {
                for offset in stride(from: 28.0, through: 38.0, by: 2.0) {
                    let between = offsetting(on, metres: offset, bearing: across + side)
                    let fresh = locator.locate(position(between, second: 10), after: nil)
                    guard case .run = fresh.place, fresh.place != first.place,
                          let toFirst = Geo.project(between, onto: run.coordinates)?.distanceM,
                          toFirst <= 38 else { continue }
                    let held = locator.locate(position(between, second: 10), after: first)
                    #expect(held.place == first.place, "\(run.id) at \(offset) m")
                    found = true
                    break search
                }
            }
        }
        #expect(found)
    }

    @Test func farFromEveryLineIsNil() throws {
        let lines = bundle.graph.edges.map(\.coordinates)
        let clear = stride(from: 0.0, to: 360.0, by: 15.0).lazy.flatMap { direction in
            stride(from: 500.0, through: 4_000.0, by: 250.0).lazy.map { distance in
                offsetting(bundle.center, metres: distance, bearing: direction)
            }
        }.first { point in
            let nearest = lines.compactMap { Geo.project(point, onto: $0)?.distanceM }.min() ?? 0
            return (200...300).contains(nearest)
        }
        let point = try #require(clear)
        #expect(locator.locate(position(point), after: nil).place == nil)
    }

    private func bearing(_ a: Coordinate, _ b: Coordinate) -> Double {
        let dx = (b.lon - a.lon) * cos(a.lat * .pi / 180), dy = b.lat - a.lat
        // Phones report 0..<360; a negative course means none.
        return (atan2(dx, dy) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360)
    }

    private func offsetting(_ c: Coordinate, metres: Double, bearing: Double) -> Coordinate {
        let radians = bearing * .pi / 180
        return Coordinate(
            lon: c.lon + metres * sin(radians) / (111_320 * cos(c.lat * .pi / 180)),
            lat: c.lat + metres * cos(radians) / 111_132
        )
    }
}
