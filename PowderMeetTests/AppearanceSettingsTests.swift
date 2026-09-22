import XCTest
import SwiftUI
@testable import PowderMeet

final class AppearanceSettingsTests: XCTestCase {
    func testCustomPaletteRoundTrips() throws {
        let theme = CustomAppTheme()
        let decoded = try JSONDecoder().decode(CustomAppTheme.self, from: JSONEncoder().encode(theme))
        XCTAssertEqual(decoded, theme)
        XCTAssertTrue(theme.isValid)
        XCTAssertTrue(theme.hasReadableSurfaces)
    }

    func testInvalidNamesAndColorsAreRejected() {
        var theme = CustomAppTheme()
        theme.name = "  \n"
        XCTAssertFalse(theme.isValid)
        theme.name = "Winter"
        for invalid in ["FFF", "GGGGGG", "#123456", ""] {
            theme.accentHex = invalid
            XCTAssertFalse(theme.isValid)
        }
    }

    func testLightSurfacesCannotHideWhiteLabels() {
        var theme = CustomAppTheme()
        theme.backgroundHex = "FFFFFF"
        XCTAssertFalse(theme.hasReadableSurfaces)
        theme.backgroundHex = "101010"
        theme.surfaceHex = "EEEEEE"
        XCTAssertFalse(theme.hasReadableSurfaces)
    }

    @MainActor
    func testEightDistinctCoreIcons() {
        XCTAssertEqual(ThemeManager.coreIcons.count, 8)
        XCTAssertEqual(Set(ThemeManager.coreIcons).count, 8)
        XCTAssertEqual(ThemeManager.coreIcons,
                       [.original, .whiteout, .carbon, .infrared, .retro, .retroIce, .aurora, .auroraDawn],
                       "Original, the three flat colorways, the two tech marks, the two auroras")
        for theme: ThemeManager.Theme in [.original, .retro, .retroIce, .aurora, .auroraDawn] {
            XCTAssertTrue(ThemeManager.coreIcons.contains(theme))
        }
    }

    @MainActor
    func testAppearanceRendersAtCompactAndAccessibleSizes() async throws {
        for size in [DynamicTypeSize.large, .accessibility3] {
            let host = UIHostingController(rootView: ThemePickerSheet().environment(\.dynamicTypeSize, size))
            let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
            window.rootViewController = host
            window.isHidden = false
            defer { window.isHidden = true }
            host.view.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(250))
            let image = UIGraphicsImageRenderer(bounds: host.view.bounds).image { _ in
                host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
            }
            XCTAssertEqual(image.size.width, 390, accuracy: 0.5)
            let attachment = XCTAttachment(image: image)
            attachment.name = "appearance-\(size)"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }
}
