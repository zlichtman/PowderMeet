import SwiftUI

/// Two horizontal skis stacked, each carrying one label (name over skill on a
/// friend row), or none on the profile's strip. The skis are drawn
/// as `look` says: a catalog topsheet (the brand's or the drawn one) or the
/// PowderMeet ski.
struct SkiPairView: View {
    let topLabel: String
    let bottomLabel: String
    var highlight: Highlight = .none
    var look: SkiLook = .house

    nonisolated enum Highlight {
        case none
        case onMountain
        case offMountain
    }

    private let skiHeight: CGFloat = 36
    private let spacing: CGFloat = 8

    /// Lets callers size an avatar beside the pair so the two read as one unit.
    static let defaultPairHeight: CGFloat = 36 * 2 + 8

    var body: some View {
        VStack(spacing: spacing) {
            LabelledSki(label: topLabel, weight: .bold, height: skiHeight, highlight: highlight, look: look)
            LabelledSki(label: bottomLabel, weight: .medium, height: skiHeight, highlight: highlight, look: look)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct LabelledSki: View {
    let label: String
    let weight: Font.Weight
    let height: CGFloat
    let highlight: SkiPairView.Highlight
    let look: SkiLook

    var body: some View {
        ZStack {
            // The label below names the row, so a drawn topsheet leaves out
            // the model's name.
            SkiBody(look: look, showsName: false)
                .skiGlow(highlight)

            // White with a 1px black outline so the label reads on any topsheet
            // and any theme.
            Text(label)
                .font(.footnote.weight(weight))
                .foregroundColor(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.55)
                .shadow(color: .black, radius: 0, x: 1, y: 0)
                .shadow(color: .black, radius: 0, x: -1, y: 0)
                .shadow(color: .black, radius: 0, x: 0, y: 1)
                .shadow(color: .black, radius: 0, x: 0, y: -1)
                .padding(.horizontal, height * 0.9)
        }
        .frame(maxWidth: .infinity)
        .frame(height: height)
    }
}

/// One ski, tip to the left, fitted into whatever frame it is given. The
/// topsheet images are trimmed to the ski when they are imported, so the
/// image's own shape is the ski's. A catalog ski whose image is switched off
/// or missing is drawn instead (`DrawnTopsheet`).
struct SkiBody: View {
    let look: SkiLook
    /// Whether a drawn topsheet carries the model's name (and reads it to
    /// VoiceOver); off where the caller labels the ski itself.
    var showsName = true

    var body: some View {
        switch look {
        case .house:
            photo("powdermeet-default")
        case .topsheet(let key):
            if SkiCatalog.hasArtwork(key: key) {
                photo(key)
            } else if let model = SkiCatalog.model(key: key) {
                DrawnTopsheet(model: model, showsName: showsName)
            } else {
                photo("powdermeet-default")
            }
        }
    }

    private func photo(_ name: String) -> some View {
        Image(name)
            .resizable()
            .interpolation(.high)
            .scaledToFit()
    }
}

/// A catalog ski drawn without any brand artwork: the ski's outline in the
/// model's own accent (the theme's when it has none), with the model's name
/// along it once the ski is long enough to read. It keeps the trimmed
/// images' long, thin proportions, so every frame a topsheet sits in lays
/// it out the same way.
struct DrawnTopsheet: View {
    let model: SkiModel
    var showsName = true

    /// Length over width of the trimmed topsheet images.
    private static let aspectRatio: CGFloat = 14
    /// Shorter than this the name could not be read, and a picker row
    /// already shows it beside the ski.
    private static let shortestNamed: CGFloat = 200

    private var tint: Color { model.accentHex.map { Color(hex: $0) } ?? HUDTheme.accent }

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            ZStack {
                SkiOutline().fill(tint)
                // Light along the top edge, shade along the bottom: a curved
                // topsheet rather than a flat cut-out.
                SkiOutline().fill(LinearGradient(
                    colors: [.white.opacity(0.3), .clear, .black.opacity(0.25)],
                    startPoint: .top, endPoint: .bottom))
                SkiOutline().stroke(.black.opacity(0.35), lineWidth: 1)
                if showsName, size.width >= Self.shortestNamed {
                    Text(model.model)
                        .textRole(.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(HUDTheme.onAccent)
                        .lineLimit(1)
                        // The ski is about 20 pt across: large text shrinks
                        // to fit it rather than spilling over the edges.
                        .minimumScaleFactor(0.3)
                        // A black outline, as on the ski pair's labels, so
                        // the name reads on a pale accent too.
                        .shadow(color: .black, radius: 0, x: 1, y: 0)
                        .shadow(color: .black, radius: 0, x: -1, y: 0)
                        .shadow(color: .black, radius: 0, x: 0, y: 1)
                        .shadow(color: .black, radius: 0, x: 0, y: -1)
                        .padding(.leading, size.width * 0.14)
                        .padding(.trailing, size.width * 0.08)
                        .frame(maxWidth: .infinity, maxHeight: size.height)
                }
            }
        }
        .aspectRatio(Self.aspectRatio, contentMode: .fit)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(model.displayName) skis")
        // Without the name, a label of the caller's already says it.
        .accessibilityHidden(!showsName)
    }
}

/// A ski seen from above, tip to the left: a rounded, slightly upturned tip,
/// a waist narrower than tip and tail (the sidecut), and a squared-off,
/// rounded tail.
private nonisolated struct SkiOutline: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height
        func at(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + x * w, y: rect.minY + y * h) }
        var path = Path()
        path.move(to: at(0.12, 0))
        // Top edge, in at the waist.
        path.addQuadCurve(to: at(0.92, 0.04), control: at(0.5, 0.2))
        // The tail.
        path.addCurve(to: at(1, 0.5), control1: at(0.97, 0.04), control2: at(1, 0.2))
        path.addCurve(to: at(0.92, 0.96), control1: at(1, 0.8), control2: at(0.97, 0.96))
        // Bottom edge, in at the waist.
        path.addQuadCurve(to: at(0.12, 1), control: at(0.5, 0.8))
        // The tip.
        path.addCurve(to: at(0, 0.5), control1: at(0.05, 1), control2: at(0, 0.78))
        path.addCurve(to: at(0.12, 0), control1: at(0, 0.22), control2: at(0.05, 0))
        path.closeSubpath()
        return path
    }
}

extension View {
    /// A ski's edge and glow: always a dark edge that gives the cut-out
    /// definition on any background; then the glow the user chose in the ski
    /// picker, if on. (`highlight` does not change the colour: the glow is
    /// one free colour.)
    func skiGlow(_ highlight: SkiPairView.Highlight = .none) -> some View {
        modifier(SkiGlowModifier(highlight: highlight))
    }
}

private struct SkiGlowModifier: ViewModifier {
    let highlight: SkiPairView.Highlight

    func body(content: Content) -> some View {
        let manager = ThemeManager.shared
        content
            .shadow(color: .black.opacity(0.55), radius: 1.5)
            .shadow(color: manager.skiGlowOn ? manager.skiGlowColor.opacity(0.9) : .clear, radius: 4)
    }
}
