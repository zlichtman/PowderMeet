/// Polyline segments bucketed in square cells, each segment in every cell
/// its bounding box (grown by the search radius) touches, so one cell lookup
/// finds every segment within the radius of a point. `TrailMatcher` builds
/// one per descent; `PlaceLocator` builds one per bundle.
struct SegmentGrid: Sendable {
    private let cell: Double
    private var buckets: [SIMD2<Int>: [(line: Int, segment: Int)]] = [:]

    init(lines: [[SIMD2<Double>]], radius: Double) {
        cell = max(radius, 25)
        for (lineIndex, vertices) in lines.enumerated() {
            for s in 0..<(vertices.count - 1) {
                let low = pointwiseMin(vertices[s], vertices[s + 1]) - SIMD2(repeating: radius)
                let high = pointwiseMax(vertices[s], vertices[s + 1]) + SIMD2(repeating: radius)
                let a = key(low), b = key(high)
                for x in a.x...b.x {
                    for y in a.y...b.y { buckets[SIMD2(x, y), default: []].append((lineIndex, s)) }
                }
            }
        }
    }

    private func key(_ p: SIMD2<Double>) -> SIMD2<Int> {
        SIMD2(Int((p.x / cell).rounded(.down)), Int((p.y / cell).rounded(.down)))
    }

    func segments(near point: SIMD2<Double>) -> [(line: Int, segment: Int)] {
        buckets[key(point)] ?? []
    }
}
