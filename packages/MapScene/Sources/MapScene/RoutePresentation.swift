import Foundation
import MeetSolver
import MountainCore

/// The part of a route still ahead. During a meet the map is an instruction
/// surface, not a breadcrumb: finished legs are dropped and the current edge is
/// clipped to where the skier is.
public struct RemainingRoute: Sendable, Hashable {
    public var edgeIDs: [EdgeID]
    /// Share of the first remaining edge already behind the skier.
    public var initialEdgeFraction: Double

    public init(edgeIDs: [EdgeID], initialEdgeFraction: Double) {
        self.edgeIDs = edgeIDs
        self.initialEdgeFraction = initialEdgeFraction
    }

    public static let none = RemainingRoute(edgeIDs: [], initialEdgeFraction: 0)

    public static func remaining(
        of route: Route, legIndex: Int, fractionAlongLeg: Double
    ) -> RemainingRoute {
        let index = min(max(0, legIndex), route.legs.count)
        guard index < route.legs.count else { return .none }
        // A route that began part-way along an edge never draws back to its top.
        let started = index == 0 ? route.legs[0].startFraction : 0
        let fraction = max(started, fractionAlongLeg.isFinite ? fractionAlongLeg : 0)
        return RemainingRoute(
            edgeIDs: route.legs[index...].map(\.edgeID),
            initialEdgeFraction: max(0, min(1, fraction))
        )
    }

    /// The line to draw: first edge clipped, the rest joined. Trail stretches are
    /// smoothed; lift stretches stay straight between towers, as the lift itself
    /// is drawn, so the route lies on the lift line. Empty when the bundle does
    /// not hold every edge.
    public func coordinates(in bundle: ResortBundle) -> [Coordinate] {
        let traversals = edgeIDs.compactMap(bundle.graph.edge)
        guard !traversals.isEmpty, traversals.count == edgeIDs.count else { return [] }
        var stretches: [(isLift: Bool, line: [Coordinate])] = []
        for (index, edge) in traversals.enumerated() {
            let coordinates = index == 0
                ? Polyline.trimPolylineStart(edge.coordinates, fraction: initialEdgeFraction)
                : edge.coordinates
            let isLift = edge.kind == .lift
            if let last = stretches.last, last.isLift == isLift {
                stretches[stretches.count - 1].line = Self.joined(last.line, coordinates)
            } else {
                stretches.append((isLift, coordinates))
            }
        }
        // Smoothing keeps each stretch's ends, so the stretches still meet.
        return stretches.reduce(into: []) { line, stretch in
            line = Self.joined(line, stretch.isLift ? stretch.line : Polyline.chaikinSmooth(stretch.line))
        }
    }

    private static func joined(_ line: [Coordinate], _ next: [Coordinate]) -> [Coordinate] {
        if let last = line.last, let first = next.first, Polyline.coincide(last, first) {
            return line + next.dropFirst()
        }
        return line + next
    }
}

/// The draw-on reveal is for a new plan. Losing a finished prefix is ordinary
/// progress and must not redraw the whole remainder.
public enum MapRouteAnimationPolicy {
    public static func shouldReplay(
        previousA: [EdgeID], previousB: [EdgeID], nextA: [EdgeID], nextB: [EdgeID], forced: Bool
    ) -> Bool {
        if forced { return !nextA.isEmpty || !nextB.isEmpty }
        let changedA = previousA != nextA
        let changedB = previousB != nextB
        guard changedA || changedB else { return false }
        guard !nextA.isEmpty || !nextB.isEmpty else { return false }

        func isCompletedPrefixRemoval(_ previous: [EdgeID], _ next: [EdgeID]) -> Bool {
            guard next.count < previous.count else { return false }
            if next.isEmpty { return !previous.isEmpty }
            return Array(previous.suffix(next.count)) == next
        }
        let aIsProgress = !changedA || isCompletedPrefixRemoval(previousA, nextA)
        let bIsProgress = !changedB || isCompletedPrefixRemoval(previousB, nextB)
        return !(aIsProgress && bIsProgress)
    }
}

