//
//  SystemAppearance.swift
//  PowderMeet
//
//  The app paints itself dark through HUDTheme's explicit color tokens
//  AND forces `.preferredColorScheme(.dark)` on its views. A SwiftUI
//  scheme never reaches out-of-process system surfaces such as the Sign
//  in with Apple sheet, which renders the app icon in the presenting
//  window's interface style; only a real UIKit window override does.
//

import SwiftUI
import UIKit

/// Forces the hosting *window's* interface style. Used to pin the Auth
/// flow dark so the out-of-process Sign in with Apple sheet renders
/// the dark app-icon variant. `.unspecified` hands the window back to
/// the system everywhere else.
struct WindowOverrideStyle: UIViewRepresentable {
    let style: UIUserInterfaceStyle

    func makeUIView(context: Context) -> UIView {
        let v = UIView(frame: .zero)
        v.isHidden = true
        v.isUserInteractionEnabled = false
        return v
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        let style = style
        Task { @MainActor in
            uiView.window?.overrideUserInterfaceStyle = style
        }
    }
}

/// Dark status bar glyphs while `isDark` (the map in Whiteout, where light
/// glyphs would be white on white). The app's scheme is forced dark, so its own window's
/// status bar is always light, and since SDK 27 the app-wide style setter
/// does nothing; a clear, touch-through window above the app whose root asks
/// for dark content is the one supported way. It draws nothing, takes no
/// touches and has no accessibility elements; it is removed when not needed.
struct StatusBarDarkener: UIViewRepresentable {
    let isDark: Bool

    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        view.isHidden = true
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        let isDark = isDark
        let coordinator = context.coordinator
        Task { @MainActor in coordinator.set(isDark, scene: view.window?.windowScene) }
    }

    static func dismantleUIView(_ view: UIView, coordinator: Coordinator) {
        coordinator.set(false, scene: nil)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor
    final class Coordinator {
        private var window: UIWindow?

        func set(_ dark: Bool, scene: UIWindowScene?) {
            guard dark, let scene else {
                window?.isHidden = true
                window = nil
                return
            }
            guard window == nil else { return }
            let overlay = PassThroughWindow(windowScene: scene)
            overlay.windowLevel = .normal + 1
            overlay.backgroundColor = .clear
            overlay.rootViewController = DarkStatusBarController()
            overlay.isHidden = false
            window = overlay
        }
    }

    private final class PassThroughWindow: UIWindow {
        override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? { nil }
    }

    private final class DarkStatusBarController: UIViewController {
        override var preferredStatusBarStyle: UIStatusBarStyle { .darkContent }

        override func viewDidLoad() {
            super.viewDidLoad()
            view.backgroundColor = .clear
            view.isUserInteractionEnabled = false
            view.accessibilityElementsHidden = true
        }
    }
}
