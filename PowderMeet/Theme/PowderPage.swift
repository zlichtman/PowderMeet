import SwiftUI

enum PowderLayout {
    static let pageInset: CGFloat = 20
    static let sectionSpacing: CGFloat = 16
}

/// Branded sheet chrome shared by all standalone panels.
private struct PowderSheetChrome: ViewModifier {
    @Environment(\.dismiss) private var dismiss
    let title: String
    var doneTitle = "Done"
    var showsDone = true
    var doneDisabled = false
    var onDone: (() -> Void)? = nil

    func body(content: Content) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text(title.uppercased())
                    .hudType(.bodyEmph)
                    .tracking(2)
                    .foregroundStyle(HUDTheme.accent)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 8)
                if showsDone {
                    Button {
                        if let onDone { onDone() } else { dismiss() }
                    } label: {
                        Text(doneTitle.uppercased())
                            .hudType(.section)
                            .foregroundColor(HUDTheme.accent)
                            .tracking(1.5)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
                            .background(HUDTheme.cardBackground)
                            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .stroke(HUDTheme.cardBorder, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .disabled(doneDisabled)
                    .opacity(doneDisabled ? 0.4 : 1)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 14)
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background {
            ZStack {
                HUDTheme.mapBackground.ignoresSafeArea()
                MountainLinesTexture(placement: .panel).ignoresSafeArea()
            }
        }
        .tint(HUDTheme.accent)
        .preferredColorScheme(.dark)
        .presentationBackground(HUDTheme.mapBackground)
        .presentationDragIndicator(.visible)
    }
}

extension View {
    func powderSheet(title: String, doneTitle: String = "Done", showsDone: Bool = true,
                     doneDisabled: Bool = false, onDone: (() -> Void)? = nil) -> some View {
        modifier(PowderSheetChrome(title: title, doneTitle: doneTitle, showsDone: showsDone,
                                   doneDisabled: doneDisabled, onDone: onDone))
    }
}
