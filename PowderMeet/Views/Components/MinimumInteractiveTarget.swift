import SwiftUI

extension View {
    /// Keeps compact HUD chrome visually small while guaranteeing the whole
    /// surrounding surface is a reliable finger/glove target. Apply after the
    /// label's visual background/clip modifiers so those visuals do not grow.
    func minimumInteractiveTarget(_ size: CGFloat = 44) -> some View {
        frame(minWidth: size, minHeight: size)
            .contentShape(Rectangle())
    }
}
