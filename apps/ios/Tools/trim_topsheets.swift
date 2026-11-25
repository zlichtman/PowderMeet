import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// Trims each topsheet PNG to its alpha bounding box (in place) and prints
// "<key> <accent hex> <w>x<h>": the accent is the mean of the dominant
// saturated hue, for the optional theme link.
let root = URL(fileURLWithPath: CommandLine.arguments[1])
let sets = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
    .filter { $0.pathExtension == "imageset" }.sorted { $0.path < $1.path }
for set in sets {
    let key = set.deletingPathExtension().lastPathComponent
    let png = set.appendingPathComponent("\(key).png")
    guard let source = CGImageSourceCreateWithURL(png as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { print("\(key) UNREADABLE"); continue }
    let w = image.width, h = image.height
    var px = [UInt8](repeating: 0, count: w * h * 4)
    let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
    var minX = w, minY = h, maxX = -1, maxY = -1
    var bins = [(weight: Double, r: Double, g: Double, b: Double)](repeating: (0, 0, 0, 0), count: 24)
    for y in 0..<h { for x in 0..<w {
        let i = (y * w + x) * 4
        let a = px[i + 3]
        guard a > 16 else { continue }
        minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
        guard a > 200 else { continue }
        let r = Double(px[i]) / Double(a), g = Double(px[i + 1]) / Double(a), b = Double(px[i + 2]) / Double(a)
        let hi = max(r, g, b), lo = min(r, g, b), span = hi - lo
        guard span > 0.25, hi > 0.3 else { continue }
        var hue = hi == r ? (g - b) / span : hi == g ? 2 + (b - r) / span : 4 + (r - g) / span
        if hue < 0 { hue += 6 }
        let bin = min(23, Int(hue * 4))
        let weight = span * hi
        bins[bin].weight += weight; bins[bin].r += r * weight; bins[bin].g += g * weight; bins[bin].b += b * weight
    } }
    guard maxX >= minX else { print("\(key) EMPTY"); continue }
    var accent = "-"
    if let top = bins.max(by: { $0.weight < $1.weight }), top.weight > Double(w * h) * 0.002 {
        accent = String(format: "%02X%02X%02X", Int(top.r / top.weight * 255), Int(top.g / top.weight * 255), Int(top.b / top.weight * 255))
    }
    let box = CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    if Int(box.width) != w || Int(box.height) != h, let cropped = image.cropping(to: box),
       let dest = CGImageDestinationCreateWithURL(png as CFURL, UTType.png.identifier as CFString, 1, nil) {
        CGImageDestinationAddImage(dest, cropped, nil)
        CGImageDestinationFinalize(dest)
    }
    print("\(key) \(accent) \(Int(box.width))x\(Int(box.height))")
}
