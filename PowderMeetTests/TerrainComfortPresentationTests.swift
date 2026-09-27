import SwiftUI
import XCTest
@testable import PowderMeet

@MainActor
final class TerrainComfortPresentationTests: XCTestCase {
    func testTerrainChoicesUseDeployedProfileColumns() {
        // Verified against the live profiles schema: continuous tolerance
        // columns are absent. A single absent column rejects the whole PATCH.
        XCTAssertEqual(TerrainComfortKind.moguls.profileColumn, "condition_moguls")
        XCTAssertEqual(TerrainComfortKind.ungroomed.profileColumn, "condition_ungroomed")
        XCTAssertEqual(TerrainComfortKind.glades.profileColumn, "condition_gladed")
    }

    func testTerrainControlFitsCompactAndLargeTextWidths() async throws {
        for width: CGFloat in [280, 350, 390] {
            for size in [DynamicTypeSize.large, .accessibility3] {
                let host = UIHostingController(rootView:
                    TerrainComfortPicker(values: [.moguls: 0, .ungroomed: 0.6, .glades: 1],
                                         onSelect: { _, _ in })
                        .environment(\.dynamicTypeSize, size)
                        .preferredColorScheme(.dark)
                        .ignoresSafeArea()
                )
                // Native segmented controls are UIKit-backed and cannot
                // be captured by SwiftUI ImageRenderer.
                let fitting = host.sizeThatFits(in: CGSize(width: width, height: 2000))
                let window = UIWindow(frame: CGRect(origin: .zero, size: fitting))
                window.rootViewController = host
                window.isHidden = false
                defer { window.isHidden = true }
                host.view.layoutIfNeeded()
                try await Task.sleep(for: .milliseconds(150))
                let image = UIGraphicsImageRenderer(bounds: host.view.bounds).image { _ in
                    host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
                }
                XCTAssertLessThanOrEqual(image.size.width, width + 0.5)
                XCTAssertGreaterThanOrEqual(image.size.height, 3 * 44)
                let attachment = XCTAttachment(image: image)
                attachment.name = "terrain-\(width)-\(size)"
                attachment.lifetime = .keepAlways
                add(attachment)
            }
        }
    }
}
