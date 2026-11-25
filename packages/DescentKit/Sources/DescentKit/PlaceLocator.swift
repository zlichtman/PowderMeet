import Foundation
import MountainCore

/// One position of a skier, as this phone or a friend's presence reports it.
public struct SkierPosition: Hashable, Sendable {
    public var coordinate: Coordinate
    /// Horizontal accuracy, metres.
    public var accuracyM: Double?
    /// Ground speed, m/s.
    public var speedMS: Double?
    /// Course over ground, degrees clockwise from north.
    public var headingDeg: Double?
    public var capturedAt: Date

    public init(
        coordinate: Coordinate, accuracyM: Double? = nil, speedMS: Double? = nil,
        headingDeg: Double? = nil, capturedAt: Date
    ) {
        self.coordinate = coordinate
        self.accuracyM = accuracyM
        self.speedMS = speedMS
        self.headingDeg = headingDeg
        self.capturedAt = capturedAt
    }
}

/// The run or lift a skier is on, for labels such as "On Pika's Traverse".
public enum SkierPlace: Hashable, Sendable {
    /// A named run, or a named connection (a cat track or link), which
    /// skiers call a run too.
    case run(name: String, difficulty: Difficulty?)
    case lift(name: String)
}

/// One answer from `PlaceLocator`, kept by the caller and handed back with the
/// same person's next position so the answer holds steady.
public struct PlaceReading: Hashable, Sendable {
    /// Nil when off the map, on an unnamed line, or unsure.
    public let place: SkierPlace?
    let bundleID: BundleID
    /// The line the answer came from, also when it is unnamed, so a skier on an
    /// unnamed track beside a named run does not flicker onto the run.
    let key: PlaceLocator.LineKey?
    /// The earlier position the direction of travel is measured from. It moves
    /// on only once the skier is far enough from it, so fixes a second apart
    /// on a slow chair still add up to a direction.
    let anchor: SkierPosition
}

/// Works out which run or lift a skier is on from one position. Build one per
/// bundle and keep it: the spatial index is built here, and each `locate` is
/// one grid-cell lookup, cheap enough for every friend on every update.
public struct PlaceLocator: Sendable {
    /// A line is a candidate within this distance, before accuracy widens it.
    static let baseRadiusM = 25.0
    /// Reported accuracy widens the radius by this share of itself…
    static let accuracyShare = 0.5
    /// …up to this distance.
    static let maximumRadiusM = 50.0
    /// The previous answer holds while its line is this close.
    static let holdRadiusM = 40.0
    /// A fix less accurate than this says too little to name anything.
    static let worstUsableAccuracyM = 100.0
    /// Below this the skier is standing still and a heading means nothing.
    static let movingSpeedMS = 0.7
    /// Travel within this angle of a lift's direction can be riding it.
    static let liftHeadingToleranceDeg = 40.0
    /// A held lift answer ends this close to either station: the skier is
    /// queueing or has got off.
    static let stationClearanceM = 20.0
    /// The previous position gives a direction of travel when it is at most
    /// this old and this far away.
    static let travelWindowS = 120.0
    static let travelMinimumM = 10.0

    enum LineKey: Hashable, Sendable {
        case group(GroupID)
        case edge(EdgeID)
    }

    private struct Line: Sendable {
        let key: LineKey
        let kind: EdgeKind
        let points: [SIMD2<Double>]
        /// Length before each vertex.
        let cumulative: [Double]
        /// Typical ride speed, m/s.
        let liftSpeedMS: Double?
    }

    private struct Projection {
        let line: Int
        let distance: Double
        let along: Double
        /// Unit direction of the segment, in the line's from→to order.
        let direction: SIMD2<Double>
    }

    private let bundleID: BundleID
    private let origin: Coordinate
    private let kx: Double
    private let ky: Double
    private let lines: [Line]
    private let grid: SegmentGrid
    private let places: [LineKey: SkierPlace]

