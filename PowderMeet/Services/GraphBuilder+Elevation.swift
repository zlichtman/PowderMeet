import CoreLocation

nonisolated extension GraphBuilder {
    /// Retain every finite source sample. Only gaps are interpolated between
    /// their nearest known anchors, along traveled distance rather than the
    /// density of geometry vertices. This does not invent trail connections.
    static func elevationProfile(
        geometry: [CLLocationCoordinate2D], raw: [Double?], from: Double, to: Double
    ) -> [Double] {
        guard !geometry.isEmpty else { return [] }
        var values: [Double?] = geometry.indices.map { index in
            guard raw.indices.contains(index), let value = raw[index], value.isFinite else { return nil }
            return value
        }
        values[0] = from
        values[values.count - 1] = to
        var distances = [0.0]
        for index in geometry.indices.dropFirst() {
            distances.append(distances[index - 1] + polylineLength([
                geometry[index - 1], geometry[index]
            ]))
        }
        var left = 0
        for right in values.indices.dropFirst() {
            guard let rightValue = values[right], let leftValue = values[left] else { continue }
            let span = distances[right] - distances[left]
            for index in (left + 1)..<right {
                let fraction = span > 0 ? (distances[index] - distances[left]) / span : 0
                values[index] = leftValue + (rightValue - leftValue) * fraction
            }
            left = right
        }
        return values.map { $0 ?? from }
    }

    static func profileMaximumGradient(
        geometry: [CLLocationCoordinate2D], elevations: [Double]
    ) -> Double {
        computeMaxGradient(zip(geometry, elevations).map { coordinate, elevation in
            Coordinate(lat: coordinate.latitude, lon: coordinate.longitude, ele: elevation)
        })
    }
}
