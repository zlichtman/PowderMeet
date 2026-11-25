@preconcurrency import MapboxMaps
import UIKit

/// The Mapbox logo with the ⓘ beside it, as one pair centred at the bottom
/// of the map under the app's bottom row (owner, 21 Nov: centred, so the
/// screen's rounded corners never cut it off). Both are Mapbox's own views,
/// unstyled and working, as their terms require ("You may not style the
/// Mapbox logo"): no tint, opacity or backing on the logo, and the ⓘ opens
/// their attribution.
///
/// The SDK has no bottom-centre position, and it stacks two ornaments that
/// share a corner one above the other, so the logo is pinned bottom-left and
/// the button bottom-right, each margin worked out so the pair is centred.
/// Both are measured from the same safe area, and placed again from the
/// button's real glyph after layout.
@MainActor
final class MapAttribution {
    private unowned let mapView: MapView
    private let sentinel = LayoutSentinel()
    /// The pair's lower edge, from the map view's bottom edge.
    private var bottom = 16.0
    private var isPlacing = false

    private static let height = MapObscuredArea.badgeHeight
    private static let gap = 6.0
    private static let logoSize = CGSize(width: 85, height: 21)

    init(mapView: MapView) {
        self.mapView = mapView
        let ornaments: OrnamentsManager = mapView.ornaments
        ornaments.options.logo.position = .bottomLeft
        ornaments.options.attributionButton.position = .bottomRight
        // Size, safe area or the window changing all move the pair.
        sentinel.isUserInteractionEnabled = false
        sentinel.frame = mapView.bounds
        sentinel.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        sentinel.onLayout = { [weak self] in self?.place() }
        mapView.insertSubview(sentinel, at: 0)
    }

    /// Where the app's bottom row leaves room for the pair.
    func setBottom(_ new: Double) {
        guard new != bottom else { return }
        bottom = new
        place()
    }

    /// Debug stills only (`-demoCapture`): the website carries the credit
    /// as text beside the image, as Mapbox allows for static images.
    /// Taken out of the picture only: the SDK's own visibility switch is
    /// restricted, and its layout resets `isHidden`.
    func setHidden(_ hidden: Bool) {
        let alpha: CGFloat = hidden ? 0 : 1
        mapView.ornaments.logoView.alpha = alpha
        mapView.ornaments.attributionButton.alpha = alpha
    }

    // MARK: Layout

    private func place() {
        guard !isPlacing, mapView.bounds.width > 0 else { return }
        isPlacing = true
        defer { isPlacing = false }
        let ornaments: OrnamentsManager = mapView.ornaments
        let insets = safeInsets()
        let width = Double(mapView.bounds.width)
        // Bottom margins are measured up from the safe area's lower edge.
        let safeBottom = Double(mapView.bounds.height) - insets.bottom
        let top = Double(mapView.bounds.height) - bottom - Self.height
        let box = ornaments.attributionButton
        let glyph = glyphRect(in: box)
        let pair = Self.logoSize.width + Self.gap + glyph.width
        let left = (width - pair) / 2
        let logo = CGPoint(
            x: left - insets.left,
            y: safeBottom - (top + (Self.height + Self.logoSize.height) / 2))
        if ornaments.options.logo.margins != logo { ornaments.options.logo.margins = logo }

        // The ⓘ glyph sits at the bottom centre of its 44 pt tap box.
        let glyphLeft = left + Self.logoSize.width + Self.gap
        let glyphTop = top + (Self.height - glyph.height) / 2
        let boxWidth = Double(box.bounds.width > 0 ? box.bounds.width : 44)
        let boxHeight = Double(box.bounds.height > 0 ? box.bounds.height : 44)
        let button = CGPoint(
            x: width - insets.right - (glyphLeft - glyph.minX + boxWidth),
            y: safeBottom - (glyphTop - glyph.minY + boxHeight))
        if ornaments.options.attributionButton.margins != button {
            ornaments.options.attributionButton.margins = button
        }
    }

    /// The ⓘ's drawn glyph inside the attribution button's box.
    private func glyphRect(in box: UIView) -> CGRect {
        if let button = box.subviews.compactMap({ $0 as? UIButton }).first {
            button.layoutIfNeeded()
            if let image = button.imageView, image.bounds.width > 0 {
                return image.convert(image.bounds, to: box)
            }
        }
        let side = 22.0
        let width = box.bounds.width > 0 ? Double(box.bounds.width) : 44
        let height = box.bounds.height > 0 ? Double(box.bounds.height) : 44
        return CGRect(x: (width - side) / 2, y: height - side, width: side, height: side)
    }

    /// Before its first layout the map has no safe area, though the margins
    /// will be measured from it: the window's stands in.
    private func safeInsets() -> (left: Double, right: Double, bottom: Double) {
        var insets = mapView.safeAreaInsets
        if insets == .zero {
            insets = mapView.window?.safeAreaInsets
                ?? UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }
                .first?.safeAreaInsets ?? .zero
        }
        return (Double(insets.left), Double(insets.right), Double(insets.bottom))
    }
}

/// Calls back whenever the map view's size or safe area changes.
private final class LayoutSentinel: UIView {
    var onLayout: (() -> Void)?

    override func layoutSubviews() {
        super.layoutSubviews()
        onLayout?()
    }

    override func safeAreaInsetsDidChange() {
        super.safeAreaInsetsDidChange()
        setNeedsLayout()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        setNeedsLayout()
    }
}
