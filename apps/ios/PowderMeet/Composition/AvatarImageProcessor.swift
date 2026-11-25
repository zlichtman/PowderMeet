import CoreGraphics
import Foundation
import ImageIO
import PowderMeetAPI
import UniformTypeIdentifiers

/// Turns a picked or taken photo into the profile photo the app uploads: a
/// square crop, 512 × 512 px, JPEG. The pixels are drawn into a new bitmap and
/// encoded with no properties, so nothing of the original file's metadata
/// (location, camera, dates, faces) can reach the upload. Core Graphics and
/// Image I/O only, so it runs off the main actor.
nonisolated enum AvatarImageProcessor {
    /// The longest side the crop screen works on. A 48 MP photo is never
    /// decoded at full size.
    static let workingMaxPixel = 2_048
    static let quality = 0.82

    /// The photo upright (its orientation tag applied) and at most
    /// `workingMaxPixel` on its long side. Nil for bytes Image I/O cannot read.
    static func workingImage(from data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary)
        else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: workingMaxPixel,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// The square `crop` of `data`'s working image (pixels, origin top left),
    /// redrawn at `AvatarPath.pixelSize` and encoded as JPEG with no metadata.
    static func avatarJPEG(from data: Data, crop: CGRect) -> Data? {
        guard let image = workingImage(from: data) else { return nil }
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let square = crop.integral.intersection(bounds)
        guard !square.isEmpty, let cropped = image.cropping(to: square) else { return nil }

        let side = AvatarPath.pixelSize
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        context.interpolationQuality = .high
        context.draw(cropped, in: CGRect(x: 0, y: 0, width: side, height: side))
        guard let redrawn = context.makeImage() else { return nil }

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil)
        else { return nil }
        // Only the compression setting: no EXIF, TIFF, GPS or IPTC dictionaries.
        CGImageDestinationAddImage(
            destination, redrawn, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }

    /// The largest centred square of a `width` × `height` image.
    static func centredSquare(width: Int, height: Int) -> CGRect {
        let side = min(width, height)
        return CGRect(x: (width - side) / 2, y: (height - side) / 2, width: side, height: side)
    }
}
