//
//  SystemAppearance.swift
//  PowderMeet
//
//  The app paints itself dark through HUDTheme's explicit color
//  tokens AND forces `.preferredColorScheme(.dark)` on its views, so
//  the SwiftUI environment colorScheme is always `.dark` and can't
//  tell you what the device's actual Light/Dark (Control Center)
//  setting is. Two places genuinely need the *real* system setting:
//
//   • the theme gallery, which previews each app-icon variant exactly
//     as it would look on the home screen for the current setting, and
//   • the Sign in with Apple sheet, an out-of-process system surface
//     that renders the primary app icon in the presenting window's
//     interface style (a SwiftUI `.preferredColorScheme` does NOT
//     reach it — only a real UIKit window override does).
//
//  `.preferredColorScheme` / `overrideUserInterfaceStyle` are window-
//  and view-controller-level and flow *downward*; they never change
//  the enclosing UIWindowScene's trait collection. So the scene is the
//  one vantage point that still reports the genuine Control-Center
//  setting and emits a change when the user flips it while the app is
//  foregrounded. (The app-level Info.plist `UIUserInterfaceStyle` key
//  *would* mask even the scene — which is exactly why it was removed.)
//

import SwiftUI
import UIKit

/// Observable mirror of the device's real Light/Dark setting, kept in
/// sync by `SceneAppearanceObserver`. Read `colorScheme` from a view
/// body and it re-renders when the user toggles appearance.
@MainActor
@Observable
final class SystemAppearance {
    static let shared = SystemAppearance()

    var style: UIUserInterfaceStyle = UITraitCollection.current.userInterfaceStyle

    var colorScheme: ColorScheme { style == .dark ? .dark : .light }

    private init() {}
}

/// Zero-size bridge that latches onto its `UIWindowScene` and pushes
/// the genuine system interface style into `SystemAppearance`, both
/// once on appear and live whenever it changes. Drop it anywhere in a
/// view that's on screen when the value matters (the theme gallery).
struct SceneAppearanceObserver: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView {
        let v = UIView(frame: .zero)
        v.isHidden = true
        v.isUserInteractionEnabled = false
        return v
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        guard let scene = uiView.window?.windowScene else { return }
        let style = scene.traitCollection.userInterfaceStyle
        Task { @MainActor in SystemAppearance.shared.style = style }

        guard !context.coordinator.registered else { return }
        context.coordinator.registered = true
        scene.registerForTraitChanges(
            [UITraitUserInterfaceStyle.self]
        ) { (scene: UIWindowScene, _: UITraitCollection) in
            let s = scene.traitCollection.userInterfaceStyle
            Task { @MainActor in SystemAppearance.shared.style = s }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator { var registered = false }
}

/// Forces the hosting *window's* interface style. Used to pin the Auth
/// flow dark so the out-of-process Sign in with Apple sheet renders
/// the dark app-icon variant — a scoped replacement for the old
/// app-wide Info.plist `UIUserInterfaceStyle = Dark`, which also
/// blinded `SceneAppearanceObserver`. `.unspecified` hands the window
/// back to the system everywhere else.
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
        DispatchQueue.main.async {
            uiView.window?.overrideUserInterfaceStyle = style
        }
    }
}
