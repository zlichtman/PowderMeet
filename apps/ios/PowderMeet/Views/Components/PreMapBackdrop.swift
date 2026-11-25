import SwiftUI

/// What sign-in and onboarding sit on (`specs/13-APP-MAP.md` section 0): no
/// mountain and no map, but red and black liquid moving slowly, a mesh gradient in the theme's background and accent whose
/// inner points drift past one another, with the faint 2D contour lines over
/// it. Still under Reduce Motion and in Low Power Mode. `RootView` holds one for
/// sign-in and onboarding together, so it does not restart between them.
struct PreMapBackdrop: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let still = reduceMotion || ProcessInfo.processInfo.isLowPowerModeEnabled
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: still)) { context in
            let t = still ? 0 : context.date.timeIntervalSinceReferenceDate
            ZStack {
                HUDTheme.mapBackground
                MeshGradient(width: 3, height: 3, points: Self.points(at: t), colors: colors)
                MountainLinesTexture(placement: .panel)
                    .opacity(0.16)
            }
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }

    /// Near-black with two slow pools of the accent: one low on the right,
    /// a dimmer one high on the left, meeting through the middle.
    private var colors: [Color] {
        let night = HUDTheme.mapBackground
        let glow = HUDTheme.accent.opacity(0.22)
        let ember = HUDTheme.accent.opacity(0.5)
        return [
            night, glow, night,
            glow, ember.opacity(0.7), night,
            night, glow, ember,
        ]
    }

    /// The nine control points. Corners stay put and edge points slide only
    /// along their edge, so the gradient always fills the screen; the centre
    /// wanders in both directions. Each point has its own pace, so the
    /// pattern never repeats in an obvious loop.
    private static func points(at t: Double) -> [SIMD2<Float>] {
        func wave(_ speed: Double, _ phase: Double, _ amount: Float) -> Float {
            amount * Float(sin(t * speed + phase))
        }
        return [
            SIMD2(0, 0), SIMD2(0.5 + wave(0.17, 0.0, 0.22), 0), SIMD2(1, 0),
            SIMD2(0, 0.5 + wave(0.13, 1.7, 0.2)),
            SIMD2(0.5 + wave(0.21, 2.4, 0.2), 0.5 + wave(0.16, 0.9, 0.2)),
            SIMD2(1, 0.5 + wave(0.11, 3.1, 0.22)),
            SIMD2(0, 1), SIMD2(0.5 + wave(0.19, 4.2, 0.24), 1), SIMD2(1, 1),
        ]
    }
}
