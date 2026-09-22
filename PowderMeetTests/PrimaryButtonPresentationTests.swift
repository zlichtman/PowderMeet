import SwiftUI
import XCTest
@testable import PowderMeet

@MainActor
final class PrimaryButtonPresentationTests: XCTestCase {
    func testButtonDoesNotExpandToFillTallFormProposal() throws {
        let renderer = ImageRenderer(content:
            PrimaryButton(title: "CREATE ACCOUNT", action: {})
                .environment(\.dynamicTypeSize, .large)
        )
        renderer.proposedSize = ProposedViewSize(width: 350, height: 700)
        let image = try XCTUnwrap(renderer.uiImage)
        XCTAssertEqual(image.size.width, 350, accuracy: 0.5)
        XCTAssertGreaterThanOrEqual(image.size.height, 48)
        XCTAssertLessThan(image.size.height, 120,
                          "The button must be content-sized, not consume all remaining form height")
    }

    func testLargeTextKeepsPaddingAroundWrappedTitle() throws {
        let width: CGFloat = 240
        let title = "CREATE ACCOUNT"
        let label = ImageRenderer(content:
            Text(title).hudType(.bodyEmph).tracking(1.6)
                .frame(width: width - 32)
                .fixedSize(horizontal: false, vertical: true)
                .environment(\.dynamicTypeSize, .accessibility3)
        )
        let labelHeight = try XCTUnwrap(label.uiImage).size.height
        let renderer = ImageRenderer(content:
            PrimaryButton(title: title, action: {}).frame(width: width)
                .environment(\.dynamicTypeSize, .accessibility3)
        )
        let image = try XCTUnwrap(renderer.uiImage)
        XCTAssertGreaterThanOrEqual(image.size.height, labelHeight + 28 - 1,
                                   "Wrapped titles must retain 14pt top and bottom padding")
    }

    func testPrimaryButtonStatesRenderAtStandardAndAccessibilitySizes() async throws {
        for size in [DynamicTypeSize.large, .accessibility3] {
            let view = VStack(spacing: 16) {
                PrimaryButton(title: "CREATE ACCOUNT", action: {})
                PrimaryButton(title: "SEND RESET LINK", kind: .quiet, action: {})
                PrimaryButton(title: "GET STARTED", isEnabled: false, action: {})
                PrimaryButton(title: "CREATE ACCOUNT", isLoading: true, action: {})
            }
            .padding(20).frame(width: 350)
            .background(HUDTheme.mapBackground)
            .environment(\.dynamicTypeSize, size)
            .environment(\.colorScheme, .dark)
            // ProgressView contains UIKit-backed content that ImageRenderer
            // replaces with an unsupported-view placeholder. Host the real
            // hierarchy so loading-state attachments show the actual control.
            let host = UIHostingController(rootView: view.ignoresSafeArea())
            let fitting = host.sizeThatFits(in: CGSize(width: 350, height: 2000))
            let window = UIWindow(frame: CGRect(origin: .zero, size: fitting))
            window.rootViewController = host
            window.isHidden = false
            defer { window.isHidden = true }
            host.view.setNeedsLayout()
            host.view.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(100))
            let image = UIGraphicsImageRenderer(bounds: host.view.bounds).image { _ in
                host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
            }
            XCTAssertEqual(image.size.width, 350, accuracy: 0.5)
            XCTAssertGreaterThan(image.size.height, 250)
            let attachment = XCTAttachment(image: image)
            attachment.name = "primary-buttons-\(size)"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }
}
