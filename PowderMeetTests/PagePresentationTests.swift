import SwiftUI
import XCTest
@testable import PowderMeet

@MainActor
final class PagePresentationTests: XCTestCase {
    func testBrandedControlsFitAndCaptureAccessibilityLayout() async throws {
        for size in [DynamicTypeSize.large, .accessibility3] {
                let view = VStack(spacing: PowderLayout.sectionSpacing) {
                    HUDDoneButton()
                    PrimaryButton(title: "Choose destination", action: {})
                }
                .padding(PowderLayout.pageInset)
                .background(HUDTheme.mapBackground)
                .environment(\.dynamicTypeSize, size)
                .preferredColorScheme(.dark)
                // This is a component-sized window, not a full phone screen;
                // don't let simulated status-bar insets clip the snapshot.
                let host = UIHostingController(rootView: view.ignoresSafeArea())
                let fitting = host.sizeThatFits(in: CGSize(width: 320, height: 1200))
                XCTAssertLessThanOrEqual(fitting.width, 320.5)
                XCTAssertGreaterThanOrEqual(fitting.height, 100)
                let window = UIWindow(frame: CGRect(origin: .zero, size: fitting))
                window.rootViewController = host
                window.isHidden = false
                defer { window.isHidden = true }
                host.view.layoutIfNeeded()
                try await Task.sleep(for: .milliseconds(200))
                let image = UIGraphicsImageRenderer(bounds: host.view.bounds).image { _ in
                    host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
                }
                let attachment = XCTAttachment(image: image)
                attachment.name = "page-controls-\(size)"
                attachment.lifetime = .keepAlways
                add(attachment)
        }
    }
}
