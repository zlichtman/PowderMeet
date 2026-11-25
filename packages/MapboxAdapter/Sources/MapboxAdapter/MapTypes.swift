import Foundation
import MapScene
import MountainCore

/// What the app may ask of the map. Everything the map shows comes from a
/// `RenderModel`; commands are only for the camera and for housekeeping.
public enum MapCommand: Sendable, Hashable {
    /// Return to the resort's landing pose. The intro plays by itself whenever a new
    /// bundle arrives, so this is for a "whole mountain" button.
    case showResort
    /// The explicit "show route on map": frame the routes and meeting point in the
    /// current model and replay the draw-on reveal. Accepting a meet never does this.
    /// Like `showResort`, it ends following.
    case showRoute
    /// Keep the camera on the user's position (navigation). A pan or pinch turns it
    /// off; `MapEvent.followingChanged` reports that.
    case follow(Bool)
    /// One move to the user's position, or to the resort when there is none.
    case recenter
    /// One move to a place that is not the user (a friend, a meeting point).
    /// Following stops, or the next fix would pull the camera straight back.
    case focus(Coordinate)
    case resetNorth
    /// Try the style again after `MapEvent.styleFailed`.
    case reloadStyle
    /// While on, every tap reports `MapEvent.tappedMap` with the point under the
    /// finger, whatever it lands on: developer testing places skiers on runs
    /// and lifts, which would otherwise be selections. A new map starts off.
    case captureTaps(Bool)
}

/// The strips of the map the app's floating controls cover, in the map view's own
/// points from its top and bottom edges (the map runs under the bars, so these
/// include them). The camera keeps what it frames inside the rest. The Mapbox
/// logo and attribution button, which must stay visible, sit side by side,
/// centred under the app's bottom row, their lower edge `badgeBottom` from the
/// map's bottom edge (`MapAttribution`).
public struct MapObscuredArea: Sendable, Hashable {
    public var top: Double
    public var bottom: Double
    public var badgeBottom: Double

    public init(top: Double = 0, bottom: Double = 0, badgeBottom: Double = 16) {
        self.top = top
        self.bottom = bottom
        self.badgeBottom = badgeBottom
    }

    /// The row the Mapbox logo and ⓘ are centred in.
    public static let badgeHeight = 30.0
}

public struct MapCameraSnapshot: Sendable, Hashable {
    public var center: Coordinate
    public var zoom: Double
    /// Degrees clockwise from north.
    public var bearing: Double
    public var pitch: Double
}

/// How long a map's first load took, in milliseconds from the map's creation.
public struct MapLoadTiming: Sendable, Hashable {
    public var styleMS: Int
    /// Nil when no terrain tile arrived before the map went idle (offline, no cache).
    public var firstTerrainMS: Int?
    public var tilesLoadedMS: Int?
    public var idleMS: Int
    /// Tiles fetched for the first view, by where they came from.
    public var networkTiles: Int
    public var cachedTiles: Int
    public var networkBytes: Int
    /// Everything else fetched for the first view: style, sprite, glyphs,
    /// TileJSON, models.
    public var otherNetworkBytes: Int = 0
    public var otherNetworkRequests: Int = 0

    public var summary: String {
        func ms(_ value: Int?) -> String { value.map { "\($0) ms" } ?? "never" }
        return "style \(styleMS) ms, first terrain \(ms(firstTerrainMS)), tiles \(ms(tilesLoadedMS)), "
            + "idle \(idleMS) ms, \(networkTiles) tiles from network (\(networkBytes / 1_024) kB), "
            + "\(cachedTiles) from cache, \(otherNetworkRequests) other requests "
            + "(\(otherNetworkBytes / 1_024) kB)"
    }
}

public enum MapEvent: Sendable, Hashable {
    /// Sources and layers are installed and the latest model is on screen.
    case styleLoaded
    /// The first view has finished loading and the map is at rest. Sent once per
    /// map; background work that competes for tiles waits for it.
    case firstLoad(MapLoadTiming)
    /// The base style could not be loaded after the automatic retries. The
    /// app's own layers then draw on a plain ground (`styleLoaded` follows)
    /// until `MapCommand.reloadStyle` succeeds.
    case styleFailed
    /// A trail or lift line was tapped.
    case tappedGroup(GroupID)
    case tappedRendezvous(RendezvousID)
    case tappedFriend(UUID)
    /// A tap that hit nothing: dismiss the open card.
    case tappedMap(Coordinate)
    /// The user took the camera with a gesture.
    case userMovedCamera
    case followingChanged(Bool)
    /// The camera came to rest.
    case cameraIdle(MapCameraSnapshot)
}
