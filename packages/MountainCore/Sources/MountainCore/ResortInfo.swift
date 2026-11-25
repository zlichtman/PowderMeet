import Foundation

/// A catalog row: enough to list a resort and frame the map before its bundle loads.
public struct ResortInfo: Hashable, Sendable, Codable, Identifiable {
    public struct Camera: Hashable, Sendable, Codable {
        public var zoom: Double
        public var bearing: Double
        public var pitch: Double

        public init(zoom: Double, bearing: Double = 0, pitch: Double = 62) {
            self.zoom = zoom
            self.bearing = bearing
            self.pitch = pitch
        }
    }

    public var id: String
    public var name: String
    public var timezone: String
    public var bbox: BoundingBox
    public var camera: Camera?

    public init(
        id: String, name: String, timezone: String, bbox: BoundingBox, camera: Camera? = nil
    ) {
        self.id = id
        self.name = name
        self.timezone = timezone
        self.bbox = bbox
        self.camera = camera
    }

    public var center: Coordinate {
        Coordinate(lon: (bbox.minLon + bbox.maxLon) / 2, lat: (bbox.minLat + bbox.maxLat) / 2)
    }
}
