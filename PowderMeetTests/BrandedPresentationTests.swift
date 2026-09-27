import SwiftUI
import XCTest
@testable import PowderMeet

@MainActor
final class BrandedPresentationTests: XCTestCase {
    func testAuthenticationAndResortPickerPresentation() async throws {
        let screens: [(String, AnyView)] = [
            ("auth", AnyView(AuthView().environment(SupabaseManager.shared))),
            ("appearance", AnyView(ThemePickerSheet())),
            ("resorts", AnyView(ResortPickerSheet(selectedEntry: .constant(nil))
                .environment(ResortDataManager())))
        ]
        for (name, screen) in screens {
            try await capture(name: name, view: screen, width: 390, height: 844)
        }
    }

    func testBrandedControlsAndHouseSkisAtReadableTextSizes() async throws {
        let loadedSki = await TopsheetCache.loadAsync("powdermeet-default")
        let ski = try XCTUnwrap(loadedSki)
        XCTAssertGreaterThan(ski.aspectRatio, 9, "The whole ski must retain its long product proportions")
        XCTAssertLessThan(ski.aspectRatio, 16)
        for size in [DynamicTypeSize.large, .accessibility3] {
            let view = ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("Mountain essentials").hudType(.title)
                    HUDDoneButton()
                    VStack(alignment: .leading, spacing: 16) {
                        Text("Your PowderMeet skis").hudType(.bodyEmph)
                        SkiPairView(topLabel: "Whistler Blackcomb", bottomLabel: "Tap to set location")
                        Text("Choose a trail or lift to preview your route.")
                            .hudType(.body).foregroundStyle(HUDTheme.textSecondary)
                    }
                    .padding(20).powderControl(cornerRadius: 10)
                    TextField("Search resorts", text: .constant(""))
                        .hudType(.body).padding(16).powderControl()
                    PrimaryButton(title: "Choose a mountain", action: {})
                    PrimaryButton(title: "View friends", kind: .quiet, action: {})
                    PrimaryButton(title: "Waiting for location", isEnabled: false, action: {})
                }
                .padding(20)
            }
            .background(HUDTheme.mapBackground)
            .environment(\.dynamicTypeSize, size)
            try await capture(name: "branded-surfaces-\(size)", view: AnyView(view), width: 390, height: 844)
        }
    }

    private func capture(name: String, view: AnyView, width: CGFloat, height: CGFloat) async throws {
        let host = UIHostingController(rootView: view.preferredColorScheme(.dark))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: width, height: height))
        window.rootViewController = host
        window.isHidden = false
        defer { window.isHidden = true }
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(350))
        let image = UIGraphicsImageRenderer(bounds: host.view.bounds).image { _ in
            host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
        }
        XCTAssertEqual(image.size.width, width, accuracy: 0.5)
        XCTAssertEqual(image.size.height, height, accuracy: 0.5)
        let attachment = XCTAttachment(image: image)
        attachment.name = "branded-\(name)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
