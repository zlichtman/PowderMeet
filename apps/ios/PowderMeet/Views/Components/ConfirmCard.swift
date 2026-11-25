import SwiftUI

/// The app's own question before something is removed, ended or left: a glass
/// card in the middle of the screen over a dimmed map, in place of the
/// system's alert, which opens wherever it likes and looks like another app.
/// One title, one line saying what happens, the way out first and the action
/// second.
struct ConfirmCard: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let title: String
    let message: String
    let confirmTitle: String
    let cancelTitle: String
    let isDestructive: Bool
    let onConfirm: () -> Void
    let onCancel: () -> Void

    @State private var isShown = false

    var body: some View {
        ZStack {
            Color.black.opacity(isShown ? 0.45 : 0)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture(perform: onCancel)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 12) {
                Text(title)
                    .textRole(.section)
                    .foregroundStyle(HUDTheme.primaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                Text(message)
                    .textRole(.label)
                    .foregroundStyle(HUDTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: GlassLayout.gap) {
                    SecondaryButton(title: cancelTitle, action: onCancel)
                    SecondaryButton(title: confirmTitle, destructive: isDestructive, action: onConfirm)
                }
                .padding(.top, 4)
            }
            .frame(maxWidth: 360, alignment: .leading)
            .glassCard()
            .padding(.horizontal, 24)
            .scaleEffect(isShown || reduceMotion ? 1 : 0.92)
            .opacity(isShown ? 1 : 0)
            .accessibilityElement(children: .contain)
            .accessibilityAddTraits(.isModal)
        }
        .onAppear {
            withAnimation(MapChrome.motion(reduce: reduceMotion)) { isShown = true }
        }
    }
}

extension View {
    /// Asks before `action` with the app's own card.
    func confirmCard(
        _ title: String, isPresented: Binding<Bool>, message: String,
        confirm: String, cancel: String = "Cancel", isDestructive: Bool = true,
        action: @escaping () -> Void
    ) -> some View {
        modifier(ConfirmCardPresenter(isPresented: isPresented) {
            ConfirmCard(
                title: title, message: message, confirmTitle: confirm, cancelTitle: cancel,
                isDestructive: isDestructive,
                onConfirm: {
                    isPresented.wrappedValue = false
                    action()
                },
                onCancel: { isPresented.wrappedValue = false })
        })
    }

    /// Asks about one thing (a friend, a run, a map): shown while `item` is
    /// set, and cleared on either answer.
    func confirmCard<Item>(
        item: Binding<Item?>, title: @escaping (Item) -> String, message: @escaping (Item) -> String,
        confirm: String, cancel: String = "Cancel", isDestructive: Bool = true,
        action: @escaping (Item) -> Void
    ) -> some View {
        let isPresented = Binding(get: { item.wrappedValue != nil }, set: { if !$0 { item.wrappedValue = nil } })
        return modifier(ConfirmCardPresenter(isPresented: isPresented) {
            if let value = item.wrappedValue {
                ConfirmCard(
                    title: title(value), message: message(value), confirmTitle: confirm, cancelTitle: cancel,
                    isDestructive: isDestructive,
                    onConfirm: {
                        item.wrappedValue = nil
                        action(value)
                    },
                    onCancel: { item.wrappedValue = nil })
            }
        })
    }
}

/// Puts the card over everything, sheets included, with no slide of its own:
/// the card brings its own short fade.
private struct ConfirmCardPresenter<Card: View>: ViewModifier {
    @Binding var isPresented: Bool
    @ViewBuilder let card: () -> Card

    func body(content: Content) -> some View {
        content
            .fullScreenCover(isPresented: $isPresented) {
                card().presentationBackground(.clear)
            }
            .transaction(value: isPresented) { $0.disablesAnimations = true }
    }
}
