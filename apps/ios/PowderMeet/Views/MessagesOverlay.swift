import AppCore
import SwiftUI

/// Everything transient the app says: over the map in the row kept for it
/// under the status bar or the meet's pinned instruction (`.top`), and at the bottom of a sheet while one is up (`.bottom`), so a
/// failure is seen wherever the user is. One message at a time, on one line,
/// in one glass chip, never stacked: the connection notice (offline,
/// reconnecting, back online) holds the slot while there is one, then a
/// notification, otherwise the oldest toast. A toast that only repeats what
/// is already on screen (the connection notice, the status dot) is dropped.
struct MessagesOverlay: View {
    enum Placement {
        case top, bottom
    }

    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var placement: Placement = .top
    /// How much of the top the map's chrome covers (`MapTopCoverKey`).
    var coveredTop: CGFloat = 0

    /// What is on screen now.
    private enum Message: Identifiable {
        case connection(ConnectionNotice)
        case banner(InAppBanner)
        case toast(Toast)

        var id: String {
            switch self {
            // One identity for all three, so the chip changes its words in
            // place instead of leaving and coming back.
            case .connection: "connection"
            case .banner(let banner): banner.id.uuidString
            case .toast(let toast): toast.id.uuidString
            }
        }
    }

    private var current: Message? {
        // A notification still interrupts "offline", which can last all day;
        // the two short states are never interrupted.
        if let notice = model.connectionNotice, notice != .offline || model.banner == nil {
            return .connection(notice)
        }
        if let banner = model.banner { return .banner(banner) }
        return model.toasts.first { !repeatsScreen($0) }.map(Message.toast)
    }

    /// The first toast in the queue that the screen already covers, if any.
    private var redundant: Toast? { model.toasts.first(where: repeatsScreen) }

    var body: some View {
        VStack(spacing: 0) {
            if let current {
                row(for: current)
                    .transition(.opacity)
                    .id(current.id)
            }
        }
        // Over the map: under the status bar and the meet's pinned
        // instruction, neither of which may be covered.
        .padding(.top, placement == .top ? MapChrome.messagesTop(covered: coveredTop) : 0)
        .padding(.horizontal, placement == .top ? GlassLayout.inset : 0)
        .animation(.easeInOut(duration: 0.3), value: current?.id)
        // Moves with the instruction as it slides in, opens its steps or folds.
        .animation(MapChrome.motion(reduce: reduceMotion), value: coveredTop)
        // Cleared from the queue so it cannot hold up the messages behind it.
        .task(id: redundant?.id) {
            if let redundant { model.dismissToast(redundant.id) }
        }
    }

    @ViewBuilder
    private func row(for message: Message) -> some View {
        switch message {
        case .connection(let notice):
            ConnectionRow(notice: notice)
        case .banner(let banner):
            MessageRow(
                icon: "bell.fill", tint: HUDTheme.accent,
                text: banner.title.isEmpty ? banner.body : "\(banner.title) · \(banner.body)",
                spoken: banner.title.isEmpty ? banner.body : "\(banner.title). \(banner.body)",
                actionLabel: nil, showsForS: 6, dismiss: { model.dismissBanner() }, act: {}
            )
        case .toast(let toast) where toast.kind == .badge:
            // Said to VoiceOver as it appears: it comes after an import or a
            // run, when the skier is not looking at this row.
            MessageRow(
                icon: "rosette", tint: HUDTheme.accent, text: toast.message,
                spoken: toast.message.replacingOccurrences(of: " · ", with: ": "),
                actionLabel: nil, showsForS: 4, announces: true,
                dismiss: { model.dismissToast(toast.id) }, act: {}
            )
        case .toast(let toast):
            MessageRow(
                icon: toast.recovery == .none ? "info.circle.fill" : "exclamationmark.circle.fill",
                tint: toast.recovery == .none ? HUDTheme.accentCyan : HUDTheme.accentAmber,
                text: Self.headline(toast.message), spoken: toast.message,
                actionLabel: Self.recoveryLabel(toast.recovery), showsForS: 4,
                dismiss: { model.dismissToast(toast.id) },
                act: {
                    if toast.recovery == .openSettings,
                       let settings = URL(string: UIApplication.openSettingsURLString) {
                        openURL(settings)
                    } else {
                        model.perform(toast.recovery)
                    }
                    model.dismissToast(toast.id)
                }
            )
        }
    }

