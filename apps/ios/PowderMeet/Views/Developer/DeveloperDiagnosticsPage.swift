import SwiftUI

/// The connection's state for a tester (`specs/07-CLIENT.md` section 8): short
/// groups of labelled values, refreshed every two seconds, and a copy as text.
struct DeveloperDiagnosticsPage: View {
    @Environment(DeveloperModel.self) private var developer

    var body: some View {
        Group {
            if let note = developer.note {
                ContextNote(icon: "info.circle.fill", text: note)
            }
            ForEach(developer.diagnostics) { group in
                GlassSection(group.title) {
                    ForEach(Array(group.rows.enumerated()), id: \.element.id) { index, row in
                        if index > 0 { GlassDivider() }
                        line(row)
                    }
                }
            }
            SecondaryButton(title: "Copy as text", systemImage: "doc.on.doc") {
                developer.copyDiagnostics()
            }
        }
        .pageScroll()
        .task { await developer.keepDiagnosticsFresh() }
    }

    /// The value at the trailing edge while it fits, else on a line of its own.
    private func line(_ row: DiagnosticsGroup.Row) -> some View {
        let underneath = GlassRow(icon: nil, title: row.label, detail: row.value)
        return Group {
            if row.isLong {
                underneath
            } else {
                ViewThatFits(in: .horizontal) {
                    GlassRow(icon: nil, title: row.label) { GlassValue(text: row.value) }
                    underneath
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}