    public init(bundle: ResortBundle) {
        // A local plane around the resort is accurate to well under a metre at resort scale.
        let origin = bundle.center
        let ky = 111_132.0, kx = 111_320.0 * cos(origin.lat * .pi / 180)
        bundleID = bundle.id
        self.origin = origin
        self.kx = kx
        self.ky = ky
        var lines: [Line] = []
        var places: [LineKey: SkierPlace] = [:]
        for edge in bundle.graph.edges where edge.geometry.count >= 2 {
            let group = edge.group.flatMap(bundle.group)
            let key: LineKey = edge.group.map { .group($0) } ?? .edge(edge.id)
            let name = (group?.name ?? edge.name)?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let name, !name.isEmpty {
                places[key] = edge.kind == .lift
                    ? .lift(name: name)
                    : .run(name: name, difficulty: group?.difficulty ?? edge.difficulty)
            }
            let points = edge.geometry.map {
                SIMD2(($0.lon - origin.lon) * kx, ($0.lat - origin.lat) * ky)
            }
            var cumulative = [0.0]
            for i in 1..<points.count { cumulative.append(cumulative[i - 1] + length(points[i] - points[i - 1])) }
            guard cumulative[cumulative.count - 1] > 0 else { continue }
            let lift = edge.lift
            lines.append(Line(
                key: key, kind: edge.kind, points: points, cumulative: cumulative,
                liftSpeedMS: lift.flatMap { $0.rideS > 0 ? edge.lengthM / $0.rideS : nil }
            ))
        }
        self.lines = lines
        self.places = places
        grid = SegmentGrid(lines: lines.map(\.points), radius: max(Self.maximumRadiusM, Self.holdRadiusM))
    }

    /// Where the skier is now. Pass the reading this returned for the same
    /// person's previous position, or nil for their first.
    public func locate(_ position: SkierPosition, after previous: PlaceReading?) -> PlaceReading {
        let previous = previous?.bundleID == bundleID ? previous : nil
        let anchor = nextAnchor(after: previous?.anchor, for: position)
        func answer(_ key: LineKey?) -> PlaceReading {
            PlaceReading(place: key.flatMap { places[$0] }, bundleID: bundleID, key: key, anchor: anchor)
        }
        let accuracy = position.accuracyM.flatMap { $0 >= 0 ? $0 : nil } ?? 0
        guard position.coordinate.isValid, accuracy <= Self.worstUsableAccuracyM else { return answer(nil) }
        let radius = min(Self.baseRadiusM + Self.accuracyShare * accuracy, Self.maximumRadiusM)
        let hold = max(Self.holdRadiusM, radius)
        let point = xy(position.coordinate)
        let nearby = projections(at: point, within: hold)
        let travel = travel(of: position, after: previous)

        // Riding a lift needs evidence of riding; the run under it is the fallback.
        let riding = nearby.filter { lines[$0.line].kind == .lift && $0.distance <= radius && fits(travel, $0) }
        if let best = riding.min(by: { $0.distance < $1.distance }) { return answer(lines[best.line].key) }

        if let key = previous?.key {
            let held = nearby.filter { lines[$0.line].key == key }
            if let first = held.first {
                // A stopped chair keeps its riders; moving off the line's way or
                // reaching a station ends the ride.
                let keeps = lines[first.line].kind != .lift
                    || held.contains { isMidRide($0) && (travel.direction == nil || fits(travel, $0)) }
                if keeps { return answer(key) }
            }
        }

        let nearest = nearby
            .filter { lines[$0.line].kind != .lift && $0.distance <= radius }
            .min { $0.distance != $1.distance ? $0.distance < $1.distance : $0.line < $1.line }
        return answer(nearest.map { lines[$0.line].key })
    }

    // MARK: - Evidence

    /// Speed and, when known, the unit direction of travel.
    private struct Travel {
        let speedMS: Double?
        let direction: SIMD2<Double>?
    }

