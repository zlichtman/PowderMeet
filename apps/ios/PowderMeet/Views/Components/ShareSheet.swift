import SwiftUI
import UIKit

/// The file a share sheet is open for.
nonisolated struct ShareItem: Identifiable, Hashable {
    let url: URL
    var id: URL { url }
}

/// The system share sheet for one file (a bug report, a backup).
struct ShareSheet: UIViewControllerRepresentable {
    let fileURL: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [fileURL], applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
