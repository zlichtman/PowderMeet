import MapboxMaps
import UIKit

/// People's photos for their markers on the map (owner, 21 Nov): small
/// circles ringed in the person's colour, friends in amber and you in blue,
/// over the disc that shows when there is no photo. Keyed by the user id's
/// string, or `me` for the signed-in skier.
public struct MapPhotos: Equatable {
    public static let me = "me"
    static let prefix = "avatar-"

    public var images: [String: UIImage]

    public init(_ images: [String: UIImage] = [:]) {
        self.images = images
    }

    public static func == (lhs: MapPhotos, rhs: MapPhotos) -> Bool {
        lhs.images.count == rhs.images.count
            && lhs.images.allSatisfy { key, image in rhs.images[key] === image }
    }

    /// Side of the drawn marker, in points.
    static let side: CGFloat = 30
    static let ring: CGFloat = 2.5

    /// The photo cut to a circle inside its coloured ring.
    static func marker(_ photo: UIImage, isMe: Bool) -> UIImage {
        let side = Self.side, ring = Self.ring
        let colour = isMe ? UIColor(hex: "3B82F6") : UIColor(hex: "F59E0B")
        return UIGraphicsImageRenderer(size: CGSize(width: side, height: side)).image { context in
            let cg = context.cgContext
            let outer = CGRect(x: 0, y: 0, width: side, height: side)
            cg.setFillColor(colour.cgColor)
            cg.fillEllipse(in: outer)
            let inner = outer.insetBy(dx: ring, dy: ring)
            cg.addEllipse(in: inner)
            cg.clip()
            // Aspect-fill the photo into the circle.
            let size = photo.size
            let scale = max(inner.width / max(size.width, 1), inner.height / max(size.height, 1))
            let drawn = CGSize(width: size.width * scale, height: size.height * scale)
            photo.draw(in: CGRect(
                x: inner.midX - drawn.width / 2, y: inner.midY - drawn.height / 2,
                width: drawn.width, height: drawn.height))
        }
    }
}
