import SwiftUI

/// Original PowderMeet control styling: matte panels, crisp borders and
/// compact corners. One shared implementation prevents system glass from
/// mixing with the branded HUD on newer iOS versions.
struct PowderControlSurface: ViewModifier {
    var tint: Color? = nil
    var cornerRadius: CGFloat = 10

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: min(cornerRadius, 12), style: .continuous)
        content
            .background(tint ?? HUDTheme.inputBackground, in: shape)
            .overlay(shape.strokeBorder(tint == nil ? HUDTheme.cardBorder : Color.white.opacity(0.10), lineWidth: 0.75))
    }
}

extension View {
    func powderControl(tint: Color? = nil, cornerRadius: CGFloat = 10,
                       interactive: Bool = true) -> some View {
        modifier(PowderControlSurface(tint: tint, cornerRadius: cornerRadius))
    }
}
