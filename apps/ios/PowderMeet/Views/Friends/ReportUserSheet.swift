import AppCore
import PowderMeetAPI
import SwiftUI

/// Report a user (App Store guideline 1.2): a reason from the list, an
/// optional note, then the offer to block them. Reached from the friend card,
/// a request's menu and a contact match's menu. Reports go to the owner's
/// review queue; nobody can read them in the app.
struct ReportUserSheet: View {
    @Environment(AppModel.self) private var model

    let target: ReportTarget

    @State private var reason: ReportReason?
    @State private var note = ""
    @FocusState private var writing: Bool

    var body: some View {
        Group {
                HStack(spacing: 12) {
                    AvatarView(userID: target.userID, path: target.avatarURL, name: target.displayName, size: 44)
                    Text(target.displayName)
                        .textRole(.bodyEmph)
                        .foregroundColor(HUDTheme.primaryText)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .glassCard()

                if model.report.sent {
                    sent
                } else {
                    form
                }
        }
        .pageScroll(spacing: GlassLayout.gap)
        .onAppear { model.resetReport() }
        .onDisappear { model.resetReport() }
    }

    // MARK: Form

    private var form: some View {
        VStack(alignment: .leading, spacing: GlassLayout.gap) {
            SectionHeader("What's wrong")
            VStack(spacing: 2) {
                ForEach(ReportReason.allCases, id: \.self) { choice in
                    Button {
                        reason = choice
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: reason == choice ? "largecircle.fill.circle" : "circle")
                                .font(.subheadline)
                                .foregroundColor(reason == choice ? HUDTheme.accent : HUDTheme.secondaryText)
                            Text(Self.label(choice))
                                .textRole(.label)
                                .foregroundColor(HUDTheme.primaryText)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 10)
                        .frame(minHeight: GlassLayout.chipHeight)
                        .background(reason == choice ? HUDTheme.accent.opacity(0.08) : Color.clear)
                        .clipShape(RoundedRectangle(cornerRadius: GlassLayout.innerRadius, style: .continuous))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(reason == choice ? [.isSelected] : [])
                }
            }
            .padding(6)
            .glassCard()

            SectionHeader("Details (optional)")
            TextField("", text: $note, prompt: Text("What happened?").foregroundColor(HUDTheme.secondaryText),
                      axis: .vertical)
                .textRole(.body)
                .foregroundColor(HUDTheme.primaryText)
                .lineLimit(3...6)
                .focused($writing)
                .padding(12)
                .glassField()
                .onChange(of: note) { _, new in
                    if new.count > reportNoteLimit { note = String(new.prefix(reportNoteLimit)) }
                }
                .accessibilityLabel("Details, optional")

            if let failure = model.report.failure {
                Text(failure.userMessage)
                    .textRole(.label)
                    .foregroundColor(HUDTheme.accentRed)
            }

            PrimaryButton(
                title: "Send report", isLoading: model.report.isSending, isEnabled: reason != nil,
                tint: HUDTheme.accentRed
            ) {
                guard let reason else { return }
                writing = false
                model.sendReport(target, reason: reason, note: note)
            }
        }
    }

    // MARK: Sent

    @ViewBuilder
    private var sent: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Report sent", systemImage: "checkmark.circle.fill")
                .textRole(.section)
                .foregroundColor(HUDTheme.accentGreen)
            Text("Thank you. We review every report and act on those that break the rules.")
                .textRole(.label)
                .foregroundColor(HUDTheme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(GlassLayout.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()

        if model.isBlocked(target.userID) {
            Text("\(target.displayName) is blocked.")
                .textRole(.label)
                .foregroundColor(HUDTheme.secondaryText)
        } else {
            PrimaryButton(title: "Block \(target.displayName)", tint: HUDTheme.accentRed) {
                model.block(target.userID)
                model.leavePanelPage(.report(target))
            }
        }
        SecondaryButton(title: "Done") { model.leavePanelPage(.report(target)) }
    }

    static func label(_ reason: ReportReason) -> String {
        switch reason {
        case .inappropriatePhoto: "Inappropriate photo"
        case .inappropriateName: "Offensive name"
        case .harassment: "Harassment or threats"
        case .spam: "Spam or scam"
        case .impersonation: "Pretending to be someone else"
        case .other: "Something else"
        }
    }
}
