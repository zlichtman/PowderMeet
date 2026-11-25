import QuartzCore
import UIKit

/// Falling snow over the map, drawn by Core Animation instead of the map.
///
/// The SDK's own snowfall made the 3D map redraw every frame while it fell,
/// terrain and all. Here the render server moves the flakes, so the map
/// stays idle and nothing runs per frame in the app. Flakes come in over the
/// top edge and fall down the screen, light enough never to hide the runs:
/// three layers stand for depth (far flakes small, slow and faint; near ones
/// bigger, quicker and brighter), and a field that starts is run ahead so it
/// opens as if it had been snowing rather than as a sheet coming down. The
/// layers are built once; a new hour only changes their rates and colour.
@MainActor
final class SnowField: UIView {
    private struct Depth {
        /// Flake width in points.
        let size: CGFloat
        /// Points a second.
        let speed: Float
        let opacity: Float
        /// Flakes alive in this layer at full density over a phone-sized view.
        let flakes: Float
    }

    private static let depths = [
        Depth(size: 2.5, speed: 40, opacity: 0.35, flakes: 60),
        Depth(size: 4, speed: 65, opacity: 0.55, flakes: 30),
        Depth(size: 6, speed: 100, opacity: 0.75, flakes: 10),
    ]
    /// The length the cells' own lifetimes are set for; each layer's
    /// `lifetime` stretches it to the view.
    private static let nominalTravel: Float = 1000
    private static let nominalWidth: CGFloat = 390
    /// Flakes are born this far above the top edge, so none pops into view.
    private static let topMargin: CGFloat = 12

    private let emitters: [CAEmitterLayer]
    private var fall: SnowFall?
    /// Whether flakes are on screen (falling, or thinning away).
    private var running = false
    private var clearTask: Task<Void, Never>?

    override init(frame: CGRect) {
        let flake = Self.flakeImage()
        emitters = Self.depths.map { depth in
            let cell = CAEmitterCell()
            cell.name = "flake"
            cell.contents = flake
            let lifetime = Self.nominalTravel / depth.speed
            cell.lifetime = lifetime
            cell.birthRate = depth.flakes / lifetime
            cell.velocity = CGFloat(depth.speed)
            cell.velocityRange = CGFloat(depth.speed) * 0.25
            cell.emissionRange = 0.06
            cell.scale = depth.size / 16
            cell.scaleRange = depth.size / 16 * 0.3
            let layer = CAEmitterLayer()
            layer.emitterShape = .line
            layer.emitterCells = [cell]
            layer.opacity = depth.opacity
            layer.birthRate = 0
            return layer
        }
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        isHidden = true
        autoresizingMask = [.flexibleWidth, .flexibleHeight]
        emitters.forEach { layer.addSublayer($0) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        place()
        CATransaction.commit()
    }

    /// Snow for an hour: eases to the new fall if it is already snowing,
    /// otherwise starts full and fades in.
    func show(_ new: SnowFall) {
        clearTask?.cancel()
        clearTask = nil
        guard new != fall || !running else { return }
        let starting = !running
        fall = new
        running = true
        isHidden = false
        CATransaction.begin()
        if starting {
            CATransaction.setDisableActions(true)
        } else {
            CATransaction.setAnimationDuration(WeatherEffect.fade)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeInEaseOut))
        }
        place()
        let colour = UIColor(red: new.colour.r, green: new.colour.g, blue: new.colour.b, alpha: 1).cgColor
        for (layer, depth) in zip(emitters, Self.depths) {
            layer.setValue(colour, forKeyPath: "emitterCells.flake.color")
            layer.opacity = depth.opacity * Float(new.opacity)
        }
        if starting {
            // Run the field ahead by its longest flake life, so it opens full.
            let now = layer.convertTime(CACurrentMediaTime(), from: nil)
            for emitter in emitters {
                emitter.beginTime = now - CFTimeInterval(Self.nominalTravel / Self.depths[0].speed * emitter.lifetime)
            }
        }
        CATransaction.commit()
        if starting {
            let fadeIn = CABasicAnimation(keyPath: "opacity")
            fadeIn.fromValue = 0
            fadeIn.toValue = 1
            fadeIn.duration = WeatherEffect.fade
            layer.add(fadeIn, forKey: "fadeIn")
        }
    }

    /// The snow stops: no more flakes are born, and the ones in the air fall
    /// out of the view before the field goes quiet.
    func clear() {
        guard running, clearTask == nil else { return }
        fall = nil
        CATransaction.begin()
        CATransaction.setAnimationDuration(WeatherEffect.fade)
        emitters.forEach { $0.birthRate = 0 }
        CATransaction.commit()
        let longest = emitters.map { Self.nominalTravel / Self.depths[0].speed * $0.lifetime }.max() ?? 0
        clearTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(Double(longest) + WeatherEffect.fade)) } catch { return }
            self?.stop()
        }
    }

    /// Gone at once: a panel over the map, Reduce Motion, the background.
    func stop() {
        clearTask?.cancel()
        clearTask = nil
        fall = nil
        running = false
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        emitters.forEach { $0.birthRate = 0 }
        CATransaction.commit()
        layer.removeAnimation(forKey: "fadeIn")
        isHidden = true
    }

    /// Lays each layer's birth line just above the top edge, reaching upwind
    /// by the slant, and sets its rates so the flakes in view keep the same
    /// density on any width and any slant.
    private func place() {
        let size = bounds.size
        guard size.width > 0, size.height > 0 else { return }
        let fall = fall ?? SnowFall(density: 0, scale: 1, speed: 1, slant: 0, opacity: 0, colour: .white)
        let slant = CGFloat(fall.slant) * .pi / 180
        let reach = (size.height + Self.topMargin) * tan(slant)
        let width = size.width + reach
        // Long enough for the slowest flake to reach the bottom edge.
        let travel = Float((size.height + Self.topMargin) / cos(slant)) * 1.35
        let crowd = Float(width / Self.nominalWidth)
        for emitter in emitters {
            emitter.frame = bounds
            emitter.emitterPosition = CGPoint(x: size.width / 2 - reach / 2, y: -Self.topMargin)
            emitter.emitterSize = CGSize(width: width, height: 0)
            // A line emitter's longitude is measured from the line's upward
            // normal, so π is straight down the screen (π / 2 would send the
            // flakes along the birth line, above the view); less than π leans
            // right, the way `reach` extends the line to the left to feed.
            emitter.setValue(CGFloat.pi - slant, forKeyPath: "emitterCells.flake.emissionLongitude")
            emitter.velocity = Float(fall.speed)
            emitter.scale = Float(fall.scale)
            emitter.lifetime = travel / Self.nominalTravel / Float(fall.speed)
            emitter.birthRate = Float(fall.density) * crowd / emitter.lifetime
        }
    }

    /// A soft round flake, 16 points across, drawn into an 8-bit sRGB bitmap
    /// of its own so the cell's contents never depend on the screen's format.
    private static func flakeImage() -> CGImage? {
        let side = 16
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let gradient = CGGradient(
                colorsSpace: space,
                colors: [
                    CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1),
                    CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.55),
                    CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0),
                ] as CFArray,
                locations: [0, 0.45, 1])
        else { return nil }
        let centre = CGPoint(x: CGFloat(side) / 2, y: CGFloat(side) / 2)
        context.drawRadialGradient(
            gradient, startCenter: centre, startRadius: 0, endCenter: centre, endRadius: CGFloat(side) / 2, options: [])
        return context.makeImage()
    }
}