    /// True for a toast that says what the screen is already saying: offline
    /// (or a timeout caused by it) while the connection notice is up, or no live
    /// status while the resort bar's dot says so. `Toast` carries only its
    /// text, so it is matched by text.
    private func repeatsScreen(_ toast: Toast) -> Bool {
        if model.connectionNotice == .offline || model.connectionNotice == .reconnecting,
           toast.message == PowderMeetError.network(.offline).userMessage
            || toast.message == PowderMeetError.network(.timeout).userMessage {
            return true
        }
        return model.resort?.ready != nil
            && toast.message == PowderMeetError.data(.statusUnavailable).userMessage
    }

    /// The first sentence: what happened. The advice after it is the action
    /// button's job, and VoiceOver still reads the whole message.
    private static func headline(_ message: String) -> String {
        guard let end = message.range(of: ". ") else { return message }
        return String(message[..<end.lowerBound])
    }

    private static func recoveryLabel(_ recovery: Recovery) -> String? {
        switch recovery {
        case .retry: "Retry"
        case .openSettings: "Settings"
        case .pickResort: "Pick resort"
        case .signIn, .none: nil
        }
    }
}

/// The connection, in the same chip as every other message. It is not
/// dismissed by a tap or a timer: it says what is true until that changes.
private struct ConnectionRow: View {
    let notice: ConnectionNotice

    private var text: String {
        switch notice {
        case .offline: "No connection · showing what was last loaded"
        case .reconnecting: "Reconnecting"
        case .backOnline: "Connected again"
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            Group {
                switch notice {
                case .offline:
                    Image(systemName: "wifi.slash").foregroundStyle(HUDTheme.accentAmber)
                case .reconnecting:
                    ProgressView().controlSize(.small)
                case .backOnline:
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(HUDTheme.accentGreen)
                }
            }
            .font(.footnote.weight(.semibold))
            .frame(width: 18, height: 18)
            .accessibilityHidden(true)
            Text(text)
                .textRole(.label)
                .fontWeight(.semibold)
                .foregroundStyle(HUDTheme.primaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .contentTransition(.opacity)
        }
        .glassChip()
        .animation(.easeInOut(duration: 0.25), value: notice)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(text)
    }
}

/// The one transient-message style: an icon, one line of text (up to three at
/// the accessibility text sizes, so nothing is cut) and at most one action, on
/// a glass chip. It leaves by itself after a few seconds, or sooner when tapped;
/// with VoiceOver on, one with an action stays four times as long.
private struct MessageRow: View {
    let icon: String
    let tint: Color
    let text: String
    /// The full message, for VoiceOver.
    let spoken: String
    let actionLabel: String?
    let showsForS: Double
    /// Read out by VoiceOver when it appears.
    var announces = false
    let dismiss: () -> Void
    let act: () -> Void

    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            Text(text)
                .textRole(.label)
                .fontWeight(.semibold)
                .foregroundStyle(HUDTheme.primaryText)
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? 3 : 1)
                .minimumScaleFactor(0.8)
                .truncationMode(.tail)
                .accessibilityLabel(spoken)
                // The message is the chip's dismiss control, as a tap is.
                .accessibilityAddTraits(.isButton)
                .accessibilityHint("Dismisses the message")
                .accessibilityAction { dismiss() }
                .accessibilityAction(named: "Dismiss", dismiss)
            if let actionLabel {
                Spacer(minLength: 4)
                Button(action: act) {
                    Text(actionLabel)
                        .textRole(.label)
                        .fontWeight(.semibold)
                        .foregroundStyle(HUDTheme.accent)
                        .minimumInteractiveTarget()
                }
                .buttonStyle(.plain)
            }
        }
        .glassChip()
        .onTapGesture(perform: dismiss)
        .task {
            if announces, voiceOver {
                AccessibilityNotification.Announcement(spoken).post()
            }
            // A VoiceOver user needs time to reach Retry or Settings; it still
            // leaves, so the queue behind it is never held up.
            let seconds = voiceOver && actionLabel != nil ? showsForS * 4 : showsForS
            do {
                try await Task.sleep(for: .seconds(seconds))
            } catch {
                return
            }
            dismiss()
        }
    }
}