    private func travel(of position: SkierPosition, after previous: PlaceReading?) -> Travel {
        var speed = position.speedMS.flatMap { $0 >= 0 ? $0 : nil }
        if let heading = position.headingDeg, heading >= 0, (speed ?? 0) >= Self.movingSpeedMS {
            let radians = heading * .pi / 180
            return Travel(speedMS: speed, direction: SIMD2(sin(radians), cos(radians)))
        }
        // This phone's fixes and some friends' carry no course; the move since the anchor gives one.
        if let last = previous?.anchor {
            let seconds = position.capturedAt.timeIntervalSince(last.capturedAt)
            let moved = xy(position.coordinate) - xy(last.coordinate)
            let distance = length(moved)
            if seconds > 0, seconds <= Self.travelWindowS, distance >= Self.travelMinimumM {
                speed = speed ?? distance / seconds
                if (speed ?? 0) >= Self.movingSpeedMS {
                    return Travel(speedMS: speed, direction: moved / distance)
                }
            }
        }
        return Travel(speedMS: speed, direction: nil)
    }

    private func nextAnchor(after anchor: SkierPosition?, for position: SkierPosition) -> SkierPosition {
        guard let anchor else { return position }
        let seconds = position.capturedAt.timeIntervalSince(anchor.capturedAt)
        let distance = length(xy(position.coordinate) - xy(anchor.coordinate))
        return seconds <= 0 || seconds > Self.travelWindowS || distance >= Self.travelMinimumM ? position : anchor
    }

    /// Moving up the lift line at a speed a lift goes. Riding a gondola down
    /// is not told apart: at skiing speed it looks like the run beneath it.
    private func fits(_ travel: Travel, _ projection: Projection) -> Bool {
        guard let direction = travel.direction, let speed = travel.speedMS, speed >= Self.movingSpeedMS else {
            return false
        }
        let nominal = lines[projection.line].liftSpeedMS ?? 5
        return dot(direction, projection.direction) >= cos(Self.liftHeadingToleranceDeg * .pi / 180)
            && speed <= nominal * 1.5 + 1
    }

    /// Between the stations, where a stopped chair still has its riders on it.
    private func isMidRide(_ projection: Projection) -> Bool {
        let total = lines[projection.line].cumulative.last ?? 0
        return projection.along > Self.stationClearanceM && projection.along < total - Self.stationClearanceM
    }

    // MARK: - Geometry

    private func xy(_ c: Coordinate) -> SIMD2<Double> {
        SIMD2((c.lon - origin.lon) * kx, (c.lat - origin.lat) * ky)
    }

    /// The closest point of each line within `radius`.
    private func projections(at point: SIMD2<Double>, within radius: Double) -> [Projection] {
        var best: [Int: Projection] = [:]
        for (lineIndex, segment) in grid.segments(near: point) {
            let line = lines[lineIndex]
            let a = line.points[segment], b = line.points[segment + 1]
            let d = b - a
            let lengthSquared = dot(d, d)
            guard lengthSquared > 0 else { continue }
            let t = max(0, min(1, dot(point - a, d) / lengthSquared))
            let distance = length(point - (a + t * d))
            guard distance <= radius, best[lineIndex].map({ distance < $0.distance }) ?? true else { continue }
            let segmentLength = lengthSquared.squareRoot()
            best[lineIndex] = Projection(
                line: lineIndex, distance: distance,
                along: line.cumulative[segment] + t * segmentLength, direction: d / segmentLength
            )
        }
        return best.values.sorted { $0.line < $1.line }
    }
}

// The `simd` module is Apple-only; these keep the package building on Linux.
private func dot(_ a: SIMD2<Double>, _ b: SIMD2<Double>) -> Double { a.x * b.x + a.y * b.y }
private func length(_ v: SIMD2<Double>) -> Double { (v.x * v.x + v.y * v.y).squareRoot() }