/// Camera input for an explicit "show route on map". Only geometry inside the
/// resort is admitted, so a route left over from another resort cannot send the
/// camera somewhere empty. Accepting a meet never frames anything.
public enum RoutePreviewFraming {
    public static func coordinates(
        routes: [[EdgeID]], meeting: RendezvousID?, in bundle: ResortBundle,
        maximumCount: Int = 64
    ) -> [Coordinate] {
        let bounds = bundle.bbox
        let latPadding = max(0.002, (bounds.maxLat - bounds.minLat) * 0.15)
        let lonPadding = max(0.002, (bounds.maxLon - bounds.minLon) * 0.15)
        func admits(_ c: Coordinate) -> Bool {
            c.isValid
                && c.lat >= bounds.minLat - latPadding && c.lat <= bounds.maxLat + latPadding
                && c.lon >= bounds.minLon - lonPadding && c.lon <= bounds.maxLon + lonPadding
        }

        struct Key: Hashable { let lat: Int, lon: Int }
        var seen: Set<Key> = []
        var collected: [Coordinate] = []
        func append(_ c: Coordinate) {
            guard admits(c) else { return }
            let key = Key(
                lat: Int((c.lat * 10_000_000).rounded()), lon: Int((c.lon * 10_000_000).rounded()))
            if seen.insert(key).inserted { collected.append(c) }
        }

        for route in routes {
            for id in route {
                bundle.graph.edge(id)?.coordinates.forEach(append)
            }
        }
        if let meeting, let point = bundle.rendezvous(meeting),
           let node = bundle.graph.nodes[point.nodeID] {
            append(node.coordinate)
        }

        let limit = max(2, maximumCount)
        guard collected.count > limit else { return collected }
        let step = Double(collected.count - 1) / Double(limit - 1)
        return (0..<limit).map { collected[Int((Double($0) * step).rounded())] }
    }
}

/// Where the camera lands for a resort, and how far it may roam.
public struct SceneFrame: Sendable, Hashable {
    public var bounds: BoundingBox
    public var center: Coordinate
    public var zoom: Double
    public var bearing: Double
    public var pitch: Double

    public init(bounds: BoundingBox, center: Coordinate, zoom: Double, bearing: Double, pitch: Double) {
        self.bounds = bounds
        self.center = center
        self.zoom = zoom
        self.bearing = bearing
        self.pitch = pitch
    }

    /// The landing pose for a bundle. A catalog camera override, when the resort
    /// has one, replaces zoom, bearing and pitch.
    public init(bundle: ResortBundle, camera: ResortInfo.Camera? = nil) {
        self.init(
            bounds: bundle.bbox, center: bundle.center,
            zoom: camera?.zoom ?? Self.defaultZoom(for: bundle.bbox),
            bearing: camera?.bearing ?? 0, pitch: camera?.pitch ?? 62
        )
    }

    /// Whole-resort zoom from the bounding box span.
    public static func defaultZoom(for bounds: BoundingBox) -> Double {
        let span = max(bounds.maxLat - bounds.minLat, bounds.maxLon - bounds.minLon)
        if span > 0.12 { return 11.5 }
        if span > 0.08 { return 12.5 }
        if span > 0.05 { return 13.0 }
        return 13.5
    }
}

/// Sun position from an absolute instant and the mountain's own coordinates; the
/// device time zone is never read (invariant I-06). `MeetSolver.SunExposure` holds
/// the same arithmetic but is internal to that package.
public enum Solar {
    public static func position(at date: Date, latitude: Double, longitude: Double)
        -> (altitudeDeg: Double, azimuthDeg: Double)
    {
        let seconds = date.timeIntervalSinceReferenceDate
        let dayIndex = (seconds / 86_400).rounded(.down)
        let utcHour = (seconds - dayIndex * 86_400) / 3_600
        // Day of year, to the accuracy a light direction needs.
        let dayOfYear = (dayIndex.truncatingRemainder(dividingBy: 365.2425) + 365.2425)
            .truncatingRemainder(dividingBy: 365.2425) + 1

        let declination = 23.45 * sin((360.0 / 365.0 * (284 + dayOfYear)) * .pi / 180)
        let b = (360.0 / 365.0 * (dayOfYear - 81)) * .pi / 180
        let equationOfTimeMinutes = 9.87 * sin(2 * b) - 7.53 * cos(b) - 1.5 * sin(b)
        let solarNoonUTC = 12.0 - longitude / 15.0 - equationOfTimeMinutes / 60.0
        let hourAngle = (utcHour - solarNoonUTC) * 15.0 * .pi / 180

        let lat = latitude * .pi / 180
        let dec = declination * .pi / 180
        let sinAltitude = sin(lat) * sin(dec) + cos(lat) * cos(dec) * cos(hourAngle)
        let altitude = asin(max(-1, min(1, sinAltitude))) * 180 / .pi
        let azimuth = (atan2(sin(hourAngle), cos(hourAngle) * sin(lat) - tan(dec) * cos(lat))
            * 180 / .pi + 180).truncatingRemainder(dividingBy: 360)
        return (altitude, azimuth)
    }
}
